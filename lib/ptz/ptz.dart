import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../brands/brands.dart';
import '../models/device.dart';
import '../onvif/onvif_client.dart';
import '../services/camera_http.dart';
import '../services/device_api.dart';

/// Lo que puede hacer una cámara PTZ y cómo controlarla.
class PtzSupport {
  const PtzSupport({required this.panTilt, required this.zoom, required this.driver});

  /// Puede girar a los lados y subir/bajar.
  final bool panTilt;

  /// Tiene zoom óptico motorizado.
  final bool zoom;

  final PtzDriver driver;
}

/// Envía los movimientos a la cámara, siempre en orden: así un "detener"
/// nunca llega antes que el "mover" anterior y la cámara no queda girando.
abstract class PtzDriver {
  Future<void> _queue = Future<void>.value();

  /// Se llama si la cámara rechaza un comando.
  void Function(String message)? onError;

  /// [pan] y [tilt] van de -1 a 1 (tilt positivo = arriba). (0, 0) detiene.
  void move(double pan, double tilt);

  /// 1 = acercar, -1 = alejar, 0 = detener el zoom.
  void zoom(int direction);

  /// Detiene todo movimiento.
  void stop();

  @protected
  void enqueue(Future<void> Function() command) {
    _queue = _queue.then((_) => command()).catchError((Object e) {
      onError?.call(e.toString());
    });
  }
}

/// Recuerda qué cámaras son PTZ durante la sesión, para no preguntarle
/// al equipo cada vez que se abre la misma cámara.
class PtzService {
  static final _cache = <String, Future<PtzSupport?>>{};

  static Future<PtzSupport?> detect(Device device, int channel) {
    // Marcada a mano como "no es PTZ": no se pregunta.
    if (device.noPtzChannels.contains(channel)) return Future.value(null);
    final key = [
      device.id,
      device.brand.name,
      device.host,
      device.httpPort,
      device.username,
      device.password.hashCode,
      channel,
    ].join('|');

    return _cache.putIfAbsent(key, () async {
      try {
        return await adapterFor(device.brand).detectPtz(device, channel);
      } catch (e) {
        // Error de red: no se guarda, para volver a intentar la próxima vez.
        debugPrint('No se pudo revisar PTZ: $e');
        scheduleMicrotask(() => _cache.remove(key));
        return null;
      }
    });
  }
}

// =============================================================================
// Hikvision (ISAPI)
// =============================================================================

/// Pregunta a un equipo Hikvision si el canal es PTZ.
/// Prueba la ruta directa (cámara o NVR moderno) y la de NVR "proxy".
Future<PtzSupport?> detectHikvisionPtz(Device device, int channel) async {
  final http = CameraHttp(device);
  final bases = [
    '/ISAPI/PTZCtrl/channels/$channel',
    '/ISAPI/ContentMgmt/PTZCtrlProxy/channels/$channel',
  ];
  for (final base in bases) {
    final res = await http.get('$base/capabilities');
    if (res.statusCode == 401 || res.statusCode == 403 && res.body.contains('Unauthorized')) {
      http.close();
      return null; // credenciales incorrectas: no seguir intentando
    }
    if (res.statusCode != 200) continue;
    final caps = parseHikvisionPtzCaps(res.body);
    if (caps == null) continue;
    final checked = await _checkModel(device, channel, caps);
    if (checked == null) break;
    return PtzSupport(panTilt: checked.panTilt, zoom: checked.zoom, driver: HikvisionPtz(http, base));
  }
  http.close();
  return null;
}

/// Revisa el modelo de la cámara: si es una fija conocida, no tiene joystick
/// (solo zoom si su lente es motorizado), aunque el equipo diga otra cosa.
Future<PtzCaps?> _checkModel(Device device, int channel, PtzCaps caps) async {
  final api = DeviceApi(device);
  try {
    final model = await api.channelModel(channel);
    return applyModelRules(device.brand, model, caps);
  } finally {
    api.close();
  }
}

