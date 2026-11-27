import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/device.dart';

/// Guarda y entrega los equipos y las preferencias de la app.
/// - Los datos normales van en SharedPreferences.
/// - Las contraseñas van en el almacenamiento seguro del teléfono
///   (Keychain en iPhone, Keystore en Android).
class AppStore extends ChangeNotifier {
  static const _devicesKey = 'devices_v1';
  static const _columnsKey = 'grid_columns';

  final _secure = const FlutterSecureStorage();
  final List<Device> _devices = [];
  SharedPreferences? _prefs;
  int _gridColumns = 2;

  List<Device> get devices => List.unmodifiable(_devices);

  int get gridColumns => _gridColumns;

  /// Todas las cámaras a mostrar (cada canal de cada equipo).
  List<CameraRef> get cameras => [
        for (final d in _devices)
          for (var ch = 1; ch <= d.channels; ch++) CameraRef(d, ch),
      ];

  Future<void> load() async {
    final prefs = _prefs = await SharedPreferences.getInstance();
    _gridColumns = prefs.getInt(_columnsKey) ?? 2;

    final raw = prefs.getString(_devicesKey);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        for (final item in list) {
          final device = Device.fromJson(item as Map<String, dynamic>);
          final password = await _readPassword(device.id);
          _devices.add(device.copyWith(password: password));
        }
      } catch (e) {
        debugPrint('No se pudieron leer los equipos guardados: $e');
      }
    }
    notifyListeners();
  }

  /// Agrega un equipo nuevo o actualiza uno existente (mismo id).
  Future<void> saveDevice(Device device) async {
    final index = _devices.indexWhere((d) => d.id == device.id);
    if (index >= 0) {
      _devices[index] = device;
    } else {
      _devices.add(device);
    }
    notifyListeners();
    await _secure.write(key: _passKey(device.id), value: device.password);
    await _persist();
  }

  Future<void> deleteDevice(String id) async {
    _devices.removeWhere((d) => d.id == id);
    notifyListeners();
    await _secure.delete(key: _passKey(id));
    await _persist();
  }

  Future<void> setGridColumns(int columns) async {
    _gridColumns = columns;
    notifyListeners();
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setInt(_columnsKey, columns);
  }

  static String newId() => DateTime.now().microsecondsSinceEpoch.toString();

  Future<void> _persist() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    final data = jsonEncode(_devices.map((d) => d.toJson()).toList());
    await prefs.setString(_devicesKey, data);
  }

  Future<String> _readPassword(String id) async {
    try {
      return await _secure.read(key: _passKey(id)) ?? '';
    } catch (e) {
      debugPrint('No se pudo leer la contraseña guardada: $e');
      return '';
    }
  }

  String _passKey(String id) => 'pass_$id';
}
