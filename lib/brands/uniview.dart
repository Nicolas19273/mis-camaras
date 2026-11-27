import '../models/device.dart';
import '../ptz/ptz.dart';
import 'brand_adapter.dart';

class UniviewAdapter extends BrandAdapter {
  const UniviewAdapter();

  /// Uniview:
  /// - Cámara: /media/video1 (principal) y /media/video2 (secundario).
  /// - NVR: /unicast/c(canal)/s0/live (principal) y s1 (secundario).
  @override
  String rtspPath(int channel, StreamQuality quality) =>
      quality == StreamQuality.main ? '/media/video1' : '/media/video2';

  @override
  String rtspPathFor(Device device, int channel, StreamQuality quality) {
    if (!device.isRecorder) return rtspPath(channel, quality);
    final stream = quality == StreamQuality.main ? 0 : 1;
    return '/unicast/c$channel/s$stream/live';
  }

  @override
  Future<PtzSupport?> detectPtz(Device device, int channel) => detectOnvifPtz(device, channel);
}
