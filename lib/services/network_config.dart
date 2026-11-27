import 'dart:async';
import 'dart:io';

import '../models/device.dart';
import 'camera_http.dart';
import 'discovery.dart';

/// Configuración de red de un equipo.
class NetSettings {
  const NetSettings({
    required this.dhcp,
    required this.ip,
    required this.mask,
    required this.gateway,
    this.mac,
  });

  final bool dhcp;
  final String ip;
  final String mask;
  final String gateway;
  final String? mac;
}

class NetworkConfigException implements Exception {
  NetworkConfigException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Lee y cambia la IP de un equipo Hikvision (ISAPI) o Dahua (configManager).
class NetworkConfig {
  NetworkConfig(this.device) : _http = CameraHttp(device);

  final Device device;
  final CameraHttp _http;
  String? _hikXml;
  String _dahuaIface = 'eth0';

  static const _hikPath = '/ISAPI/System/Network/interfaces/1/ipAddress';

  void close() => _http.close();

  Future<NetSettings> read() =>
      device.brand == Brand.hikvision ? _readHikvision() : _readDahua();

  /// Aplica la configuración. Si la conexión se corta justo después,
  /// se considera aplicada (el equipo ya cambió de IP).
  Future<void> apply(NetSettings s) async {
    try {
      if (device.brand == Brand.hikvision) {
        await _applyHikvision(s);
      } else {
        await _applyDahua(s);
      }
    } on NetworkConfigException {
      rethrow;
    } on SocketException {
      // Se cortó: el equipo ya está cambiando de IP.
    } on TimeoutException {
      // Igual que arriba.
    } on Exception catch (e) {
      if (!e.toString().contains('Connection')) rethrow;
    }
  }

  // --- Hikvision -------------------------------------------------------------

  Future<NetSettings> _readHikvision() async {
    final res = await _http.get(_hikPath);
    _check(res.statusCode);
    final xml = res.body;
    _hikXml = xml;

    String? mac;
    try {
      final r = await _http.get('/ISAPI/System/Network/interfaces/1');
      if (r.statusCode == 200) mac = xmlTag(r.body, 'MACAddress');
    } catch (_) {}

    return NetSettings(
      dhcp: (xmlTag(xml, 'addressingType') ?? 'static') == 'dynamic',
      ip: xmlTag(xml, 'ipAddress') ?? device.host,
      mask: xmlTag(xml, 'subnetMask') ?? '255.255.255.0',
      gateway: hikvisionGateway(xml) ?? '',
      mac: mac,
    );
  }

  Future<void> _applyHikvision(NetSettings s) async {
    if (_hikXml == null) await _readHikvision();
    final xml = buildHikvisionIpXml(_hikXml!, s);
    final res = await _http.put(_hikPath, xml);
    _check(res.statusCode);
    if (res.statusCode != 200) {
      throw NetworkConfigException('El equipo rechazó el cambio (${res.statusCode}).');
    }
    // Algunos modelos piden reiniciar para aplicar la red.
    if (res.body.contains('rebootRequired') || res.body.contains('<statusCode>7</statusCode>')) {
      try {
        await _http.put('/ISAPI/System/reboot', '');
      } catch (_) {}
    }
  }

  // --- Dahua -----------------------------------------------------------------

  Future<NetSettings> _readDahua() async {
    final res = await _http.get('/cgi-bin/configManager.cgi?action=getConfig&name=Network');
    _check(res.statusCode);
    final kv = parseDahuaTable(res.body, 'table.Network.');
    _dahuaIface = kv['DefaultInterface'] ?? 'eth0';
    final p = '$_dahuaIface.';
    return NetSettings(
      dhcp: kv['${p}DhcpEnable'] == 'true',
      ip: kv['${p}IPAddress'] ?? device.host,
      mask: kv['${p}SubnetMask'] ?? '255.255.255.0',
      gateway: kv['${p}DefaultGateway'] ?? '',
      mac: kv['${p}PhysicalAddress'],
    );
  }

  Future<void> _applyDahua(NetSettings s) async {
    final p = 'Network.$_dahuaIface';
    final query = s.dhcp
        ? '$p.DhcpEnable=true'
        : '$p.DhcpEnable=false&$p.IPAddress=${s.ip}&$p.SubnetMask=${s.mask}&$p.DefaultGateway=${s.gateway}';
    final res = await _http.get('/cgi-bin/configManager.cgi?action=setConfig&$query');
    _check(res.statusCode);
    if (res.statusCode != 200 || !res.body.contains('OK')) {
      throw NetworkConfigException('El equipo rechazó el cambio (${res.statusCode}).');
    }
  }

  // ---------------------------------------------------------------------------

  void _check(int status) {
    if (status == 401 || status == 403) {
      throw NetworkConfigException(
        'Usuario o contraseña incorrectos, o el usuario no tiene permiso para cambiar la red.',
      );
    }
    if (status == 404) {
      throw NetworkConfigException('Este equipo no permite cambiar la red por esta vía.');
    }
  }

