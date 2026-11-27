import 'package:flutter/material.dart';

import '../models/device.dart';
import '../recording/recording_api.dart';
import '../services/app_store.dart';
import '../services/device_api.dart';
import '../services/discovery.dart';
import '../services/network_config.dart';
import '../theme.dart';
import '../widgets/brand_badge.dart';
import 'channels_screen.dart';
import 'network_screen.dart';
import 'recording_screen.dart';

/// Herramientas de un equipo: información, cámaras, IP, rescate y reinicio.
/// Devuelve la IP nueva al cerrar, si cambió.
class DeviceToolsScreen extends StatefulWidget {
  const DeviceToolsScreen({super.key, required this.store, required this.device});

  final AppStore store;
  final Device device;

  @override
  State<DeviceToolsScreen> createState() => _DeviceToolsScreenState();
}

class _DeviceToolsScreenState extends State<DeviceToolsScreen> {
  DeviceInfo? _info;
  String? _infoError;
  bool _loadingInfo = true;
  String? _newHost;
  bool _searching = false;

  Device get _device => widget.store.deviceById(widget.device.id) ?? widget.device;

  @override
  void initState() {
    super.initState();
    _loadInfo();
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _loadInfo() async {
    setState(() {
      _loadingInfo = true;
      _infoError = null;
    });
    final api = DeviceApi(_device);
    try {
      final info = await api.info();
      // Se guarda la MAC para poder encontrar el equipo si cambia de IP.
      if (info.mac != null && _device.mac == null) {
        await widget.store.saveDevice(_device.copyWith(mac: info.mac));
      }
      if (mounted) setState(() => _info = info);
    } catch (e) {
      if (mounted) {
        setState(() => _infoError = e is DeviceApiException
            ? e.message
            : 'No responde. Revisa que esté encendido y en tu WiFi.');
      }
    } finally {
      api.close();
      if (mounted) setState(() => _loadingInfo = false);
    }
  }

  Future<void> _openNetwork() async {
    final host = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => NetworkScreen(store: widget.store, device: _device)),
    );
    if (host != null && mounted) setState(() => _newHost = host);
  }

  Future<void> _openChannels() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ChannelsScreen(store: widget.store, device: _device)),
    );
    if (mounted) setState(() {});
  }

  /// Busca el equipo en la red por su MAC (o por marca si no se conoce la MAC).
  Future<void> _findLost() async {
    setState(() => _searching = true);
    final device = _device;
    final found = await DiscoveryService().scan();
    if (!mounted) return;
    setState(() => _searching = false);

    final mac = device.mac;
    FoundDevice? match;
    if (mac != null) {
      for (final f in found) {
        if (f.mac != null && normalizeMac(f.mac!) == normalizeMac(mac)) match = f;
      }
    }
    if (match != null) {
      if (match.ip == device.host) return _snack('Está donde debe: ${device.host}. Si no se ve, revisa la contraseña o reinícialo.');
      final use = await _askUse(match);
      if (use == true) await _useHost(match.ip);
      return;
    }
    // Sin MAC conocida: se ofrecen los equipos de la misma marca.
    final candidates = found
        .where((f) => f.brand == device.brand && !widget.store.devices.any((d) => d.host == f.ip))
        .toList();
    if (candidates.isEmpty) {
      return _snack('No lo encontré. Revisa que esté encendido y conectado al mismo router.');
    }
    final picked = await showModalBottomSheet<FoundDevice>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text('¿Es alguno de estos?',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            for (final f in candidates)
              ListTile(
                leading: BrandBadge(brand: device.brand),
                title: Text(f.title),
                subtitle: Text(f.ip),
                onTap: () => Navigator.of(ctx).pop(f),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked != null) await _useHost(picked.ip);
  }

  Future<bool?> _askUse(FoundDevice f) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('¡Lo encontré!'),
          content: Text('${_device.name} ahora está en ${f.ip} (antes ${_device.host}). '
              '¿Actualizo la dirección en la app?'),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('No')),
            FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Sí, actualizar')),
          ],
        ),
      );

  Future<void> _useHost(String ip) async {
    await widget.store.saveDevice(_device.copyWith(host: ip));
    if (!mounted) return;
    setState(() => _newHost = ip);
    _snack('Listo: ${_device.name} ahora usa $ip.');
    _loadInfo();
  }

  Future<void> _reboot() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('¿Reiniciar el equipo?'),
        content: Text(_device.isRecorder
            ? 'El grabador y sus cámaras dejarán de verse y grabar por 1 a 3 minutos.'
            : 'La cámara dejará de verse por 1 a 2 minutos.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Reiniciar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final api = DeviceApi(_device);
    try {
      await api.reboot();
      _snack('Reiniciando… vuelve a estar disponible en 1 a 3 minutos.');
    } catch (e) {
      _snack(e is DeviceApiException ? e.message : 'No se pudo reiniciar.');
    } finally {
      api.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = _device;
    final info = _info;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) Navigator.of(context).pop(_newHost);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Herramientas')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
          children: [
            Material(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    BrandBadge(brand: device.brand, size: 44),
                    const SizedBox(width: 14),
                    Expanded(
                      child: _loadingInfo
                          ? const Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child: LinearProgressIndicator(),
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(device.name,
                                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                                const SizedBox(height: 4),
                                Text(
                                  [
                                    if (info?.model != null) 'Modelo: ${info!.model}',
                                    if (info?.firmware != null && info!.firmware!.isNotEmpty)
                                      'Firmware: ${info.firmware}',
                                    if (info?.serial != null) 'Serie: ${info!.serial}',
                                    'IP: ${device.host}',
                                    if (device.mac != null) 'MAC: ${device.mac}',
                                    if (_infoError != null) _infoError!,
                                  ].join('\n'),
                                  style: TextStyle(
                                    color: _infoError != null ? AppColors.connecting : AppColors.textMuted,
                                    height: 1.45,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            ),
            const SectionLabel('Grabación'),
            _ToolTile(
              icon: Icons.fiber_manual_record,
              title: 'Grabación',
              subtitle: RecordingApi.supports(device)
                  ? 'Disco o tarjeta SD, grabar siempre o con movimiento, y ver si está grabando'
                  : 'Por ahora solo Hikvision y Dahua. En esta marca, hazlo desde su página web.',
              onTap: RecordingApi.supports(device)
                  ? () => Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => RecordingScreen(store: widget.store, device: _device),
                      ))
                  : null,
            ),
            const SectionLabel('Cámaras'),
            _ToolTile(
              icon: Icons.videocam_outlined,
              title: device.isRecorder ? 'Nombres y visibilidad de cámaras' : 'Nombre y PTZ',
              subtitle: 'Renombrar, ocultar del mosaico y desactivar el joystick',
              onTap: _openChannels,
            ),
            const SectionLabel('Red'),
            _ToolTile(
              icon: Icons.lan_outlined,
              title: 'Cambiar IP',
              subtitle: device.brand.hasFullApi
                  ? 'Con modo seguro, respaldo y rescate automático'
                  : 'Por ahora solo Hikvision y Dahua. En esta marca, hazlo desde su página web.',
              onTap: device.brand.hasFullApi ? _openNetwork : null,
            ),
            const SizedBox(height: 8),
            _ToolTile(
              icon: Icons.travel_explore,
              title: 'Buscar equipo perdido',
              subtitle: _searching
                  ? 'Buscando en tu WiFi…'
                  : 'Si cambió de IP, lo encuentra por su MAC y actualiza la app',
              onTap: _searching ? null : _findLost,
              trailing: _searching
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : null,
            ),
            const SectionLabel('Mantenimiento'),
            _ToolTile(
              icon: Icons.restart_alt,
              title: 'Reiniciar equipo',
              subtitle: 'Útil si se queda pegado o no responde bien',
              onTap: _reboot,
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Icon(icon),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle, style: const TextStyle(color: AppColors.textMuted)),
        trailing: trailing ?? (onTap == null ? null : const Icon(Icons.chevron_right)),
        onTap: onTap,
      ),
    );
  }
}
