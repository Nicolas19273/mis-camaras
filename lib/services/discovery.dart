import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../models/device.dart';

/// Un equipo encontrado en la red WiFi.
class FoundDevice {
  FoundDevice({required this.ip});

  final String ip;
  Brand? brand;
  String? model;
  String? name;
  String? mac;
  String? serial;
  int httpPort = 80;

  /// Canales informados por el equipo (puede ser la capacidad máxima del NVR).
  int? channels;
  bool isRecorder = false;

  /// false = Hikvision sin activar (todavía no tiene contraseña).
  bool activated = true;

  /// Cómo se encontró: SADP, Dahua, ONVIF o HTTP.
  final Set<String> sources = {};

  String get title => model?.isNotEmpty == true ? model! : (name ?? 'Equipo $ip');

  /// Junta datos que llegaron por distintos métodos.
  void mergeFrom(FoundDevice o) {
    brand ??= o.brand;
    if ((model == null || model!.isEmpty) && o.model != null) model = o.model;
    name ??= o.name;
    mac ??= o.mac;
    serial ??= o.serial;
    if (httpPort == 80 && o.httpPort != 80) httpPort = o.httpPort;
    channels ??= o.channels;
    isRecorder = isRecorder || o.isRecorder;
    activated = activated && o.activated;
    sources.addAll(o.sources);
  }
}

/// Busca cámaras y grabadores Hikvision y Dahua en la misma red WiFi.
/// Usa cuatro métodos a la vez, porque no todos los equipos responden a todos:
/// - SADP: búsqueda propia de Hikvision (la que usa su programa SADP).
/// - DHIP: búsqueda propia de Dahua (la que usa ConfigTool), puerto 37810.
/// - ONVIF: búsqueda estándar que entienden casi todas las cámaras.
/// - HTTP: revisa cada dirección de la red buscando la página de Hikvision o Dahua.
class DiscoveryService {
  static const _channel = MethodChannel('mis_camaras/red');

  final _found = <String, FoundDevice>{};
  final _sockets = <RawDatagramSocket>[];
  final _random = Random();
  bool _stopped = false;

  /// IP del teléfono en el WiFi (null si no está conectado a WiFi).
  String? localIp;

  Future<List<FoundDevice>> scan({
    Duration duration = const Duration(seconds: 6),
    void Function(List<FoundDevice> devices)? onUpdate,
  }) async {
    _found.clear();
    _stopped = false;
    void report() => onUpdate?.call(results);

    localIp = await findLocalIp();
    await _multicastLock(true);
    try {
      await Future.wait([
        _guard(() => _sadp(report)),
        _guard(() => _dhip(report)),
        _guard(() => _onvif(report)),
        if (localIp != null) _guard(() => _httpScan(localIp!, report)),
        Future<void>.delayed(duration),
      ]).timeout(duration + const Duration(seconds: 2), onTimeout: () => []);
    } finally {
      stop();
      await _multicastLock(false);
    }
    return results;
  }

  List<FoundDevice> get results {
    final list = _found.values.toList();
    list.sort((a, b) => _ipValue(a.ip).compareTo(_ipValue(b.ip)));
    return list;
  }

  void stop() {
    _stopped = true;
    for (final s in _sockets) {
      s.close();
    }
    _sockets.clear();
  }

  // ---------------------------------------------------------------------------

