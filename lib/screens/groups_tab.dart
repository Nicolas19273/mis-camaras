import 'package:flutter/material.dart';

import '../models/camera_group.dart';
import '../services/app_store.dart';
import '../theme.dart';
import '../widgets/groups.dart';
import 'group_editor_screen.dart';
import 'group_view_screen.dart';

/// Lista de grupos dentro de la pestaña Equipos.
class GroupsTab extends StatelessWidget {
  const GroupsTab({super.key, required this.store});

  final AppStore store;

  static Future<void> create(BuildContext context, AppStore store) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => GroupEditorScreen(store: store)),
      );

  void _open(BuildContext context, CameraGroup g) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => GroupViewScreen(store: store, groupId: g.id)),
      );

  void _edit(BuildContext context, CameraGroup g) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => GroupEditorScreen(store: store, group: g)),
      );

  Future<void> _delete(BuildContext context, CameraGroup g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Eliminar grupo'),
        content: Text('¿Eliminar el grupo "${g.name}"? Las cámaras y los equipos no se borran.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (ok == true) await store.deleteGroup(g.id);
  }

  Widget _card(BuildContext context, CameraGroup g) {
    final cameras = store.camerasOfGroup(g);
    return Padding(
      key: ValueKey('grupo-${g.id}'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          contentPadding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
          leading: GroupIcon(color: groupColor(g.colorIndex)),
          title: Text(g.name, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(
            '${cameras.length == 1 ? '1 cámara' : '${cameras.length} cámaras'}\n${groupPreview(cameras)}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.textMuted, height: 1.35),
          ),
          isThreeLine: true,
          onTap: () => _open(context, g),
          trailing: PopupMenuButton<String>(
            tooltip: 'Opciones',
            color: AppColors.surface,
            onSelected: (v) => v == 'edit' ? _edit(context, g) : _delete(context, g),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Editar')),
              PopupMenuItem(value: 'delete', child: Text('Eliminar')),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = store.groups;
    if (groups.isEmpty) {
      final noCameras = store.allCameras.isEmpty;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.grid_view_rounded, size: 44, color: AppColors.textMuted.withValues(alpha: 0.6)),
              const SizedBox(height: 14),
              Text(
                noCameras
                    ? 'Primero agrega tus equipos. Después podrás juntar sus cámaras en grupos.'
                    : 'Junta cámaras de distintos equipos y marcas en grupos, como "Patio", '
                        '"Local" o "Entradas", para verlas ordenadas.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textMuted, height: 1.45),
              ),
              if (!noCameras) ...[
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => create(context, store),
                  icon: const Icon(Icons.add),
                  label: const Text('Crear grupo'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
      itemCount: groups.length,
      onReorder: store.moveGroup,
      header: const Padding(
        padding: EdgeInsets.fromLTRB(8, 0, 8, 10),
        child: Text(
          'Toca un grupo para verlo en vivo. Mantén presionado y arrastra para ordenarlos.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12),
        ),
      ),
      itemBuilder: (context, index) => _card(context, groups[index]),
    );
  }
}
