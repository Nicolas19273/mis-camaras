import '../models/device.dart';
import '../onvif/onvif_client.dart';
import 'camera_http.dart';

/// Datos del equipo leídos por su API.
class DeviceInfo {
  const DeviceInfo({this.name, this.model, this.firmware, this.serial, this.type, this.mac});

  final String? name;
  final String? model;
  final String? firmware;
  final String? serial;
  final String? type;
  final String? mac;
}

class DeviceApiException implements Exception {
  DeviceApiException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Funciones del equipo que no son video: información, reinicio,
/// nombres de canales y modelo de cada cámara.
class DeviceApi {
  DeviceApi(this.device) : _http = CameraHttp(device);

  final Device device;
  final CameraHttp _http;

  bool get _hik => device.brand == Brand.hikvision;

  /// Marcas sin API propia en la app: se usa ONVIF.
  bool get _onvif => !device.brand.hasFullApi;
  OnvifClient? _onvifClient;
  OnvifClient get _ov => _onvifClient ??= OnvifClient(device);

  void close() {
    _http.close();
    _onvifClient?.close();
  }

  Future<DeviceInfo> _onvifInfo() async {
    try {
      final i = await _ov.info();
      return DeviceInfo(model: i.model, firmware: i.firmware, serial: i.serial, type: i.manufacturer);
    } on OnvifException catch (e) {
      throw DeviceApiException(e.auth
          ? 'Usuario o contraseña incorrectos, o sin permiso para esta acción.'
          : 'El equipo no respondió por ONVIF: ${e.message}');
    }
  }

  // --- Información -------------------------------------------------------------

  Future<DeviceInfo> info() async {
    if (_onvif) return _onvifInfo();
    if (_hik) {
      final res = await _http.get('/ISAPI/System/deviceInfo');
      _check(res.statusCode);
      final b = res.body;
      return DeviceInfo(
        name: xmlValue(b, 'deviceName'),
        model: xmlValue(b, 'model'),
        firmware: [xmlValue(b, 'firmwareVersion'), xmlValue(b, 'firmwareReleasedDate')]
            .whereType<String>()
            .join(' '),
        serial: xmlValue(b, 'serialNumber'),
        type: xmlValue(b, 'deviceType'),
        mac: xmlValue(b, 'macAddress'),
      );
    }
    final type = await _http.get('/cgi-bin/magicBox.cgi?action=getDeviceType');
    _check(type.statusCode);
    Future<String?> value(String action, String key) async {
      try {
        final r = await _http.get('/cgi-bin/magicBox.cgi?action=$action');
        return r.statusCode == 200 ? keyValue(r.body, key) : null;
      } catch (_) {
        return null;
      }
    }

    return DeviceInfo(
      model: keyValue(type.body, 'type'),
      name: await value('getMachineName', 'name'),
      serial: await value('getSerialNo', 'sn'),
      firmware: await value('getSoftwareVersion', 'version'),
    );
  }

  // --- Reiniciar ---------------------------------------------------------------

  Future<void> reboot() async {
    if (_onvif) {
      try {
        await _ov.reboot();
        return;
      } on OnvifException catch (e) {
        throw DeviceApiException(e.auth
            ? 'Usuario o contraseña incorrectos, o sin permiso para esta acción.'
            : 'El equipo no aceptó el reinicio: ${e.message}');
      }
    }
    final res = _hik
        ? await _http.put('/ISAPI/System/reboot', '')
        : await _http.get('/cgi-bin/magicBox.cgi?action=reboot');
    _check(res.statusCode);
    if (res.statusCode != 200) {
      throw DeviceApiException('El equipo no aceptó el reinicio (${res.statusCode}).');
    }
  }

  // --- Nombres de los canales -------------------------------------------------------

