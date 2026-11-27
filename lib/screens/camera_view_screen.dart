import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../brands/brand_adapter.dart';
import '../brands/brands.dart';
import '../models/device.dart';
import '../ptz/ptz.dart';
import '../services/camera_status.dart';
import '../widgets/brand_badge.dart';
import '../widgets/live_clock.dart';
import '../widgets/live_video.dart';
import '../widgets/ptz_pad.dart';
import '../widgets/status_dot.dart';

/// Una cámara en pantalla completa.
/// - Desliza a los lados para pasar a la cámara siguiente o anterior.
/// - Pellizca para hacer zoom. Doble toque para volver al tamaño normal.
/// - Toca para mostrar u ocultar los controles.
/// - Si la cámara es PTZ, aparece un joystick para moverla.
class CameraViewScreen extends StatefulWidget {
  const CameraViewScreen({
    super.key,
    required this.cameras,
    required this.initialIndex,
    this.restoreSystemUi = true,
  });

  final List<CameraRef> cameras;
  final int initialIndex;

  /// false cuando se abre desde el mosaico (que ya está en pantalla completa).
  final bool restoreSystemUi;

  @override
  State<CameraViewScreen> createState() => _CameraViewScreenState();
}

class _CameraViewScreenState extends State<CameraViewScreen> {
  late final PageController _pages = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  final _statuses = <int, LiveStatus>{};
  StreamQuality _quality = StreamQuality.main;
  bool _muted = true;
  bool _controls = true;
  bool _zoomed = false;
  Timer? _hideTimer;

