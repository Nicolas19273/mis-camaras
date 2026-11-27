import '../models/device.dart';
import '../ptz/ptz.dart';
import 'brand_adapter.dart';

class DahuaAdapter extends BrandAdapter {
  const DahuaAdapter();

  /// Dahua usa channel=N y subtype=0 (principal) o subtype=1 (secundario).
  /// Sirve igual para cámaras y para NVR/XVR Dahua.
  @override
  String rtspPath(int channel, StreamQuality quality) {
    final subtype = quality == StreamQuality.main ? 0 : 1;
    return '/cam/realmonitor?channel=$channel&subtype=$subtype';
  }

  /// PTZ por CGI: /cgi-bin/ptz.cgi?action=getCurrentProtocolCaps.
  @override
  Future<PtzSupport?> detectPtz(Device device, int channel) =>
      detectDahuaPtz(device, channel);
}
