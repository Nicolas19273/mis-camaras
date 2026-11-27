import 'package:flutter/material.dart';

import '../models/device.dart';
import '../services/app_store.dart';
import '../services/discovery.dart';
import '../services/network_config.dart';
import '../theme.dart';

/// Cambiar la IP del equipo (fija o automática por DHCP).
/// Devuelve la IP nueva al cerrar, si cambió.
class NetworkScreen extends StatefulWidget {
  const NetworkScreen({super.key, required this.store, required this.device});

  final AppStore store;
  final Device device;

  @override
  State<NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends State<NetworkScreen> {
  late final NetworkConfig _config = NetworkConfig(widget.device);
  final _ip = TextEditingController();
  final _mask = TextEditingController();
  final _gateway = TextEditingController();

  NetSettings? _current;
  bool _dhcp = false;
  bool _loading = true;
  bool _busy = false;
  String? _loadError;
  String? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _config.close();
    _ip.dispose();
    _mask.dispose();
    _gateway.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final s = await _config.read();
      if (!mounted) return;
      setState(() {
        _current = s;
        _dhcp = s.dhcp;
        _ip.text = s.ip;
        _mask.text = s.mask;
        _gateway.text = s.gateway;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = e is NetworkConfigException
            ? e.message
            : 'No se pudo leer la red del equipo. Revisa que esté encendido y en el mismo WiFi.';
      });
    }
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _apply() async {
    final current = _current;
    if (current == null) return;
    final ip = _ip.text.trim();
    final mask = _mask.text.trim();
    final gateway = _gateway.text.trim();

    // --- Validaciones --------------------------------------------------------
    if (!_dhcp) {
      if (!isValidIpv4(ip)) return _snack('La IP no es válida. Ejemplo: 192.168.1.70');
      if (!isValidMask(mask)) return _snack('La máscara no es válida. Normalmente es 255.255.255.0');
      if (!isValidIpv4(gateway)) return _snack('La puerta de enlace no es válida (la IP del router).');
      if (ip == gateway) return _snack('La IP no puede ser la misma del router.');
      if (!sameSubnet(ip, gateway, mask)) {
        return _snack('La IP y la puerta de enlace deben estar en la misma red.');
      }
      if (ip == current.ip && mask == current.mask && gateway == current.gateway && !current.dhcp) {
        return _snack('No hay cambios para aplicar.');
      }
    } else if (current.dhcp) {
      return _snack('El equipo ya está en automático (DHCP).');
    }

    setState(() {
      _busy = true;
      _status = 'Revisando…';
    });

    final warnings = <String>[];
    if (!_dhcp && ip != current.ip && await NetworkConfig.ipInUse(ip)) {
      if (!mounted) return;
      setState(() => _busy = false);
      return _snack('La IP $ip ya la está usando otro equipo. Elige otra.');
    }
    final phoneIp = await DiscoveryService.findLocalIp();
    if (!_dhcp && phoneIp != null && !sameSubnet(ip, phoneIp, mask)) {
      warnings.add('Tu teléfono ($phoneIp) está en otra red: no podrás ver el equipo en $ip '
          'hasta que cambies de WiFi.');
    }
    if (_dhcp && (current.mac == null || current.mac!.isEmpty)) {
      warnings.add('No se pudo leer la MAC del equipo: después tendrás que encontrarlo con '
          '"Buscar en mi red".');
    }
    if (widget.device.isRecorder) {
      warnings.add('Es un grabador: las cámaras conectadas a sus puertos PoE no cambian.');
    }

    if (!mounted) return;
    setState(() => _busy = false);
    final ok = await _confirm(ip, warnings);
    if (ok != true || !mounted) return;

    // --- Aplicar -------------------------------------------------------------
    setState(() {
      _busy = true;
      _status = 'Aplicando el cambio…';
    });
    try {
      await _config.apply(NetSettings(dhcp: _dhcp, ip: ip, mask: mask, gateway: gateway));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      return _snack(e is NetworkConfigException ? e.message : 'No se pudo aplicar: $e');
    }

    // --- Reconectar ------------------------------------------------------------
    if (!mounted) return;
    String? newHost;
    if (_dhcp) {
      setState(() => _status = 'Buscando el equipo con su nueva IP…');
      await Future<void>.delayed(const Duration(seconds: 8));
      newHost = current.mac == null ? null : await NetworkConfig.findByMac(current.mac!);
    } else {
      setState(() => _status = 'Esperando que el equipo responda en $ip…');
      final reachable = await NetworkConfig.waitFor(widget.device, ip);
      newHost = ip;
      if (!reachable && mounted) {
        _snack('El equipo aún no responde en $ip. Si se está reiniciando, espera un minuto.');
      }
    }
    if (!mounted) return;

    if (newHost != null && newHost != widget.device.host) {
      await widget.store.saveDevice(widget.device.copyWith(host: newHost));
      if (!mounted) return;
      _snack('Listo: el equipo ahora está en $newHost.');
      Navigator.of(context).pop(newHost);
    } else {
      setState(() => _busy = false);
      _snack(_dhcp
          ? 'Cambio aplicado. No encontré la IP nueva: usa "Buscar en mi red" para ubicarlo.'
          : 'Cambio aplicado.');
    }
  }

