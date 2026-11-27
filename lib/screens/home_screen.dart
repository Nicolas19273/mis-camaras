import 'package:flutter/material.dart';

import '../models/device.dart';
import '../services/app_store.dart';
import '../theme.dart';
import '../widgets/camera_tile.dart';
import 'device_form_screen.dart';
import 'device_list_screen.dart';
import 'live_view_screen.dart';

/// Pantalla principal: cuadrícula con todas las cámaras en vivo.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.store});

  final AppStore store;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// Se apaga la cuadrícula mientras hay otra pantalla encima,
  /// para no gastar datos ni batería decodificando videos que no se ven.
  bool _videoActive = true;

  Future<void> _pushPaused(Widget screen) async {
    setState(() => _videoActive = false);
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    if (mounted) setState(() => _videoActive = true);
  }

  void _cycleColumns() {
    final next = widget.store.gridColumns % 3 + 1; // 1 → 2 → 3 → 1
    widget.store.setGridColumns(next);
  }

  IconData _gridIcon(int columns) => switch (columns) {
        1 => Icons.view_agenda_outlined,
        2 => Icons.grid_view,
        _ => Icons.apps,
      };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, child) {
        final cameras = widget.store.cameras;
        final columns = widget.store.gridColumns;

        return Scaffold(
          appBar: AppBar(
            title: const Text('Mis cámaras'),
            actions: [
              if (cameras.isNotEmpty)
                IconButton(
                  tooltip: 'Cambiar cuadrícula',
                  icon: Icon(_gridIcon(columns)),
                  onPressed: _cycleColumns,
                ),
              IconButton(
                tooltip: 'Equipos',
                icon: const Icon(Icons.tune),
                onPressed: () => _pushPaused(DeviceListScreen(store: widget.store)),
              ),
            ],
          ),
          body: cameras.isEmpty
              ? _EmptyState(
                  onAdd: () => _pushPaused(DeviceFormScreen(store: widget.store)),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 16 / 9,
                  ),
                  itemCount: cameras.length,
                  itemBuilder: (context, index) {
                    final camera = cameras[index];
                    return CameraTile(
                      key: ValueKey('${camera.device.id}-${camera.channel}'),
                      camera: camera,
                      active: _videoActive,
                      onTap: () => _openLive(camera),
                    );
                  },
                ),
        );
      },
    );
  }

  void _openLive(CameraRef camera) => _pushPaused(LiveViewScreen(camera: camera));
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_outlined, size: 56, color: AppColors.textMuted),
            const SizedBox(height: 16),
            const Text(
              'Aún no tienes cámaras',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              'Agrega una cámara o un NVR Hikvision o Dahua para empezar.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMuted),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Agregar equipo'),
            ),
          ],
        ),
      ),
    );
  }
}
