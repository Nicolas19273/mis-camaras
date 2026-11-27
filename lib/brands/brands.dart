import '../models/device.dart';
import 'brand_adapter.dart';
import 'axis.dart';
import 'dahua.dart';
import 'generic.dart';
import 'hanwha.dart';
import 'hikvision.dart';
import 'uniview.dart';
import 'vivotek.dart';

/// Devuelve el adaptador que corresponde a cada marca.
BrandAdapter adapterFor(Brand brand) => switch (brand) {
      Brand.hikvision => const HikvisionAdapter(),
      Brand.dahua => const DahuaAdapter(),
      Brand.vivotek => const VivotekAdapter(),
      Brand.axis => const AxisAdapter(),
      Brand.hanwha => const HanwhaAdapter(),
      Brand.uniview => const UniviewAdapter(),
      Brand.onvif => const OnvifAdapter(),
    };
