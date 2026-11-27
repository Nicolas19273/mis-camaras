import 'package:flutter/material.dart';

import '../brands/brand_adapter.dart';
import '../brands/brands.dart';
import '../models/device.dart';
import '../widgets/brand_badge.dart';
import '../widgets/live_video.dart';

/// Una cámara en pantalla completa.
/// - Toque: muestra / oculta los controles.
/// - Pellizco: zoom digital. Doble toque: vuelve al tamaño normal.
class LiveViewScreen extends StatefulWidget {
  const LiveViewScreen({super.key, required this.camera});

  final CameraRef camera;

  @override
  State<LiveViewScreen> createState() => _LiveViewScreenState();
}

class _LiveViewScreenState extends State<LiveViewScreen> {
  final _zoom = TransformationController();
  StreamQuality _quality = StreamQuality.main;
  bool _muted = true;
  bool _showControls = true;

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = widget.camera;
    final url = adapterFor(camera.device.brand)
        .rtspUrl(camera.device, camera.channel, _quality);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => setState(() => _showControls = !_showControls),
              onDoubleTap: () => _zoom.value = Matrix4.identity(),
              child: InteractiveViewer(
                transformationController: _zoom,
                minScale: 1,
                maxScale: 6,
                child: LiveVideo(
                  url: url,
                  fit: BoxFit.contain,
                  muted: _muted,
                  compact: false,
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: IgnorePointer(
              ignoring: !_showControls,
              child: AnimatedOpacity(
                opacity: _showControls ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: _TopBar(
                  camera: camera,
                  quality: _quality,
                  muted: _muted,
                  onToggleQuality: () => setState(() {
                    _quality = _quality == StreamQuality.main
                        ? StreamQuality.sub
                        : StreamQuality.main;
                  }),
                  onToggleMute: () => setState(() => _muted = !_muted),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.camera,
    required this.quality,
    required this.muted,
    required this.onToggleQuality,
    required this.onToggleMute,
  });

  final CameraRef camera;
  final StreamQuality quality;
  final bool muted;
  final VoidCallback onToggleQuality;
  final VoidCallback onToggleMute;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 8, 20),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
              BrandBadge(brand: camera.device.brand, size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  camera.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: onToggleQuality,
                child: Text(
                  quality == StreamQuality.main ? 'HD' : 'SD',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: muted ? 'Activar sonido' : 'Silenciar',
                icon: Icon(
                  muted ? Icons.volume_off : Icons.volume_up,
                  color: Colors.white,
                ),
                onPressed: onToggleMute,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
