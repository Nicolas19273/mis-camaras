import '../models/device.dart';
import '../ptz/ptz.dart';
import 'brand_adapter.dart';

/// Cualquier otra marca: las rutas las informa la cámara por ONVIF al
/// agregarla (o se escriben a mano en el formulario).
class OnvifAdapter extends BrandAdapter {
  const OnvifAdapter();

  @override
  String rtspPath(int channel, StreamQuality quality) => '/';

  @override
  Future<PtzSupport?> detectPtz(Device device, int channel) => detectOnvifPtz(device, channel);
}
