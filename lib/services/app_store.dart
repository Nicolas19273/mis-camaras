import 'dart:convert';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/device.dart';
import '../theme.dart';

/// Guarda y entrega los equipos y las preferencias de la app.
/// - Los datos normales van en SharedPreferences.
/// - Las contraseñas van en el almacenamiento seguro del teléfono
///   (Keychain en iPhone, Keystore en Android).
class AppStore extends ChangeNotifier {
  static const _devicesKey = 'devices_v1';
  static const _columnsKey = 'grid_columns';
  static const _accentKey = 'accent_index';
  static const _labelsKey = 'show_labels';
  static const _gridHdKey = 'grid_hd';
  static const _autoUpdateKey = 'auto_update';

  final _secure = const FlutterSecureStorage();
  final List<Device> _devices = [];
  SharedPreferences? _prefs;

  int _gridColumns = 2;
  int _accentIndex = 0;
  bool _showLabels = true;
  bool _gridHd = false;
  bool _autoUpdate = true;

  List<Device> get devices => List.unmodifiable(_devices);

  /// Columnas del mosaico: 1, 2, 3 o 4 (vistas de 1, 4, 9 o 16 cámaras).
  int get gridColumns => _gridColumns;

  Color get accent => accentOptions[_accentIndex];
  int get accentIndex => _accentIndex;

  /// Mostrar el nombre sobre cada cámara en el mosaico.
  bool get showLabels => _showLabels;

  /// Usar alta calidad también en el mosaico (gasta más datos y batería).
  bool get gridHd => _gridHd;

  /// Buscar actualizaciones al abrir la app.
  bool get autoUpdate => _autoUpdate;

  /// Todas las cámaras a mostrar (cada canal visible de cada equipo).
  List<CameraRef> get cameras => [
        for (final d in _devices)
          for (var ch = 1; ch <= d.channels; ch++)
            if (!d.hiddenChannels.contains(ch)) CameraRef(d, ch),
      ];

  Device? deviceById(String id) {
    for (final d in _devices) {
      if (d.id == id) return d;
    }
    return null;
  }

  Future<void> load() async {
    final prefs = _prefs = await SharedPreferences.getInstance();
    _gridColumns = (prefs.getInt(_columnsKey) ?? 2).clamp(1, 4);
    _accentIndex = (prefs.getInt(_accentKey) ?? 0).clamp(0, accentOptions.length - 1);
    _showLabels = prefs.getBool(_labelsKey) ?? true;
    _gridHd = prefs.getBool(_gridHdKey) ?? false;
    _autoUpdate = prefs.getBool(_autoUpdateKey) ?? true;

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

  // --- Equipos --------------------------------------------------------------

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
    await _persistDevices();
  }

  Future<void> deleteDevice(String id) async {
    _devices.removeWhere((d) => d.id == id);
    notifyListeners();
    await _secure.delete(key: _passKey(id));
    await _persistDevices();
  }

  /// Cambia el orden de los equipos (arrastrar en la lista de Equipos).
  Future<void> moveDevice(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex -= 1;
    final d = _devices.removeAt(oldIndex);
    _devices.insert(newIndex, d);
    notifyListeners();
    await _persistDevices();
  }

  /// Marca o desmarca un canal como "no es PTZ".
  Future<void> setNoPtz(String deviceId, int channel, bool noPtz) async {
    final d = deviceById(deviceId);
    if (d == null) return;
    final set = {...d.noPtzChannels};
    noPtz ? set.add(channel) : set.remove(channel);
    await saveDevice(d.copyWith(noPtzChannels: set));
  }

  // --- Respaldo de red (para deshacer un cambio de IP) ------------------------

  /// Guarda la configuración de red anterior de un equipo.
  Future<void> saveNetworkBackup(String deviceId, Map<String, dynamic> data) async {
    await (await _p()).setString('netbackup_$deviceId', jsonEncode(data));
  }

  Map<String, dynamic>? networkBackup(String deviceId) {
    final raw = _prefs?.getString('netbackup_$deviceId');
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // --- Preferencias ----------------------------------------------------------

  Future<void> setGridColumns(int value) async {
    _gridColumns = value.clamp(1, 4);
    notifyListeners();
    await (await _p()).setInt(_columnsKey, _gridColumns);
  }

  Future<void> setAccentIndex(int value) async {
    _accentIndex = value.clamp(0, accentOptions.length - 1);
    notifyListeners();
    await (await _p()).setInt(_accentKey, _accentIndex);
  }

  Future<void> setShowLabels(bool value) async {
    _showLabels = value;
    notifyListeners();
    await (await _p()).setBool(_labelsKey, value);
  }

  Future<void> setGridHd(bool value) async {
    _gridHd = value;
    notifyListeners();
    await (await _p()).setBool(_gridHdKey, value);
  }

  Future<void> setAutoUpdate(bool value) async {
    _autoUpdate = value;
    notifyListeners();
    await (await _p()).setBool(_autoUpdateKey, value);
  }

  static String newId() => DateTime.now().microsecondsSinceEpoch.toString();

  // --- Interno ---------------------------------------------------------------

  Future<SharedPreferences> _p() async => _prefs ??= await SharedPreferences.getInstance();

  Future<void> _persistDevices() async {
    final data = jsonEncode(_devices.map((d) => d.toJson()).toList());
    await (await _p()).setString(_devicesKey, data);
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
