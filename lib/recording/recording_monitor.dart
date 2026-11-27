import 'package:flutter/foundation.dart';

import '../models/device.dart';
import 'recording.dart';
import 'recording_api.dart';

/// Revisa en segundo plano si cada cámara está grabando, para mostrar
/// el "● REC" sobre el video. Cada equipo se revisa como máximo cada
/// 5 minutos, y nunca se insiste si la contraseña es incorrecta
/// (para no bloquear el usuario del equipo).
class RecordingMonitor extends ChangeNotifier {
  RecordingMonitor._();

  static final instance = RecordingMonitor._();

  static const _every = Duration(minutes: 5);

  final _states = <String, RecState>{};
  final _checked = <String, DateTime>{};
  final _running = <String>{};
  final _authFailed = <String>{};

  static String _key(String deviceId, int channel) => '$deviceId#$channel';

  RecState stateOf(Device device, int channel) => _states[_key(device.id, channel)] ?? RecState.unknown;

  /// Cuántas cámaras están grabando (o listas para grabar) de las indicadas.
  int countRecording(Iterable<CameraRef> cameras) => cameras
      .where((c) => const {RecState.recording, RecState.armed}.contains(stateOf(c.device, c.channel)))
      .length;

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
    for (var ch = 1; ch <= device.channels; ch++) {
      _states[_key(device.id, ch)] = report.stateOf(ch);
    }
    _checked[_signature(device)] = DateTime.now();
    notifyListeners();
  }

  /// Olvida lo sabido de un equipo (por ejemplo, después de cambiar su modo).
  void invalidate(Device device) {
    _checked.removeWhere((k, _) => k.startsWith('${device.id}|'));
    _authFailed.removeWhere((k) => k.startsWith('${device.id}|'));
  }

  Future<void> _check(Device device, String signature) async {
    _running.add(device.id);
    final api = RecordingApi.forDevice(device)!;
    try {
      // Para el "● REC" basta con mirar la última hora.
      final report = await api.report(window: const Duration(hours: 2));
      for (var ch = 1; ch <= device.channels; ch++) {
        _states[_key(device.id, ch)] = report.stateOf(ch);
      }
      notifyListeners();
    } on RecordingException catch (e) {
      if (e.auth) _authFailed.add(signature);
    } catch (_) {
      // Sin respuesta: se vuelve a intentar en la próxima revisión.
    } finally {
      api.close();
      _running.remove(device.id);
    }
  }
}
