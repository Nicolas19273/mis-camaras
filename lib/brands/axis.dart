import '../models/device.dart';
import '../ptz/ptz.dart';
import 'brand_adapter.dart';

class AxisAdapter extends BrandAdapter {
  const AxisAdapter();

  /// Axis: /axis-media/media.amp con "camera" para el canal.
  /// El secundario pide 640x480, que aceptan casi todos los modelos.
  @override
  String rtspPath(int channel, StreamQuality quality) => quality == StreamQuality.main
      ? '/axis-media/media.amp?camera=$channel&videocodec=h264'
      : '/axis-media/media.amp?camera=$channel&videocodec=h264&resolution=640x480';

  @override
  Future<PtzSupport?> detectPtz(Device device, int channel) => detectOnvifPtz(device, channel);
}
