import '../models/device.dart';
import '../ptz/ptz.dart';

/// Calidad del video:
/// - main: flujo principal (alta resolución), para pantalla completa.
/// - sub: flujo secundario (liviano), para la cuadrícula.
enum StreamQuality { main, sub }

/// Todo lo que cambia entre marcas vive en un "adaptador".
/// La interfaz de la app solo habla con esta clase, así se ve igual
/// sin importar si el equipo es Hikvision o Dahua.
abstract class BrandAdapter {
  const BrandAdapter();

  /// Ruta RTSP propia de la marca (lo que va después de IP:puerto).
  String rtspPath(int channel, StreamQuality quality);

  /// Dirección completa del video en vivo.
  /// Con [hidePassword] la contraseña se reemplaza por puntos (para mostrarla en pantalla).
  String rtspUrl(
    Device device,
    int channel,
    StreamQuality quality, {
    bool hidePassword = false,
  }) {
    final user = Uri.encodeComponent(device.username);
    final pass = hidePassword ? '••••' : Uri.encodeComponent(device.password);
    final auth = device.username.isEmpty ? '' : '$user:$pass@';
    return 'rtsp://$auth${device.host}:${device.rtspPort}${rtspPath(channel, quality)}';
  }

  /// Revisa si el canal es una cámara PTZ (que se puede mover).
  /// Devuelve null si no lo es o si no se pudo comprobar.
  Future<PtzSupport?> detectPtz(Device device, int channel) async => null;

  // ---------------------------------------------------------------------
  // PRÓXIMOS PASOS: aquí se agregarán los métodos de configuración, por ej.
  //   Future<DeviceInfo> getDeviceInfo(Device d);
  //   Future<ImageSettings> getImage(Device d, int channel);
  //   Future<void> setImage(Device d, int channel, ImageSettings s);
  //   Future<void> reboot(Device d);
  // Cada marca los implementa con su propia API (ISAPI o API HTTP de Dahua).
  // ---------------------------------------------------------------------
}
