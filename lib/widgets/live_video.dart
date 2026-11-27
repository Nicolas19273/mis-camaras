import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../services/camera_status.dart';
import '../theme.dart';

/// Reproductor de video en vivo por RTSP.
/// - Muestra un indicador mientras conecta.
/// - Si el video se corta después de haber funcionado, se reconecta solo.
/// - Si no conecta la primera vez, prueba la ruta alternativa ([fallbackUrl])
///   y reintenta unas pocas veces más (muchas cámaras juntas pueden saturar
///   al grabador por un momento).
/// - Si la contraseña está mal (401), NO reintenta, para no bloquear la cuenta.
/// - Se detiene cuando la app pasa a segundo plano y vuelve al regresar.
class LiveVideo extends StatefulWidget {
  const LiveVideo({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.muted = true,
    this.compact = true,
    this.onStatus,
    this.fallbackUrl,
  });

  final String url;

  /// Otra dirección para la misma cámara si [url] no funciona
  /// (por ejemplo, el flujo principal si falla el secundario).
  final String? fallbackUrl;
  final BoxFit fit;
  final bool muted;

  /// true = vista chica (mosaico): muestra el error de forma resumida.
  final bool compact;

  /// Avisa cuando la cámara pasa a conectando / en vivo / sin conexión.
  final ValueChanged<LiveStatus>? onStatus;

  @override
  State<LiveVideo> createState() => LiveVideoState();
}

class LiveVideoState extends State<LiveVideo> with WidgetsBindingObserver {
  late final Player _player;
  late final VideoController _controller;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Timer? _retryTimer;

  bool _hasVideo = false;
  bool _everPlayed = false;
  bool _suspended = false;
  bool _disposed = false;
  String? _error;
  LiveStatus? _lastStatus;

  /// Dirección en uso (la normal o la alternativa).
  late String _url = widget.url;

  /// Intentos fallidos sin haber visto video nunca.
  int _failures = 0;
  static const _retryDelays = [Duration(seconds: 4), Duration(seconds: 10), Duration(seconds: 25)];
  static final _random = Random();

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
      _emitStatus();
    }));

    _subscriptions.add(_player.stream.error.listen((message) {
      if (!mounted || _suspended || _hasVideo) return;
      setState(() => _error = message);
      _emitStatus();
      if (_everPlayed) {
        _scheduleRetry(const Duration(seconds: 5));
      } else {
        _onFirstFailure(message);
      }
    }));

    // En vivo, "terminado" significa que se cortó la conexión.
    _subscriptions.add(_player.stream.completed.listen((completed) {
      if (!completed || !mounted || _suspended) return;
      setState(() {
        _hasVideo = false;
        if (!_everPlayed) _error ??= 'Sin señal';
      });
      _emitStatus();
      if (_everPlayed) {
        _scheduleRetry(const Duration(seconds: 3));
      } else {
        _onFirstFailure(_error ?? '');
      }
    }));

    // Pequeña espera al azar: así no se conectan todas las cámaras en el
    // mismo instante (los grabadores rechazan conexiones si llegan juntas).
    _retryTimer = Timer(Duration(milliseconds: _random.nextInt(900)), () {
      if (!_disposed && !_suspended) _open();
    });
  }

  static bool _isAuthError(String message) {
    final m = message.toLowerCase();
    return m.contains('401') || m.contains('unauthorized') || m.contains('authoriz');
  }

  /// Nunca llegó video: prueba la ruta alternativa y luego reintenta
  /// unas pocas veces, salvo que sea la contraseña.
  void _onFirstFailure(String message) {
    if (_isAuthError(message) || (_retryTimer?.isActive ?? false)) return;
    final alt = widget.fallbackUrl;
    if (alt != null && _url != alt) {
      _url = alt;
      _scheduleRetry(const Duration(milliseconds: 300));
      return;
    }
    if (_failures >= _retryDelays.length) return;
    final delay = _retryDelays[_failures];
    _failures++;
    // Vuelve a la dirección normal en cada vuelta (la alternativa se prueba de nuevo si falla).
    if (alt != null) _url = widget.url;
    _scheduleRetry(delay);
  }

  @override
  void didUpdateWidget(LiveVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _everPlayed = false;
      _failures = 0;
      _url = widget.url;
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

  LiveStatus get _status {
    if (_hasVideo) return LiveStatus.live;
    if (_error != null) return LiveStatus.offline;
    return LiveStatus.connecting;
  }

  /// Avisa el estado fuera del ciclo de dibujo (evita errores de Flutter
  /// al cambiar el estado de otra pantalla mientras se arma esta).
  void _emitStatus() {
    final status = _status;
    if (status == _lastStatus) return;
    _lastStatus = status;
    final callback = widget.onStatus;
    if (callback == null) return;
    scheduleMicrotask(() {
      if (!_disposed) callback(status);
    });
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
    _emitStatus();

    await _configureForRtsp(_player);
    if (_disposed) return;
    await _player.setVolume(widget.muted ? 0 : 100);
    if (_disposed) return;
    await _player.open(Media(_url));
  }

  /// Foto del cuadro actual (JPEG), o null si todavía no hay video.
  Future<Uint8List?> snapshot() async {
    if (!_hasVideo) return null;
    try {
      return await _player.screenshot();
    } catch (_) {
      return null;
    }
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
                ? SizedBox(
                    width: widget.compact ? 18 : 26,
                    height: widget.compact ? 18 : 26,
                    child: const CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white54,
                    ),
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
        Icon(
          Icons.videocam_off_outlined,
          color: AppColors.textMuted,
          size: compact ? 20 : 32,
        ),
        const SizedBox(height: 4),
        const Text(
          'Sin conexión',
          style: TextStyle(color: AppColors.textMuted, fontSize: 11),
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