  Future<void> _guard(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      debugPrint('Búsqueda: $e');
    }
  }

  /// Android descarta los paquetes multicast si la app no lo pide.
  Future<void> _multicastLock(bool on) async {
    try {
      await _channel.invokeMethod(on ? 'multicastLock' : 'multicastUnlock');
    } catch (_) {
      // En otras plataformas no hace falta.
    }
  }

  void _add(FoundDevice d, void Function() report) {
    if (_stopped || d.ip.isEmpty || d.ip == localIp) return;
    final existing = _found[d.ip];
    if (existing == null) {
      _found[d.ip] = d;
    } else {
      existing.mergeFrom(d);
    }
    report();
  }

  Future<RawDatagramSocket> _udp({int port = 0, String? group}) async {
    RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: true);
    } catch (_) {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    }
    socket.broadcastEnabled = true;
    if (group != null) {
      try {
        socket.joinMulticast(InternetAddress(group));
      } catch (_) {}
    }
    _sockets.add(socket);
    return socket;
  }

  void _listen(RawDatagramSocket socket, void Function(Datagram d) onData) {
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = socket.receive();
      if (d != null) onData(d);
    }, onError: (_) {});
  }

  Future<void> _sendTwice(RawDatagramSocket socket, List<int> data, List<(String, int)> targets) async {
    for (var i = 0; i < 2 && !_stopped; i++) {
      for (final (host, port) in targets) {
        try {
          socket.send(data, InternetAddress(host), port);
        } catch (_) {}
      }
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    }
  }

  // --- Hikvision SADP -------------------------------------------------------------

  Future<void> _sadp(void Function() report) async {
    final socket = await _udp(port: 37020, group: '239.255.255.250');
    _listen(socket, (d) {
      final found = parseSadp(utf8.decode(d.data, allowMalformed: true), d.address.address);
      if (found != null) _add(found, report);
    });
    final probe = '<?xml version="1.0" encoding="utf-8"?>'
        '<Probe><Uuid>${_uuid()}</Uuid><Types>inquiry</Types></Probe>';
    await _sendTwice(socket, utf8.encode(probe), [('239.255.255.250', 37020)]);
  }

  // --- Dahua DHIP -----------------------------------------------------------------

  Future<void> _dhip(void Function() report) async {
    final socket = await _udp(port: 37810, group: '239.255.255.251');
    _listen(socket, (d) {
      final found = parseDhip(d.data, d.address.address);
      if (found != null) _add(found, report);
    });
    await _sendTwice(socket, buildDhipSearch(), [
      ('239.255.255.251', 37810),
      ('255.255.255.255', 37810),
    ]);
  }

  // --- ONVIF WS-Discovery ------------------------------------------------------------

  Future<void> _onvif(void Function() report) async {
    final socket = await _udp();
    _listen(socket, (d) {
      final found = parseOnvif(utf8.decode(d.data, allowMalformed: true), d.address.address);
      if (found != null) _add(found, report);
    });
    final probe = '<?xml version="1.0" encoding="UTF-8"?>'
        '<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" '
        'xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" '
        'xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" '
        'xmlns:dn="http://www.onvif.org/ver10/network/wsdl">'
        '<e:Header><w:MessageID>uuid:${_uuid()}</w:MessageID>'
        '<w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>'
        '<w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>'
        '</e:Header><e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe>'
        '</e:Body></e:Envelope>';
    await _sendTwice(socket, utf8.encode(probe), [('239.255.255.250', 3702)]);
  }

  // --- Rastreo HTTP de la red /24 -----------------------------------------------------

  Future<void> _httpScan(String local, void Function() report) async {
    final prefix = local.substring(0, local.lastIndexOf('.') + 1);
    final targets = [for (var i = 1; i < 255; i++) '$prefix$i']..remove(local);
    final client = http.Client();
    var index = 0;

    Future<void> worker() async {
      while (!_stopped && index < targets.length) {
        final ip = targets[index++];
        if (!await _portOpen(ip, 80)) continue;
        final found = await _fingerprint(client, ip);
        if (found != null) _add(found, report);
      }
    }

    try {
      await Future.wait([for (var i = 0; i < 40; i++) worker()]);
    } finally {
      client.close();
    }
  }

  Future<bool> _portOpen(String ip, int port) async {
    try {
      final s = await Socket.connect(ip, port, timeout: const Duration(milliseconds: 500));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<FoundDevice?> _fingerprint(http.Client client, String ip) async {
    const t = Duration(seconds: 2);
    try {
      final d = await client.get(Uri.parse('http://$ip/cgi-bin/magicBox.cgi?action=getDeviceType')).timeout(t);
      if (looksLikeDahua(d.statusCode, d.headers['www-authenticate'])) {
        return FoundDevice(ip: ip)
          ..brand = Brand.dahua
          ..sources.add('HTTP');
      }
      final h = await client.get(Uri.parse('http://$ip/ISAPI/System/deviceInfo')).timeout(t);
      if (looksLikeHikvision(h.statusCode, h.headers['www-authenticate'], h.body)) {
        return FoundDevice(ip: ip)
          ..brand = Brand.hikvision
          ..sources.add('HTTP');
      }
    } catch (_) {}
    return null;
  }

  // ---------------------------------------------------------------------------

  String _uuid() {
    String hex(int n) => List.generate(n, (_) => _random.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-a${hex(3)}-${hex(12)}'.toUpperCase();
  }

  static int _ipValue(String ip) {
    final p = ip.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    return p.length == 4 ? (p[0] << 24) + (p[1] << 16) + (p[2] << 8) + p[3] : 0;
  }

  /// Busca la IP del teléfono en el WiFi (descarta datos móviles).
  static Future<String?> findLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      String? fallback;
      for (final i in interfaces) {
        for (final a in i.addresses) {
          if (!isPrivateIp(a.address)) continue;
          final name = i.name.toLowerCase();
          if (name.startsWith('wlan') || name.startsWith('wl') || name.startsWith('en')) {
            return a.address;
          }
          if (!name.startsWith('rmnet') && !name.startsWith('ccmni')) fallback ??= a.address;
        }
      }
      return fallback;
    } catch (_) {
      return null;
    }
  }
}

