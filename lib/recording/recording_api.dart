import 'dart:math';

import '../models/device.dart';
import '../services/camera_http.dart';
import '../services/device_api.dart' show keyValue;
import 'recording.dart';

class RecordingException implements Exception {
  RecordingException(this.message, {this.auth = false});
  final String message;

  /// true = usuario o contraseña incorrectos (no se reintenta solo).
  final bool auth;

  @override
  String toString() => message;
}

/// Resultado de cambiar el modo de grabación.
class ApplyResult {
  ApplyResult(this.ok, this.failed, this.warnings);

  final List<int> ok;
  final Map<int, String> failed;
  final List<String> warnings;
}

/// Grabación de un equipo: discos, horario y videos grabados.
/// Por ahora Hikvision (ISAPI) y Dahua (API HTTP).
abstract class RecordingApi {
  RecordingApi(this.device) : http = CameraHttp(device);

  final Device device;
  final CameraHttp http;

  static bool supports(Device d) => d.brand == Brand.hikvision || d.brand == Brand.dahua;

  static RecordingApi? forDevice(Device d) => switch (d.brand) {
        Brand.hikvision => HikvisionRecording(d),
        Brand.dahua => DahuaRecording(d),
        _ => null,
      };

  /// Cuánto puede tener el último video para decir "está grabando ahora".
  Duration get tolerance;

  Future<DateTime> deviceTime();
  Future<List<StorageDisk>> storage();
  Future<Map<int, RecordMode>> modes();
  Future<Map<int, DateTime?>> lastRecordings(List<int> channels, DateTime from, DateTime to);
  Future<ApplyResult> apply(List<int> channels, RecordMode mode);
  Future<void> format(StorageDisk disk);

  /// Avance del formateo (0-100), o null si ya terminó o no se sabe.
  Future<int?> formatProgress(StorageDisk disk) async => null;

  void close() => http.close();

  List<int> get allChannels => [for (var c = 1; c <= device.channels; c++) c];

  /// Revisión completa: discos, modo de cada cámara y su último video.
  Future<RecordingReport> report({Duration window = const Duration(hours: 24)}) async {
    final now = await deviceTime();
    final disks = await storage();
    final modes = await this.modes();
    final active = allChannels.where((c) => modes[c] != RecordMode.off).toList();
    final last = disks.any((d) => d.ok) && active.isNotEmpty
        ? await lastRecordings(active, now.subtract(window), now.add(const Duration(hours: 1)))
        : <int, DateTime?>{};
    return RecordingReport(
      disks: disks,
      modes: modes,
      lastEnd: last,
      deviceNow: now,
      tolerance: tolerance,
    );
  }

  void checkAuth(int status) {
    if (status == 401 || status == 403) {
      throw RecordingException(
        'Usuario o contraseña incorrectos, o el usuario no tiene permiso para la grabación.',
        auth: true,
      );
    }
  }
}

// =============================================================================
// Hikvision
// =============================================================================

class HikvisionRecording extends RecordingApi {
  HikvisionRecording(super.device);

  final _random = Random();

  @override
  Duration get tolerance => const Duration(minutes: 15);

