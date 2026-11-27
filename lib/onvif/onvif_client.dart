import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../models/device.dart';
import '../services/camera_http.dart';

/// Un perfil de video ONVIF (normalmente: principal, secundario, tercero).
class OnvifProfile {
  const OnvifProfile({
    required this.token,
    this.width = 0,
    this.height = 0,
    this.encoding = '',
    this.hasPtz = false,
  });

  final String token;
  final int width;
  final int height;
  final String encoding;
  final bool hasPtz;

  int get pixels => width * height;
  bool get isJpeg => encoding.toUpperCase().contains('JPEG');
}

/// Información del equipo según ONVIF.
class OnvifInfo {
  const OnvifInfo({this.manufacturer, this.model, this.firmware, this.serial});

  final String? manufacturer;
  final String? model;
  final String? firmware;
  final String? serial;
}

class OnvifException implements Exception {
  OnvifException(this.message, {this.auth = false});
  final String message;

  /// true = usuario o contraseña incorrectos.
  final bool auth;

  @override
  String toString() => message;
}

/// Cliente ONVIF mínimo: lo que la app necesita para trabajar con cámaras
/// de cualquier marca (video, PTZ, información y reinicio).
/// Usa la hora de la cámara para firmar (WS-Security), porque muchas
/// cámaras rechazan el acceso si su reloj y el del teléfono no coinciden.
class OnvifClient {
  OnvifClient(this.device) : _http = CameraHttp(device);

  final Device device;
  final CameraHttp _http;
  final _random = Random.secure();

  Duration _clockOffset = Duration.zero;
  bool _clockSynced = false;
  String? _mediaPath;
  String? _ptzPath;

  static const _devicePath = '/onvif/device_service';

  void close() => _http.close();

  // --- Información y reinicio ----------------------------------------------------------

  Future<OnvifInfo> info() async {
    final body = await _call(_devicePath, '<tds:GetDeviceInformation/>');
    return OnvifInfo(
      manufacturer: onvifValue(body, 'Manufacturer'),
      model: onvifValue(body, 'Model'),
      firmware: onvifValue(body, 'FirmwareVersion'),
      serial: onvifValue(body, 'SerialNumber'),
    );
  }

  Future<void> reboot() => _call(_devicePath, '<tds:SystemReboot/>');

  // --- Video ------------------------------------------------------------------

  Future<List<OnvifProfile>> profiles() async {
    await _capabilities();
    final body = await _call(_mediaPath!, '<trt:GetProfiles/>');
    return parseOnvifProfiles(body);
  }

  /// Ruta RTSP (lo que va después de IP:puerto) y puerto de un perfil.
  Future<({String path, int port})> streamPath(String token) async {
    await _capabilities();
    final body = await _call(
      _mediaPath!,
      '<trt:GetStreamUri><trt:StreamSetup>'
      '<tt:Stream>RTP-Unicast</tt:Stream><tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport>'
      '</trt:StreamSetup><trt:ProfileToken>$token</trt:ProfileToken></trt:GetStreamUri>',
    );
    final uri = Uri.tryParse(_unescape(onvifValue(body, 'Uri') ?? ''));
    if (uri == null || uri.scheme != 'rtsp') {
      throw OnvifException('La cámara no informó su dirección de video.');
    }
    final path = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
    return (path: path.isEmpty ? '/' : path, port: uri.hasPort ? uri.port : 554);
  }

  /// Elige los flujos principal (más grande) y secundario (más chico).
  Future<({String main, String sub, int port, OnvifProfile? ptzProfile})> detectStreams() async {
    final all = await profiles();
    final video = all.where((p) => !p.isJpeg).toList();
    final list = video.isNotEmpty ? video : all;
    if (list.isEmpty) throw OnvifException('La cámara no tiene perfiles de video.');
    list.sort((a, b) => b.pixels.compareTo(a.pixels));
    final mainProfile = list.first;
    final subProfile = list.length > 1 ? list.last : list.first;
    final main = await streamPath(mainProfile.token);
    final sub = subProfile == mainProfile ? main : await streamPath(subProfile.token);
    OnvifProfile? ptz;
    for (final p in all) {
      if (p.hasPtz) {
        ptz = p;
        break;
      }
    }
    return (main: main.path, sub: sub.path, port: main.port, ptzProfile: ptz);
  }