  /// Resultado de revisar si cada cámara es PTZ (null = no lo es / aún no se sabe).
  final _ptz = <int, PtzSupport?>{};
  bool _ptzVisible = true;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _scheduleHide();
    _detectPtz(widget.initialIndex);
  }

  void _detectPtz(int index) {
    if (_ptz.containsKey(index)) return;
    final camera = widget.cameras[index];
    PtzService.detect(camera.device, camera.channel).then((support) {
      if (mounted) setState(() => _ptz[index] = support);
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _pages.dispose();
    if (widget.restoreSystemUi) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _controls = false);
    });
  }

  void _toggleControls() {
    setState(() => _controls = !_controls);
    if (_controls) _scheduleHide();
  }

  void _touch(VoidCallback action) {
    action();
    _scheduleHide();
  }

  void _goTo(int delta) {
    final target = _index + delta;
    if (target < 0 || target >= widget.cameras.length) return;
    _pages.animateToPage(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final camera = widget.cameras[_index];
    final status = _statuses[_index] ?? LiveStatus.connecting;
    final count = widget.cameras.length;
    final ptz = _ptz[_index];
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pages,
            physics: _zoomed
                ? const NeverScrollableScrollPhysics()
                : const PageScrollPhysics(),
            itemCount: count,
            onPageChanged: (i) {
              setState(() {
                _index = i;
                _zoomed = false;
              });
              _detectPtz(i);
            },
            itemBuilder: (context, i) => _CameraPage(
              camera: widget.cameras[i],
              quality: _quality,
              muted: _muted,
              onTap: _toggleControls,
              onZoomChanged: (z) {
                if (i == _index && z != _zoomed) setState(() => _zoomed = z);
              },
              onStatus: (s) {
                if (mounted) setState(() => _statuses[i] = s);
              },
            ),
          ),

          // Barra superior: volver, nombre, estado y reloj.
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: _Fade(
              visible: _controls,
              child: Container(
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
                    padding: const EdgeInsets.fromLTRB(4, 4, 12, 24),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back, color: Colors.white),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        BrandBadge(brand: camera.device.brand, size: 28),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                camera.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 2),
                              const LiveClock(
                                style: TextStyle(color: Colors.white70, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                        if (ptz != null) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              'PTZ',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        LiveBadge(status: status),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Barra inferior: anterior, calidad, sonido, siguiente.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _Fade(
              visible: _controls,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black87, Colors.transparent],
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 24, 12, 8),
                    child: Row(
                      children: [
                        _ControlButton(
                          icon: Icons.chevron_left,
                          enabled: _index > 0,
                          onTap: () => _touch(() => _goTo(-1)),
                        ),
                        const Spacer(),
                        _ControlButton(
                          label: _quality == StreamQuality.main ? 'HD' : 'SD',
                          onTap: () => _touch(() => setState(() {
                                _quality = _quality == StreamQuality.main
                                    ? StreamQuality.sub
                                    : StreamQuality.main;
                              })),
                        ),
                        const SizedBox(width: 10),
                        _ControlButton(
                          icon: _muted ? Icons.volume_off : Icons.volume_up,
                          onTap: () => _touch(() => setState(() => _muted = !_muted)),
                        ),
                        if (ptz != null) ...[
                          const SizedBox(width: 10),
                          _ControlButton(
                            icon: Icons.open_with,
                            highlighted: _ptzVisible,
                            onTap: () => _touch(() => setState(() => _ptzVisible = !_ptzVisible)),
                          ),
                        ],
                        const SizedBox(width: 10),
                        Text(
                          '${_index + 1} / $count',
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                        const Spacer(),
                        _ControlButton(
                          icon: Icons.chevron_right,
                          enabled: _index < count - 1,
                          onTap: () => _touch(() => _goTo(1)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Joystick PTZ: solo si la cámara se puede mover.
          if (ptz != null && _ptzVisible)
            Positioned(
              left: landscape ? null : 0,
              right: landscape ? 24 : 0,
              bottom: landscape ? 80 : 110,
              child: SafeArea(
                top: false,
                child: Center(
                  child: PtzPad(
                    key: ValueKey('ptz-$_index'),
                    support: ptz,
                    size: landscape ? 132 : 150,
                    onInteract: _scheduleHide,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Una página: video con zoom.
class _CameraPage extends StatefulWidget {
  const _CameraPage({
    required this.camera,
    required this.quality,
    required this.muted,
    required this.onTap,
    required this.onZoomChanged,
    required this.onStatus,
  });

  final CameraRef camera;
  final StreamQuality quality;
  final bool muted;
  final VoidCallback onTap;
  final ValueChanged<bool> onZoomChanged;
  final ValueChanged<LiveStatus> onStatus;

  @override
  State<_CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<_CameraPage> {
  final _zoom = TransformationController();
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _zoom.addListener(_onZoom);
  }

  void _onZoom() {
    final zoomed = _zoom.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) {
      setState(() => _zoomed = zoomed);
      widget.onZoomChanged(zoomed);
    }
  }

  @override
  void dispose() {
    _zoom.removeListener(_onZoom);
    _zoom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = widget.camera;
    final url = adapterFor(camera.device.brand)
        .rtspUrl(camera.device, camera.channel, widget.quality);

    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTap: () => _zoom.value = Matrix4.identity(),
      child: InteractiveViewer(
        transformationController: _zoom,
        minScale: 1,
        maxScale: 6,
        panEnabled: _zoomed,
        child: LiveVideo(
          url: url,
          fit: BoxFit.contain,
          muted: widget.muted,
          compact: false,
          onStatus: widget.onStatus,
        ),
      ),
    );
  }
}

class _Fade extends StatelessWidget {
  const _Fade({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: child,
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    this.icon,
    this.label,
    required this.onTap,
    this.enabled = true,
    this.highlighted = false,
  });

  final IconData? icon;
  final String? label;
  final VoidCallback onTap;
  final bool enabled;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final color = highlighted ? Colors.black : (enabled ? Colors.white : Colors.white24);
    return Material(
      color: highlighted ? accent : Colors.white.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: enabled ? onTap : null,
        child: SizedBox(
          width: 48,
          height: 40,
          child: Center(
            child: icon != null
                ? Icon(icon, color: color)
                : Text(
                    label ?? '',
                    style: TextStyle(color: color, fontWeight: FontWeight.w800),
                  ),
          ),
        ),
      ),
    );
  }
}
