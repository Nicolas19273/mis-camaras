import 'brand_adapter.dart';

class HikvisionAdapter extends BrandAdapter {
  const HikvisionAdapter();

  /// Hikvision numera los flujos como canal × 100 + tipo:
  ///   canal 1 principal = 101, canal 1 secundario = 102,
  ///   canal 2 principal = 201, canal 12 secundario = 1202, etc.
  @override
  String rtspPath(int channel, StreamQuality quality) {
    final stream = quality == StreamQuality.main ? 1 : 2;
    return '/Streaming/Channels/${channel * 100 + stream}';
  }
}