  // --- PTZ --------------------------------------------------------------------

  /// Perfil con PTZ, o null si la cámara no es PTZ.
  Future<OnvifProfile?> ptzProfile() async {
    await _capabilities();
    if (_ptzPath == null) return null;
    for (final p in await profiles()) {
      if (p.hasPtz) return p;
    }
    return null;
  }

  /// Velocidades de -1 a 1. Todo en 0 = detener.
  Future<void> continuousMove(String token, double pan, double tilt, double zoom) async {
    await _capabilities();
    final path = _ptzPath;
    if (path == null) throw OnvifException('La cámara no tiene PTZ.');
    String f(double v) => v.clamp(-1.0, 1.0).toStringAsFixed(2);
    if (pan == 0 && tilt == 0 && zoom == 0) {
      await _call(path,
          '<tptz:Stop><tptz:ProfileToken>$token</tptz:ProfileToken>'
          '<tptz:PanTilt>true</tptz:PanTilt><tptz:Zoom>true</tptz:Zoom></tptz:Stop>');
      return;
    }
    await _call(path,
        '<tptz:ContinuousMove><tptz:ProfileToken>$token</tptz:ProfileToken><tptz:Velocity>'
        '<tt:PanTilt x="${f(pan)}" y="${f(tilt)}"/><tt:Zoom x="${f(zoom)}"/>'
        '</tptz:Velocity></tptz:ContinuousMove>');
  }

  // --- Interno ------------------------------------------------------------------

  Future<void> _syncClock() async {
    if (_clockSynced) return;
    _clockSynced = true;
    try {
      final res = await _http.send('POST', _devicePath,
          body: _envelope('<tds:GetSystemDateAndTime/>', secure: false),
          contentType: 'application/soap+xml; charset=utf-8');
      final utc = parseOnvifUtc(res.body);
      if (utc != null) _clockOffset = utc.difference(DateTime.now().toUtc());
    } catch (_) {
      // Sin hora de la cámara: se usa la del teléfono.
    }
  }

  Future<void> _capabilities() async {
    if (_mediaPath != null) return;
    final body = await _call(
      _devicePath,
      '<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>',
    );
    _mediaPath = _pathOf(onvifSectionXAddr(body, 'Media')) ?? '/onvif/media_service';
    _ptzPath = _pathOf(onvifSectionXAddr(body, 'PTZ'));
  }

  String? _pathOf(String? url) {
    if (url == null) return null;
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.path.isEmpty) return null;
    return uri.path;
  }

  Future<String> _call(String path, String body) async {
    await _syncClock();
    final res = await _http.send('POST', path,
        body: _envelope(body), contentType: 'application/soap+xml; charset=utf-8');
    if (res.statusCode == 401 || res.body.contains('NotAuthorized')) {
      throw OnvifException('Usuario o contraseña incorrectos (ONVIF).', auth: true);
    }
    if (res.statusCode != 200) {
      final reason = onvifValue(res.body, 'Text');
      throw OnvifException(reason ?? 'La cámara respondió ${res.statusCode}.');
    }
    return res.body;
  }

  String _envelope(String body, {bool secure = true}) {
    final header = secure ? '<s:Header>${_security()}</s:Header>' : '';
    return '<?xml version="1.0" encoding="UTF-8"?>'
        '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
        'xmlns:tds="http://www.onvif.org/ver10/device/wsdl" '
        'xmlns:trt="http://www.onvif.org/ver10/media/wsdl" '
        'xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl" '
        'xmlns:tt="http://www.onvif.org/ver10/schema">'
        '$header<s:Body>$body</s:Body></s:Envelope>';
  }

  String _security() {
    final nonce = List<int>.generate(16, (_) => _random.nextInt(256));
    final created = DateTime.now().toUtc().add(_clockOffset);
    final createdText = '${created.toIso8601String().split('.').first}Z';
    final digest = wsseDigest(nonce, createdText, device.password);
    return '<Security s:mustUnderstand="1" '
        'xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">'
        '<UsernameToken><Username>${_escape(device.username)}</Username>'
        '<Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">$digest</Password>'
        '<Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">${base64Encode(nonce)}</Nonce>'
        '<Created xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">$createdText</Created>'
        '</UsernameToken></Security>';
  }

  static String _escape(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  static String _unescape(String s) =>
      s.replaceAll('&amp;', '&').replaceAll('&lt;', '<').replaceAll('&gt;', '>');
}

