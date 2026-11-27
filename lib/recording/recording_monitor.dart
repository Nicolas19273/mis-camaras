import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/device.dart';
import 'recording.dart';
import 'recording_api.dart';

/// Revisa en segundo plano si cada cámara está grabando, para mostrar el
/// "● REC" sobre el video, y mantiene la grabación como la dejó la persona.
///
/// Para que el aviso sea estable:
/// - Si una revisión falla o no trae datos, se conserva lo último que se sabía.
/// - Para pasar de "grabando" a "no está grabando" hacen falta 2 revisiones
///   seguidas que lo confirmen.
/// - Lo último que se sabía queda guardado en el teléfono, así al abrir la
///   app el "● REC" aparece de inmediato.
/// - Si la persona eligió "Mantener siempre así" y el equipo cambia o apaga
///   la grabación, la app la vuelve a dejar como estaba.
///
/// Nunca insiste si la contraseña es incorrecta (para no bloquear el usuario).
class RecordingMonitor extends ChangeNotifier {
  RecordingMonitor._();

  static final instance = RecordingMonitor._();

  static const _every = Duration(minutes: 5);
  static const _grace = Duration(hours: 2);
  static const _enforceEvery = Duration(minutes: 30);
  static const _prefsKey = 'recording_monitor_v1';

  final _states = <String, RecState>{};
  final _bad = <String, int>{};
  final _checked = <String, DateTime>{};
  final _running = <String>{};
  final _authFailed = <String>{};

  /// Lo que la persona eligió mantener: equipo → (canal → modo).
  final _desired = <String, Map<int, RecordMode>>{};
  final _appliedAt = <String, DateTime>{};
  final _enforcedAt = <String, DateTime>{};
  final _lastCheck = <String, DateTime>{};
  final _gaveUp = <String>{};

  Timer? _saveTimer;

  static String _key(String deviceId, int channel) => '$deviceId#$channel';

  // --- Consultas ---------------------------------------------------------------

  RecState stateOf(Device device, int channel) => _states[_key(device.id, channel)] ?? RecState.unknown;

  /// Cuántas de esas cámaras están grabando (o listas para grabar).
  int countRecording(Iterable<CameraRef> cameras) => cameras
      .where((c) => const {RecState.recording, RecState.armed}.contains(stateOf(c.device, c.channel)))
      .length;

  /// Recién configurado: todavía puede no aparecer video nuevo.
  bool inGrace(Device device) {
    final t = _appliedAt[device.id];
    return t != null && DateTime.now().difference(t) < _grace;
  }

  /// true si alguna vez se configuró la grabación de este equipo desde la app.
  bool configured(Device device) => _appliedAt.containsKey(device.id);

  /// true si la app mantiene la grabación de este equipo.
  bool keeps(Device device) => _desired[device.id]?.isNotEmpty ?? false;

  /// Última vez que la app tuvo que volver a activar la grabación.
  DateTime? enforcedAt(Device device) => _enforcedAt[device.id];

  /// Última revisión que respondió bien.
  DateTime? lastCheck(Device device) => _lastCheck[device.id];

  /// true si el equipo vuelve a cambiar la grabación aunque la app la corrija.
  bool gaveUp(Device device) => _gaveUp.contains(device.id);

  // --- Cambios hechos por la persona -----------------------------------------------

  /// Avisa que se acaba de cambiar la grabación desde la app.
  void markApplied(Device device, List<int> channels, RecordMode mode, {required bool keep}) {
    _appliedAt[device.id] = DateTime.now();
    _gaveUp.remove(device.id);
    final want = _desired.putIfAbsent(device.id, () => {});
    for (final ch in channels) {
      if (keep) {
        want[ch] = mode;
      } else {
        want.remove(ch);
      }
      _bad.remove(_key(device.id, ch));
    }
    if (want.isEmpty) _desired.remove(device.id);
    invalidate(device);
    _scheduleSave();
    notifyListeners();
  }

  /// Activa o desactiva "Mantener siempre así" con los modos actuales.
  void setKeep(Device device, bool keep, Map<int, RecordMode> current) {
    if (keep) {
      _desired[device.id] = {
        for (final e in current.entries)
          if (e.value != RecordMode.custom) e.key: e.value,
      };
      _gaveUp.remove(device.id);
    } else {
      _desired.remove(device.id);
    }
    _scheduleSave();
    notifyListeners();
  }

  /// Olvida cuándo se revisó un equipo, para revisarlo de nuevo pronto.
  void invalidate(Device device) {
    _checked.removeWhere((k, _) => k.startsWith('${device.id}|'));
    _authFailed.removeWhere((k) => k.startsWith('${device.id}|'));
  }

  // --- Revisión -------------------------------------------------------------------

  String _signature(Device d) =>
      [d.id, d.host, d.httpPort, d.username, d.password.hashCode, d.channels].join('|');

