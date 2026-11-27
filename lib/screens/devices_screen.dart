import 'package:flutter/material.dart';

import '../models/device.dart';
import '../services/app_store.dart';
import '../theme.dart';
import '../widgets/brand_badge.dart';
import 'device_form_screen.dart';
import 'discovery_screen.dart';

/// Pestaña "Equipos": agregar, editar, eliminar y ordenar.
class DevicesScreen extends StatelessWidget {
  const DevicesScreen({super.key, required this.store});

  final AppStore store;

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
          trailing: IconButton(
            tooltip: 'Eliminar',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmDelete(context, d),
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
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _edit(context),
            icon: const Icon(Icons.add),
            label: const Text('Agregar'),
          ),
          body: devices.isEmpty
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
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
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
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
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
                    ),
        );
      },
    );
  }
}
