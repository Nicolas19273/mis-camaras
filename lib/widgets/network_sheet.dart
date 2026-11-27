import 'package:flutter/material.dart';

import '../models/device.dart';
import '../models/network.dart';
import '../services/app_store.dart';
import '../services/network_watcher.dart';
import '../theme.dart';

/// Barra fina en En vivo: en qué red estás, cuántos equipos quedaron en
/// espera (de otras redes) y cuántas cámaras repetidas se ocultaron.
class NetworkBar extends StatelessWidget {
  const NetworkBar({super.key, required this.store});

  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final standby = store.standbyDevices.length;
    final dups = store.duplicates.length;
    final showAll = store.showAllNetworks;
    if (!store.separateNetworks && dups == 0) return const SizedBox.shrink();
    if (standby == 0 && dups == 0 && !showAll && store.networks.length < 2) return const SizedBox.shrink();

    final info = store.netInfo;
    final here = store.currentNetwork;
    final name = info == null
        ? 'Revisando la red…'
        : !info.wifi
            ? 'Sin WiFi'
            : here?.name ?? KnownNetwork.defaultName(info);
    final parts = [
      if (showAll) 'viendo todas las redes' else if (standby > 0) '$standby en espera',
      if (dups > 0) '$dups ${dups == 1 ? 'repetida oculta' : 'repetidas ocultas'}',
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => showNetworkSheet(context, store),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(info?.wifi == false ? Icons.signal_cellular_alt : Icons.wifi,
                    size: 16, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: name, style: const TextStyle(fontWeight: FontWeight.w600)),
                        if (parts.isNotEmpty)
                          TextSpan(
                            text: ' · ${parts.join(' · ')}',
                            style: const TextStyle(color: AppColors.textMuted),
                          ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
                const Icon(Icons.expand_more, size: 18, color: AppColors.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Hoja con la red actual, los equipos en espera, las cámaras repetidas
/// y las redes guardadas.
Future<void> showNetworkSheet(BuildContext context, AppStore store) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.85),
      child: _NetworkSheet(store: store),
    ),
  );
}

class _NetworkSheet extends StatefulWidget {
  const _NetworkSheet({required this.store});

  final AppStore store;

  @override
  State<_NetworkSheet> createState() => _NetworkSheetState();
}

class _NetworkSheetState extends State<_NetworkSheet> {
  bool? _hasPermission;

  AppStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    NetworkWatcher.hasPermission().then((v) {
      if (mounted) setState(() => _hasPermission = v);
    });
  }

  Future<void> _askPermission() async {
    final ok = await NetworkWatcher.requestPermission();
    if (!mounted) return;
    setState(() => _hasPermission = ok);
    await NetworkWatcher.instance?.refreshNow();
  }

  Future<void> _rename(KnownNetwork n) async {
    final controller = TextEditingController(text: n.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Nombre de la red'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: fieldDecoration('Nombre', hint: 'Ej: Casa, Trabajo, Local'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(controller.text), child: const Text('Guardar')),
        ],
      ),
    );
    controller.dispose();
    if (name != null) await store.renameNetwork(n.id, name);
  }

  Future<void> _forget(KnownNetwork n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Olvidar "${n.name}"'),
        content: const Text(
          'Sus equipos no se borran: quedan sin red y se asignan solos a la red donde respondan.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Olvidar')),
        ],
      ),
    );
    if (ok == true) await store.forgetNetwork(n.id);
  }

  Future<void> _removeDuplicates() async {
    final n = store.duplicates.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Quitar ${n == 1 ? 'la cámara repetida' : 'las $n cámaras repetidas'}'),
        content: const Text(
          'Se quitan de la app las cámaras sueltas que ya se ven dentro de un grabador. '
          'Si tenían nombre, el nombre pasa al canal del grabador. Las cámaras no se tocan.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Quitar')),
        ],
      ),
    );
    if (ok == true) await store.removeDuplicates();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, child) {
        final info = store.netInfo;
        final here = store.currentNetwork;
        final standby = store.standbyDevices;
        final dups = store.duplicates;
        const muted = TextStyle(color: AppColors.textMuted, fontSize: 12.5);

        String count(String id) {
          final n = store.devices.where((d) => d.network == id).length;
          return n == 1 ? '1 equipo' : '$n equipos';
        }

        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
          children: [
            ListTile(
              leading: Icon(info?.wifi == false ? Icons.signal_cellular_alt : Icons.wifi),
              title: Text(
                info == null
                    ? 'Revisando la red…'
                    : !info.wifi
                        ? 'Sin WiFi (datos móviles)'
                        : here?.name ?? 'Red nueva: ${KnownNetwork.defaultName(info)}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: info == null || !info.wifi
                  ? const Text('Solo se ven los equipos de acceso remoto.', style: muted)
                  : Text(
                      [
                        if (info.ssid != null) 'WiFi: ${info.ssid}',
                        'Red ${info.subnet}.x',
                        if (here == null) 'Todavía no tienes equipos aquí',
                      ].join(' · '),
                      style: muted,
                    ),
              trailing: here == null
                  ? null
                  : IconButton(
                      tooltip: 'Cambiar nombre',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _rename(here),
                    ),
            ),
            if (info != null && info.wifi && info.ssid == null)
              ListTile(
                leading: const Icon(Icons.badge_outlined, color: AppColors.connecting),
                title: const Text('Ver el nombre del WiFi'),
                subtitle: Text(
                  _hasPermission == true && !info.locationOn
                      ? 'Enciende la ubicación del teléfono: Android solo muestra el nombre del WiFi '
                          'con la ubicación encendida.'
                      : 'Así la app distingue bien tus redes aunque usen los mismos números. '
                          'Android lo llama "ubicación", pero la app no usa tu ubicación.',
                  style: muted,
                ),
                onTap: _hasPermission == true ? null : _askPermission,
                trailing: _hasPermission == true ? null : const Icon(Icons.chevron_right),
              ),
            SwitchListTile(
              secondary: const Icon(Icons.layers_outlined),
              title: const Text('Mostrar todas las redes'),
              subtitle: const Text('Por ahora, también los equipos en espera.', style: muted),
              value: store.showAllNetworks,
              onChanged: store.setShowAllNetworks,
            ),
            if (standby.isNotEmpty) ...[
              const SectionLabel('En espera (otras redes)'),
              for (final d in standby)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.pause_circle_outline, color: AppColors.textMuted),
                  title: Text(d.name),
                  subtitle: Text(
                    '${store.networkById(d.network)?.name ?? 'Sin red asignada'} · ${d.host}',
                    style: muted,
                  ),
                ),
            ],
            if (dups.isNotEmpty) ...[
              const SectionLabel('Cámaras repetidas (ocultas)'),
              for (final d in dups)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.copy_all_outlined, color: AppColors.textMuted),
                  title: Text(d.name),
                  subtitle: Text(_whereDuplicate(d), style: muted),
                  trailing: TextButton(
                    onPressed: () => store.setKeepDuplicate(d, true),
                    child: const Text('Mostrar'),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: OutlinedButton.icon(
                  onPressed: _removeDuplicates,
                  icon: const Icon(Icons.cleaning_services_outlined),
                  label: const Text('Quitar repetidas de la app'),
                ),
              ),
            ],
            if (store.networks.isNotEmpty) ...[
              const SectionLabel('Redes guardadas'),
              for (final n in store.networks)
                ListTile(
                  leading: Icon(n.id == here?.id ? Icons.wifi : Icons.wifi_off_outlined),
                  title: Text(n.id == here?.id ? '${n.name} (aquí)' : n.name),
                  subtitle: Text(
                    [count(n.id), if (n.ssid != null) 'WiFi: ${n.ssid}', 'Red ${n.subnet}.x'].join(' · '),
                    style: muted,
                  ),
                  trailing: PopupMenuButton<String>(
                    color: AppColors.surface,
                    onSelected: (v) => v == 'rename' ? _rename(n) : _forget(n),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rename', child: Text('Cambiar nombre')),
                      PopupMenuItem(value: 'forget', child: Text('Olvidar red')),
                    ],
                  ),
                ),
            ],
          ],
        );
      },
    );
  }

  String _whereDuplicate(Device d) {
    final w = store.duplicateOf(d);
    if (w == null) return d.host;
    return w.device.isRecorder
        ? 'Ya se ve en "${w.device.name}" (cámara ${w.channel})'
        : 'Agregada dos veces: igual a "${w.device.name}"';
  }
}
