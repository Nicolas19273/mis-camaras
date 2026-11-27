import 'package:flutter/material.dart';

import '../services/camera_status.dart';
import '../theme.dart';

Color statusColor(LiveStatus status) => switch (status) {
      LiveStatus.live => AppColors.live,
      LiveStatus.connecting => AppColors.connecting,
      LiveStatus.offline => AppColors.offline,
    };

/// Punto de color con el estado de la cámara. Parpadea mientras conecta.
class StatusDot extends StatefulWidget {
  const StatusDot({super.key, required this.status, this.size = 7});

  final LiveStatus status;
  final double size;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot> with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) _sync();
  }

  void _sync() {
    if (widget.status == LiveStatus.connecting) {
      _blink.repeat(reverse: true);
    } else {
      _blink.stop();
      _blink.value = 1;
    }
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = statusColor(widget.status);
    return FadeTransition(
      opacity: Tween<double>(begin: 0.25, end: 1).animate(_blink),
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 6),
          ],
        ),
      ),
    );
  }
}

/// Etiqueta "EN VIVO" con punto, como en los visores profesionales.
class LiveBadge extends StatelessWidget {
  const LiveBadge({super.key, required this.status});

  final LiveStatus status;

  @override
  Widget build(BuildContext context) {
    final label = switch (status) {
      LiveStatus.live => 'EN VIVO',
      LiveStatus.connecting => 'CONECTANDO',
      LiveStatus.offline => 'SIN SEÑAL',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(status: status),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}