// =============================================================================
// Utilidades (públicas para poder probarlas)
// =============================================================================

/// PasswordDigest = Base64(SHA1(nonce + created + password)).
String wsseDigest(List<int> nonce, String created, String password) {
  final bytes = <int>[...nonce, ...utf8.encode(created), ...utf8.encode(password)];
  return base64Encode(sha1.convert(bytes).bytes);
}

/// Valor de una etiqueta, sin importar el prefijo (tt:, tds:, etc.).
String? onvifValue(String xml, String tag) {
  final m = RegExp('<(?:[\\w-]+:)?$tag(?:\\s[^>]*)?>([^<]*)</(?:[\\w-]+:)?$tag>').firstMatch(xml);
  final v = m?.group(1)?.trim();
  return (v == null || v.isEmpty) ? null : v;
}

/// XAddr de una sección de GetCapabilities (Media, PTZ...).
String? onvifSectionXAddr(String xml, String section) {
  final m = RegExp('<(?:[\\w-]+:)?$section(?:\\s[^>]*)?>[\\s\\S]*?<(?:[\\w-]+:)?XAddr>([^<]+)</')
      .firstMatch(xml);
  return m?.group(1)?.trim();
}

/// Lee los perfiles de GetProfiles.
List<OnvifProfile> parseOnvifProfiles(String xml) {
  final result = <OnvifProfile>[];
  final re = RegExp(r'<(?:[\w-]+:)?Profiles\b([^>]*)>([\s\S]*?)</(?:[\w-]+:)?Profiles>');
  for (final m in re.allMatches(xml)) {
    final token = RegExp(r'token="([^"]+)"').firstMatch(m.group(1)!)?.group(1);
    if (token == null) continue;
    final block = m.group(2)!;
    final encoder = RegExp(r'<(?:[\w-]+:)?VideoEncoderConfiguration\b[\s\S]*?</(?:[\w-]+:)?VideoEncoderConfiguration>')
            .firstMatch(block)
            ?.group(0) ??
        '';
    result.add(OnvifProfile(
      token: token,
      width: int.tryParse(onvifValue(encoder, 'Width') ?? '') ?? 0,
      height: int.tryParse(onvifValue(encoder, 'Height') ?? '') ?? 0,
      encoding: onvifValue(encoder, 'Encoding') ?? '',
      hasPtz: RegExp(r'<(?:[\w-]+:)?PTZConfiguration\b').hasMatch(block),
    ));
  }
  return result;
}

/// Hora UTC de la cámara (GetSystemDateAndTime).
DateTime? parseOnvifUtc(String xml) {
  final m = RegExp(r'<(?:[\w-]+:)?UTCDateTime>([\s\S]*?)</(?:[\w-]+:)?UTCDateTime>').firstMatch(xml);
  if (m == null) return null;
  final b = m.group(1)!;
  int v(String tag) => int.tryParse(onvifValue(b, tag) ?? '') ?? 0;
  final year = v('Year');
  if (year < 2000) return null;
  return DateTime.utc(year, v('Month'), v('Day'), v('Hour'), v('Minute'), v('Second'));
}
