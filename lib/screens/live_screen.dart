import 'package:flutter/material.dart';

import '../brands/brand_adapter.dart';
import '../models/device.dart';
import '../services/app_store.dart';
import '../services/camera_status.dart';
import '../services/update_service.dart';
import '../theme.dart';
import '../widgets/brand_badge.dart';
import '../widgets/camera_tile.dart';
import '../widgets/layout_chip.dart';
import '../widgets/status_dot.dart';
import '../widgets/update_sheet.dart';
import 'camera_view_screen.dart';
import 'device_form_screen.dart';
import 'mosaic_screen.dart';

/// Pestaña "En vivo": mosaico de cámaras al estilo NVR.
class LiveScreen extends StatefulWidget {
  const LiveScreen({super.key, required this.store, required this.updates});

  final AppStore store;
  final UpdateService updates;

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> {
  final _registry = CameraStatusRegistry();

  /// Se apaga el mosaico mientras hay otra pantalla encima,
  /// para no gastar datos ni batería en videos que no se ven.
  bool _videoActive = true;

  /// Al cambiar este número se reconectan todas las cámaras.
  int _reloadToken = 0;

  @override
  void dispose() {
    _registry.dispose();
    super.dispose();
  }

  Future<void> _pushPaused(Widget screen) async {
    setState(() => _videoActive = false);
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    if (mounted) setState(() => _videoActive = true);
  }

  void _reloadAll() {
    setState(() => _reloadToken++);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Reconectando cámaras…'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  void _openCamera(List<CameraRef> cameras, int index) =>
      _pushPaused(CameraViewScreen(cameras: cameras, initialIndex: index));

  void _openMosaic(List<CameraRef> cameras) =>
      _pushPaused(MosaicScreen(store: widget.store, cameras: cameras));

  void _showTileMenu(List<CameraRef> cameras, int index) {
    final camera = cameras[index];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: BrandBadge(brand: camera.device.brand),
              title: Text(camera.label),
              subtitle: Text(
                '${camera.device.brand.label} · ${camera.device.host} · canal ${camera.channel}',
                style: const TextStyle(color: AppColors.textMuted),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.fullscreen),
              title: const Text('Ver en pantalla completa'),
              onTap: () {
                Navigator.of(ctx).pop();
                _openCamera(cameras, index);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Editar equipo'),
              onTap: () {
                Navigator.of(ctx).pop();
                _pushPaused(DeviceFormScreen(store: widget.store, device: camera.device));
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.store, widget.updates]),
      builder: (context, child) {
        final store = widget.store;
        final cameras = store.cameras;
        final columns = store.gridColumns;
        final quality = store.gridHd ? StreamQuality.main : StreamQuality.sub;

        return Scaffold(
          appBar: AppBar(
            backgroundColor: AppColors.background,
            surfaceTintColor: Colors.transparent,
            titleSpacing: 16,
            toolbarHeight: 64,
            title: _Header(registry: _registry, total: cameras.length),
            actions: [
              if (cameras.isNotEmpty) ...[
                IconButton(
                  tooltip: 'Reconectar todas',
                  icon: const Icon(Icons.refresh),
                  onPressed: _reloadAll,
                ),
                IconButton(
                  tooltip: 'Mosaico en pantalla completa',
                  icon: const Icon(Icons.fullscreen),
                  onPressed: () => _openMosaic(cameras),
                ),
              ],
              const SizedBox(width: 4),
            ],
          ),
          body: Column(
            children: [
              if (widget.updates.hasUpdate)
                _UpdateBanner(
                  version: widget.updates.release?.version ?? '',
                  onTap: () => showUpdateSheet(context, widget.updates),
                ),
              if (cameras.isNotEmpty)
                _LayoutBar(
                  columns: columns,
                  cameraCount: cameras.length,
                  onChanged: store.setGridColumns,
                ),
              Expanded(
                child: cameras.isEmpty
                    ? _EmptyState(
                        onAdd: () => _pushPaused(DeviceFormScreen(store: store)),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.only(bottom: 12),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          mainAxisSpacing: 2,
                          crossAxisSpacing: 2,
                          childAspectRatio: 16 / 9,
                        ),
                        itemCount: cameras.length,
                        itemBuilder: (context, index) {
                          final camera = cameras[index];
                          return CameraTile(
                            key: ValueKey(
                              '${camera.device.id}-${camera.channel}-$_reloadToken',
                            ),
                            camera: camera,
                            active: _videoActive,
                            registry: _registry,
                            showLabel: store.showLabels,
                            quality: quality,
                            onTap: () => _openCamera(cameras, index),
                            onLongPress: () => _showTileMenu(cameras, index),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Título con el resumen de estado: "5 en vivo · 1 sin conexión".
class _Header extends StatelessWidget {
  const _Header({required this.registry, required this.total});

  final CameraStatusRegistry registry;
  final int total;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: registry,
      builder: (context, child) {
        final live = registry.count(LiveStatus.live);
        final offline = registry.count(LiveStatus.offline);

        String text;
        LiveStatus dot;
        if (total == 0) {
          text = 'Sin cámaras';
          dot = LiveStatus.offline;
        } else if (live == 0 && offline == 0) {
          text = 'Conectando…';
          dot = LiveStatus.connecting;
        } else {
          text = '$live en vivo${offline > 0 ? ' · $offline sin conexión' : ''}';
          dot = offline > 0 && live == 0 ? LiveStatus.offline : LiveStatus.live;
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'En vivo',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 3),
            Row(
              children: [
                StatusDot(status: dot),
                const SizedBox(width: 7),
                Text(
                  text,
                  style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Selector de vista: 1, 4, 9 o 16 cámaras, como en un NVR.
class _LayoutBar extends StatelessWidget {
  const _LayoutBar({
    required this.columns,
    required this.cameraCount,
    required this.onChanged,
  });

  final int columns;
  final int cameraCount;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 16, 10),
      child: Row(
        children: [
          for (var c = 1; c <= 4; c++)
            LayoutChip(
              columns: c,
              selected: c == columns,
              onTap: () => onChanged(c),
            ),
          const Spacer(),
          Text(
            cameraCount == 1 ? '1 cámara' : '$cameraCount cámaras',
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner({required this.version, required this.onTap});

  final String version;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Material(
        color: accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.system_update_alt, color: accent, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Nueva versión $version disponible',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  'Actualizar',
                  style: TextStyle(color: accent, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Icon(Icons.videocam_outlined, size: 40, color: AppColors.textMuted),
            ),
            const SizedBox(height: 20),
            const Text(
              'Aún no tienes cámaras',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              'Agrega una cámara o un NVR Hikvision o Dahua para verlas aquí.',
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
