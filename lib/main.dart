import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'recording/recording_monitor.dart';
import 'services/app_store.dart';
import 'services/network_watcher.dart';
import 'services/update_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicializa el reproductor de video (mpv), que entiende RTSP.
  MediaKit.ensureInitialized();

  // Barras del sistema transparentes, para que la app se vea de borde a borde.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  // Carga los equipos guardados antes de mostrar la app.
  final store = AppStore();
  await store.load();

  // Último estado de grabación conocido (para mostrar ● REC de inmediato).
  await RecordingMonitor.instance.load();

  // Vigila la red WiFi: muestra solo los equipos de la red actual.
  NetworkWatcher(store).start();

  // Prepara el actualizador y recupera una descarga que haya quedado a medias.
  final updates = UpdateService();
  await updates.init();

  runApp(MisCamarasApp(store: store, updates: updates));
}