// =============================================================================
// Lectura de respuestas (públicas para poder probarlas)
// =============================================================================

bool isPrivateIp(String ip) {
  final p = ip.split('.').map((e) => int.tryParse(e) ?? -1).toList();
  if (p.length != 4) return false;
  if (p[0] == 10) return true;
  if (p[0] == 192 && p[1] == 168) return true;
  if (p[0] == 172 && p[1] >= 16 && p[1] <= 31) return true;
  return false;
}

String? _tag(String xml, String tag) {
  final m = RegExp('<(?:[\\w-]+:)?$tag(?:\\s[^>]*)?>([^<]*)</(?:[\\w-]+:)?$tag>').firstMatch(xml);
  final v = m?.group(1)?.trim();
  return (v == null || v.isEmpty) ? null : v;
}

/// Deduce la marca por el nombre o el modelo (incluye marcas "blancas").
Brand? brandFromText(String text) {
  final t = text.toLowerCase();
  if (t.contains('hikvision') || t.contains('hiwatch') || t.contains('hilook') ||
      RegExp(r'(^|[^a-z])i?ds-').hasMatch(t)) {
    return Brand.hikvision;
  }
  if (t.contains('dahua') || t.contains('lorex') || t.contains('amcrest') || t.contains('imou') ||
      RegExp(r'(^|[^a-z])(dh-|dhi-|ipc-h|sd\d|nvr\d|xvr\d|hcvr)').hasMatch(t)) {
    return Brand.dahua;
  }
  return null;
}

bool _looksLikeRecorder(String text) {
  final t = text.toUpperCase();
  return t.contains('NVR') || t.contains('DVR') || t.contains('XVR') ||
      RegExp(r'I?DS-(7[0-9]|9[0-9])').hasMatch(t);
}

/// Respuesta SADP de Hikvision (XML con <ProbeMatch>).
FoundDevice? parseSadp(String xml, String fromIp) {
  if (!xml.contains('<ProbeMatch')) return null;
  final ip = _tag(xml, 'IPv4Address') ?? fromIp;
  final d = FoundDevice(ip: ip)
    ..brand = Brand.hikvision
    ..model = _tag(xml, 'DeviceDescription')
    ..serial = _tag(xml, 'DeviceSN')
    ..mac = _tag(xml, 'MAC')
    ..sources.add('SADP');
  final port = int.tryParse(_tag(xml, 'HttpPort') ?? '');
  if (port != null && port > 0) d.httpPort = port;
  final digital = int.tryParse(_tag(xml, 'DigitalChannelNum') ?? '') ?? 0;
  final analog = int.tryParse(_tag(xml, 'AnalogChannelNum') ?? '') ?? 0;
  d.isRecorder = digital > 0 || analog > 1 || _looksLikeRecorder(d.model ?? '');
  if (d.isRecorder && digital + analog > 0) d.channels = digital + analog;
  if ((_tag(xml, 'Activated') ?? '').toLowerCase() == 'false') d.activated = false;
  return d;
}

/// Paquete de búsqueda Dahua: encabezado DHIP de 32 bytes + JSON.
Uint8List buildDhipSearch() {
  final body = utf8.encode('{"method":"DHDiscover.search","params":{"mac":"","uni":1}}');
  final header = ByteData(32);
  header.setUint32(0, 0x20, Endian.little);
  header.setUint8(4, 0x44); // D
  header.setUint8(5, 0x48); // H
  header.setUint8(6, 0x49); // I
  header.setUint8(7, 0x50); // P
  header.setUint32(16, body.length, Endian.little);
  header.setUint32(24, body.length, Endian.little);
  return Uint8List.fromList([...header.buffer.asUint8List(), ...body]);
}