  String _searchId() {
    String hex(int n) => List.generate(n, (_) => _random.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-${hex(4)}-${hex(4)}-${hex(12)}'.toUpperCase();
  }

  static String? _error(String body) {
    final m = RegExp(r'<subStatusCode>([^<]+)</subStatusCode>').firstMatch(body) ??
        RegExp(r'<statusString>([^<]+)</statusString>').firstMatch(body);
    return m?.group(1)?.trim();
  }

  @override
  Future<DateTime> deviceTime() async {
    try {
      final r = await http.get('/ISAPI/System/time');
      checkAuth(r.statusCode);
      if (r.statusCode == 200) {
        final t = parseDeviceTime(RegExp(r'<localTime>([^<]+)</localTime>').firstMatch(r.body)?.group(1));
        if (t != null) return t;
      }
    } on RecordingException {
      rethrow;
    } catch (_) {}
    return DateTime.now();
  }

  @override
  Future<List<StorageDisk>> storage() async {
    final r = await http.get('/ISAPI/ContentMgmt/Storage');
    checkAuth(r.statusCode);
    if (r.statusCode == 200) return parseHikvisionStorage(r.body);
    final h = await http.get('/ISAPI/ContentMgmt/Storage/hdd');
    checkAuth(h.statusCode);
    if (h.statusCode == 200) return parseHikvisionStorage(h.body);
    if (r.statusCode == 404 && h.statusCode == 404) return const [];
    throw RecordingException('El equipo no informó sus discos (${r.statusCode}).');
  }

  @override
  Future<Map<int, RecordMode>> modes() async {
    final result = <int, RecordMode>{};
    // Primero todas las pistas de una vez; si no se puede, una por una.
    try {
      final r = await http.get('/ISAPI/ContentMgmt/record/tracks');
      checkAuth(r.statusCode);
      if (r.statusCode == 200) {
        for (final m in RegExp(r'<Track(?:\s[^>]*)?>([\s\S]*?)</Track>').allMatches(r.body)) {
          final id = int.tryParse(RegExp(r'<id>\s*(\d+)\s*</id>').firstMatch(m.group(1)!)?.group(1) ?? '');
          if (id == null || id % 100 != 1) continue;
          final ch = id ~/ 100;
          if (ch >= 1 && ch <= device.channels) result[ch] = parseHikvisionTrackMode(m.group(0)!);
        }
      }
    } on RecordingException {
      rethrow;
    } catch (_) {}
    for (final ch in allChannels) {
      if (result.containsKey(ch)) continue;
      final r = await http.get('/ISAPI/ContentMgmt/record/tracks/${hikvisionTrack(ch)}');
      checkAuth(r.statusCode);
      if (r.statusCode == 200) result[ch] = parseHikvisionTrackMode(r.body);
    }
    return result;
  }

  Future<DateTime?> _lastIn(int channel, DateTime from, DateTime to) async {
    final id = _searchId();
    DateTime? last;
    var position = 0;
    for (var page = 0; page < 6; page++) {
      final body = buildHikvisionSearch(id, [hikvisionTrack(channel)], from, to, position: position, maxResults: 50);
      final r = await http.send('POST', '/ISAPI/ContentMgmt/search', body: body, contentType: 'application/xml');
      checkAuth(r.statusCode);
      if (r.statusCode != 200) break;
      final parsed = parseHikvisionSearch(r.body);
      for (final s in parsed.spans) {
        if (last == null || s.end.isAfter(last)) last = s.end;
      }
      if (!parsed.more || parsed.spans.isEmpty) break;
      position += parsed.spans.length;
    }
    return last;
  }

  @override
  Future<Map<int, DateTime?>> lastRecordings(List<int> channels, DateTime from, DateTime to) async {
    final result = <int, DateTime?>{};
    for (final ch in channels) {
      try {
        // Primero las últimas 2 horas (rápido); si no hay nada, todo el rango.
        final recentFrom = to.subtract(const Duration(hours: 3));
        var last = await _lastIn(ch, recentFrom.isAfter(from) ? recentFrom : from, to);
        if (last == null && recentFrom.isAfter(from)) last = await _lastIn(ch, from, to);
        result[ch] = last;
      } on RecordingException {
        rethrow;
      } catch (_) {
        result[ch] = null;
      }
    }
    return result;
  }

  @override
  Future<ApplyResult> apply(List<int> channels, RecordMode mode) async {
    final ok = <int>[];
    final failed = <int, String>{};
    final warnings = <String>[];
    for (final ch in channels) {
      final path = '/ISAPI/ContentMgmt/record/tracks/${hikvisionTrack(ch)}';
      try {
        final r = await http.get(path);
        checkAuth(r.statusCode);
        if (r.statusCode != 200) {
          failed[ch] = r.statusCode == 404 ? 'No tiene dónde grabar' : 'Respondió ${r.statusCode}';
          continue;
        }
        final put = await http.put(path, buildHikvisionTrack(r.body, mode));
        checkAuth(put.statusCode);
        if (put.statusCode != 200) {
          failed[ch] = _error(put.body) ?? 'Respondió ${put.statusCode}';
          continue;
        }
        ok.add(ch);
        if (mode == RecordMode.motion) {
          final w = await _enableMotion(ch);
          if (w != null) warnings.add(w);
        }
      } on RecordingException {
        rethrow;
      } catch (_) {
        failed[ch] = 'No respondió';
      }
    }
    return ApplyResult(ok, failed, warnings);
  }

  /// Activa la detección de movimiento y su aviso "grabar".
  Future<String?> _enableMotion(int ch) async {
    final label = device.isRecorder ? 'Cámara $ch' : 'La cámara';
    final paths = device.isRecorder
        ? [
            '/ISAPI/ContentMgmt/InputProxy/channels/$ch/video/motionDetection',
            '/ISAPI/System/Video/inputs/channels/$ch/motionDetection',
          ]
        : ['/ISAPI/System/Video/inputs/channels/1/motionDetection'];
    var motionOk = false;
    for (final p in paths) {
      try {
        final r = await http.get(p);
        if (r.statusCode != 200) continue;
        final m = RegExp(r'<enabled>\s*(true|false)\s*</enabled>').firstMatch(r.body);
        if (m == null) continue;
        if (m.group(1) == 'true') {
          motionOk = true;
          break;
        }
        final put = await http.put(p, r.body.replaceRange(m.start, m.end, '<enabled>true</enabled>'));
        if (put.statusCode == 200) {
          motionOk = true;
          break;
        }
      } catch (_) {}
    }
    var linkOk = false;
    try {
      final tp = '/ISAPI/Event/triggers/VMD-${device.isRecorder ? ch : 1}';
      final r = await http.get(tp);
      if (r.statusCode == 200) {
        final updated = addHikvisionRecordLinkage(r.body, device.isRecorder ? ch : 1);
        if (updated == null) {
          linkOk = true;
        } else {
          linkOk = (await http.put(tp, updated)).statusCode == 200;
        }
      }
    } catch (_) {}
    if (motionOk && linkOk) return null;
    if (!motionOk) {
      return '$label: no se pudo activar la detección de movimiento. Actívala en su página web.';
    }
    return '$label: revisa en su página web que el movimiento tenga marcado "Activar grabación".';
  }

  @override
  Future<void> format(StorageDisk disk) async {
    final r = await http.put('/ISAPI/ContentMgmt/Storage/hdd/${disk.id}/format', '');
    checkAuth(r.statusCode);
    if (r.statusCode != 200) {
      throw RecordingException(_error(r.body) ?? 'El equipo no aceptó el formateo (${r.statusCode}).');
    }
  }

  @override
  Future<int?> formatProgress(StorageDisk disk) async {
    try {
      final r = await http.get('/ISAPI/ContentMgmt/Storage/hdd/${disk.id}/formatStatus');
      if (r.statusCode != 200) return null;
      final busy = RegExp(r'<formating>\s*true', caseSensitive: false).hasMatch(r.body);
      final p = int.tryParse(RegExp(r'<percent>\s*(\d+)').firstMatch(r.body)?.group(1) ?? '');
      return busy ? (p ?? 0) : null;
    } catch (_) {
      return null;
    }
  }
}

// =============================================================================
// Dahua
// =============================================================================

class DahuaRecording extends RecordingApi {
  DahuaRecording(super.device);

