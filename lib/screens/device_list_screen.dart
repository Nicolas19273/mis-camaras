import 'package:flutter/material.dart';

import '../models/device.dart';
import '../services/app_store.dart';
import '../theme.dart';
import '../widgets/brand_badge.dart';
import 'device_form_screen.dart';

/// Lista de equipos guardados: agregar, editar y eliminar.
class DeviceListScreen extends StatelessWidget {
  const DeviceListScreen({super.key, required this.store});

  final AppStore store;

  Future<void> _edit(BuildContext context, [Device? device]) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DeviceFormScreen(store: store, device: device),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, Device device) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, child) {
        final devices = store.devices;
        return Scaffold(
          appBar: AppBar(title: const Text('Equipos')),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _edit(context),
            icon: const Icon(Icons.add),
            label: const Text('Agregar'),
          ),
          body: devices.isEmpty
              ? const Center(
                  child: Text(
                    'No hay equipos todavía.',
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                  itemCount: devices.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final d = devices[index];
                    final channels = d.channels == 1 ? '1 canal' : '${d.channels} canales';
                    return Material(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(14),
                      clipBehavior: Clip.antiAlias,
                      child: ListTile(
                        leading: BrandBadge(brand: d.brand),
                        title: Text(d.name),
                        subtitle: Text(
                          '${d.brand.label} · ${d.host} · $channels',
                          style: const TextStyle(color: AppColors.textMuted),
                        ),
                        onTap: () => _edit(context, d),
                        trailing: IconButton(
                          tooltip: 'Eliminar',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _confirmDelete(context, d),
                        ),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}
