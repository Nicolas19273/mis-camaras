import 'dart:async';

import 'package:flutter/foundation.dart';

/// Estado de una cámara en pantalla.
enum LiveStatus { connecting, live, offline }

/// Lleva la cuenta de cuántas cámaras están en vivo o sin conexión,
/// para mostrarlo en la barra superior.
class CameraStatusRegistry extends ChangeNotifier {
  final Map<String, LiveStatus> _status = {};
  bool _notifyPending = false;
  bool _disposed = false;

  int count(LiveStatus s) => _status.values.where((v) => v == s).length;

  int get total => _status.length;

  void set(String key, LiveStatus status) {
    if (_status[key] == status) return;
    _status[key] = status;
    _scheduleNotify();
  }

  void remove(String key) {
    if (_status.remove(key) != null) _scheduleNotify();
  }

  // Avisa a la interfaz fuera del ciclo de dibujo, para evitar errores
  // cuando las cámaras se crean o se destruyen mientras se arma la pantalla.
  void _scheduleNotify() {
    if (_notifyPending || _disposed) return;
    _notifyPending = true;
    scheduleMicrotask(() {
      _notifyPending = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
