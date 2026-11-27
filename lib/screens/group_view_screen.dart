import 'package:flutter/material.dart';

import '../brands/brand_adapter.dart';
import '../models/camera_group.dart';
import '../models/device.dart';
import '../services/app_store.dart';
import '../services/camera_status.dart';
import '../theme.dart';
import '../widgets/camera_tile.dart';
import '../widgets/groups.dart';
import '../widgets/layout_chip.dart';
import 'camera_view_screen.dart';
import 'group_editor_screen.dart';
import 'mosaic_screen.dart';

/// Las cámaras de un grupo en vivo, en cuadrícula.
class GroupViewScreen extends StatefulWidget {
  const GroupViewScreen({super.key, required this.store, required this.groupId});

  final AppStore store;
  final String groupId;

  @override
  State<GroupViewScreen> createState() => _GroupViewScreenState();
}

class _GroupViewScreenState extends State<GroupViewScreen> {
  final _registry = CameraStatusRegistry();

  /// Se pausa el video mientras hay otra pantalla encima.
  bool _videoActive = true;

  @override
  void dispose() {
    _registry.dispose();
    super.dispose();
  }

  Future<void> _push(Widget screen) async {
    setState(() => _videoActive = false);
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    if (mounted) setState(() => _videoActive = true);
  }

  void _edit(CameraGroup group) => _push(GroupEditorScreen(store: widget.store, group: group));

  void _tileMenu(CameraGroup group, List<CameraRef> cameras, int index) {
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
              title: Text(camera.label, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(
                '${camera.device.brand.shortLabel} · ${camera.device.host}',
                style: const TextStyle(color: AppColors.textMuted),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.fullscreen),
              title: const Text('Ver en pantalla completa'),
              onTap: () {
                Navigator.of(ctx).pop();
                _push(CameraViewScreen(cameras: cameras, initialIndex: index, store: widget.store));
              },
            ),
            ListTile(
              leading: const Icon(Icons.remove_circle_outline),
              title: Text('Quitar de "${group.name}"'),
              onTap: () {
                Navigator.of(ctx).pop();
                widget.store.setInGroup(group.id, camera, false);
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
      listenable: widget.store,
      builder: (context, child) {
        final store = widget.store;
        final group = store.groupById(widget.groupId);
        if (group == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Este grupo ya no existe.')),
          );
        }
        final cameras = store.camerasOfGroup(group);
        final columns = store.gridColumns;
        final quality = store.gridHd ? StreamQuality.main : StreamQuality.sub;

        return Scaffold(
          appBar: AppBar(
            backgroundColor: AppColors.background,
            surfaceTintColor: Colors.transparent,
            titleSpacing: 0,
            title: Row(
              children: [
                GroupIcon(color: groupColor(group.colorIndex), size: 32),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        group.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                      Text(
                        cameras.length == 1 ? '1 cámara' : '${cameras.length} cámaras',
                        style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              if (cameras.isNotEmpty)
                IconButton(
                  tooltip: 'Mosaico en pantalla completa',
                  icon: const Icon(Icons.fullscreen),
                  onPressed: () => _push(MosaicScreen(store: store, cameras: cameras)),
                ),
              IconButton(
                tooltip: 'Editar grupo',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => _edit(group),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: cameras.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Este grupo todavía no tiene cámaras.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.textMuted),
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: () => _edit(group),
                          icon: const Icon(Icons.add),
                          label: const Text('Elegir cámaras'),
                        ),
                      ],
                    ),
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 16, 10),
                      child: Row(
                        children: [
                          for (var c = 1; c <= 4; c++)
                            LayoutChip(
                              columns: c,
                              selected: c == columns,
                              onTap: () => store.setGridColumns(c),
                            ),
                          const Spacer(),
                          ListenableBuilder(
                            listenable: _registry,
                            builder: (context, child) {
                              final live = _registry.count(LiveStatus.live);
                              final off = _registry.count(LiveStatus.offline);
                              return Text(
                                off > 0 ? '$live en vivo · $off sin conexión' : '$live en vivo',
                                style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: GridView.builder(
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
                            key: ValueKey('grupo-${group.id}-${camera.device.id}-${camera.channel}'),
                            camera: camera,
                            active: _videoActive,
                            registry: _registry,
                            showLabel: store.showLabels,
                            quality: quality,
                            onTap: () => _push(
                              CameraViewScreen(cameras: cameras, initialIndex: index, store: store),
                            ),
                            onLongPress: () => _tileMenu(group, cameras, index),
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