  /// Nombres que el equipo tiene guardados para cada canal (sin los genéricos).
  Future<Map<int, String>> channelNames() async {
    final result = <int, String>{};
    if (_onvif) return result; // por ahora solo Hikvision y Dahua
    if (_hik) {
      final res = await _http.get('/ISAPI/ContentMgmt/InputProxy/channels');
      if (res.statusCode == 200) {
        for (final block in RegExp(r'<InputProxyChannel[\s>][\s\S]*?</InputProxyChannel>')
            .allMatches(res.body)) {
          final text = block.group(0)!;
          final id = int.tryParse(xmlValue(text, 'id') ?? '');
          final name = xmlValue(text, 'name');
          if (id != null && name != null && !isGenericChannelName(name)) result[id] = name;
        }
      }
      if (result.isEmpty) {
        final r = await _http.get('/ISAPI/System/Video/inputs/channels');
        if (r.statusCode == 200) {
          for (final block in RegExp(r'<VideoInputChannel[\s>][\s\S]*?</VideoInputChannel>')
              .allMatches(r.body)) {
            final text = block.group(0)!;
            final id = int.tryParse(xmlValue(text, 'id') ?? '');
            final name = xmlValue(text, 'name');
            if (id != null && name != null && !isGenericChannelName(name)) result[id] = name;
          }
        }
      }
      return result;
    }
    final res = await _http.get('/cgi-bin/configManager.cgi?action=getConfig&name=ChannelTitle');
    if (res.statusCode == 200) result.addAll(parseDahuaChannelTitles(res.body));
    return result;
  }

  // --- IP de la cámara de cada canal (grabadores) ------------------------------------

  /// IP de cada cámara conectada al grabador (canal → IP). Sirve para
  /// detectar cámaras que también se agregaron solas.
  Future<Map<int, String>> channelAddresses() async {
    if (!device.isRecorder || _onvif) return const {};
    try {
      if (_hik) {
        final r = await _http.get('/ISAPI/ContentMgmt/InputProxy/channels');
        return r.statusCode == 200 ? parseHikvisionChannelAddresses(r.body) : const {};
      }
      final r = await _http.get('/cgi-bin/configManager.cgi?action=getConfig&name=RemoteDevice');
      return r.statusCode == 200 ? parseDahuaChannelAddresses(r.body) : const {};
    } catch (_) {
      return const {};
    }
  }

  // --- Modelo de la cámara de un canal (para saber si puede girar) -------------------

  Future<String?> channelModel(int channel) async {
    try {
      if (_onvif) return device.isRecorder ? null : (await _ov.info()).model;
      if (_hik) {
        if (!device.isRecorder) {
          final r = await _http.get('/ISAPI/System/deviceInfo');
          return r.statusCode == 200 ? xmlValue(r.body, 'model') : null;
        }
        final r = await _http.get('/ISAPI/ContentMgmt/InputProxy/channels/$channel');
        return r.statusCode == 200 ? xmlValue(r.body, 'model') : null;
      }
      if (!device.isRecorder) {
        final r = await _http.get('/cgi-bin/magicBox.cgi?action=getDeviceType');
        return r.statusCode == 200 ? keyValue(r.body, 'type') : null;
      }
      final r = await _http.get('/cgi-bin/configManager.cgi?action=getConfig&name=RemoteDevice');
      return r.statusCode == 200 ? dahuaRemoteModels(r.body)[channel] : null;
    } catch (_) {
      return null;
    }
  }

