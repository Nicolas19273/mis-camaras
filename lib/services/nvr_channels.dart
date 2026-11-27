import '../models/device.dart';
import 'camera_http.dart';
import 'device_api.dart' show xmlValue;

/// Una cámara tal como la tiene guardada el NVR en su lista.
class NvrChannel {
  const NvrChannel({
    required this.channel,
    required this.address,
    required this.key,
    this.port,
    this.enabled = true,
    this.protocol,
    this.userName,
    this.mac,
  });

  /// Canal del NVR (1, 2, 3...).
  final int channel;

  /// IP donde el NVR busca la cámara.
  final String address;

  /// Dahua: prefijo de la configuración ("RemoteDevice.uuid:...NETCAMERA_INFO_0").
  /// Hikvision: id del canal.
  final String key;

  /// Puerto con el que el NVR se conecta a la cámara (37777, 8000, 80...).
  final int? port;
  final bool enabled;
  final String? protocol;
  final String? userName;
  final String? mac;
}

class NvrChannelException implements Exception {
  NvrChannelException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Lee y corrige la lista de cámaras del NVR (a qué IP y puerto se conecta).
class NvrChannels {
  NvrChannels(this.nvr) : _http = CameraHttp(nvr);

  final Device nvr;
  final CameraHttp _http;

  static bool supports(Device d) => d.isRecorder && (d.brand == Brand.hikvision || d.brand == Brand.dahua);

  void close() => _http.close();

  void _check(int status) {
    if (status == 401 || status == 403) {
      throw NvrChannelException('Usuario o contraseña del NVR incorrectos, o sin permiso.');
    }
  }

  Future<List<NvrChannel>> list() async {
    if (nvr.brand == Brand.hikvision) {
      final r = await _http.get('/ISAPI/ContentMgmt/InputProxy/channels');
      _check(r.statusCode);
      if (r.statusCode != 200) throw NvrChannelException('El NVR no entregó su lista de cámaras (${r.statusCode}).');
      return parseHikvisionNvrChannels(r.body);
    }
    final r = await _http.get('/cgi-bin/configManager.cgi?action=getConfig&name=RemoteDevice');
    _check(r.statusCode);
    if (r.statusCode != 200) throw NvrChannelException('El NVR no entregó su lista de cámaras (${r.statusCode}).');
    return parseDahuaNvrChannels(r.body);
  }

  /// Cambia la IP (y opcionalmente puerto, usuario y contraseña) de un canal.
  Future<void> update(NvrChannel ch, {String? address, int? port, String? user, String? password}) async {
    if (nvr.brand == Brand.hikvision) {
      final path = '/ISAPI/ContentMgmt/InputProxy/channels/${ch.key}';
      final r = await _http.get(path);
      _check(r.statusCode);
      if (r.statusCode != 200) throw NvrChannelException('El NVR no entregó el canal (${r.statusCode}).');
      final xml = buildHikvisionNvrChannelXml(r.body, address: address, port: port, user: user, password: password);
      final put = await _http.put(path, xml);
      _check(put.statusCode);
      if (put.statusCode != 200) {
        final why = RegExp(r'<subStatusCode>([^<]+)</subStatusCode>').firstMatch(put.body)?.group(1);
        throw NvrChannelException('El NVR no aceptó el cambio${why != null ? ' ($why)' : ''}.');
      }
      return;
    }
    final params = dahuaNvrChannelParams(ch.key, address: address, port: port, user: user, password: password);
    if (params.isEmpty) return;
    final query = params.map((p) {
      final i = p.indexOf('=');
      return '${p.substring(0, i)}=${Uri.encodeComponent(p.substring(i + 1))}';
    }).join('&');
    final r = await _http.get('/cgi-bin/configManager.cgi?action=setConfig&$query');
    _check(r.statusCode);
    if (r.statusCode != 200 || !r.body.contains('OK')) {
      throw NvrChannelException('El NVR no aceptó el cambio (${r.statusCode}).');
    }
  }

