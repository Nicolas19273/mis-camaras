import 'package:flutter/material.dart';

import '../config.dart';
import '../services/app_store.dart';
import '../services/update_service.dart';
import '../theme.dart';
import '../widgets/update_sheet.dart';

/// Pestaña "Ajustes": actualizaciones, apariencia y video.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.store, required this.updates});

  final AppStore store;
  final UpdateService updates;

  Future<void> _checkNow(BuildContext context) async {
    final hasUpdate = await updates.check();
    if (!context.mounted) return;
    if (hasUpdate) {
      await showUpdateSheet(context, updates);
    } else if (updates.state == UpdateState.upToDate) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ya tienes la última versión.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;

    return ListenableBuilder(
      listenable: Listenable.merge([store, updates]),
      builder: (context, child) {
        final release = updates.release;

        String checkSubtitle;
        switch (updates.state) {
          case UpdateState.checking:
            checkSubtitle = 'Buscando…';
          case UpdateState.upToDate:
            checkSubtitle = 'Tienes la última versión';
          case UpdateState.error:
            checkSubtitle = updates.error ?? 'No se pudo revisar';
          default:
            checkSubtitle = 'Revisa si hay una versión nueva en GitHub';
        }

        return Scaffold(
          appBar: AppBar(
            backgroundColor: AppColors.background,
            surfaceTintColor: Colors.transparent,
            toolbarHeight: 64,
            titleSpacing: 16,
            title: const Text(
              'Ajustes',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              // --- Actualizaciones ---------------------------------------------
              const SectionLabel('Actualizaciones'),
              _Group(
                children: [
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: const Text('Versión instalada'),
                    trailing: Text(
                      AppConfig.versionName,
                      style: const TextStyle(color: AppColors.textMuted),
                    ),
                  ),
                  if (updates.hasUpdate && release != null)
                    ListTile(
                      leading: Icon(Icons.system_update_alt, color: accent),
                      title: Text('Versión ${release.version} disponible'),
                      subtitle: const Text('Toca para actualizar'),
                      trailing: Icon(Icons.chevron_right, color: accent),
                      onTap: () => showUpdateSheet(context, updates),
                    )
                  else
                    ListTile(
                      leading: const Icon(Icons.refresh),
                      title: const Text('Buscar actualizaciones'),
                      subtitle: Text(
                        checkSubtitle,
                        style: TextStyle(
                          color: updates.state == UpdateState.error
                              ? AppColors.danger
                              : AppColors.textMuted,
                        ),
                      ),
                      trailing: updates.state == UpdateState.checking
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : null,
                      onTap: updates.isBusy ? null : () => _checkNow(context),
                    ),
                  SwitchListTile(
                    secondary: const Icon(Icons.autorenew),
                    title: const Text('Buscar al abrir la app'),
                    value: store.autoUpdate,
                    onChanged: store.setAutoUpdate,
                  ),
                ],
              ),

              // --- Apariencia --------------------------------------------------
              const SectionLabel('Apariencia'),
              _Group(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Color principal', style: TextStyle(fontSize: 16)),
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 14,
                          runSpacing: 12,
                          children: [
                            for (var i = 0; i < accentOptions.length; i++)
                              _ColorDot(
                                color: accentOptions[i],
                                selected: i == store.accentIndex,
                                onTap: () => store.setAccentIndex(i),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.label_outline),
                    title: const Text('Nombres sobre las cámaras'),
                    value: store.showLabels,
                    onChanged: store.setShowLabels,
                  ),
                ],
              ),

              // --- Video ------------------------------------------------------
              const SectionLabel('Video'),
              _Group(
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.hd_outlined),
                    title: const Text('Alta calidad en el mosaico'),
                    subtitle: const Text(
                      'Se ve más nítido, pero gasta más datos y batería.',
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                    value: store.gridHd,
                    onChanged: store.setGridHd,
                  ),
                ],
              ),

              // --- Acerca de --------------------------------------------------
              const SectionLabel('Acerca de'),
              const _Group(
                children: [
                  ListTile(
                    leading: Icon(Icons.videocam_outlined),
                    title: Text('Mis Cámaras'),
                    subtitle: Text(
                      'Visor para cámaras Hikvision y Dahua\ngithub.com/${AppConfig.githubRepo}',
                      style: TextStyle(color: AppColors.textMuted, height: 1.35),
                    ),
                    isThreeLine: true,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Column(children: children),
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color, required this.selected, required this.onTap});

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Colors.white : Colors.transparent,
            width: 2.5,
          ),
          boxShadow: selected
              ? [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 10)]
              : null,
        ),
        child: selected ? const Icon(Icons.check, color: Colors.black, size: 20) : null,
      ),
    );
  }
}
