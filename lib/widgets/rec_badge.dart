import 'package:flutter/material.dart';

import '../models/device.dart';
import '../recording/recording.dart';
import '../recording/recording_monitor.dart';
import '../theme.dart';

/// "● REC" sobre el video: rojo parpadeando si está grabando, aro si está
/// lista para grabar (con movimiento), y "SIN GRABAR" si hay un problema.
class RecBadge extends StatelessWidget {
  const RecBadge({super.key, required this.device, required this.channel});

  final Device device;
  final int channel;

  @override
  Widget build(BuildContext context) {
    final monitor = RecordingMonitor.instance;
    return ListenableBuilder(
      listenable: monitor,
      builder: (context, child) {
        final state = monitor.stateOf(device, channel);
        return switch (state) {
          RecState.recording => const _Pill(dot: _BlinkingDot(), text: 'REC'),
          RecState.armed => _Pill(
              dot: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.danger, width: 1.5),
                ),
              ),
              text: 'REC',
              muted: true,
            ),
          RecState.problem => const _Pill(
              dot: Icon(Icons.warning_amber_rounded, size: 10, color: AppColors.connecting),
              text: 'SIN GRABAR',
              color: AppColors.connecting,
            ),
          _ => const SizedBox.shrink(),
        };
      },
    );
  }
}

/// Color, ícono y texto de un estado (para listas y tarjetas).
({Color color, IconData icon, String text}) recStateStyle(RecState s) => switch (s) {
      RecState.recording => (color: AppColors.danger, icon: Icons.fiber_manual_record, text: 'Grabando'),
      RecState.armed => (color: AppColors.textMuted, icon: Icons.radio_button_checked, text: 'Lista para grabar'),
      RecState.problem => (color: AppColors.connecting, icon: Icons.warning_amber_rounded, text: 'No está grabando'),
      RecState.off => (color: AppColors.textMuted, icon: Icons.stop_circle_outlined, text: 'Grabación apagada'),
      RecState.unknown => (color: AppColors.textMuted, icon: Icons.help_outline, text: 'Sin revisar'),
    };

class _Pill extends StatelessWidget {
  const _Pill({required this.dot, required this.text, this.muted = false, this.color});

  final Widget dot;
  final String text;
  final bool muted;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          dot,
          const SizedBox(width: 3),
          Text(
            text,
            style: TextStyle(
              color: color ?? (muted ? Colors.white60 : Colors.white),
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}

class _BlinkingDot extends StatefulWidget {
  const _BlinkingDot();

  @override
  State<_BlinkingDot> createState() => _BlinkingDotState();
}

class _BlinkingDotState extends State<_BlinkingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.25, end: 1.0).animate(_c),
      child: Container(
        width: 7,
        height: 7,
        decoration: const BoxDecoration(color: AppColors.danger, shape: BoxShape.circle),
      ),
    );
  }
}
