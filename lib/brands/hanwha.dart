import '../models/device.dart';
import '../ptz/ptz.dart';
import 'brand_adapter.dart';

class HanwhaAdapter extends BrandAdapter {
  const HanwhaAdapter();

  /// Hanwha Wisenet:
  /// - Cámara: /profileN/media.smp (al agregarla, ONVIF indica qué perfil es cuál).
  /// - NVR: /LiveChannel/(canal desde 0)/media.smp/profile=1 (en vivo) o 3 (remoto, liviano).
  @override
  String rtspPath(int channel, StreamQuality quality) =>
      quality == StreamQuality.main ? '/profile2/media.smp' : '/profile3/media.smp';

  @override
  String rtspPathFor(Device device, int channel, StreamQuality quality) {
    if (!device.isRecorder) return rtspPath(channel, quality);
    final profile = quality == StreamQuality.main ? 1 : 3;
    return '/LiveChannel/${channel - 1}/media.smp/profile=$profile';
  }

  @override
  Future<PtzSupport?> detectPtz(Device device, int channel) => detectOnvifPtz(device, channel);
}