  /// Revisa los equipos que hace rato no se revisan. No espera: avisa al terminar.
  void refresh(Iterable<Device> devices, {bool force = false}) {
    for (final d in devices) {
      if (!RecordingApi.supports(d)) continue;
      final sig = _signature(d);
      if (_authFailed.contains(sig) || _running.contains(d.id)) continue;
      final last = _checked[sig];
      if (!force && last != null && DateTime.now().difference(last) < _every) continue;
      _checked[sig] = DateTime.now();
      _check(d, sig);
    }
  }

  /// Guarda el resultado de una revisión hecha en la pantalla Grabación.
  void update(Device device, RecordingReport report) {
    _applyReport(device, report);
    _checked[_signature(device)] = DateTime.now();
  }

  void _applyReport(Device d, RecordingReport r) {
    final grace = inGrace(d);
    for (var ch = 1; ch <= d.channels; ch++) {
      final key = _key(d.id, ch);
      final fresh = r.stateOf(ch, inGrace: grace);
      final prev = _states[key];
      // Sin datos nuevos: se mantiene lo que se sabía.
      if (fresh == RecState.unknown && prev != null) continue;
      // De "grabando" a "problema" solo con 2 revisiones seguidas que lo digan.
      if (fresh == RecState.problem && (prev == RecState.recording || prev == RecState.armed)) {
        final n = (_bad[key] ?? 0) + 1;
        _bad[key] = n;
        if (n < 2) continue;
      } else {
        _bad.remove(key);
      }
      _states[key] = fresh;
    }
    _lastCheck[d.id] = DateTime.now();
    _scheduleSave();
    notifyListeners();
  }

  Future<void> _check(Device device, String signature) async {
    _running.add(device.id);
    final api = RecordingApi.forDevice(device)!;
    try {
      final report = await api.report(window: const Duration(hours: 4));
      _applyReport(device, report);
      await _enforce(device, api, report);
    } on RecordingException catch (e) {
      if (e.auth) _authFailed.add(signature);
    } catch (_) {
      // Sin respuesta: se conserva lo que se sabía y se reintenta luego.
    } finally {
      api.close();
      _running.remove(device.id);
    }
  }

  /// Si el equipo cambió la grabación, la vuelve a dejar como la eligió la persona.
  Future<void> _enforce(Device d, RecordingApi api, RecordingReport r) async {
    final want = _desired[d.id];
    if (want == null || want.isEmpty || _gaveUp.contains(d.id)) return;
    final wrong = <RecordMode, List<int>>{};
    for (final e in want.entries) {
      if (e.key > d.channels) continue;
      final have = r.modes[e.key];
      if (have == null || have == e.value) continue;
      wrong.putIfAbsent(e.value, () => []).add(e.key);
    }
    if (wrong.isEmpty) return;
    final last = _enforcedAt[d.id];
    if (last != null && DateTime.now().difference(last) < _enforceEvery) return;

    for (final e in wrong.entries) {
      await api.apply(e.value, e.key);
    }
    _enforcedAt[d.id] = DateTime.now();
    _appliedAt[d.id] = DateTime.now();

    // Si al volver a leer sigue distinto, no se insiste (el equipo no lo acepta).
    try {
      final now = await api.modes();
      final still = wrong.entries.any((e) => e.value.any((ch) => now[ch] != null && now[ch] != e.key));
      if (still) _gaveUp.add(d.id);
    } catch (_) {}
    _scheduleSave();
    notifyListeners();
  }

  // --- Guardar en el teléfono ---------------------------------------------------------

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final states = RecState.values.asNameMap();
      final modes = RecordMode.values.asNameMap();
      (j['states'] as Map<String, dynamic>? ?? {}).forEach((k, v) {
        final s = states[v];
        if (s != null && s != RecState.unknown) _states[k] = s;
      });
      (j['desired'] as Map<String, dynamic>? ?? {}).forEach((id, m) {
        final map = <int, RecordMode>{};
        (m as Map<String, dynamic>).forEach((ch, mode) {
          final c = int.tryParse(ch);
          final value = modes[mode];
          if (c != null && value != null) map[c] = value;
        });
        if (map.isNotEmpty) _desired[id] = map;
      });
      void times(String name, Map<String, DateTime> into) {
        (j[name] as Map<String, dynamic>? ?? {}).forEach((id, t) {
          final d = DateTime.tryParse('$t');
          if (d != null) into[id] = d;
        });
      }

      times('appliedAt', _appliedAt);
      times('enforcedAt', _enforcedAt);
      times('lastCheck', _lastCheck);
    } catch (e) {
      debugPrint('No se pudo leer el estado de grabación guardado: $e');
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _save);
  }

  Future<void> _save() async {
    try {
      Map<String, String> times(Map<String, DateTime> m) =>
          {for (final e in m.entries) e.key: e.value.toIso8601String()};
      final data = {
        'states': {for (final e in _states.entries) e.key: e.value.name},
        'desired': {
          for (final e in _desired.entries)
            e.key: {for (final m in e.value.entries) '${m.key}': m.value.name},
        },
        'appliedAt': times(_appliedAt),
        'enforcedAt': times(_enforcedAt),
        'lastCheck': times(_lastCheck),
      };
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(data));
    } catch (e) {
      debugPrint('No se pudo guardar el estado de grabación: $e');
    }
  }
}