  /// Espera hasta que el equipo responda en [host] (máximo [timeout]).
  static Future<bool> waitFor(Device device, String host,
      {Duration timeout = const Duration(seconds: 60)}) async {
    final target = device.copyWith(host: host);
    final path = device.brand == Brand.hikvision
        ? '/ISAPI/System/deviceInfo'
        : '/cgi-bin/magicBox.cgi?action=getDeviceType';
    final end = DateTime.now().add(timeout);
    await Future<void>.delayed(const Duration(seconds: 3));
    while (DateTime.now().isBefore(end)) {
      final http = CameraHttp(target);
      try {
        final res = await http.get(path);
        if (res.statusCode == 200) return true;
      } catch (_) {
        // Todavía no responde.
      } finally {
        http.close();
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    return false;
  }

  /// Busca en la red el equipo con esa MAC (después de pasar a DHCP).
  static Future<String?> findByMac(String mac) async {
    final wanted = normalizeMac(mac);
    if (wanted.isEmpty) return null;
    final found = await DiscoveryService().scan(duration: const Duration(seconds: 8));
    for (final d in found) {
      if (d.mac != null && normalizeMac(d.mac!) == wanted) return d.ip;
    }
    return null;
  }

  /// true si algo responde en esa IP en alguno de esos puertos.
  static Future<bool> hostResponds(String ip, List<int> ports) async {
    for (final port in ports) {
      try {
        final s = await Socket.connect(ip, port, timeout: const Duration(milliseconds: 700));
        s.destroy();
        return true;
      } catch (_) {}
    }
    return false;
  }

  /// Busca una IP libre en la red del teléfono (primero .100 a .199).
  static Future<String?> suggestFreeIp(String phoneIp, Set<String> exclude) async {
    final prefix = phoneIp.substring(0, phoneIp.lastIndexOf('.') + 1);
    final candidates = [
      for (var i = 100; i < 200; i++) '$prefix$i',
      for (var i = 50; i < 100; i++) '$prefix$i',
    ];
    for (final ip in candidates) {
      if (ip == phoneIp || exclude.contains(ip)) continue;
      if (!await ipInUse(ip)) return ip;
    }
    return null;
  }

  /// true si algo ya responde en esa IP (puerto web o de video).
  static Future<bool> ipInUse(String ip) async {
    for (final port in [80, 554, 8000, 37777]) {
      try {
        final s = await Socket.connect(ip, port, timeout: const Duration(milliseconds: 700));
        s.destroy();
        return true;
      } catch (_) {}
    }
    return false;
  }
}

// =============================================================================
// Utilidades (públicas para poder probarlas)
// =============================================================================

String? xmlTag(String xml, String tag) {
  final m = RegExp('<$tag>([^<]*)</$tag>').firstMatch(xml);
  final v = m?.group(1)?.trim();
  return (v == null || v.isEmpty) ? null : v;
}

String? hikvisionGateway(String xml) {
  final m = RegExp(r'<DefaultGateway>\s*<ipAddress>([^<]*)</ipAddress>').firstMatch(xml);
  return m?.group(1)?.trim();
}

/// Arma el XML de Hikvision con la IP nueva, conservando todo lo demás.
String buildHikvisionIpXml(String current, NetSettings s) {
  String replaceFirst(String text, String tag, String value) =>
      text.replaceFirst(RegExp('<$tag>[^<]*</$tag>'), '<$tag>$value</$tag>');

  var xml = replaceFirst(current, 'addressingType', s.dhcp ? 'dynamic' : 'static');
  if (!s.dhcp) {
    // El primer <ipAddress> del documento es el del equipo (los demás
    // están dentro de DefaultGateway, PrimaryDNS, etc.).
    xml = replaceFirst(xml, 'ipAddress', s.ip);
    xml = replaceFirst(xml, 'subnetMask', s.mask);
    xml = xml.replaceFirstMapped(
      RegExp(r'(<DefaultGateway>\s*<ipAddress>)[^<]*(</ipAddress>)'),
      (m) => '${m[1]}${s.gateway}${m[2]}',
    );
  }
  return xml;
}

/// Lee la respuesta "table.Network.eth0.IPAddress=..." de Dahua.
Map<String, String> parseDahuaTable(String body, String prefix) {
  final map = <String, String>{};
  for (final line in body.split(RegExp(r'\r?\n'))) {
    final i = line.indexOf('=');
    if (i <= 0) continue;
    var key = line.substring(0, i).trim();
    if (key.startsWith(prefix)) key = key.substring(prefix.length);
    map[key] = line.substring(i + 1).trim();
  }
  return map;
}

String normalizeMac(String mac) => mac.toLowerCase().replaceAll(RegExp('[^0-9a-f]'), '');

bool isValidIpv4(String ip) {
  final parts = ip.trim().split('.');
  if (parts.length != 4) return false;
  return parts.every((p) {
    final n = int.tryParse(p);
    return n != null && n >= 0 && n <= 255 && p == '$n';
  });
}

int ipToInt(String ip) =>
    ip.split('.').map(int.parse).fold(0, (acc, n) => (acc << 8) | n);

/// Máscara válida: unos seguidos de ceros (255.255.255.0, 255.255.0.0, etc.).
bool isValidMask(String mask) {
  if (!isValidIpv4(mask)) return false;
  final v = ipToInt(mask);
  if (v == 0) return false;
  final inverted = (~v) & 0xFFFFFFFF;
  return (inverted & (inverted + 1)) == 0;
}

bool sameSubnet(String a, String b, String mask) =>
    (ipToInt(a) & ipToInt(mask)) == (ipToInt(b) & ipToInt(mask));