  String? _recordBody;

  /// Dahua guarda en archivos de hasta 1 hora: el actual puede no aparecer aún.
  @override
  Duration get tolerance => const Duration(minutes: 75);

  Future<String> _get(String path) async {
    final r = await http.get(path);
    checkAuth(r.statusCode);
    if (r.statusCode != 200) throw RecordingException('El equipo respondió ${r.statusCode}.');
    return r.body;
  }

  Future<String?> _tryGet(String path) async {
    try {
      return await _get(path);
    } on RecordingException catch (e) {
      if (e.auth) rethrow;
      return null;
    } catch (_) {
      return null;
    }
  }

  static String _param(String p) {
    final i = p.indexOf('=');
    return '${p.substring(0, i)}=${Uri.encodeComponent(p.substring(i + 1))}';
  }

  Future<bool> _setConfig(List<String> params) async {
    final r = await http.get('/cgi-bin/configManager.cgi?action=setConfig&${params.map(_param).join('&')}');
    checkAuth(r.statusCode);
    return r.statusCode == 200 && r.body.contains('OK');
  }

  @override
  Future<DateTime> deviceTime() async {
    final body = await _tryGet('/cgi-bin/global.cgi?action=getCurrentTime');
    return parseDeviceTime(body) ?? DateTime.now();
  }

  @override
  Future<List<StorageDisk>> storage() async {
    final body = await _tryGet('/cgi-bin/storageDevice.cgi?action=getDeviceAllInfo');
    return body == null ? const [] : parseDahuaStorage(body);
  }

