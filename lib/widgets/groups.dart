import 'package:flutter/material.dart';

import '../models/device.dart';
import '../services/app_store.dart';
import '../theme.dart';

/// Color de un grupo (usa la misma paleta que los colores de la app).
Color groupColor(int index) => accentOptions[index.abs() % accentOptions.length];

/// Ícono cuadrado de un grupo, con su color.
class GroupIcon extends StatelessWidget {
  const GroupIcon({super.key, required this.color, this.size = 40});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Icon(Icons.grid_view_rounded, color: color, size: size * 0.55),
    );
  }
}

/// Hoja para meter o sacar una cámara de los grupos.
/// Devuelve true si la persona quiere crear un grupo nuevo con esa cámara.
Future<bool> showAddToGroupSheet(BuildContext context, AppStore store, CameraRef camera) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: AppColors.surface,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
        child: ListenableBuilder(
          listenable: store,
          builder: (ctx, child) {
            final groups = store.groups;
            return ListView(
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    'Grupos de "${camera.label}"',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                if (groups.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                    child: Text(
                      'Todavía no tienes grupos.',
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                  ),
                for (final g in groups)
                  CheckboxListTile(
                    value: g.contains(camera),
                    onChanged: (v) => store.setInGroup(g.id, camera, v ?? false),
                    secondary: GroupIcon(color: groupColor(g.colorIndex), size: 34),
                    title: Text(g.name),
                    subtitle: Text(
                      _count(store.camerasOfGroup(g).length),
                      style: const TextStyle(color: AppColors.textMuted),
                    ),
                  ),
                ListTile(
                  leading: const Icon(Icons.add),
                  title: const Text('Crear grupo nuevo con esta cámara'),
                  onTap: () => Navigator.of(ctx).pop(true),
                ),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      ),
    ),
  );
  return result == true;
}

String _count(int n) => n == 1 ? '1 cámara' : '$n cámaras';

/// Texto corto con los nombres de las cámaras de un grupo.
String groupPreview(List<CameraRef> cameras) {
  if (cameras.isEmpty) return 'Sin cámaras todavía';
  final names = cameras.take(3).map((c) => c.label).join(', ');
  final more = cameras.length > 3 ? ' y ${cameras.length - 3} más' : '';
  return '$names$more';
}
