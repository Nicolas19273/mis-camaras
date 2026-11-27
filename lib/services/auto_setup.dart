import 'dart:async';
import 'dart:io';

import '../models/device.dart';
import '../onvif/onvif_client.dart';
import 'app_store.dart';
import 'camera_http.dart';
import 'device_api.dart';
import 'discovery.dart';

enum SetupResult { added, wrongPassword, unreachable, notActivated, unsupported, inRecorder }

/// Resultado de registrar un equipo encontrado.
class SetupOutcome {
  const SetupOutcome(this.result, {this.device, this.detail});

  final SetupResult result;
  final Device? device;
  final String? detail;
}

/// Registra automáticamente un equipo encontrado en la red:
/// comprueba usuario y contraseña, lee el nombre, el modelo y cuántas
/// cámaras tiene (si es NVR), y lo guarda.
/// Se intenta UNA sola vez con la contraseña, para no bloquear el usuario.
class AutoSetup {
  AutoSetup(this.store);

  final AppStore store;

  Future<SetupOutcome> register(FoundDevice found, String username, String password) async {
    final brand = found.brand;
    if (brand == null) return const SetupOutcome(SetupResult.unsupported);
    if (!found.activated) return const SetupOutcome(SetupResult.notActivated);

    // Cámara que ya se ve dentro de un grabador agregado: no se repite.
    if (!found.isRecorder) {
      final recorder = store.recorderShowing(found.ip);
      if (recorder != null) {
        return SetupOutcome(SetupResult.inRecorder, detail: recorder.name);
      }
    }

    final draft = Device(
      id: AppStore.newId(),
      name: _fallbackName(found),
      brand: brand,
      host: found.ip,
      httpPort: found.httpPort,
      username: username,
      password: password,
      channels: found.channels ?? 1,
      network: store.ensureCurrentNetwork()?.id,
    );

    if (!brand.hasFullApi) return _registerOnvif(draft, found);

    final http = CameraHttp(draft);
    try {
      final info = brand == Brand.hikvision
          ? await _hikvisionInfo(http, found)
          : await _dahuaInfo(http, found);
      if (info == null) return const SetupOutcome(SetupResult.wrongPassword);

      // Nombres que el equipo ya tiene para cada cámara (ej. "Patio").
      var names = <int, String>{};
      final api = DeviceApi(draft.copyWith(channels: info.channels));
      try {
        names = await api.channelNames();
      } catch (_) {
      } finally {
        api.close();
      }
      names.removeWhere((ch, _) => ch < 1 || ch > info.channels);

      // En grabadores: qué cámara hay en cada canal (para no repetirlas).
      var hosts = <int, String>{};
      if (info.channels > 1) {
        final api2 = DeviceApi(draft.copyWith(channels: info.channels));
        try {
          hosts = await api2.channelAddresses();
        } catch (_) {
        } finally {
          api2.close();
        }
      }

      final device = draft.copyWith(
        name: info.name,
        channels: info.channels,
        mac: found.mac,
        channelNames: info.channels > 1 ? names : const {},
        channelHosts: hosts,
      );
      await store.saveDevice(device);
      return SetupOutcome(SetupResult.added, device: device);
    } on TimeoutException {
      return const SetupOutcome(SetupResult.unreachable);
    } on SocketException {
      return const SetupOutcome(SetupResult.unreachable);
    } catch (e) {
      return SetupOutcome(SetupResult.unreachable, detail: '$e');
    } finally {
      http.close();
    }
  }

  // --- Otras marcas (ONVIF) ------------------------------------------------------

  /// Comprueba la contraseña por ONVIF y le pregunta a la cámara cuáles son
  /// sus flujos de video reales (así no hay que adivinar la ruta RTSP).
  Future<SetupOutcome> _registerOnvif(Device draft, FoundDevice found) async {
    final client = OnvifClient(draft);
    try {
      OnvifInfo? info;
      try {
        info = await client.info();
      } on OnvifException catch (e) {
        if (e.auth) return const SetupOutcome(SetupResult.wrongPassword);
      }
      var device = draft;
      if (!found.isRecorder) {
        final streams = await client.detectStreams();
        device = device.copyWith(
          rtspMain: streams.main,
          rtspSub: streams.sub,
          rtspPort: streams.port,
        );
      }
      device = device.copyWith(
        name: _pickName(found.name, info?.model ?? found.model, found),
        mac: found.mac,
      );
      await store.saveDevice(device);
      return SetupOutcome(SetupResult.added, device: device);
    } on OnvifException catch (e) {
      if (e.auth) return const SetupOutcome(SetupResult.wrongPassword);
      return SetupOutcome(SetupResult.unreachable, detail: e.message);
    } on TimeoutException {
      return const SetupOutcome(SetupResult.unreachable);
    } on SocketException {
      return const SetupOutcome(SetupResult.unreachable);
    } catch (e) {
      return SetupOutcome(SetupResult.unreachable, detail: '$e');
    } finally {
      client.close();
    }
  }

