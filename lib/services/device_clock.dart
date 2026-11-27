import '../models/device.dart';
import '../recording/recording.dart' show dahuaTime, parseDeviceTime;
import 'camera_http.dart';

class ClockException implements Exception {
  ClockException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Hora del equipo: leerla y ponerle la del teléfono.
/// Una hora mal puesta hace que las grabaciones queden con fecha equivocada
/// y cuesta encontrar los videos.
class DeviceClock {
  DeviceClock(this.device) : _http = CameraHttp(device);

  final Device device;
  final CameraHttp _http;

  static bool supports(Device d) => d.brand == Brand.hikvision || d.brand == Brand.dahua;

  void close() => _http.close();

  Future<DateTime?> read() async {
    if (device.brand == Brand.hikvision) {
      final r = await _http.get('/ISAPI/System/time');
      _check(r.statusCode);
      return r.statusCode == 200
          ? parseDeviceTime(RegExp(r'<localTime>([^<]+)</localTime>').firstMatch(r.body)?.group(1))
          : null;
    }
    if (device.brand == Brand.dahua) {
      final r = await _http.get('/cgi-bin/global.cgi?action=getCurrentTime');
      _check(r.statusCode);
      return r.statusCode == 200 ? parseDeviceTime(r.body) : null;
    }
    return null;
  }

  /// Pone la hora del teléfono en el equipo.
  Future<void> setToPhone() async {
    final now = DateTime.now();
    if (device.brand == Brand.hikvision) {
      final r = await _http.get('/ISAPI/System/time');
      _check(r.statusCode);
      if (r.statusCode != 200) throw ClockException('El equipo no informó su hora (${r.statusCode}).');
      final put = await _http.put('/ISAPI/System/time', buildHikvisionTimeXml(r.body, now));
      _check(put.statusCode);
      if (put.statusCode != 200) throw ClockException('El equipo no aceptó la hora (${put.statusCode}).');
      return;
    }
    if (device.brand == Brand.dahua) {
      final time = dahuaTime(now).replaceAll(' ', '%20');
      final r = await _http.get('/cgi-bin/global.cgi?action=setCurrentTime&time=$time');
      _check(r.statusCode);
      if (r.statusCode != 200 || !r.body.contains('OK')) {
        throw ClockException('El equipo no aceptó la hora (${r.statusCode}).');
      }
      return;
    }
    throw ClockException('Esta marca todavía no permite cambiar la hora desde la app.');
  }

  void _check(int status) {
    if (status == 401 || status == 403) {
      throw ClockException('Usuario o contraseña incorrectos, o sin permiso para cambiar la hora.');
    }
  }
}

/// Cambia la hora del XML de Hikvision por [now] (conserva la zona horaria)
/// y la deja en modo manual, porque si estaba mal es que la hora automática
/// (NTP) no le está funcionando.
String buildHikvisionTimeXml(String current, DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp = '${now.year}-${two(now.month)}-${two(now.day)}T${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  var xml = current.replaceFirstMapped(RegExp(r'<localTime>([^<]*)</localTime>'), (m) {
    final old = m.group(1)!.trim();
    final suffix = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(.*)$').firstMatch(old)?.group(1) ?? '';
    return '<localTime>$stamp$suffix</localTime>';
  });
  xml = xml.replaceFirst(RegExp(r'<timeMode>[^<]*</timeMode>'), '<timeMode>manual</timeMode>');
  return xml;
}