/// Reglas por modelo (pública para poder probarla).
PtzCaps? applyModelRules(Brand brand, String? model, PtzCaps caps) {
  var panTilt = caps.panTilt;
  var zoom = caps.zoom;
  if (model != null) {
    final fixed = isFixedCameraModel(brand, model);
    if (fixed == true) {
      panTilt = false;
      zoom = zoom && hasMotorizedLens(model);
    }
  }
  if (!panTilt && !zoom) return null;
  return (panTilt: panTilt, zoom: zoom);
}

typedef PtzCaps = ({bool panTilt, bool zoom});

/// Lee la respuesta de /capabilities. Devuelve null si el canal no es PTZ.
PtzCaps? parseHikvisionPtzCaps(String body) {
  if (body.contains('notSupport') || body.contains('<statusCode>4</statusCode>')) return null;
  // Solo cuenta lo que el equipo declara explícitamente.
  final panTilt = body.contains('ContinuousPanTiltSpace');
  final zoom = body.contains('ContinuousZoomSpace');
  if (!panTilt && !zoom) return null;
  return (panTilt: panTilt, zoom: zoom);
}

/// Movimiento continuo: pan, tilt y zoom de -100 a 100. Todo en 0 = detener.
class HikvisionPtz extends PtzDriver {
  HikvisionPtz(this._http, this._base);

  final CameraHttp _http;
  final String _base;
  ({int pan, int tilt, int zoom}) _last = (pan: 0.0, tilt: 0.0, zoom: 0.0);

  @override
  void move(double pan, double tilt) =>
      _send((pan * 100).round().clamp(-100, 100), (tilt * 100).round().clamp(-100, 100), 0);

  @override
  void zoom(int direction) => _send(0, 0, direction.sign * 60);

  @override
  void stop() => _send(0.0, 0.0, 0.0, force: true);

  void _send(int pan, int tilt, int zoom, {bool force = false}) {
    final next = (pan: pan, tilt: tilt, zoom: zoom);
    if (!force && next == _last) return;
    _last = next;
    final xml = '<PTZData><pan>$pan</pan><tilt>$tilt</tilt><zoom>$zoom</zoom></PTZData>';
    enqueue(() async {
      final res = await _http.put('$_base/continuous', xml);
      if (res.statusCode != 200) {
        throw Exception('La cámara respondió ${res.statusCode}');
      }
    });
  }
}

// =============================================================================
// Dahua (CGI ptz.cgi)
// =============================================================================

/// Pregunta a un equipo Dahua si el canal es PTZ.
/// En cámaras sueltas algunos firmware numeran desde 0 y otros desde 1:
/// se prueban ambos. En NVR se usa el número de canal tal cual (desde 1).
Future<PtzSupport?> detectDahuaPtz(Device device, int channel) async {
  final http = CameraHttp(device);
  final candidates = device.channels == 1 ? [channel, channel - 1] : [channel];
  for (final ch in candidates) {
    final res = await http.get('/cgi-bin/ptz.cgi?action=getCurrentProtocolCaps&channel=$ch');
    if (res.statusCode == 401) {
      http.close();
      return null;
    }
    if (res.statusCode != 200) continue;
    final caps = parseDahuaPtzCaps(res.body);
    if (caps == null) continue;
    final checked = await _checkModel(device, channel, caps);
    if (checked == null) break;
    return PtzSupport(panTilt: checked.panTilt, zoom: checked.zoom, driver: DahuaPtz(http, ch));
  }
  http.close();
  return null;
}

/// Lee la respuesta "caps.Pan=true / caps.Tile=true / caps.Zoom=true".
PtzCaps? parseDahuaPtzCaps(String body) {
  bool flag(String key) => RegExp('caps\\.$key=true', caseSensitive: false).hasMatch(body);
  // Debe declarar giro horizontal Y vertical: las fijas con puerto RS-485
  // suelen informar solo parte de esto.
  final panTilt = flag('Pan') && (flag('Tile') || flag('Tilt'));
  final zoom = flag('Zoom');
  if (!panTilt && !zoom) return null;
  return (panTilt: panTilt, zoom: zoom);
}

