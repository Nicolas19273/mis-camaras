import 'dart:convert';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/camera_group.dart';
import '../models/device.dart';
import '../models/network.dart';
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
  static const _brandFilterKey = 'brand_filter';
  static const _groupByBrandKey = 'group_by_brand';
  static const _groupsKey = 'camera_groups_v1';
  static const _networksKey = 'networks_v1';
  static const _separateKey = 'separate_networks';

  final _secure = const FlutterSecureStorage();
  final List<Device> _devices = [];
  final List<CameraGroup> _groups = [];
  final List<KnownNetwork> _networks = [];

  NetInfo? _net;
  KnownNetwork? _here;
  bool _separate = true;
  bool _showAll = false;
  bool _probed = false;
  Set<String> _reachable = {};
  SharedPreferences? _prefs;

  int _gridColumns = 2;
  int _accentIndex = 0;
  bool _showLabels = true;
  bool _gridHd = false;
  bool _autoUpdate = true;
  Brand? _brandFilter;
  bool _groupByBrand = false;

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

  /// Marca elegida en "En vivo" (null = todas).
  Brand? get brandFilter => _brandFilter;

  /// Mostrar las cámaras separadas por marca (con un título por marca).
  bool get groupByBrand => _groupByBrand;

  /// Marcas que hay entre los equipos guardados, en orden fijo.
  List<Brand> get brands {
    final present = cameras.map((c) => c.device.brand).toSet();
    return Brand.values.where(present.contains).toList();
  }

  /// Cámaras de una marca, en el orden de los equipos.
  List<CameraRef> camerasOf(Brand brand) =>
      cameras.where((c) => c.device.brand == brand).toList();

  /// Cámaras como se ven en "En vivo": filtradas por marca y, si está
  /// activado, ordenadas por marca (Hikvision primero, luego Dahua).
  List<CameraRef> get visibleCameras {
    final filter = _brandFilter;
    if (filter != null && brands.contains(filter)) return camerasOf(filter);
    if (_groupByBrand) return [for (final b in brands) ...camerasOf(b)];
    return cameras;
  }

  /// Cámaras a mostrar en En vivo: las de la red actual, sin las ocultas y
  /// cada una una sola vez. Si una cámara se agregó sola y también está en un
  /// grabador, se muestra en el lugar de su canal, pero conectando directo a
  /// la cámara (más estable) y con el "● REC" del grabador, que es quien graba.
  /// Los canales del grabador sin cámara conectada no se muestran.
  List<CameraRef> get cameras => composeCameras(_devices, isHere);

  /// Cómo mostrar una cámara elegida en un grupo: si también está en un NVR,
  /// se conecta directo y el "● REC" sale del NVR (igual que en En vivo).
  CameraRef present(CameraRef c) {
    final d = c.device;
    if (!d.isRecorder) {
      final dup = duplicateOf(d);
      if (dup != null && dup.device.isRecorder && dup.device.host != d.host) {
        return CameraRef(d, c.channel, alias: c.alias, recordedBy: CameraRef(dup.device, dup.channel));
      }
      return c;
    }
    for (final x in _devices) {
      if (x.isRecorder || !isHere(x) || x.hiddenChannels.contains(1)) continue;
      final dup = duplicateOf(x);
      if (dup != null && dup.device.id == d.id && dup.channel == c.channel && x.host != d.host) {
        final nvrName = d.channelNames[c.channel]?.trim() ?? '';
        final own = x.channelNames[1]?.trim() ?? '';
        return CameraRef(x, 1,
            alias: own.isNotEmpty ? own : (nvrName.isNotEmpty ? nvrName : null), recordedBy: c);
      }
    }
    return c;
  }

  /// Canal de un NVR sin cámara conectada (según la lista del propio NVR).
  /// Solo se decide en grabadores cuyos canales de red empiezan en el 1; en
  /// DVR/XVR los primeros canales son analógicos y no aparecen en esa lista.
  bool isEmptyChannel(Device d, int channel) => isEmptyRecorderChannel(d, channel);

  /// Equipos cuya grabación se revisa (las cámaras que graba un NVR no:
  /// su "● REC" sale del NVR).
  List<Device> get monitoredDevices => [
        for (final d in activeDevices)
          if (duplicateOf(d) == null) d,
      ];

  // --- Redes ---------------------------------------------------------------------

  List<KnownNetwork> get networks => List.unmodifiable(_networks);

  /// Red a la que está conectado el teléfono (null = no se sabe todavía).
  NetInfo? get netInfo => _net;

  /// Red conocida en la que está el teléfono (null = otra red o datos móviles).
  KnownNetwork? get currentNetwork => _here;

  /// Mostrar solo los equipos de la red actual.
  bool get separateNetworks => _separate;

  /// Mostrar por ahora también los equipos de otras redes.
  bool get showAllNetworks => _showAll;

  /// true cuando ya se probó qué equipos responden en esta red.
  bool get probed => _probed;

  KnownNetwork? networkById(String? id) {
    for (final n in _networks) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// ¿Este equipo es de la red actual? Los de otras redes quedan "en espera":
  /// no se muestran ni se conectan, para no confundir.
  bool isHere(Device d) {
    if (!_separate || _showAll || _net == null) return true;
    final n = d.network;
    if (n == Device.anyNetwork || !d.isLocalHost) return true;
    if (n == null) return !_probed || _reachable.contains(d.id);
    return _here != null && n == _here!.id;
  }

  /// Equipos de la red actual.
  List<Device> get activeDevices => _devices.where(isHere).toList();

  /// Equipos de otras redes (en espera).
  List<Device> get standbyDevices => _devices.where((d) => !isHere(d)).toList();

  /// Actualiza la red actual. Devuelve true si cambió.
  bool updateNetInfo(NetInfo info) {
    final before = '${_here?.id}|${_net?.wifi}|${_net?.subnet}';
    _net = info;
    var match = matchNetwork(_networks, info);
    if (match != null) {
      final completed = match.adopt(info);
      if (completed.ssid != match.ssid || completed.gateway != match.gateway || completed.name != match.name) {
        _networks[_networks.indexWhere((n) => n.id == match!.id)] = completed;
        match = completed;
        _persistNetworks();
      }
    }
    _here = match;
    final changed = before != '${_here?.id}|${info.wifi}|${info.subnet}';
    if (changed) {
      _probed = false;
      notifyListeners();
    }
    return changed;
  }

  /// La red actual como red conocida (la crea si es nueva).
  KnownNetwork? ensureCurrentNetwork() {
    final here = _here;
    if (here != null) return here;
    final info = _net;
    if (info == null || !info.hasNetwork) return null;
    final n = KnownNetwork(
      id: newId(),
      name: KnownNetwork.defaultName(info),
      subnet: info.subnet!,
      ssid: info.ssid,
      gateway: info.gateway,
    );
    _networks.add(n);
    _here = n;
    _persistNetworks();
    notifyListeners();
    return n;
  }

  /// Equipos que respondieron en esta red (los que todavía no tenían red).
  void setProbed(Set<String> reachable) {
    _probed = true;
    _reachable = reachable;
    notifyListeners();
  }

  Future<void> assignNetwork(Iterable<String> deviceIds, String? networkId) async {
    final ids = deviceIds.toSet();
    for (var i = 0; i < _devices.length; i++) {
      if (!ids.contains(_devices[i].id)) continue;
      _devices[i] = networkId == null
          ? _devices[i].copyWith(clearNetwork: true)
          : _devices[i].copyWith(network: networkId);
    }
    notifyListeners();
    await _persistDevices();
  }

  Future<void> renameNetwork(String id, String name) async {
    final i = _networks.indexWhere((n) => n.id == id);
    if (i < 0 || name.trim().isEmpty) return;
    _networks[i] = _networks[i].copyWith(name: name.trim());
    if (_here?.id == id) _here = _networks[i];
    notifyListeners();
    await _persistNetworks();
  }

  /// Olvida una red: sus equipos vuelven a "sin red" hasta que respondan en alguna.
  Future<void> forgetNetwork(String id) async {
    _networks.removeWhere((n) => n.id == id);
    if (_here?.id == id) _here = null;
    for (var i = 0; i < _devices.length; i++) {
      if (_devices[i].network == id) _devices[i] = _devices[i].copyWith(clearNetwork: true);
    }
    _probed = false;
    notifyListeners();
    await _persistNetworks();
    await _persistDevices();
  }

  void setShowAllNetworks(bool value) {
    _showAll = value;
    notifyListeners();
  }

  Future<void> setSeparateNetworks(bool value) async {
    _separate = value;
    notifyListeners();
    await (await _p()).setBool(_separateKey, value);
  }

  // --- Cámaras repetidas ------------------------------------------------------------

  /// Si [d] es una cámara que ya se ve dentro de un grabador (o el mismo
  /// equipo agregado dos veces), devuelve dónde se ve.
  ({Device device, int channel})? duplicateOf(Device d) => findDuplicate(_devices, d);

  /// Grabador de la red actual que ya muestra la cámara con esa IP.
  Device? recorderShowing(String ip) {
    for (final r in _devices) {
      if (r.isRecorder && isHere(r) && r.channelHosts.values.contains(ip)) return r;
    }
    return null;
  }

  /// Cámaras repetidas (ocultas en En vivo).
  List<Device> get duplicates => _devices.where((d) => duplicateOf(d) != null).toList();

  /// Borra las cámaras repetidas. Si tenían un nombre propio y el canal del
  /// grabador no, el nombre pasa al grabador.
  Future<int> removeDuplicates() async {
    final dups = duplicates;
    for (final d in dups) {
      final where = duplicateOf(d);
      if (where != null && where.device.isRecorder) {
        final r = deviceById(where.device.id)!;
        final current = r.channelNames[where.channel]?.trim() ?? '';
        if (current.isEmpty && d.name.trim().isNotEmpty) {
          await saveDevice(r.copyWith(channelNames: {...r.channelNames, where.channel: d.name.trim()}));
        }
      }
      await deleteDevice(d.id);
    }
    return dups.length;
  }

  Future<void> setKeepDuplicate(Device d, bool keep) async {
    final current = deviceById(d.id);
    if (current != null) await saveDevice(current.copyWith(keepDuplicate: keep));
  }

  /// Todas las cámaras de todos los equipos, incluidas las ocultas del mosaico.
  List<CameraRef> get allCameras => [
        for (final d in _devices)
          for (var ch = 1; ch <= d.channels; ch++) CameraRef(d, ch),
      ];

  // --- Grupos ----------------------------------------------------------------

  /// Grupos armados por la persona, en su orden.
  List<CameraGroup> get groups => List.unmodifiable(_groups);

  /// Cámaras de un grupo (las que todavía existen), en el orden del grupo.
  List<CameraRef> camerasOfGroup(CameraGroup group) => group.resolve(_devices);

  CameraGroup? groupById(String id) {
    for (final g in _groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  /// Crea un grupo nuevo o actualiza uno existente (mismo id).
  Future<void> saveGroup(CameraGroup group) async {
    final index = _groups.indexWhere((g) => g.id == group.id);
    if (index >= 0) {
      _groups[index] = group;
    } else {
      _groups.add(group);
    }
    notifyListeners();
    await _persistGroups();
  }

  Future<void> deleteGroup(String id) async {
    _groups.removeWhere((g) => g.id == id);
    notifyListeners();
    await _persistGroups();
  }

  Future<void> moveGroup(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex -= 1;
    final g = _groups.removeAt(oldIndex);
    _groups.insert(newIndex, g);
    notifyListeners();
    await _persistGroups();
  }

  /// Agrega o saca una cámara de un grupo.
  Future<void> setInGroup(String groupId, CameraRef camera, bool inGroup) async {
    final group = groupById(groupId);
    if (group == null) return;
    final key = CameraGroup.keyOfCamera(camera);
    final members = [...group.members]..remove(key);
    if (inGroup) members.add(key);
    await saveGroup(group.copyWith(members: members));
  }

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
    _groupByBrand = prefs.getBool(_groupByBrandKey) ?? false;
    _separate = prefs.getBool(_separateKey) ?? true;
    final rawNetworks = prefs.getString(_networksKey);
    if (rawNetworks != null) {
      try {
        for (final item in jsonDecode(rawNetworks) as List<dynamic>) {
          _networks.add(KnownNetwork.fromJson(item as Map<String, dynamic>));
        }
      } catch (e) {
        debugPrint('No se pudieron leer las redes guardadas: $e');
      }
    }
    final filter = prefs.getString(_brandFilterKey);
    _brandFilter = null;
    for (final b in Brand.values) {
      if (b.name == filter) _brandFilter = b;
    }

    final rawGroups = prefs.getString(_groupsKey);
    if (rawGroups != null) {
      try {
        for (final item in jsonDecode(rawGroups) as List<dynamic>) {
          _groups.add(CameraGroup.fromJson(item as Map<String, dynamic>));
        }
      } catch (e) {
        debugPrint('No se pudieron leer los grupos guardados: $e');
      }
    }

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
    // Sus cámaras también salen de los grupos.
    var groupsChanged = false;
    for (var i = 0; i < _groups.length; i++) {
      final cleaned = _groups[i].withoutDevice(id);
      if (cleaned.members.length != _groups[i].members.length) {
        _groups[i] = cleaned;
        groupsChanged = true;
      }
    }
    notifyListeners();
    await _secure.delete(key: _passKey(id));
    await _persistDevices();
    if (groupsChanged) await _persistGroups();
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

  Future<void> setBrandFilter(Brand? brand) async {
    _brandFilter = brand;
    notifyListeners();
    final p = await _p();
    brand == null ? await p.remove(_brandFilterKey) : await p.setString(_brandFilterKey, brand.name);
  }

  Future<void> setGroupByBrand(bool value) async {
    _groupByBrand = value;
    notifyListeners();
    await (await _p()).setBool(_groupByBrandKey, value);
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

  Future<void> _persistNetworks() async {
    final data = jsonEncode(_networks.map((n) => n.toJson()).toList());
    await (await _p()).setString(_networksKey, data);
  }

  Future<void> _persistGroups() async {
    final data = jsonEncode(_groups.map((g) => g.toJson()).toList());
    await (await _p()).setString(_groupsKey, data);
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

/// Si [d] es una cámara que ya se ve dentro de un grabador de [devices]
/// (o el mismo equipo agregado dos veces), devuelve dónde se ve.
({Device device, int channel})? findDuplicate(List<Device> devices, Device d) {
  if (d.keepDuplicate || d.isRecorder) return null;
  bool sameNetwork(Device a, Device b) => a.network == null || b.network == null || a.network == b.network;
  final index = devices.indexWhere((x) => x.id == d.id);
  for (var i = 0; i < devices.length; i++) {
    final r = devices[i];
    if (r.id == d.id || !sameNetwork(r, d)) continue;
    if (r.isRecorder) {
      if (r.host == d.host) return (device: r, channel: 1);
      for (final e in r.channelHosts.entries) {
        if (e.value == d.host && e.key <= r.channels) return (device: r, channel: e.key);
      }
    } else if (r.host == d.host && r.httpPort == d.httpPort && i < index) {
      return (device: r, channel: 1);
    }
  }
  return null;
}

/// Canal de un NVR sin cámara conectada (según la lista del propio NVR).
/// Solo se decide en grabadores cuyos canales de red empiezan en el 1; en
/// DVR/XVR los primeros canales son analógicos y no aparecen en esa lista.
bool isEmptyRecorderChannel(Device d, int channel) {
  if (!d.isRecorder || d.channelHosts.isEmpty || !d.channelHosts.containsKey(1)) return false;
  return !d.channelHosts.containsKey(channel);
}

/// Arma la lista de En vivo: cada cámara una sola vez. Si una cámara se
/// agregó sola y también está en un grabador, va en el lugar de su canal,
/// conectando directo a la cámara y con el "● REC" del grabador.
List<CameraRef> composeCameras(List<Device> devices, bool Function(Device) isHere) {
  final covered = <String, Device>{};
  for (final d in devices) {
    final dup = isHere(d) ? findDuplicate(devices, d) : null;
    if (dup != null && dup.device.isRecorder && dup.device.host != d.host && isHere(dup.device)) {
      covered['${dup.device.id}#${dup.channel}'] = d;
    }
  }
  final result = <CameraRef>[];
  for (final d in devices) {
    if (!isHere(d)) continue;
    final dup = findDuplicate(devices, d);
    if (dup != null && (!dup.device.isRecorder || isHere(dup.device))) continue;
    for (var ch = 1; ch <= d.channels; ch++) {
      if (d.hiddenChannels.contains(ch)) continue;
      final direct = covered['${d.id}#$ch'];
      if (direct != null) {
        if (direct.hiddenChannels.contains(1)) continue;
        final own = direct.channelNames[1]?.trim() ?? '';
        final nvrName = d.channelNames[ch]?.trim() ?? '';
        result.add(CameraRef(
          direct,
          1,
          alias: own.isNotEmpty ? own : (nvrName.isNotEmpty ? nvrName : null),
          recordedBy: CameraRef(d, ch),
        ));
        continue;
      }
      if (isEmptyRecorderChannel(d, ch)) continue;
      result.add(CameraRef(d, ch));
    }
  }
  return result;
}

