import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../models/device.dart';

/// Habla con la página web interna del equipo (ISAPI en Hikvision,
/// CGI en Dahua). Ambos piden autenticación "Digest", que el paquete
/// http no trae, así que se implementa aquí.
class CameraHttp {
  CameraHttp(this.device, {http.Client? client}) : _client = client ?? http.Client();

  final Device device;
  final http.Client _client;

  Map<String, String>? _digest;
  bool _basic = false;
  int _nc = 0;
  final _random = Random();

  static const timeout = Duration(seconds: 6);

  Future<http.Response> get(String path) => send('GET', path);

  Future<http.Response> put(String path, String body, {String contentType = 'application/xml'}) =>
      send('PUT', path, body: body, contentType: contentType);

  /// Envía la petición. Si el equipo pide credenciales (401), las calcula
  /// y reintenta UNA sola vez, para no bloquear el usuario por intentos fallidos.
  Future<http.Response> send(
    String method,
    String path, {
    String? body,
    String? contentType,
    Duration? timeout,
  }) async {
    final limit = timeout ?? CameraHttp.timeout;
    var res = await _send(method, path, body, contentType, limit);
    if (res.statusCode == 401) {
      final challenge = res.headers['www-authenticate'] ?? '';
      if (!_learnChallenge(challenge)) return res;
      res = await _send(method, path, body, contentType, limit);
    }
    return res;
  }

  void close() => _client.close();

  bool _learnChallenge(String header) {
    final lower = header.toLowerCase();
    final i = lower.indexOf('digest');
    if (i >= 0) {
      _digest = parseDigestChallenge(header.substring(i + 6));
      _nc = 0;
      _basic = false;
      return true;
    }
    if (lower.contains('basic')) {
      _basic = true;
      _digest = null;
      return true;
    }
    return false;
  }

  Future<http.Response> _send(
      String method, String path, String? body, String? contentType, Duration timeout) async {
    final uri = Uri.parse('http://${device.host}:${device.httpPort}$path');
    final request = http.Request(method, uri);
    if (contentType != null) request.headers['Content-Type'] = contentType;
    if (body != null) request.body = body;
    final auth = _authorization(method, uri);
    if (auth != null) request.headers['Authorization'] = auth;

    final streamed = await _client.send(request).timeout(timeout);
    return http.Response.fromStream(streamed).timeout(timeout);
  }

  String? _authorization(String method, Uri uri) {
    final target = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
    final digest = _digest;
    if (digest != null) {
      _nc++;
      return buildDigestHeader(
        challenge: digest,
        method: method,
        uri: target,
        username: device.username,
        password: device.password,
        nc: _nc,
        cnonce: _cnonce(),
      );
    }
    if (_basic) {
      return 'Basic ${base64Encode(utf8.encode('${device.username}:${device.password}'))}';
    }
    return null;
  }

  String _cnonce() =>
      List.generate(16, (_) => _random.nextInt(16).toRadixString(16)).join();
}

/// Lee los datos del encabezado WWW-Authenticate (realm, nonce, qop...).
Map<String, String> parseDigestChallenge(String text) {
  final result = <String, String>{};
  final re = RegExp(r'(\w+)\s*=\s*(?:"([^"]*)"|([^,\s]+))');
  for (final m in re.allMatches(text)) {
    result[m.group(1)!.toLowerCase()] = m.group(2) ?? m.group(3) ?? '';
  }
  return result;
}

/// Arma el encabezado Authorization de tipo Digest (RFC 2617 / 7616).
String buildDigestHeader({
  required Map<String, String> challenge,
  required String method,
  required String uri,
  required String username,
  required String password,
  required int nc,
  required String cnonce,
}) {
  final realm = challenge['realm'] ?? '';
  final nonce = challenge['nonce'] ?? '';
  final opaque = challenge['opaque'];
  final algorithm = challenge['algorithm'];
  final useSha256 = (algorithm ?? '').toUpperCase().startsWith('SHA-256');

  String hash(String s) => useSha256
      ? sha256.convert(utf8.encode(s)).toString()
      : md5.convert(utf8.encode(s)).toString();

  final qops = (challenge['qop'] ?? '').split(',').map((q) => q.trim()).toList();
  final useQop = qops.contains('auth');

  final ha1 = hash('$username:$realm:$password');
  final ha2 = hash('$method:$uri');
  final ncText = nc.toRadixString(16).padLeft(8, '0');
  final response = useQop
      ? hash('$ha1:$nonce:$ncText:$cnonce:auth:$ha2')
      : hash('$ha1:$nonce:$ha2');

  final parts = <String>[
    'username="$username"',
    'realm="$realm"',
    'nonce="$nonce"',
    'uri="$uri"',
    if (algorithm != null) 'algorithm=$algorithm',
    'response="$response"',
    if (opaque != null) 'opaque="$opaque"',
    if (useQop) ...['qop=auth', 'nc=$ncText', 'cnonce="$cnonce"'],
  ];
  return 'Digest ${parts.join(', ')}';
}
