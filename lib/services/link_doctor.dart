import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/device.dart';
import 'camera_http.dart';
import 'discovery.dart';
import 'network_config.dart';

// =============================================================================
// Pruebas de la conexión entre el NVR y una cámara
// =============================================================================

/// Resultado de preguntarle muchas veces seguidas a una IP "¿quién eres?".
class StabilityResult {
  StabilityResult({
    required this.attempts,
    required this.failures,
    required this.fingerprints,
    required this.latencies,
  });

  final int attempts;
  final int failures;

  /// Respuestas distintas recibidas (marca, número de serie, servidor).
  final Set<String> fingerprints;
  final List<int> latencies;

  double get loss => attempts == 0 ? 1 : failures / attempts;

  int? get medianMs {
    if (latencies.isEmpty) return null;
    final sorted = [...latencies]..sort();
    return sorted[sorted.length ~/ 2];
  }

  /// Contestan aparatos distintos en la misma IP.
  bool get mixedAnswers => fingerprints.length > 1;

  /// A veces contesta y a veces no (típico de una IP repetida o un cable malo).
  bool get intermittent => failures > 0 && failures < attempts;
}

/// "Huella" de una respuesta HTTP sin contraseña: identifica al aparato
/// (Dahua incluye su número de serie en el realm: "Login to 6J0A...").
String httpFingerprint(int status, Map<String, String> headers) {
  final auth = headers['www-authenticate'] ?? '';
  final realm = RegExp(r'realm="([^"]*)"').firstMatch(auth)?.group(1) ?? '';
  final server = headers['server'] ?? '';
  return '$status|$realm|$server';
}

/// Lista de IPs conectadas a una cámara Dahua (userManager getActiveUserInfoAll).
List<String> parseDahuaActiveUsers(String body) => [
      for (final m in RegExp(r'users\[\d+\]\.ip=([\d.]+)').allMatches(body)) m.group(1)!,
    ];

/// IPs candidatas para dejar una cámara fija, de las menos usadas por los
/// routers a las más usadas (los routers suelen repartir desde abajo).
List<String> freeIpCandidates(String subnet, Set<String> used) {
  final order = [
    for (var i = 200; i <= 249; i++) i,
    for (var i = 150; i <= 199; i++) i,
    for (var i = 100; i <= 149; i++) i,
  ];
  return [
    for (final i in order)
      if (!used.contains('$subnet.$i')) '$subnet.$i',
  ];
}

class LinkDoctor {
  /// Pregunta [rounds] veces a la IP quién es, sin contraseña y con una
  /// conexión nueva cada vez (para notar si contestan aparatos distintos).
  static Future<StabilityResult> probe(
    String ip, {
    int port = 80,
    int rounds = 16,
    Duration gap = const Duration(milliseconds: 500),
    void Function(int done)? onProgress,
  }) async {
    final fingerprints = <String>{};
    final latencies = <int>[];
    var failures = 0;
    for (var i = 0; i < rounds; i++) {
      final client = http.Client();
      final watch = Stopwatch()..start();
      try {
        final r = await client
            .get(Uri.parse('http://$ip:$port/cgi-bin/magicBox.cgi?action=getDeviceType'),
                headers: {'Connection': 'close'})
            .timeout(const Duration(seconds: 2));
        latencies.add(watch.elapsedMilliseconds);
        fingerprints.add(httpFingerprint(r.statusCode, r.headers));
      } catch (_) {
        failures++;
      } finally {
        client.close();
      }
      onProgress?.call(i + 1);
      await Future<void>.delayed(gap);
    }
    return StabilityResult(
      attempts: rounds,
      failures: failures,
      fingerprints: fingerprints,
      latencies: latencies,
    );
  }

  /// ¿Responde a ping? (null si el teléfono no permite usar ping).
  static Future<bool?> ping(String ip) async {
    try {
      final r = await Process.run('ping', ['-c', '2', '-W', '1', ip]).timeout(const Duration(seconds: 5));
      return r.exitCode == 0;
    } catch (_) {
      return null;
    }
  }

  /// ¿Hay algún aparato en esa IP? (ping y puertos comunes).
  static Future<bool> ipBusy(String ip) async {
    if (await ping(ip) == true) return true;
    return NetworkConfig.hostResponds(ip, [80, 443, 554, 8000, 37777, 22, 53, 8080, 62078],
        timeout: const Duration(milliseconds: 600));
  }

  /// Busca en la red equipos que respondan con esa IP; si responden dos
  /// aparatos distintos (dos MAC), hay un conflicto de IP.
  static Future<({bool conflict, Set<String> macs, List<FoundDevice> all})> scan(String ip) async {
    final all = await DiscoveryService().scan(duration: const Duration(seconds: 5));
    for (final d in all) {
      if (d.ip == ip) return (conflict: d.ipConflict, macs: d.macs, all: all);
    }
    return (conflict: false, macs: <String>{}, all: all);
  }

  /// Una IP libre de verdad (sin ping ni puertos, y que nadie más use).
  static Future<String?> findFreeIp(String subnet, Set<String> used, {void Function(String ip)? onTry}) async {
    var tried = 0;
    for (final ip in freeIpCandidates(subnet, used)) {
      if (tried++ > 25) break;
      onTry?.call(ip);
      if (await ipBusy(ip)) continue;
      // Segunda vuelta, por si el aparato estaba dormido.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (await ipBusy(ip)) continue;
      return ip;
    }
    return null;
  }

  /// IPs conectadas a la cámara ahora (solo Dahua). null = no se pudo saber.
  static Future<List<String>?> activeUsers(Device camera) async {
    if (camera.brand != Brand.dahua) return null;
    final h = CameraHttp(camera);
    try {
      final r = await h.get('/cgi-bin/userManager.cgi?action=getActiveUserInfoAll');
      if (r.statusCode != 200) return null;
      return parseDahuaActiveUsers(r.body);
    } catch (_) {
      return null;
    } finally {
      h.close();
    }
  }
}
