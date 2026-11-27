import 'dart:async';

import 'package:flutter/material.dart';

/// Reloj que se actualiza cada segundo (fecha y hora, estilo NVR).
class LiveClock extends StatefulWidget {
  const LiveClock({super.key, this.showDate = true, this.style});

  final bool showDate;
  final TextStyle? style;

  @override
  State<LiveClock> createState() => _LiveClockState();
}

class _LiveClockState extends State<LiveClock> {
  late Timer _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final time = '${_two(_now.hour)}:${_two(_now.minute)}:${_two(_now.second)}';
    final date = '${_two(_now.day)}/${_two(_now.month)}/${_now.year}';
    return Text(
      widget.showDate ? '$date  $time' : time,
      style: widget.style ??
          const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
    );
  }
}
