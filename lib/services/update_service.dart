import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';

import '../config.dart';

/// Una versión publicada en GitHub Releases.
class ReleaseInfo {
  const ReleaseInfo({
    required this.buildNumber,
    required this.version,
    required this.apkUrl,
    required this.apkSize,
    required this.notes,
  });

  final int buildNumber;
  final String version;
  final String apkUrl;
  final int apkSize;
  final String notes;

  String get sizeLabel => '${(apkSize / (1024 * 1024)).toStringAsFixed(0)} MB';

  /// Se guarda junto a la descarga para recordarla si la app se cierra.
  String toMeta() => jsonEncode({'b': buildNumber, 'v': version, 's': apkSize, 'n': notes});

  static ReleaseInfo? fromMeta(String meta, String url) {
    try {
      final m = jsonDecode(meta) as Map<String, dynamic>;
      return ReleaseInfo(
        buildNumber: (m['b'] as num).toInt(),
        version: m['v'] as String,
        apkUrl: url,
        apkSize: (m['s'] as num?)?.toInt() ?? 0,
        notes: m['n'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

enum UpdateState {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  paused,
  ready,
  installing,
  error,
}

/// Busca versiones nuevas en GitHub y las instala.
/// - La descarga la hace Android en segundo plano: sigue con la pantalla
///   apagada o fuera de la app, con una notificación que muestra el avance.
/// - Si la app se cierra, al abrirla de nuevo recuerda la descarga.
/// - Si el archivo ya está descargado, "Actualizar" abre el instalador directo.
/// - Al terminar, se abre el instalador solo (si estás en la app) o con la
///   notificación "Toca para instalar" (si estás fuera).
class UpdateService extends ChangeNotifier with WidgetsBindingObserver {
  static const _taskId = 'actualizacion-mis-camaras';
  static const _apkMime = 'application/vnd.android.package-archive';

  UpdateState _state = UpdateState.idle;
  ReleaseInfo? _release;
  String? _error;
  double _progress = 0;
  String? _readyPath;
  int _readyBuild = 0;
  bool _installWhenReady = false;
  bool _initialized = false;

  UpdateState get state => _state;
  ReleaseInfo? get release => _release;
  String? get error => _error;

  /// Avance de la descarga, de 0 a 1.
  double get progress => _progress;

  /// Hay una versión nueva (disponible, descargando o lista).
  bool get hasUpdate {
    final r = _release;
    if (r == null || r.buildNumber <= AppConfig.buildNumber) return false;
    return _state != UpdateState.checking && _state != UpdateState.upToDate;
  }

  /// El archivo de la versión nueva ya está completo en el teléfono.
  bool get isDownloaded {
    final r = _release;
    return _readyPath != null && r != null && _readyBuild == r.buildNumber;
  }

  bool get isBusy =>
      _state == UpdateState.checking ||
      _state == UpdateState.downloading ||
      _state == UpdateState.installing;

  /// Texto corto para avisos (barra en "En vivo" y Ajustes).
  String get summary {
    final v = _release?.version ?? '';
    return switch (_state) {
      UpdateState.downloading => 'Descargando versión $v… ${(_progress * 100).toStringAsFixed(0)} %',
      UpdateState.paused => 'Descarga de la versión $v en pausa',
      UpdateState.ready || UpdateState.installing => 'Versión $v lista para instalar',
      UpdateState.error => isDownloaded ? 'Versión $v lista para instalar' : 'No se pudo descargar la versión $v',
      _ => 'Nueva versión $v disponible',
    };
  }

  /// Texto del botón principal.
  String get actionLabel {
    if (isDownloaded) return 'Instalar ahora';
    return switch (_state) {
      UpdateState.downloading => 'Descargando…',
      UpdateState.paused => 'Continuar descarga',
      UpdateState.error => 'Reintentar',
      _ => 'Actualizar ahora',
    };
  }

  static const _headers = {
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'MisCamaras-App',
  };

  // ---------------------------------------------------------------------------
  // Inicio
  // ---------------------------------------------------------------------------

  /// Prepara el descargador y recupera una descarga anterior, si la hay.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);
    try {
      FileDownloader().configureNotification(
        running: const TaskNotification(
          'Descargando actualización',
          'Mis Cámaras {displayName} · {progress}',
        ),
        complete: const TaskNotification(
          'Actualización descargada',
          'Toca para instalar Mis Cámaras {displayName}',
        ),
        error: const TaskNotification(
          'No se pudo descargar la actualización',
          'Abre Mis Cámaras para reintentar',
        ),
        paused: const TaskNotification(
          'Descarga en pausa',
          'Abre Mis Cámaras para continuar',
        ),
        progressBar: true,
        tapOpensFile: true,
      );
      FileDownloader().updates.listen(_onTaskUpdate);
      await FileDownloader().start();
      await _restore();
    } catch (e) {
      debugPrint('No se pudo preparar el actualizador: $e');
    }
  }

  Future<void> _restore() async {
    final record = await FileDownloader().database.recordForId(_taskId);
    if (record == null) return;
    final info = ReleaseInfo.fromMeta(record.task.metaData, record.task.url);
    if (info == null) return;

    // Ya está instalada esa versión (o una más nueva): se borra el archivo.
    if (info.buildNumber <= AppConfig.buildNumber) {
      await _deleteFile(record.task);
      return;
    }

    _release ??= info;
    switch (record.status) {
      case TaskStatus.complete:
        final path = await record.task.filePath();
        if (await File(path).exists()) {
          _readyPath = path;
          _readyBuild = info.buildNumber;
          _progress = 1;
          _set(UpdateState.ready);
        }
      case TaskStatus.paused:
        _progress = record.progress.clamp(0.0, 1.0);
        _set(UpdateState.paused);
      case TaskStatus.running:
      case TaskStatus.enqueued:
      case TaskStatus.waitingToRetry:
        _progress = record.progress.clamp(0.0, 1.0);
        _set(UpdateState.downloading);
      default:
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Buscar versión nueva
  // ---------------------------------------------------------------------------

  /// Consulta la última versión publicada.
  /// Devuelve true si hay una más nueva que la instalada.
  Future<bool> check() async {
    if (_state == UpdateState.downloading ||
        _state == UpdateState.installing ||
        _state == UpdateState.checking) {
      return hasUpdate;
    }
    final previous = _state;
    _set(UpdateState.checking);

    try {
      final uri = Uri.parse(
        'https://api.github.com/repos/${AppConfig.githubRepo}/releases/latest',
      );
      final res = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 15));

      if (res.statusCode == 404) {
        return _fail(
          'No se encontró ninguna versión publicada. '
          'Si el repositorio de GitHub es privado, hay que hacerlo público.',
        );
      }
      if (res.statusCode == 403 || res.statusCode == 429) {
        return _fail('GitHub limitó las consultas por un rato. Intenta más tarde.');
      }
      if (res.statusCode != 200) {
        return _fail('GitHub respondió con un error (${res.statusCode}).');
      }

      final info = parseRelease(jsonDecode(res.body) as Map<String, dynamic>);
      if (info == null) {
        return _fail('La última versión publicada no trae el archivo de instalación.');
      }

      _release = info;
      if (info.buildNumber <= AppConfig.buildNumber) {
        _set(UpdateState.upToDate);
        return false;
      }
      if (isDownloaded) {
        _set(UpdateState.ready);
      } else if (previous == UpdateState.paused) {
        _set(UpdateState.paused);
      } else {
        _set(UpdateState.available);
      }
      return true;
    } on SocketException {
      return _fail('Sin conexión a internet.');
    } catch (e) {
      return _fail('No se pudo revisar si hay actualizaciones.');
    }
  }

  // ---------------------------------------------------------------------------
  // Descargar e instalar
  // ---------------------------------------------------------------------------

  /// Botón "Actualizar": instala si ya está descargada; si no, descarga
  /// en segundo plano y abre el instalador al terminar.
  Future<void> startUpdate() async {
    final release = _release;
    if (release == null) return;
    _installWhenReady = true;

    if (isDownloaded) {
      await _install();
      return;
    }
    if (_state == UpdateState.downloading) return;

    try {
      // Si quedó en pausa, se retoma donde iba.
      if (_state == UpdateState.paused) {
        final record = await FileDownloader().database.recordForId(_taskId);
        final task = record?.task;
        if (task is DownloadTask && await FileDownloader().resume(task)) {
          _set(UpdateState.downloading);
          return;
        }
      }

      await _ensureNotificationPermission();

      final task = DownloadTask(
        taskId: _taskId,
        url: release.apkUrl,
        filename: 'MisCamaras-${release.version}.apk',
        baseDirectory: BaseDirectory.applicationSupport,
        directory: 'actualizaciones',
        updates: Updates.statusAndProgress,
        retries: 3,
        allowPause: true,
        metaData: release.toMeta(),
        displayName: release.version,
      );
      _progress = 0;
      _set(UpdateState.downloading);
      final ok = await FileDownloader().enqueue(task);
      if (!ok) _fail('No se pudo iniciar la descarga.');
    } catch (e) {
      _fail('No se pudo iniciar la descarga: $e');
    }
  }

  Future<void> _ensureNotificationPermission() async {
    try {
      const type = PermissionType.notifications;
      final status = await FileDownloader().permissions.status(type);
      if (status != PermissionStatus.granted) {
        await FileDownloader().permissions.request(type);
      }
    } catch (_) {
      // Sin permiso igual descarga; solo no se ve la notificación.
    }
  }

  void _onTaskUpdate(TaskUpdate update) {
    if (update.task.taskId != _taskId) return;

    if (update is TaskProgressUpdate) {
      final p = update.progress;
      if (p >= 0 && p <= 1) {
        _progress = p;
        if (_state != UpdateState.ready && _state != UpdateState.installing) {
          _state = UpdateState.downloading;
        }
        notifyListeners();
      }
      return;
    }

    if (update is TaskStatusUpdate) {
      switch (update.status) {
        case TaskStatus.complete:
          _onDownloaded(update.task);
        case TaskStatus.paused:
          _set(UpdateState.paused);
        case TaskStatus.canceled:
          _set(UpdateState.available);
        case TaskStatus.failed:
        case TaskStatus.notFound:
          _fail('Se cortó la descarga. Toca "Reintentar" para seguir.');
        default:
          if (_state != UpdateState.downloading) _set(UpdateState.downloading);
      }
    }
  }

  Future<void> _onDownloaded(Task task) async {
    final info = ReleaseInfo.fromMeta(task.metaData, task.url);
    _readyPath = await task.filePath();
    _readyBuild = info?.buildNumber ?? _release?.buildNumber ?? 0;
    _release ??= info;
    _progress = 1;
    _set(UpdateState.ready);

    // Si estás en la app, se abre el instalador al tiro.
    // Si estás fuera, queda la notificación "Toca para instalar"
    // y el instalador se abre solo al volver a la app.
    if (_installWhenReady && _inForeground) await _install();
  }

  bool get _inForeground =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _installWhenReady &&
        _state == UpdateState.ready) {
      _install();
    }
  }

  Future<void> _install() async {
    final path = _readyPath;
    if (path == null) return;
    if (!await File(path).exists()) {
      _readyPath = null;
      _set(UpdateState.available);
      return;
    }
    // Se abre una sola vez por toque, para no insistir si cancelas.
    _installWhenReady = false;
    _set(UpdateState.installing);

    var opened = false;
    try {
      opened = await FileDownloader().openFile(filePath: path, mimeType: _apkMime);
    } catch (_) {}
    if (!opened) {
      try {
        final result = await OpenFilex.open(path, type: _apkMime);
        opened = result.type == ResultType.done;
      } catch (_) {}
    }
    if (!opened) {
      _fail('No se pudo abrir el instalador.');
      return;
    }
    // Android muestra ahora "¿Quieres actualizar esta app?".
    // Si cancelas, el botón sigue diciendo "Instalar ahora".
    _set(UpdateState.ready);
  }

  Future<void> _deleteFile(Task task) async {
    try {
      final file = File(await task.filePath());
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------

  /// Lee la respuesta de GitHub. Es pública para poder probarla.
  static ReleaseInfo? parseRelease(Map<String, dynamic> json) {
    final tag = (json['tag_name'] as String? ?? '').trim();
    // Las etiquetas tienen la forma v0.3.15: el último número es la compilación.
    final build = int.tryParse(tag.split('.').last) ?? 0;

    final assets = (json['assets'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
    Map<String, dynamic>? apk;
    for (final a in assets) {
      if ((a['name'] as String? ?? '').toLowerCase().endsWith('.apk')) {
        apk = a;
        break;
      }
    }
    if (apk == null) return null;

    return ReleaseInfo(
      buildNumber: build,
      version: tag.startsWith('v') ? tag.substring(1) : tag,
      apkUrl: apk['browser_download_url'] as String,
      apkSize: (apk['size'] as num?)?.toInt() ?? 0,
      notes: (json['body'] as String? ?? '').trim(),
    );
  }

  bool _fail(String message) {
    _error = message;
    _set(UpdateState.error);
    return false;
  }

  void _set(UpdateState s) {
    _state = s;
    if (s != UpdateState.error) _error = null;
    notifyListeners();
  }
}
