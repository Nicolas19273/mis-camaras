import 'package:flutter/material.dart';

import '../models/device.dart';
import '../theme.dart';

Color brandColor(Brand brand) => switch (brand) {
      Brand.hikvision => AppColors.hikvision,
      Brand.dahua => AppColors.dahua,
      Brand.vivotek => AppColors.vivotek,
      Brand.axis => AppColors.axis,
      Brand.hanwha => AppColors.hanwha,
      Brand.uniview => AppColors.uniview,
      Brand.onvif => AppColors.onvif,
    };

/// Círculo con la inicial de la marca.
class BrandBadge extends StatelessWidget {
  const BrandBadge({super.key, required this.brand, this.size = 36});

  final Brand brand;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = brandColor(brand);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        shape: BoxShape.circle,
      ),
      child: Text(
        brand.letter,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.42,
        ),
      ),
    );
  }
}