  @override
  Future<Map<int, RecordMode>> modes() async {
    final mode = await _tryGet('/cgi-bin/configManager.cgi?action=getConfig&name=RecordMode') ?? '';
    final record = await _get('/cgi-bin/configManager.cgi?action=getConfig&name=Record');
    _recordBody = record;
    return parseDahuaModes(mode, record, device.channels);
  }

  @override
  Future<Map<int, DateTime?>> lastRecordings(List<int> channels, DateTime from, DateTime to) async {
    final result = <int, DateTime?>{};
    final created = await _tryGet('/cgi-bin/mediaFileFind.cgi?action=factory.create');
    final object = created == null ? null : keyValue(created, 'result');
    if (object == null) return result;
    final start = Uri.encodeComponent(dahuaTime(from));
    final end = Uri.encodeComponent(dahuaTime(to));
    try {
      for (final ch in channels) {
        DateTime? last;
        final found = await _tryGet('/cgi-bin/mediaFileFind.cgi?action=findFile&object=$object'
            '&condition.Channel=$ch&condition.StartTime=$start&condition.EndTime=$end&condition.Types[0]=dav');
        if (found != null) {
          for (var page = 0; page < 10; page++) {
            final next = await _tryGet('/cgi-bin/mediaFileFind.cgi?action=findNextFile&object=$object&count=100');
            if (next == null) break;
            final t = parseDahuaLastFileEnd(next);
            if (t != null && (last == null || t.isAfter(last))) last = t;
            final count = int.tryParse(keyValue(next, 'found') ?? '') ?? 0;
            if (count < 100) break;
          }
          await _tryGet('/cgi-bin/mediaFileFind.cgi?action=close&object=$object');
        }
        result[ch] = last;
      }
    } finally {
      await _tryGet('/cgi-bin/mediaFileFind.cgi?action=destroy&object=$object');
    }
    return result;
  }

  @override
  Future<ApplyResult> apply(List<int> channels, RecordMode mode) async {
    final ok = <int>[];
    final failed = <int, String>{};
    final warnings = <String>[];
    final record = _recordBody ?? await _tryGet('/cgi-bin/configManager.cgi?action=getConfig&name=Record') ?? '';
    final holiday = record.contains('TimeSection[7]');
    for (final ch in channels) {
      final i = ch - 1;
      try {
        final params = dahuaModeParams(i, mode, slotsPerDay: dahuaSlotsPerDay(record, i), holiday: holiday);
        // Primero el horario (en partes, para no armar direcciones muy largas) y al final el modo.
        final schedule = params.where((p) => p.startsWith('Record[')).toList();
        final modeParams = params.where((p) => p.startsWith('RecordMode[')).toList();
        var good = true;
        for (var k = 0; k < schedule.length && good; k += 12) {
          good = await _setConfig(schedule.sublist(k, min(k + 12, schedule.length)));
        }
        if (good) good = await _setConfig(modeParams);
        if (!good) {
          failed[ch] = 'No aceptó el cambio';
          continue;
        }
        ok.add(ch);
        if (mode == RecordMode.motion) {
          final motion = await _setConfig([
            'MotionDetect[$i].Enable=true',
            'MotionDetect[$i].EventHandler.RecordEnable=true',
            'MotionDetect[$i].EventHandler.RecordChannels[0]=$i',
          ]);
          if (!motion) {
            warnings.add('${device.isRecorder ? 'Cámara $ch' : 'La cámara'}: no se pudo activar la detección '
                'de movimiento. Actívala en su página web.');
          }
        }
      } on RecordingException {
        rethrow;
      } catch (_) {
        failed[ch] = 'No respondió';
      }
    }
    _recordBody = null;
    return ApplyResult(ok, failed, warnings);
  }

  @override
  Future<void> format(StorageDisk disk) async {
    final path = disk.path;
    if (path == null) throw RecordingException('No se sabe qué disco formatear.');
    final r = await http.get('/cgi-bin/storageDevice.cgi?action=setDevice&type=FormatPatition&path=$path');
    checkAuth(r.statusCode);
    if (r.statusCode != 200 || !(r.body.contains('OK') || r.body.contains('true'))) {
      throw RecordingException('El equipo no aceptó el formateo (${r.statusCode}).');
    }
  }
}
