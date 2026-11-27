import 'package:flutter/material.dart';

import '../models/device.dart';
import '../recording/recording.dart';
import '../recording/recording_api.dart';
import '../recording/recording_monitor.dart';
import '../services/app_store.dart';
import '../theme.dart';
import '../widgets/brand_badge.dart';
import 'device_form_screen.dart';
import 'discovery_screen.dart';
import 'groups_tab.dart';
import 'recording_screen.dart';

/// Pestaña "Equipos": agregar, editar, eliminar y ordenar equipos,
/// y armar grupos de cámaras (pestaña interna "Grupos").
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key, required this.store});

  final AppStore store;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this)
    ..addListener(() {
      if (mounted) setState(() {});
    });

  AppStore get store => widget.store;

  bool get _onGroups => _tabs.index == 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => RecordingMonitor.instance.refresh(store.devices));
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _openRecording(Device d) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => RecordingScreen(store: store, device: d)),
      );

  /// Botón con el estado de grabación del equipo (rojo = grabando).
  Widget _recButton(Device d) {
    final monitor = RecordingMonitor.instance;
    return ListenableBuilder(
      listenable: monitor,
      builder: (context, child) {
        final states = [for (var ch = 1; ch <= d.channels; ch++) monitor.stateOf(d, ch)];
        final Color color;
        final String tip;
        if (states.contains(RecState.problem)) {
          color = AppColors.connecting;
          tip = 'Grabación: hay un problema';
        } else if (states.contains(RecState.recording)) {
          color = AppColors.danger;
          tip = 'Grabación: grabando';
        } else {
          color = AppColors.textMuted;
          tip = 'Grabación';
        }
        return IconButton(
          tooltip: tip,
          icon: Icon(Icons.fiber_manual_record, color: color),
          onPressed: () => _openRecording(d),
        );
      },
    );
  }

  Future<void> _edit(BuildContext context, [Device? device]) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DeviceFormScreen(store: store, device: device),
      ),
    );
  }

  Future<void> _discover(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => DiscoveryScreen(store: store)),
    );
  }

  Future<void> _confirmDelete(BuildContext context, Device device) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Eliminar equipo'),
        content: Text(
          '¿Quitar "${device.name}" de la app? La cámara no se modifica.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (ok == true) await store.deleteDevice(device.id);
  }

  Widget _card(BuildContext context, Device d, {Key? key}) {
    final channels = d.channels == 1 ? 'Cámara' : 'NVR · ${d.channels} canales';
    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          contentPadding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          leading: BrandBadge(brand: d.brand, size: 40),
          title: Text(d.name, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(
            '${d.brand.label} · $channels\n${d.host}',
            style: const TextStyle(color: AppColors.textMuted, height: 1.35),
          ),
          isThreeLine: true,
          onTap: () => _edit(context, d),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (RecordingApi.supports(d)) _recButton(d),
              IconButton(
                tooltip: 'Eliminar',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _confirmDelete(context, d),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, child) {
        final devices = store.devices;
        final totalCameras = store.cameras.length;
        final groupCount = store.groups.length;

        return Scaffold(
          appBar: AppBar(
            backgroundColor: AppColors.background,
            surfaceTintColor: Colors.transparent,
            toolbarHeight: 64,
            titleSpacing: 16,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Equipos',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  devices.isEmpty
                      ? 'Ninguno todavía'
                      : '${devices.length} ${devices.length == 1 ? 'equipo' : 'equipos'} · '
                          '$totalCameras ${totalCameras == 1 ? 'cámara' : 'cámaras'}',
                  style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Buscar en mi red',
                icon: const Icon(Icons.wifi_find),
                onPressed: () => _discover(context),
              ),
              const SizedBox(width: 4),
            ],
            bottom: TabBar(
              controller: _tabs,
              tabs: [
                Tab(text: devices.isEmpty ? 'Equipos' : 'Equipos · ${devices.length}'),
                Tab(text: groupCount == 0 ? 'Grupos' : 'Grupos · $groupCount'),
              ],
            ),
          ),
          floatingActionButton: (_onGroups && store.allCameras.isEmpty)
              ? null
              : FloatingActionButton.extended(
                  onPressed: () => _onGroups ? GroupsTab.create(context, store) : _edit(context),
                  icon: Icon(_onGroups ? Icons.create_new_folder_outlined : Icons.add),
                  label: Text(_onGroups ? 'Nuevo grupo' : 'Agregar'),
                ),
          body: TabBarView(
            controller: _tabs,
            children: [
              _devicesBody(context, devices),
              GroupsTab(store: store),
            ],
          ),
        );
      },
    );
  }

  Widget _devicesBody(BuildContext context, List<Device> devices) {
    return devices.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Busca automáticamente las cámaras de tu WiFi, o toca "Agregar" '
                          'para sumar una a mano.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.textMuted, height: 1.45),
                        ),
                        const SizedBox(height: 20),
                        FilledButton.icon(
                          onPressed: () => _discover(context),
                          icon: const Icon(Icons.wifi_find),
                          label: const Text('Buscar en mi red'),
                        ),
                      ],
                    ),
                  ),
                )
              : (store.groupByBrand && store.brands.length > 1)
                  ? ListView(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 96),
                      children: [
                        for (final brand in store.brands) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
                            child: Row(
                              children: [
                                BrandBadge(brand: brand, size: 24),
                                const SizedBox(width: 10),
                                Text(
                                  brand.label,
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                                ),
                                const Spacer(),
                                Text(
                                  '${devices.where((d) => d.brand == brand).length} equipos',
                                  style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                                ),
                              ],
                            ),
                          ),
                          for (final d in devices.where((d) => d.brand == brand)) _card(context, d),
                        ],
                        const Padding(
                          padding: EdgeInsets.fromLTRB(8, 8, 8, 0),
                          child: Text(
                            'Vista separada por marca. Para cambiar el orden, vuelve a "todas juntas" '
                            'en En vivo o en Ajustes.',
                            style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                          ),
                        ),
                      ],
                    )
                  : ReorderableListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 96),
                      itemCount: devices.length,
                      onReorder: store.moveDevice,
                      header: const Padding(
                        padding: EdgeInsets.fromLTRB(8, 0, 8, 10),
                        child: Text(
                          'Mantén presionado un equipo y arrástralo para cambiar el orden del mosaico.',
                          style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                        ),
                      ),
                      itemBuilder: (context, index) =>
                          _card(context, devices[index], key: ValueKey(devices[index].id)),
                    );
  }
}
