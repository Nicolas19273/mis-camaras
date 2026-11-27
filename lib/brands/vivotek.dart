import '../models/device.dart';
import '../ptz/ptz.dart';
import 'brand_adapter.dart';

class VivotekAdapter extends BrandAdapter {
  const VivotekAdapter();

  /// Vivotek: live.sdp (flujo 1) y live2.sdp (flujo 2).
  @override
  String rtspPath(int channel, StreamQuality quality) =>
      quality == StreamQuality.main ? '/live.sdp' : '/live2.sdp';

  @override
  Future<PtzSupport?> detectPtz(Device device, int channel) => detectOnvifPtz(device, channel);
}
