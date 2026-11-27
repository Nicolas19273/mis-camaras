import 'package:flutter/material.dart';

import '../brands/brand_adapter.dart';
import '../brands/brands.dart';
import '../models/device.dart';
import 'brand_badge.dart';
import 'live_video.dart';

/// Una cámara dentro de la cuadrícula. Usa el flujo secundario (liviano)
/// para que el teléfono aguante varias a la vez.
class CameraTile extends StatelessWidget {
  const CameraTile({
    super.key,
    required this.camera,
    required this.active,
    required this.onTap,
  });

  final CameraRef camera;

  /// false = no reproduce (por ejemplo, mientras hay otra pantalla encima).
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final url = adapterFor(camera.device.brand)
        .rtspUrl(camera.device, camera.channel, StreamQuality.sub);

    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (active)
              LiveVideo(url: url)
            else
              const ColoredBox(color: Colors.black),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _LabelBar(text: camera.label, brand: camera.device.brand),
            ),
          ],
        ),
      ),
    );
  }
}

class _LabelBar extends StatelessWidget {
  const _LabelBar({required this.text, required this.brand});

  final String text;
  final Brand brand;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 14, 8, 5),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black87],
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: brandColor(brand),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
