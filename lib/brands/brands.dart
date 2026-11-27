import '../models/device.dart';
import 'brand_adapter.dart';
import 'dahua.dart';
import 'hikvision.dart';

/// Devuelve el adaptador que corresponde a cada marca.
BrandAdapter adapterFor(Brand brand) => switch (brand) {
      Brand.hikvision => const HikvisionAdapter(),
      Brand.dahua => const DahuaAdapter(),
    };
