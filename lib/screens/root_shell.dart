import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/app_store.dart';
import '../services/network_watcher.dart';
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAskWifiName());
  }

  /// Una sola vez: pide ver el nombre del WiFi para separar bien los equipos por red.
  Future<void> _maybeAskWifiName() async {
    await Future<void>.delayed(const Duration(seconds: 2));
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('asked_wifi_name') == true || widget.store.devices.isEmpty) return;
    if (await NetworkWatcher.hasPermission()) return;
    await prefs.setBool('asked_wifi_name', true);
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Separar tus cámaras por red'),
        content: const Text(
          'La app muestra solo los equipos de la red WiFi en la que estás; los de otras redes quedan '
          'en espera. Para reconocer cada WiFi por su nombre, Android pide el permiso de "ubicación". '
          'La app no usa tu ubicación para nada más.',
          style: TextStyle(height: 1.4),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Ahora no')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Permitir')),
        ],
      ),
    );
    if (ok == true) {
      await NetworkWatcher.requestPermission();
      await NetworkWatcher.instance?.refreshNow();
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
