import 'package:flutter/material.dart';

import '../config.dart';
import '../services/update_service.dart';
import '../theme.dart';

/// Abre la hoja inferior para descargar e instalar la versión nueva.
Future<void> showUpdateSheet(BuildContext context, UpdateService updates) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _UpdateSheet(updates: updates),
  );
}

class _UpdateSheet extends StatelessWidget {
  const _UpdateSheet({required this.updates});

  final UpdateService updates;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;

    return ListenableBuilder(
      listenable: updates,
      builder: (context, child) {
        final release = updates.release;
        final state = updates.state;
        final downloading = state == UpdateState.downloading;
        final installing = state == UpdateState.installing;

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.system_update_alt, color: accent),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Nueva versión disponible',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            release == null
                                ? ''
                                : '${AppConfig.versionName}  →  ${release.version}'
                                    '${release.apkSize > 0 ? '  ·  ${release.sizeLabel}' : ''}',
                            style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (release != null && release.notes.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    release.notes,
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.textMuted, height: 1.4),
                  ),
                ],
                const SizedBox(height: 20),
                if (downloading || installing) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: installing ? null : updates.progress,
                      minHeight: 8,
                      backgroundColor: AppColors.surfaceHigh,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    installing
                        ? 'Abriendo el instalador…'
                        : 'Descargando… ${(updates.progress * 100).toStringAsFixed(0)} %',
                    style: const TextStyle(color: AppColors.textMuted),
                  ),
                ] else ...[
                  if (state == UpdateState.error && updates.error != null) ...[
                    Text(
                      updates.error!,
                      style: const TextStyle(color: AppColors.danger),
                    ),
                    const SizedBox(height: 12),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: release == null ? null : updates.downloadAndInstall,
                      icon: const Icon(Icons.download),
                      label: const Text('Actualizar ahora'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                const Text(
                  'Android te pedirá confirmar la instalación. Tus equipos y ajustes se mantienen. '
                  'La primera vez puede pedir permiso para instalar apps desde Mis Cámaras.',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12, height: 1.4),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
