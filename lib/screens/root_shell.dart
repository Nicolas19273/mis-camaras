import 'package:flutter/material.dart';

import '../services/app_store.dart';
import '../services/update_service.dart';
import '../theme.dart';
import 'devices_screen.dart';
import 'live_screen.dart';
import 'settings_screen.dart';

/// Estructura principal: tres pestañas abajo (En vivo, Equipos, Ajustes).
class RootShell extends StatefulWidget {
  const RootShell({super.key, required this.store, required this.updates});

  final AppStore store;
  final UpdateService updates;

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    // Busca actualizaciones al abrir la app, sin molestar si no hay.
    if (widget.store.autoUpdate) {
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.updates.check());
    }
  }

  @override
  Widget build(BuildContext context) {
    // Solo se arma la pestaña visible: así el video se detiene al cambiar
    // de pestaña y no se gastan datos en segundo plano.
    final body = switch (_tab) {
      0 => LiveScreen(store: widget.store, updates: widget.updates),
      1 => DevicesScreen(store: widget.store),
      _ => SettingsScreen(store: widget.store, updates: widget.updates),
    };

    return Scaffold(
      body: body,
      bottomNavigationBar: ListenableBuilder(
        listenable: widget.updates,
        builder: (context, child) => NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          backgroundColor: AppColors.surface,
          height: 64,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.videocam_outlined),
              selectedIcon: Icon(Icons.videocam),
              label: 'En vivo',
            ),
            const NavigationDestination(
              icon: Icon(Icons.dns_outlined),
              selectedIcon: Icon(Icons.dns),
              label: 'Equipos',
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: widget.updates.hasUpdate,
                child: const Icon(Icons.settings_outlined),
              ),
              selectedIcon: Badge(
                isLabelVisible: widget.updates.hasUpdate,
                child: const Icon(Icons.settings),
              ),
              label: 'Ajustes',
            ),
          ],
        ),
      ),
    );
  }
}