  /// ¿El NVR entrega imagen de ese canal? (si la entrega, ya ve la cámara).
  Future<bool?> hasImage(int channel) async {
    try {
      final path = nvr.brand == Brand.hikvision
          ? '/ISAPI/Streaming/channels/${channel * 100 + 1}/picture'
          : '/cgi-bin/snapshot.cgi?channel=$channel';
      final r = await _http.send('GET', path, timeout: const Duration(seconds: 12));
      if (r.statusCode != 200) return null;
      final type = r.headers['content-type'] ?? '';
      if (!type.contains('image')) return null;
      return r.bodyBytes.length > 6000;
    } catch (_) {
      return null;
    }
  }
}

// =============================================================================
// Lectura y armado (públicas para poder probarlas)
// =============================================================================

/// Dahua: "table.RemoteDevice.uuid:System_CONFIG_NETCAMERA_INFO_0.Address=..."
/// (el índice 0 es el canal 1). Se saltan los canales vacíos o apagados.
List<NvrChannel> parseDahuaNvrChannels(String body) {
  final fields = <int, Map<String, String>>{};
  final prefixes = <int, String>{};
  final re = RegExp(r'^(?:table\.)?(RemoteDevice\.[^.=]*?NETCAMERA_INFO_(\d+))\.(\w+)=(.*)$');
  for (final line in body.split(RegExp(r'\r?\n'))) {
    final m = re.firstMatch(line.trim());
    if (m == null) continue;
    final i = int.parse(m.group(2)!);
    prefixes[i] = m.group(1)!;
    fields.putIfAbsent(i, () => {})[m.group(3)!] = m.group(4)!.trim();
  }
  final result = <NvrChannel>[];
  for (final i in fields.keys.toList()..sort()) {
    final f = fields[i]!;
    final address = f['Address'] ?? '';
    if (address.isEmpty || address == '0.0.0.0') continue;
    if (f['Enable'] == 'false') continue;
    result.add(NvrChannel(
      channel: i + 1,
      address: address,
      key: prefixes[i]!,
      port: int.tryParse(f['Port'] ?? ''),
      enabled: f['Enable'] != 'false',
      protocol: f['ProtocolType'],
      userName: f['UserName'],
      mac: f['Mac'],
    ));
  }
  return result;
}

/// Parámetros de setConfig para corregir un canal de Dahua.
List<String> dahuaNvrChannelParams(String prefix,
    {String? address, int? port, String? user, String? password}) {
  return [
    if (address != null) '$prefix.Address=$address',
    if (port != null) '$prefix.Port=$port',
    if (user != null) '$prefix.UserName=$user',
    if (password != null) '$prefix.Password=$password',
    if (address != null || port != null) '$prefix.Enable=true',
  ];
}

/// Hikvision: /ISAPI/ContentMgmt/InputProxy/channels.
List<NvrChannel> parseHikvisionNvrChannels(String xml) {
  final result = <NvrChannel>[];
  for (final block in RegExp(r'<InputProxyChannel[\s>][\s\S]*?</InputProxyChannel>').allMatches(xml)) {
    final text = block.group(0)!;
    final id = int.tryParse(xmlValue(text, 'id') ?? '');
    final ip = xmlValue(text, 'ipAddress');
    if (id == null || ip == null || ip == '0.0.0.0') continue;
    result.add(NvrChannel(
      channel: id,
      address: ip,
      key: '$id',
      port: int.tryParse(xmlValue(text, 'managePortNo') ?? ''),
      protocol: xmlValue(text, 'proxyProtocol'),
      userName: xmlValue(text, 'userName'),
    ));
  }
  return result;
}

/// Arma el canal de Hikvision con la IP, puerto o credenciales nuevas.
String buildHikvisionNvrChannelXml(String current,
    {String? address, int? port, String? user, String? password}) {
  var xml = current;
  String esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  if (address != null) {
    xml = xml.replaceFirst(RegExp(r'<ipAddress>[^<]*</ipAddress>'), '<ipAddress>$address</ipAddress>');
  }
  if (port != null) {
    xml = xml.replaceFirst(RegExp(r'<managePortNo>[^<]*</managePortNo>'), '<managePortNo>$port</managePortNo>');
  }
  if (user != null) {
    xml = xml.replaceFirst(RegExp(r'<userName>[^<]*</userName>'), '<userName>${esc(user)}</userName>');
  }
  if (password != null) {
    if (xml.contains('<password>')) {
      xml = xml.replaceFirst(RegExp(r'<password>[^<]*</password>'), '<password>${esc(password)}</password>');
    } else if (xml.contains('</userName>')) {
      xml = xml.replaceFirst('</userName>', '</userName><password>${esc(password)}</password>');
    }
  }
  return xml;
}