  void _check(int status) {
    if (status == 401 || status == 403) {
      throw DeviceApiException('Usuario o contraseña incorrectos, o sin permiso para esta acción.');
    }
  }
}

// =============================================================================
// Utilidades (públicas para poder probarlas)
// =============================================================================

String? xmlValue(String xml, String tag) {
  final m = RegExp('<$tag>([^<]*)</$tag>').firstMatch(xml);
  final v = m?.group(1)?.trim();
  return (v == null || v.isEmpty) ? null : v;
}

/// Dahua responde texto "clave=valor".
String? keyValue(String body, String key) {
  for (final line in body.split(RegExp(r'\r?\n'))) {
    final i = line.indexOf('=');
    if (i > 0 && line.substring(0, i).trim() == key) {
      final v = line.substring(i + 1).trim();
      return v.isEmpty ? null : v;
    }
  }
  return null;
}

/// Nombres de fábrica que no aportan ("Camera 01", "IPCamera 02", "CH1"...).
bool isGenericChannelName(String name) {
  final n = name.trim().toLowerCase();
  return n.isEmpty ||
      RegExp(r'^(ip ?camera|camera|ipdome|ip ?dome|channel|canal|ch|cam|ipc|d)\s*[-_ ]?\d*$').hasMatch(n);
}

/// "table.ChannelTitle[0].Name=Patio" → {1: "Patio"} (Dahua numera desde 0).
Map<int, String> parseDahuaChannelTitles(String body) {
  final result = <int, String>{};
  for (final m in RegExp(r'ChannelTitle\[(\d+)\]\.Name=(.*)').allMatches(body)) {
    final ch = int.parse(m.group(1)!) + 1;
    final name = m.group(2)!.trim();
    if (!isGenericChannelName(name)) result[ch] = name;
  }
  return result;
}

/// Modelo de cada cámara conectada a un NVR Dahua (NETCAMERA_INFO_0 = canal 1).
Map<int, String> dahuaRemoteModels(String body) {
  final result = <int, String>{};
  for (final m in RegExp(r'NETCAMERA_INFO_(\d+)\.DeviceType=(.+)').allMatches(body)) {
    final model = m.group(2)!.trim();
    if (model.isNotEmpty) result[int.parse(m.group(1)!) + 1] = model;
  }
  return result;
}

/// ¿Es un modelo de cámara fija (no gira)?
/// true = fija, false = sabemos que gira, null = no se sabe.
bool? isFixedCameraModel(Brand brand, String model) {
  final m = model.toUpperCase().trim();
  if (brand == Brand.hikvision) {
    if (RegExp(r'^I?DS-2(DE|DF|DY|DC|SE|SF|PT|DP|TD)').hasMatch(m)) return false;
    if (RegExp(r'^I?DS-2(CD|CE|CV|XD|XS|PV)').hasMatch(m)) return true;
    return null;
  }
  if (brand != Brand.dahua) return null;
  final bare = m.replaceFirst(RegExp(r'^(DHI?[-_])'), '');
  if (RegExp(r'^(SD\d|PTZ)').hasMatch(bare) || bare.contains('-PT')) return false;
  if (RegExp(r'^IPC-(HFW|HDW|HDBW|HFS|HDS|HDPW|HUM|EB|EW|PFW|PDW|PDBW|HF\d|HD\d)').hasMatch(bare)) {
    return true;
  }
  return null;
}

/// Cámara fija con lente motorizado (zoom óptico): modelos con "Z" en el sufijo.
bool hasMotorizedLens(String model) =>
    RegExp(r'-(Z|ZS|ZE|ZHN|IZS|IZ|VFPS)\b|-I?ZS', caseSensitive: false).hasMatch(model);

/// Hikvision: <InputProxyChannel><id>3</id>...<ipAddress>192.168.1.64</ipAddress>.
Map<int, String> parseHikvisionChannelAddresses(String xml) {
  final result = <int, String>{};
  for (final block in RegExp(r'<InputProxyChannel[\s>][\s\S]*?</InputProxyChannel>').allMatches(xml)) {
    final text = block.group(0)!;
    final id = int.tryParse(xmlValue(text, 'id') ?? '');
    final ip = xmlValue(text, 'ipAddress');
    if (id != null && ip != null && ip != '0.0.0.0') result[id] = ip;
  }
  return result;
}

/// Dahua: NETCAMERA_INFO_0.Address=192.168.1.108 → canal 1 (salta los desactivados).
Map<int, String> parseDahuaChannelAddresses(String body) {
  final result = <int, String>{};
  final disabled = <int>{};
  for (final m in RegExp(r'NETCAMERA_INFO_(\d+)\.Enable=false').allMatches(body)) {
    disabled.add(int.parse(m.group(1)!));
  }
  for (final m in RegExp(r'NETCAMERA_INFO_(\d+)\.Address=(.+)').allMatches(body)) {
    final i = int.parse(m.group(1)!);
    final ip = m.group(2)!.trim();
    if (!disabled.contains(i) && ip.isNotEmpty && ip != '0.0.0.0') result[i + 1] = ip;
  }
  return result;
}
