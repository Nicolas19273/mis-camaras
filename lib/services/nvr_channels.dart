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

  NvrChannel copyWith({String? address, int? port, String? protocol}) => NvrChannel(
        channel: channel,
        address: address ?? this.address,
        key: key,
        port: port ?? this.port,
        enabled: enabled,
        protocol: protocol ?? this.protocol,
        userName: userName,
        mac: mac,
      );
}

/// Protocolo que debería usar el NVR para esa cámara, si el actual no sirve
/// (por ejemplo, una cámara Hikvision agregada con el protocolo propio de Dahua).
String? suggestedProtocol(NvrChannel ch, Device camera, Brand nvrBrand, List<NvrChannel> all) {
  final p = (ch.protocol ?? '').toLowerCase();
  if (p.isEmpty) return null;
  if (nvrBrand == Brand.dahua) {
    final private = p.contains('dahua') || p.contains('private');
    if (camera.brand == Brand.dahua || !private) return null;
    for (final c in all) {
      if ((c.protocol ?? '').toLowerCase() == 'onvif') return c.protocol;
    }
    return 'Onvif';
  }
  if (nvrBrand == Brand.hikvision && camera.brand != Brand.hikvision && p == 'hikvision') return 'ONVIF';
  return null;
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

  static const refusedMessage = 'El NVR respondió "OK" pero no guardó el cambio (algunos NVR Dahua no '
      'dejan cambiar sus cámaras desde fuera).';

  /// Cambia la IP (y opcionalmente puerto, usuario, contraseña o protocolo) de
  /// un canal y lo vuelve a leer para confirmar que de verdad quedó guardado.
  Future<void> update(NvrChannel ch,
      {String? address, int? port, String? user, String? password, String? protocol}) async {
    await _write(ch, address: address, port: port, user: user, password: password, protocol: protocol);
    if (address == null && port == null && protocol == null && user == null) return;
    NvrChannel? after;
    for (final c in await list()) {
      if (c.channel == ch.channel) after = c;
    }
    if (after == null) throw NvrChannelException(refusedMessage);
    final saved = (address == null || after.address == address) &&
        (port == null || after.port == null || after.port == port) &&
        (protocol == null || after.protocol == null || after.protocol == protocol) &&
        (user == null || after.userName == null || after.userName == user);
    if (!saved) throw NvrChannelException(refusedMessage);
  }

  Future<void> _write(NvrChannel ch,
      {String? address, int? port, String? user, String? password, String? protocol}) async {
    if (nvr.brand == Brand.hikvision) {
      final path = '/ISAPI/ContentMgmt/InputProxy/channels/${ch.key}';
      final r = await _http.get(path);
      _check(r.statusCode);
      if (r.statusCode != 200) throw NvrChannelException('El NVR no entregó el canal (${r.statusCode}).');
      final xml = buildHikvisionNvrChannelXml(r.body,
          address: address, port: port, user: user, password: password, protocol: protocol);
      final put = await _http.put(path, xml);
      _check(put.statusCode);
      if (put.statusCode != 200) {
        final why = RegExp(r'<subStatusCode>([^<]+)</subStatusCode>').firstMatch(put.body)?.group(1);
        throw NvrChannelException('El NVR no aceptó el cambio${why != null ? ' ($why)' : ''}.');
      }
      return;
    }
    final params = dahuaNvrChannelParams(ch.key,
        address: address, port: port, user: user, password: password, protocol: protocol);
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

  /// Obliga al NVR a volver a conectarse con la cámara (apaga y prende el canal).
  Future<void> reconnect(NvrChannel ch) async {
    if (nvr.brand == Brand.hikvision) {
      // En Hikvision, volver a guardar el canal lo reconecta.
      await _write(ch);
      return;
    }
    for (final on in [false, true]) {
      final r = await _http.get('/cgi-bin/configManager.cgi?action=setConfig&${ch.key}.Enable=$on');
      _check(r.statusCode);
      if (!on) await Future<void>.delayed(const Duration(seconds: 3));
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
    {String? address, int? port, String? user, String? password, String? protocol}) {
  return [
    if (address != null) '$prefix.Address=$address',
    if (port != null) '$prefix.Port=$port',
    if (protocol != null) '$prefix.ProtocolType=$protocol',
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
    {String? address, int? port, String? user, String? password, String? protocol}) {
  var xml = current;
  String esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  if (address != null) {
    xml = xml.replaceFirst(RegExp(r'<ipAddress>[^<]*</ipAddress>'), '<ipAddress>$address</ipAddress>');
  }
  if (port != null) {
    xml = xml.replaceFirst(RegExp(r'<managePortNo>[^<]*</managePortNo>'), '<managePortNo>$port</managePortNo>');
  }
  if (protocol != null) {
    xml = xml.replaceFirst(RegExp(r'<proxyProtocol>[^<]*</proxyProtocol>'), '<proxyProtocol>$protocol</proxyProtocol>');
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
