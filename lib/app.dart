import 'package:flutter/material.dart';

import 'screens/root_shell.dart';
import 'services/app_store.dart';
import 'services/update_service.dart';
import 'theme.dart';

class MisCamarasApp extends StatelessWidget {
  const MisCamarasApp({super.key, required this.store, required this.updates});

  final AppStore store;
  final UpdateService updates;

  @override
  Widget build(BuildContext context) {
    // Se vuelve a dibujar al cambiar el color principal en Ajustes.
    return ListenableBuilder(
      listenable: store,
      builder: (context, child) => MaterialApp(
        title: 'Mis Cámaras',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(store.accent),
        home: child,
      ),
      child: RootShell(store: store, updates: updates),
    );
  }
}
