import 'package:flutter/material.dart';

import '../brands/brand_adapter.dart';
import '../brands/brands.dart';
import '../models/device.dart';
import '../services/camera_status.dart';
import 'brand_badge.dart';
import 'live_video.dart';
import 'rec_badge.dart';
import 'status_dot.dart';

/// Una cámara dentro del mosaico, al estilo de un NVR:
/// nombre arriba a la izquierda, estado arriba a la derecha.
class CameraTile extends StatefulWidget {
  const CameraTile({
    super.key,
    required this.camera,
    required this.active,
    required this.onTap,
    this.onLongPress,
    this.registry,
    this.showLabel = true,
    this.quality = StreamQuality.sub,
    this.fit = BoxFit.cover,
    this.showRec = true,
  });

  final CameraRef camera;

  /// false = no reproduce (por ejemplo, mientras hay otra pantalla encima).
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final CameraStatusRegistry? registry;
  final bool showLabel;
  final StreamQuality quality;
  final BoxFit fit;

  /// Mostrar "● REC" si la cámara está grabando.
  final bool showRec;

  @override
  State<CameraTile> createState() => _CameraTileState();
}

class _CameraTileState extends State<CameraTile> {
  LiveStatus _status = LiveStatus.connecting;

  String get _key => '${widget.camera.device.id}-${widget.camera.channel}';

  void _onStatus(LiveStatus status) {
    if (!mounted || !widget.active) return;
    widget.registry?.set(_key, status);
    setState(() => _status = status);
  }

  @override
  void didUpdateWidget(CameraTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) {
      widget.registry?.remove(_key);
      _status = LiveStatus.connecting;
    }
  }

  @override
  void dispose() {
    widget.registry?.remove(_key);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = widget.camera;
    final url = adapterFor(camera.device.brand)
        .rtspUrl(camera.device, camera.channel, widget.quality);

    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.active)
            LiveVideo(url: url, fit: widget.fit, onStatus: _onStatus)
          else
            const ColoredBox(color: Colors.black),
          // Sombra suave arriba para que se lea el texto sobre cualquier imagen.
          const Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: 34,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black54, Colors.transparent],
                ),
              ),
            ),
          ),
          Positioned(
            left: 6,
            right: 6,
            top: 5,
            child: Row(
              children: [
                if (widget.showLabel) ...[
                  Container(
                    width: 3,
                    height: 11,
                    decoration: BoxDecoration(
                      color: brandColor(camera.device.brand),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      camera.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        shadows: [Shadow(blurRadius: 4)],
                      ),
                    ),
                  ),
                ] else
                  const Spacer(),
                if (widget.showRec) ...[
                  RecBadge(device: camera.device, channel: camera.channel),
                  const SizedBox(width: 6),
                ],
                if (widget.active) StatusDot(status: _status, size: 6),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
