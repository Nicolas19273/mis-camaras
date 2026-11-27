import '../models/device.dart';
import '../ptz/ptz.dart';

/// Calidad del video:
/// - main: flujo principal (alta resolución), para pantalla completa.
/// - sub: flujo secundario (liviano), para la cuadrícula.
enum StreamQuality { main, sub }

/// Todo lo que cambia entre marcas vive en un "adaptador".
/// La interfaz de la app solo habla con esta clase, así se ve igual
/// sin importar la marca del equipo.
abstract class BrandAdapter {
  const BrandAdapter();

  /// Ruta RTSP propia de la marca (lo que va después de IP:puerto).
  String rtspPath(int channel, StreamQuality quality);

  /// Igual que [rtspPath], pero sabiendo el equipo (algunas marcas usan
  /// rutas distintas en grabadores y en cámaras sueltas).
  String rtspPathFor(Device device, int channel, StreamQuality quality) =>
      rtspPath(channel, quality);

  /// Dirección completa del video en vivo.
  /// Si el equipo tiene rutas propias (detectadas por ONVIF o escritas a mano)
  /// y es de un solo canal, se usan esas.
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
    final custom = quality == StreamQuality.main ? device.rtspMain : (device.rtspSub ?? device.rtspMain);
    final path = (!device.isRecorder && custom != null && custom.isNotEmpty)
        ? (custom.startsWith('/') ? custom : '/$custom')
        : rtspPathFor(device, channel, quality);
    return 'rtsp://$auth${device.host}:${device.rtspPort}$path';
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