/// Respuesta Dahua: encabezado binario + JSON con "deviceInfo".
FoundDevice? parseDhip(List<int> data, String fromIp) {
  final text = utf8.decode(data, allowMalformed: true);
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  Map<String, dynamic> json;
  try {
    json = jsonDecode(text.substring(start, end + 1)) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
  if (json['method'] == 'DHDiscover.search') return null; // nuestro propio paquete

  Map<String, dynamic>? info;
  final params = json['params'];
  if (params is Map<String, dynamic>) {
    final di = params['deviceInfo'];
    info = di is Map<String, dynamic> ? di : params;
  }
  if (info == null) return null;

  String? ip;
  final v4 = info['IPv4Address'];
  if (v4 is Map) ip = v4['IPAddress'] as String?;
  if (v4 is String) ip = v4;
  ip ??= fromIp;

  final type = (info['DeviceType'] ?? '').toString();
  final cls = (info['DeviceClass'] ?? '').toString();
  final vendor = (info['Vendor'] ?? '').toString();
  final d = FoundDevice(ip: ip)
    ..brand = Brand.dahua
    ..model = type.isNotEmpty ? type : null
    ..name = (info['MachineName'] ?? '').toString().isEmpty ? null : info['MachineName'].toString()
    ..mac = info['Mac']?.toString()
    ..serial = info['SerialNo']?.toString()
    ..sources.add(vendor.isEmpty ? 'Dahua' : vendor);
  final port = int.tryParse('${info['HttpPort'] ?? ''}');
  if (port != null && port > 0) d.httpPort = port;
  d.isRecorder = _looksLikeRecorder('$cls $type');
  final remote = int.tryParse('${info['RemoteVideoInputChannels'] ?? ''}') ?? 0;
  final local = int.tryParse('${info['VideoInputChannels'] ?? ''}') ?? 0;
  if (d.isRecorder && remote + local > 0) d.channels = remote + local;
  return d;
}

/// Respuesta ONVIF (ProbeMatches): dirección del servicio y "scopes".
FoundDevice? parseOnvif(String xml, String fromIp) {
  if (!xml.contains('ProbeMatch')) return null;
  final xaddrs = _tag(xml, 'XAddrs') ?? '';
  String ip = fromIp;
  var port = 80;
  for (final addr in xaddrs.split(RegExp(r'\s+'))) {
    final uri = Uri.tryParse(addr);
    if (uri != null && isPrivateIp(uri.host)) {
      ip = uri.host;
      port = uri.hasPort ? uri.port : 80;
      break;
    }
  }
  final scopes = Uri.decodeFull(_tag(xml, 'Scopes') ?? '');
  String? scope(String key) {
    final m = RegExp('onvif://www\\.onvif\\.org/$key/(\\S+)', caseSensitive: false).firstMatch(scopes);
    return m?.group(1)?.replaceAll('_', ' ');
  }

  final hardware = scope('hardware');
  final name = scope('name');
  final d = FoundDevice(ip: ip)
    ..brand = brandFromText('${name ?? ''} ${hardware ?? ''}')
    ..model = hardware
    ..name = name
    ..mac = scope('MAC')
    ..httpPort = port
    ..sources.add('ONVIF');
  d.isRecorder = _looksLikeRecorder('${hardware ?? ''} ${name ?? ''}');
  return d;
}

/// Dahua responde "Digest realm=\"Login to <serie>\"" sin credenciales.
bool looksLikeDahua(int status, String? wwwAuthenticate) =>
    status == 401 && (wwwAuthenticate ?? '').contains('Login to');

/// Hikvision responde a /ISAPI con 401 y un cuerpo "userCheck" o un realm propio.
bool looksLikeHikvision(int status, String? wwwAuthenticate, String body) {
  if (status == 200 && body.contains('<DeviceInfo')) return true;
  if (status != 401) return false;
  final auth = wwwAuthenticate ?? '';
  if (auth.contains('Login to')) return false;
  return body.contains('userCheck') ||
      RegExp(r'realm="(IP Camera|DS-|iDS-|HIK|Hikvision|NVR|DVR)', caseSensitive: false).hasMatch(auth);
}
