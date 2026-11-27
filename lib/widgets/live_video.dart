import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../theme.dart';

/// Reproductor de video en vivo por RTSP.
/// - Muestra un indicador mientras conecta.
/// - Si el video se corta después de haber funcionado, se reconecta solo.
/// - Si nunca conectó, NO reintenta solo (para no bloquear la cuenta de la
///   cámara por intentos fallidos si la contraseña está mal).
/// - Se detiene cuando la app pasa a segundo plano y vuelve al regresar.
class LiveVideo extends StatefulWidget {
  const LiveVideo({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.muted = true,
    this.compact = true,
  });

  final String url;
  final BoxFit fit;
  final bool muted;

  /// true = vista chica (cuadrícula): muestra el error de forma resumida.
  final bool compact;

  @override
  State<LiveVideo> createState() => _LiveVideoState();
}

class _LiveVideoState extends State<LiveVideo> with WidgetsBindingObserver {
  late final Player _player;
  late final VideoController _controller;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Timer? _retryTimer;

  bool _hasVideo = false;
  bool _everPlayed = false;
  bool _suspended = false;
  bool _disposed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _player = Player();
    _controller = VideoController(_player);

    // Cuando llega el primer cuadro, el video tiene ancho > 0.
    _subscriptions.add(_player.stream.width.listen((width) {
      if (!mounted) return;
      final hasVideo = (width ?? 0) > 0;
      setState(() {
        _hasVideo = hasVideo;
        if (hasVideo) {
          _everPlayed = true;
          _error = null;
        }
      });
    }));

    _subscriptions.add(_player.stream.error.listen((message) {
      if (!mounted || _suspended || _hasVideo) return;
      setState(() => _error = message);
      if (_everPlayed) _scheduleRetry(const Duration(seconds: 5));
    }));

    // En vivo, "terminado" significa que se cortó la conexión.
    _subscriptions.add(_player.stream.completed.listen((completed) {
      if (!completed || !mounted || _suspended) return;
      setState(() {
        _hasVideo = false;
        if (!_everPlayed) _error ??= 'Sin señal';
      });
      if (_everPlayed) _scheduleRetry(const Duration(seconds: 3));
    }));

    _open();
  }

  @override
  void didUpdateWidget(LiveVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _everPlayed = false;
      _open();
    } else if (oldWidget.muted != widget.muted) {
      _player.setVolume(widget.muted ? 0 : 100);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      if (_suspended) return;
      _suspended = true;
      _retryTimer?.cancel();
      _player.stop();
    } else if (state == AppLifecycleState.resumed && _suspended) {
      _suspended = false;
      _open();
    }
  }

  Future<void> _open() async {
    _retryTimer?.cancel();
    if (_disposed) return;
    if (_hasVideo || _error != null) {
      setState(() {
        _hasVideo = false;
        _error = null;
      });
    }

    await _configureForRtsp(_player);
    if (_disposed) return;
    await _player.setVolume(widget.muted ? 0 : 100);
    if (_disposed) return;
    await _player.open(Media(widget.url));
  }

  void _scheduleRetry(Duration delay) {
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      if (!_disposed && !_suspended) _open();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _retryTimer?.cancel();
    for (final s in _subscriptions) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        Video(
          controller: _controller,
          fit: widget.fit,
          controls: NoVideoControls,
        ),
        if (!_hasVideo)
          Center(
            child: _error == null
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : _ErrorView(
                    compact: widget.compact,
                    detail: _error!,
                    onRetry: _open,
                  ),
          ),
      ],
    );
  }
}

/// Ajustes del reproductor pensados para cámaras:
/// - RTSP sobre TCP: más estable en WiFi y redes móviles que UDP.
/// - Sin caché: menos retraso respecto a la realidad.
/// - Timeout de red de 10 s para detectar cortes.
/// Si quieres ajustar latencia o estabilidad, este es el lugar.
Future<void> _configureForRtsp(Player player) async {
  // Se usa "dynamic" para no depender del nombre interno de la clase
  // del reproductor nativo, que puede cambiar entre versiones.
  final dynamic platform = player.platform;
  try {
    await platform.setProperty('rtsp-transport', 'tcp');
    await platform.setProperty('cache', 'no');
    await platform.setProperty('network-timeout', '10');
  } catch (e) {
    debugPrint('No se pudieron aplicar los ajustes RTSP: $e');
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({
    required this.compact,
    required this.detail,
    required this.onRetry,
  });

  final bool compact;
  final String detail;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    // Quita usuario y contraseña si el mensaje del reproductor incluye la URL.
    final safeDetail = detail.replaceAll(RegExp(r'//[^@/\s]+@'), '//');

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.videocam_off_outlined, color: AppColors.textMuted),
        const SizedBox(height: 4),
        const Text(
          'Sin conexión',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12),
        ),
        if (!compact) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
            child: Text(
              safeDetail,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Reintentar')),
        ],
      ],
    );
  }
}
