import 'dart:async';

import 'package:flutter/material.dart';

import '../brands/brand_adapter.dart';
import '../models/device.dart';
import '../recording/recording_api.dart';
import '../recording/recording_monitor.dart';
import '../services/app_store.dart';
import '../services/camera_status.dart';
import '../services/nvr_channels.dart';
import '../services/update_service.dart';
import '../theme.dart';
import '../widgets/brand_badge.dart';
import '../widgets/camera_tile.dart';
import '../widgets/groups.dart';
import '../widgets/layout_chip.dart';
import '../widgets/status_dot.dart';
import '../widgets/network_sheet.dart';
import '../widgets/update_sheet.dart';
import 'camera_view_screen.dart';
import 'device_form_screen.dart';
import 'discovery_screen.dart';
import 'group_editor_screen.dart';
import 'mosaic_screen.dart';
import 'nvr_repair_screen.dart';
import 'recording_screen.dart';

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

  /// Revisa cada tanto si las cámaras están grabando (para el "● REC").
  Timer? _recTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkRecording());
    _recTimer = Timer.periodic(const Duration(minutes: 1), (_) => _checkRecording());
  }

  void _checkRecording() {
    if (mounted && _videoActive) RecordingMonitor.instance.refresh(widget.store.monitoredDevices);
  }

  @override
  void dispose() {
    _recTimer?.cancel();
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
      _pushPaused(CameraViewScreen(cameras: cameras, initialIndex: index, store: widget.store));

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
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Renombrar cámara'),
              onTap: () {
                Navigator.of(ctx).pop();
                _rename(camera);
              },
            ),
            if (RecordingApi.supports(camera.device))
              ListTile(
                leading: const Icon(Icons.fiber_manual_record, color: AppColors.danger),
                title: const Text('Grabación'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _pushPaused(RecordingScreen(store: widget.store, device: camera.device));
                },
              ),
            if (widget.store.activeDevices.any(NvrChannels.supports))
              ListTile(
                leading: const Icon(Icons.build_circle_outlined),
                title: const Text('Reparar conexión con el NVR'),
                subtitle: const Text(
                  'Si en el monitor del NVR esta cámara no se ve',
                  style: TextStyle(color: AppColors.textMuted),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  final nvr = camera.recordedBy;
                  _pushPaused(NvrRepairScreen(
                    store: widget.store,
                    nvr: nvr?.device ?? (camera.device.isRecorder ? camera.device : null),
                    channel: nvr?.channel ?? (camera.device.isRecorder ? camera.channel : null),
                    camera: camera.device.isRecorder ? null : camera.device,
                  ));
                },
              ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('Agregar a un grupo'),
              onTap: () async {
                Navigator.of(ctx).pop();
                final createNew = await showAddToGroupSheet(context, widget.store, camera);
                if (createNew && mounted) {
                  _pushPaused(GroupEditorScreen(store: widget.store, preselected: [camera]));
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.visibility_off_outlined),
              title: const Text('Ocultar del mosaico'),
              onTap: () {
                Navigator.of(ctx).pop();
                _hide(camera);
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

  Future<void> _rename(CameraRef camera) async {
    final controller = TextEditingController(text: camera.device.channelNames[camera.channel] ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Renombrar cámara'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: fieldDecoration('Nombre', hint: camera.label),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(controller.text), child: const Text('Guardar')),
        ],
      ),
    );
    controller.dispose();
    if (name == null) return;
    final d = widget.store.deviceById(camera.device.id);
    if (d == null) return;
    final names = {...d.channelNames};
    name.trim().isEmpty ? names.remove(camera.channel) : names[camera.channel] = name.trim();
    await widget.store.saveDevice(d.copyWith(channelNames: names));
  }

  Future<void> _hide(CameraRef camera) async {
    final d = widget.store.deviceById(camera.device.id);
    if (d == null) return;
    await widget.store.saveDevice(d.copyWith(hiddenChannels: {...d.hiddenChannels, camera.channel}));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${camera.label} se ocultó del mosaico.'),
      action: SnackBarAction(
        label: 'Deshacer',
        onPressed: () {
          final current = widget.store.deviceById(camera.device.id);
          if (current == null) return;
          widget.store.saveDevice(current.copyWith(
            hiddenChannels: {...current.hiddenChannels}..remove(camera.channel),
          ));
        },
      ),
    ));
  }

  /// Una cámara del mosaico. [cameras] es el orden en que se ven,
  /// para que al deslizar en pantalla completa se siga el mismo orden.
  Widget _tile(AppStore store, List<CameraRef> cameras, int index, StreamQuality quality) {
    final camera = cameras[index];
    return CameraTile(
      key: ValueKey('${camera.device.id}-${camera.channel}-$_reloadToken'),
      camera: camera,
      active: _videoActive,
      registry: _registry,
      showLabel: store.showLabels,
      quality: quality,
      onTap: () => _openCamera(cameras, index),
      onLongPress: () => _showTileMenu(cameras, index),
    );
  }

  /// Mosaico separado por marca: un título y una cuadrícula por marca.
  Widget _groupedGrid(AppStore store, List<CameraRef> cameras, int columns, StreamQuality quality) {
    final delegate = SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      mainAxisSpacing: 2,
      crossAxisSpacing: 2,
      childAspectRatio: 16 / 9,
    );
    final slivers = <Widget>[];
    var offset = 0;
    for (final brand in store.brands) {
      final count = cameras.where((c) => c.device.brand == brand).length;
      if (count == 0) continue;
      final start = offset;
      slivers
        ..add(SliverToBoxAdapter(child: _BrandHeader(brand: brand, count: count)))
        ..add(SliverGrid(
          gridDelegate: delegate,
          delegate: SliverChildBuilderDelegate(
            (context, i) => _tile(store, cameras, start + i, quality),
            childCount: count,
          ),
        ));
      offset += count;
    }
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 12)));
    return CustomScrollView(slivers: slivers);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.store, widget.updates]),
      builder: (context, child) {
        final store = widget.store;
        final cameras = store.visibleCameras;
        final allCount = store.cameras.length;
        final brands = store.brands;
        final filter = brands.contains(store.brandFilter) ? store.brandFilter : null;
        final grouped = store.groupByBrand && filter == null && brands.length > 1;
        final columns = store.gridColumns;
        final quality = store.gridHd ? StreamQuality.main : StreamQuality.sub;

        return Scaffold(
          appBar: AppBar(
            backgroundColor: AppColors.background,
            surfaceTintColor: Colors.transparent,
            titleSpacing: 16,
            toolbarHeight: 64,
            title: _Header(registry: _registry, total: allCount, cameras: store.cameras),
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
                  text: widget.updates.summary,
                  action: widget.updates.isDownloaded ? 'Instalar' : 'Ver',
                  progress: widget.updates.state == UpdateState.downloading
                      ? widget.updates.progress
                      : null,
                  onTap: () => showUpdateSheet(context, widget.updates),
                ),
              NetworkBar(store: store),
              if (brands.length > 1)
                _BrandBar(
                  brands: brands,
                  selected: filter,
                  counts: {for (final b in brands) b: store.camerasOf(b).length},
                  total: allCount,
                  grouped: store.groupByBrand,
                  onSelect: store.setBrandFilter,
                  onToggleGrouped: () => store.setGroupByBrand(!store.groupByBrand),
                ),
              if (cameras.isNotEmpty)
                _LayoutBar(
                  columns: columns,
                  cameraCount: cameras.length,
                  onChanged: store.setGridColumns,
                ),
              Expanded(
                child: allCount == 0 && store.standbyDevices.isNotEmpty
                    ? _StandbyState(store: store)
                    : allCount == 0
                    ? _EmptyState(
                        onAdd: () => _pushPaused(DeviceFormScreen(store: store)),
                        onDiscover: () => _pushPaused(DiscoveryScreen(store: store)),
                      )
                    : grouped
                        ? _groupedGrid(store, cameras, columns, quality)
                        : GridView.builder(
                        padding: const EdgeInsets.only(bottom: 12),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          mainAxisSpacing: 2,
                          crossAxisSpacing: 2,
                          childAspectRatio: 16 / 9,
                        ),
                        itemCount: cameras.length,
                        itemBuilder: (context, index) =>
                            _tile(store, cameras, index, quality),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Barra para elegir marca: Todas · Hikvision · Dahua, y el botón para
/// ver las cámaras separadas por marca o todas juntas.
class _BrandBar extends StatelessWidget {
  const _BrandBar({
    required this.brands,
    required this.selected,
    required this.counts,
    required this.total,
    required this.grouped,
    required this.onSelect,
    required this.onToggleGrouped,
  });

  final List<Brand> brands;
  final Brand? selected;
  final Map<Brand, int> counts;
  final int total;
  final bool grouped;
  final ValueChanged<Brand?> onSelect;
  final VoidCallback onToggleGrouped;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;

    Widget chip({required String label, required bool active, required VoidCallback onTap, Color? dot}) {
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Material(
          color: active ? accent.withValues(alpha: 0.16) : AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (dot != null) ...[
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: active ? accent : AppColors.text,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  chip(label: 'Todas · $total', active: selected == null, onTap: () => onSelect(null)),
                  for (final b in brands)
                    chip(
                      label: '${b.shortLabel} · ${counts[b] ?? 0}',
                      active: selected == b,
                      dot: brandColor(b),
                      onTap: () => onSelect(b),
                    ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: grouped ? 'Ver todas juntas' : 'Separar por marca',
            isSelected: grouped,
            icon: const Icon(Icons.view_stream_outlined),
            selectedIcon: Icon(Icons.view_stream, color: accent),
            onPressed: selected == null ? onToggleGrouped : null,
          ),
        ],
      ),
    );
  }
}

/// Título de cada marca cuando las cámaras se ven separadas.
class _BrandHeader extends StatelessWidget {
  const _BrandHeader({required this.brand, required this.count});

  final Brand brand;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
      child: Row(
        children: [
          BrandBadge(brand: brand, size: 26),
          const SizedBox(width: 10),
          Text(brand.label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const Spacer(),
          Text(
            count == 1 ? '1 cámara' : '$count cámaras',
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

/// Título con el resumen de estado: "5 en vivo · 1 sin conexión".
class _Header extends StatelessWidget {
  const _Header({required this.registry, required this.total, required this.cameras});

  final CameraStatusRegistry registry;
  final int total;
  final List<CameraRef> cameras;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([registry, RecordingMonitor.instance]),
      builder: (context, child) {
        final live = registry.count(LiveStatus.live);
        final offline = registry.count(LiveStatus.offline);
        final recording = RecordingMonitor.instance.countRecording(cameras);

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
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: text),
                        if (recording > 0) ...[
                          const TextSpan(text: '   '),
                          const WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Icon(Icons.fiber_manual_record, size: 10, color: AppColors.danger),
                          ),
                          TextSpan(text: ' $recording grabando'),
                        ],
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
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
  const _UpdateBanner({
    required this.text,
    required this.action,
    required this.onTap,
    this.progress,
  });

  final String text;
  final String action;
  final VoidCallback onTap;

  /// Avance de la descarga (null si no está descargando).
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Material(
        color: accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    Icon(Icons.system_update_alt, color: accent, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        text,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text(
                      action,
                      style: TextStyle(color: accent, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              if (progress != null)
                LinearProgressIndicator(
                  value: progress,
                  minHeight: 3,
                  backgroundColor: Colors.transparent,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd, required this.onDiscover});

  final VoidCallback onAdd;
  final VoidCallback onDiscover;

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
              onPressed: onDiscover,
              icon: const Icon(Icons.wifi_find),
              label: const Text('Buscar en mi red'),
            ),
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Agregar a mano'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Todos los equipos son de otra red: se explica y se ofrece verlos igual.
class _StandbyState extends StatelessWidget {
  const _StandbyState({required this.store});

  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final here = store.currentNetwork?.name;
    final info = store.netInfo;
    final where = info == null || !info.wifi
        ? 'Estás sin WiFi (con datos móviles).'
        : here != null
            ? 'Estás en la red "$here".'
            : 'Estás en una red donde no tienes equipos.';
    final n = store.standbyDevices.length;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_find, size: 44, color: AppColors.textMuted),
            const SizedBox(height: 14),
            Text(
              '$where Tus ${n == 1 ? 'equipo está' : '$n equipos están'} en otra red, en espera.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textMuted, height: 1.45),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: () => store.setShowAllNetworks(true),
              icon: const Icon(Icons.visibility_outlined),
              label: const Text('Ver igual'),
            ),
          ],
        ),
      ),
    );
  }
}