/// Convierte el joystick en una de las 8 direcciones de Dahua.
/// Devuelve null dentro de la zona muerta del centro.
String? dahuaDirection(double pan, double tilt, {double deadZone = 0.15}) {
  if (math.sqrt(pan * pan + tilt * tilt) < deadZone) return null;
  final angle = math.atan2(tilt, pan) * 180 / math.pi; // 0 = derecha, 90 = arriba
  const codes = ['Right', 'RightUp', 'Up', 'LeftUp', 'Left', 'LeftDown', 'Down', 'RightDown'];
  final sector = (((angle + 360 + 22.5) % 360) ~/ 45);
  return codes[sector];
}

/// Comandos start/stop por dirección, velocidad de 1 a 8.
class DahuaPtz extends PtzDriver {
  DahuaPtz(this._http, this._channel);

  final CameraHttp _http;
  final int _channel;
  String? _activeCode;
  int _activeSpeed = 0;

  @override
  void move(double pan, double tilt) {
    final code = dahuaDirection(pan, tilt);
    if (code == null) {
      stop();
      return;
    }
    final magnitude = math.min(1.0, math.sqrt(pan * pan + tilt * tilt));
    final speed = (magnitude * 8).ceil().clamp(1, 8);
    _start(code, speed);
  }

  @override
  void zoom(int direction) {
    if (direction == 0) {
      stop();
    } else {
      _start(direction > 0 ? 'ZoomTele' : 'ZoomWide', 5);
    }
  }

  @override
  void stop() {
    final code = _activeCode;
    if (code == null) return;
    _activeCode = null;
    _activeSpeed = 0;
    _cmd('stop', code, 0);
  }

  void _start(String code, int speed) {
    if (code == _activeCode && speed == _activeSpeed) return;
    final previous = _activeCode;
    if (previous != null && previous != code) _cmd('stop', previous, 0);
    _activeCode = code;
    _activeSpeed = speed;
    _cmd('start', code, speed);
  }

  void _cmd(String action, String code, int speed) {
    final path = '/cgi-bin/ptz.cgi?action=$action&channel=$_channel&code=$code'
        '&arg1=$speed&arg2=$speed&arg3=0';
    enqueue(() async {
      final res = await _http.get(path);
      if (res.statusCode != 200) {
        throw Exception('La cámara respondió ${res.statusCode}');
      }
    });
  }
}

// =============================================================================
// ONVIF (Vivotek, Axis, Hanwha, Uniview y otras marcas)
// =============================================================================

/// Pregunta por ONVIF si la cámara tiene PTZ (un perfil con configuración PTZ).
Future<PtzSupport?> detectOnvifPtz(Device device, int channel) async {
  if (device.isRecorder) return null; // en grabadores de otras marcas, aún no
  final client = OnvifClient(device);
  try {
    final profile = await client.ptzProfile();
    if (profile == null) {
      client.close();
      return null;
    }
    return PtzSupport(panTilt: true, zoom: true, driver: OnvifPtz(client, profile.token));
  } catch (_) {
    client.close();
    return null;
  }
}

/// Movimiento continuo por ONVIF: velocidades de -1 a 1.
class OnvifPtz extends PtzDriver {
  OnvifPtz(this._client, this._token);

  final OnvifClient _client;
  final String _token;
  ({double pan, double tilt, double zoom}) _last = (pan: 0.0, tilt: 0.0, zoom: 0.0);

  @override
  void move(double pan, double tilt) => _send(pan * 0.8, tilt * 0.8, 0);

  @override
  void zoom(int direction) => _send(0.0, 0.0, direction.sign * 0.5);

  @override
  void stop() => _send(0.0, 0.0, 0.0, force: true);

  void _send(double pan, double tilt, double zoom, {bool force = false}) {
    final next = (pan: pan, tilt: tilt, zoom: zoom);
    if (!force && next == _last) return;
    _last = next;
    enqueue(() => _client.continuousMove(_token, pan, tilt, zoom));
  }
}

