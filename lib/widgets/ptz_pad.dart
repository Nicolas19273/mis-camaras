import 'dart:async';

import 'package:flutter/material.dart';

import '../ptz/ptz.dart';

/// Joystick para mover cámaras PTZ, con botones de zoom.
/// - Arrastra el círculo: la cámara gira en esa dirección; más lejos = más rápido.
/// - Suelta: la cámara se detiene.
/// - Mantén presionado + o −: zoom óptico.
class PtzPad extends StatefulWidget {
  const PtzPad({super.key, required this.support, this.size = 150, this.onInteract});

  final PtzSupport support;
  final double size;

  /// Se llama al tocar el control (para no ocultar los demás controles).
  final VoidCallback? onInteract;

  @override
  State<PtzPad> createState() => _PtzPadState();
}

class _PtzPadState extends State<PtzPad> {
  static const _minInterval = Duration(milliseconds: 120);

  Offset _knob = Offset.zero;
  Offset _target = Offset.zero;
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _pending;
  DateTime _lastErrorShown = DateTime.fromMillisecondsSinceEpoch(0);

  PtzDriver get _driver => widget.support.driver;

  @override
  void initState() {
    super.initState();
    _driver.onError = _showError;
  }

  @override
  void didUpdateWidget(PtzPad oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.support.driver != widget.support.driver) {
      oldWidget.support.driver.stop();
      _driver.onError = _showError;
    }
  }

  @override
  void dispose() {
    _pending?.cancel();
    _driver.stop();
    if (_driver.onError == _showError) _driver.onError = null;
    super.dispose();
  }

  void _showError(String message) {
    if (!mounted) return;
    final now = DateTime.now();
    if (now.difference(_lastErrorShown) < const Duration(seconds: 5)) return;
    _lastErrorShown = now;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('La cámara no aceptó el movimiento.')),
    );
  }

  double get _maxRadius => widget.size / 2 - 30;

  void _onDrag(Offset localPosition) {
    widget.onInteract?.call();
    final center = Offset(widget.size / 2, widget.size / 2);
    var v = localPosition - center;
    if (v.distance > _maxRadius) v = v / v.distance * _maxRadius;
    setState(() => _knob = v);

    // Vector de -1 a 1, con "arriba" positivo, redondeado a pasos de 0,1.
    double q(double x) => (x * 10).round() / 10;
    _target = Offset(q(v.dx / _maxRadius), q(-v.dy / _maxRadius));
    _flush();
  }

  void _flush() {
    final wait = _minInterval - DateTime.now().difference(_lastSent);
    if (wait > Duration.zero) {
      _pending ??= Timer(wait, () {
        _pending = null;
        _flush();
      });
      return;
    }
    _lastSent = DateTime.now();
    if (_target.distance < 0.15) {
      _driver.stop();
    } else {
      _driver.move(_target.dx, _target.dy);
    }
  }

  void _release() {
    _pending?.cancel();
    _pending = null;
    _target = Offset.zero;
    setState(() => _knob = Offset.zero);
    _driver.stop();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final support = widget.support;
    final size = widget.size;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (support.zoom) ...[
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _HoldButton(
                icon: Icons.add,
                label: 'Acercar',
                onDown: () {
                  widget.onInteract?.call();
                  _driver.zoom(1);
                },
                onUp: () => _driver.zoom(0),
              ),
              const SizedBox(height: 10),
              _HoldButton(
                icon: Icons.remove,
                label: 'Alejar',
                onDown: () {
                  widget.onInteract?.call();
                  _driver.zoom(-1);
                },
                onUp: () => _driver.zoom(0),
              ),
            ],
          ),
          const SizedBox(width: 14),
        ],
        if (support.panTilt)
          Semantics(
            label: 'Joystick para mover la cámara',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanDown: (d) => _onDrag(d.localPosition),
              onPanUpdate: (d) => _onDrag(d.localPosition),
              onPanEnd: (_) => _release(),
              onPanCancel: _release,
              child: SizedBox(
                width: size,
                height: size,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black.withValues(alpha: 0.38),
                          border: Border.all(color: Colors.white24, width: 1.5),
                        ),
                      ),
                    ),
                    const Positioned(top: 6, child: Icon(Icons.keyboard_arrow_up, color: Colors.white60)),
                    const Positioned(bottom: 6, child: Icon(Icons.keyboard_arrow_down, color: Colors.white60)),
                    const Positioned(left: 6, child: Icon(Icons.keyboard_arrow_left, color: Colors.white60)),
                    const Positioned(right: 6, child: Icon(Icons.keyboard_arrow_right, color: Colors.white60)),
                    Transform.translate(
                      offset: _knob,
                      child: Container(
                        width: 58,
                        height: 58,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: accent,
                          boxShadow: [
                            BoxShadow(color: accent.withValues(alpha: 0.45), blurRadius: 16),
                          ],
                        ),
                        child: const Icon(Icons.open_with, color: Colors.black87, size: 24),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Botón que actúa mientras se mantiene presionado.
class _HoldButton extends StatefulWidget {
  const _HoldButton({
    required this.icon,
    required this.label,
    required this.onDown,
    required this.onUp,
  });

  final IconData icon;
  final String label;
  final VoidCallback onDown;
  final VoidCallback onUp;

  @override
  State<_HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<_HoldButton> {
  bool _pressed = false;

  void _down() {
    setState(() => _pressed = true);
    widget.onDown();
  }

  void _up() {
    if (!_pressed) return;
    setState(() => _pressed = false);
    widget.onUp();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Semantics(
      button: true,
      label: widget.label,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _down(),
        onPointerUp: (_) => _up(),
        onPointerCancel: (_) => _up(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _pressed ? accent : Colors.black.withValues(alpha: 0.38),
            border: Border.all(color: Colors.white24, width: 1.5),
          ),
          child: Icon(widget.icon, color: _pressed ? Colors.black : Colors.white),
        ),
      ),
    );
  }
}
