import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/app_store.dart';
import 'theme.dart';

class MisCamarasApp extends StatelessWidget {
  const MisCamarasApp({super.key, required this.store});

  final AppStore store;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mis Cámaras',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: HomeScreen(store: store),
    );
  }
}
