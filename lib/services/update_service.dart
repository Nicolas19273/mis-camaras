import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

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
}

enum UpdateState { idle, checking, upToDate, available, downloading, installing, error }

/// Revisa si hay una versión nueva en GitHub, la descarga y abre el
/// instalador de Android. Como cada versión está firmada con la misma clave,
/// se instala encima de la actual sin perder los equipos guardados.
class UpdateService extends ChangeNotifier {
  UpdateState _state = UpdateState.idle;
  ReleaseInfo? _release;
  String? _error;
  double _progress = 0;

  UpdateState get state => _state;
  ReleaseInfo? get release => _release;
  String? get error => _error;

  /// Avance de la descarga, de 0 a 1.
  double get progress => _progress;

  bool get hasUpdate =>
      _release != null &&
      (_state == UpdateState.available ||
          _state == UpdateState.downloading ||
          _state == UpdateState.installing ||
          (_state == UpdateState.error && _progress > 0));

  bool get isBusy =>
      _state == UpdateState.checking ||
      _state == UpdateState.downloading ||
      _state == UpdateState.installing;

  static const _headers = {
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'MisCamaras-App',
  };

  /// Consulta la última versión publicada.
  /// Devuelve true si hay una más nueva que la instalada.
  Future<bool> check() async {
    if (isBusy) return hasUpdate;
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
      if (info.buildNumber > AppConfig.buildNumber) {
        _set(UpdateState.available);
        return true;
      }
      _set(UpdateState.upToDate);
      return false;
    } on SocketException {
      return _fail('Sin conexión a internet.');
    } catch (e) {
      return _fail('No se pudo revisar si hay actualizaciones.');
    }
  }

  /// Descarga el APK y abre el instalador de Android.
  Future<void> downloadAndInstall() async {
    final release = _release;
    if (release == null || isBusy) return;

    _progress = 0;
    _set(UpdateState.downloading);

    final client = http.Client();
    try {
      final dir = await getTemporaryDirectory();
      await _deleteOldApks(dir);
      final file = File('${dir.path}/MisCamaras-${release.version}.apk');

      final request = http.Request('GET', Uri.parse(release.apkUrl))
        ..headers['User-Agent'] = 'MisCamaras-App';
      final response = await client.send(request);
      if (response.statusCode != 200) {
        _fail('No se pudo descargar la actualización (${response.statusCode}).');
        return;
      }

      final total = response.contentLength ?? release.apkSize;
      final sink = file.openWrite();
      var received = 0;
      var lastNotified = 0.0;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) {
            _progress = received / total;
            // Avisa a la pantalla cada 1 % para no recargarla de más.
            if (_progress - lastNotified >= 0.01) {
              lastNotified = _progress;
              notifyListeners();
            }
          }
        }
      } finally {
        await sink.close();
      }

      _progress = 1;
      _set(UpdateState.installing);

      final result = await OpenFilex.open(
        file.path,
        type: 'application/vnd.android.package-archive',
      );
      if (result.type != ResultType.done) {
        _fail('No se pudo abrir el instalador: ${result.message}');
        return;
      }
      // Android muestra ahora su ventana "¿Quieres actualizar esta app?".
      // Volvemos al estado "disponible" por si la persona cancela.
      _set(UpdateState.available);
    } on SocketException {
      _fail('Se cortó la conexión durante la descarga.');
    } catch (e) {
      _fail('Falló la descarga: $e');
    } finally {
      client.close();
    }
  }

  /// Lee la respuesta de GitHub. Es pública para poder probarla.
  static ReleaseInfo? parseRelease(Map<String, dynamic> json) {
    final tag = (json['tag_name'] as String? ?? '').trim();
    // Las etiquetas tienen la forma v0.2.15: el último número es la compilación.
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

  Future<void> _deleteOldApks(Directory dir) async {
    try {
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.toLowerCase().endsWith('.apk')) {
          await entity.delete();
        }
      }
    } catch (_) {
      // No es grave si no se pueden borrar.
    }
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
