import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'services/app_store.dart';
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

  runApp(MisCamarasApp(store: store, updates: UpdateService()));
}
