import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'services/app_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicializa el reproductor de video (mpv), que entiende RTSP.
  MediaKit.ensureInitialized();

  // Carga los equipos guardados antes de mostrar la app.
  final store = AppStore();
  await store.load();

  runApp(MisCamarasApp(store: store));
}