  Future<bool?> _confirm(String ip, List<String> warnings) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('¿Cambiar la red del equipo?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _dhcp
                  ? 'El equipo pedirá su IP al router de forma automática.'
                  : 'El equipo pasará de ${widget.device.host} a $ip.',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            const Text(
              'Se desconectará unos segundos. Si la configuración queda mal, el equipo '
              'dejará de responder y habrá que recuperarlo con SADP (Hikvision) o '
              'ConfigTool (Dahua) desde un computador.',
              style: TextStyle(color: AppColors.textMuted, height: 1.4),
            ),
            for (final w in warnings) ...[
              const SizedBox(height: 10),
              Text('• $w', style: const TextStyle(color: AppColors.connecting, height: 1.4)),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sí, cambiar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;

    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Red del equipo')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
                ? _ErrorView(message: _loadError!, onRetry: _load)
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          '${widget.device.name}\n'
                          'IP actual: ${current?.ip ?? widget.device.host}'
                          '${current?.dhcp == true ? ' (automática)' : ' (fija)'}'
                          '${current?.mac != null ? '\nMAC: ${current!.mac}' : ''}',
                          style: const TextStyle(height: 1.5),
                        ),
                      ),
                      const SizedBox(height: 16),
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: false, label: Text('IP fija')),
                          ButtonSegment(value: true, label: Text('Automática (DHCP)')),
                        ],
                        selected: {_dhcp},
                        showSelectedIcon: false,
                        onSelectionChanged: _busy ? null : (s) => setState(() => _dhcp = s.first),
                      ),
                      const SizedBox(height: 16),
                      if (!_dhcp) ...[
                        TextField(
                          controller: _ip,
                          enabled: !_busy,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: fieldDecoration('IP nueva', hint: '192.168.1.70'),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _mask,
                          enabled: !_busy,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: fieldDecoration('Máscara de subred', hint: '255.255.255.0'),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _gateway,
                          enabled: !_busy,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: fieldDecoration(
                            'Puerta de enlace',
                            hint: '192.168.1.1',
                            helper: 'Normalmente es la IP de tu router.',
                          ),
                        ),
                      ] else
                        const Text(
                          'El router le dará una IP al equipo. La app lo buscará por su MAC para '
                          'actualizar la dirección. Para que no cambie nunca, reserva esa IP en tu router.',
                          style: TextStyle(color: AppColors.textMuted, height: 1.45),
                        ),
                      const SizedBox(height: 24),
                      if (_busy) ...[
                        const LinearProgressIndicator(),
                        const SizedBox(height: 10),
                        Text(_status ?? '', style: const TextStyle(color: AppColors.textMuted)),
                      ] else
                        FilledButton.icon(
                          onPressed: _apply,
                          icon: const Icon(Icons.check),
                          label: const Text('Aplicar cambios'),
                          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                        ),
                    ],
                  ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lan_outlined, size: 44, color: AppColors.textMuted),
            const SizedBox(height: 14),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(height: 1.45)),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }
}