  // --- Hikvision ---------------------------------------------------------------

  Future<({String name, int channels})?> _hikvisionInfo(CameraHttp http, FoundDevice found) async {
    final res = await http.get('/ISAPI/System/deviceInfo');
    if (res.statusCode == 401 || res.statusCode == 403) return null;
    if (res.statusCode != 200) throw Exception('deviceInfo ${res.statusCode}');

    final body = res.body;
    final model = _xml(body, 'model') ?? found.model;
    final deviceName = _xml(body, 'deviceName');
    final type = _xml(body, 'deviceType') ?? '';
    final recorder = found.isRecorder || RegExp('NVR|DVR', caseSensitive: false).hasMatch(type);

    var channels = 1;
    if (recorder) {
      channels = await _count(http, '/ISAPI/ContentMgmt/InputProxy/channels', 'InputProxyChannel');
      if (channels == 0) {
        channels = await _count(http, '/ISAPI/System/Video/inputs/channels', 'VideoInputChannel');
      }
      if (channels == 0) channels = found.channels ?? 1;
    }
    return (name: _pickName(deviceName, model, found), channels: channels.clamp(1, 64));
  }

  Future<int> _count(CameraHttp http, String path, String tag) async {
    try {
      final res = await http.get(path);
      if (res.statusCode != 200) return 0;
      return RegExp('<$tag[\\s>]').allMatches(res.body).length;
    } catch (_) {
      return 0;
    }
  }

  // --- Dahua -------------------------------------------------------------------

  Future<({String name, int channels})?> _dahuaInfo(CameraHttp http, FoundDevice found) async {
    final res = await http.get('/cgi-bin/magicBox.cgi?action=getDeviceType');
    if (res.statusCode == 401 || res.statusCode == 403) return null;
    if (res.statusCode != 200) throw Exception('getDeviceType ${res.statusCode}');

    final model = _keyValue(res.body, 'type') ?? found.model;
    final nameRes = await http.get('/cgi-bin/magicBox.cgi?action=getMachineName');
    final machineName = nameRes.statusCode == 200 ? _keyValue(nameRes.body, 'name') : null;
    final recorder = found.isRecorder || RegExp('NVR|XVR|DVR|HCVR', caseSensitive: false).hasMatch(model ?? '');

    var channels = 1;
    if (recorder) {
      final collect = await http.get('/cgi-bin/devVideoInput.cgi?action=getCollect');
      channels = collect.statusCode == 200 ? int.tryParse(_keyValue(collect.body, 'result') ?? '') ?? 0 : 0;
      if (channels <= 1) {
        final max = await http.get(
          '/cgi-bin/magicBox.cgi?action=getProductDefinition&name=MaxRemoteInputChannels',
        );
        if (max.statusCode == 200) {
          channels = int.tryParse(_keyValue(max.body, 'table.MaxRemoteInputChannels') ?? '') ?? channels;
        }
      }
      if (channels <= 0) channels = found.channels ?? 1;
    }
    return (name: _pickName(machineName, model, found), channels: channels.clamp(1, 64));
  }

  // --- Utilidades ----------------------------------------------------------------

  static String _fallbackName(FoundDevice f) {
    final last = f.ip.split('.').last;
    return f.isRecorder ? 'Grabador $last' : 'Cámara $last';
  }

  /// Usa el nombre del equipo si no es uno genérico de fábrica.
  static String _pickName(String? deviceName, String? model, FoundDevice f) {
    final generic = RegExp(r'^(ip ?camera|camera|network video recorder|nvr|dvr|xvr|embedded net dvr)\b',
        caseSensitive: false);
    final n = deviceName?.trim() ?? '';
    if (n.isNotEmpty && !generic.hasMatch(n)) return n;
    final m = model?.trim() ?? '';
    if (m.isNotEmpty) return m;
    return _fallbackName(f);
  }

  static String? _xml(String body, String tag) {
    final m = RegExp('<$tag>([^<]*)</$tag>').firstMatch(body);
    final v = m?.group(1)?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  /// Dahua responde texto "clave=valor".
  static String? _keyValue(String body, String key) {
    for (final line in body.split(RegExp(r'\r?\n'))) {
      final i = line.indexOf('=');
      if (i > 0 && line.substring(0, i).trim() == key) {
        final v = line.substring(i + 1).trim();
        return v.isEmpty ? null : v;
      }
    }
    return null;
  }
}
