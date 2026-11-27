import 'package:flutter/material.dart';

import '../models/device.dart';
import '../services/app_store.dart';
import '../services/discovery.dart';
import '../services/network_config.dart';
import '../theme.dart';

/// Cambiar la IP del equipo, con protecciones para no dejarlo inaccesible:
/// - Modo seguro: solo IPs de la misma red del teléfono.
/// - Revisa que la IP esté libre y que el router responda.
/// - Sugiere una IP libre.
/// - Guarda un respaldo para volver a la configuración anterior.
/// - Si no responde después del cambio, lo busca por su MAC (rescate).
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
  String? _phoneIp;
  bool _dhcp = false;
  bool _advanced = false;
  bool _loading = true;
  bool _busy = false;
  String? _loadError;
  String? _status;
  Map<String, dynamic>? _backup;

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
    _phoneIp = await DiscoveryService.findLocalIp();
    try {
      final s = await _config.read();
      if (!mounted) return;
      // Se guarda la MAC para poder encontrar el equipo si se pierde.
      if (s.mac != null && widget.device.mac == null) {
        final d = widget.store.deviceById(widget.device.id);
        if (d != null) await widget.store.saveDevice(d.copyWith(mac: s.mac));
      }
      final backup = widget.store.networkBackup(widget.device.id);
      if (!mounted) return;
      setState(() {
        _current = s;
        _dhcp = s.dhcp;
        _ip.text = s.ip;
        _mask.text = s.mask;
        _gateway.text = s.gateway;
        _backup = (backup != null && backup['ip'] != s.ip) ? backup : null;
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

  // --- Herramientas ----------------------------------------------------------------

  Future<void> _suggestIp() async {
    final phone = _phoneIp;
    if (phone == null) return _snack('Conéctate al WiFi para buscar una IP libre.');
    setState(() {
      _busy = true;
      _status = 'Buscando una IP libre…';
    });
    final used = widget.store.devices.map((d) => d.host).toSet();
    final ip = await NetworkConfig.suggestFreeIp(phone, used);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ip != null) {
        _dhcp = false;
        _ip.text = ip;
        if (_mask.text.trim().isEmpty) _mask.text = '255.255.255.0';
      }
    });
    _snack(ip != null ? 'IP libre sugerida: $ip' : 'No encontré una IP libre.');
  }

  void _restoreBackup() {
    final b = _backup;
    if (b == null) return;
    setState(() {
      _dhcp = b['dhcp'] == true;
      _ip.text = '${b['ip'] ?? ''}';
      _mask.text = '${b['mask'] ?? ''}';
      _gateway.text = '${b['gateway'] ?? ''}';
    });
    _snack('Datos anteriores cargados. Revisa y toca "Aplicar cambios".');
  }

  // --- Aplicar ---------------------------------------------------------------------

  Future<void> _apply() async {
    final current = _current;
    if (current == null) return;
    final ip = _ip.text.trim();
    final mask = _mask.text.trim();
    final gateway = _gateway.text.trim();
    final phone = _phoneIp;

    // Validaciones que bloquean.
    if (!_dhcp) {
      if (!isValidIpv4(ip)) return _snack('La IP no es válida. Ejemplo: 192.168.1.70');
      if (!isValidMask(mask)) return _snack('La máscara no es válida. Normalmente es 255.255.255.0');
      if (!isValidIpv4(gateway)) return _snack('La puerta de enlace no es válida (la IP del router).');
      if (ip == gateway) return _snack('La IP no puede ser la misma del router.');
      if (ip == phone) return _snack('Esa es la IP de tu teléfono. Elige otra.');
      if (!sameSubnet(ip, gateway, mask)) {
        return _snack('La IP y la puerta de enlace deben estar en la misma red.');
      }
      if (!_advanced && phone != null && !sameSubnet(ip, phone, mask)) {
        return _snack('Modo seguro: la IP debe estar en la red de tu teléfono '
            '(${phone.substring(0, phone.lastIndexOf('.'))}.x).');
      }
      if (ip == current.ip && mask == current.mask && gateway == current.gateway && !current.dhcp) {
        return _snack('No hay cambios para aplicar.');
      }
    } else if (current.dhcp) {
      return _snack('El equipo ya está en automático (DHCP).');
    }

    setState(() {
      _busy = true;
      _status = 'Revisando la red…';
    });

    // Revisiones en la red.
    final warnings = <String>[];
    if (!_dhcp) {
      if (ip != current.ip && await NetworkConfig.ipInUse(ip)) {
        if (!mounted) return;
        setState(() => _busy = false);
        return _snack('La IP $ip ya la está usando otro equipo. Elige otra o toca "Sugerir IP libre".');
      }
      if (!await NetworkConfig.hostResponds(gateway, [80, 443, 53, 8080])) {
        warnings.add('No encontré un router en $gateway. Si es incorrecto, el equipo funcionará '
            'en tu WiFi pero no tendrá internet.');
      }
      if (phone != null && !sameSubnet(ip, phone, mask)) {
        warnings.add('Modo avanzado: tu teléfono ($phone) está en otra red. No podrás ver el '
            'equipo en $ip desde este WiFi.');
      }
    }
    final mac = current.mac ?? widget.device.mac;
    if (_dhcp && mac == null) {
      warnings.add('No se pudo leer la MAC: después tendrás que encontrarlo con "Buscar en mi red".');
    }
    if (widget.device.isRecorder) {
      warnings.add('Es un grabador: las cámaras conectadas a sus puertos PoE no cambian.');
    }

    if (!mounted) return;
    setState(() => _busy = false);
    final ok = await _confirm(ip, warnings);
    if (ok != true || !mounted) return;

    // Respaldo de la configuración actual, para poder volver.
    await widget.store.saveNetworkBackup(widget.device.id, {
      'dhcp': current.dhcp,
      'ip': current.ip,
      'mask': current.mask,
      'gateway': current.gateway,
      'mac': mac,
      'date': DateTime.now().toIso8601String(),
    });
    if (!mounted) return;

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
    if (!mounted) return;

    // Reconectar.
    String? newHost;
    if (_dhcp) {
      setState(() => _status = 'Buscando el equipo con su nueva IP…');
      await Future<void>.delayed(const Duration(seconds: 8));
      newHost = mac == null ? null : await NetworkConfig.findByMac(mac);
    } else {
      setState(() => _status = 'Esperando que el equipo responda en $ip…');
      if (await NetworkConfig.waitFor(widget.device, ip)) {
        newHost = ip;
      } else if (mounted) {
        // Rescate: se busca por su MAC para saber dónde quedó.
        setState(() => _status = 'No responde en $ip. Buscándolo en la red…');
        newHost = await _rescue(mac, expected: ip);
      }
    }
    if (!mounted) return;

    if (newHost != null && newHost != widget.device.host) {
      final d = widget.store.deviceById(widget.device.id) ?? widget.device;
      await widget.store.saveDevice(d.copyWith(host: newHost, mac: mac));
      if (!mounted) return;
      _snack('Listo: el equipo ahora está en $newHost.');
      Navigator.of(context).pop(newHost);
    } else {
      setState(() => _busy = false);
      if (_dhcp) {
        _snack('Cambio aplicado. No encontré la IP nueva: usa "Buscar en mi red" para ubicarlo.');
      }
    }
  }

  /// Busca el equipo por su MAC después de un cambio que no respondió.
  Future<String?> _rescue(String? mac, {required String expected}) async {
    final found = mac == null ? null : await NetworkConfig.findByMac(mac);
    if (!mounted) return null;
    final phone = _phoneIp;
    final mask = _mask.text.trim();
    if (found != null && (phone == null || sameSubnet(found, phone, mask))) {
      return found; // está en nuestra red: se actualiza
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('El equipo no responde'),
        content: Text(
          found != null
              ? 'Lo encontré en $found, pero esa IP está en otra red y tu teléfono no puede '
                  'comunicarse con él. Para recuperarlo, usa SADP (Hikvision) o ConfigTool '
                  '(Dahua) en un computador conectado al mismo router, y vuelve a ponerle una IP '
                  'de tu red.'
              : 'Puede que se esté reiniciando: espera un minuto y entra a Herramientas → '
                  '"Buscar equipo perdido". Si no aparece, recupéralo con SADP (Hikvision) o '
                  'ConfigTool (Dahua) desde un computador.',
          style: const TextStyle(height: 1.45),
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Entendido')),
        ],
      ),
    );
    return found == expected ? expected : null;
  }

  Future<bool?> _confirm(String ip, List<String> warnings) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('¿Cambiar la red del equipo?'),
        content: SingleChildScrollView(
          child: Column(
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
                'Se desconectará unos segundos. Se guarda un respaldo de la configuración '
                'actual por si quieres volver atrás.',
                style: TextStyle(color: AppColors.textMuted, height: 1.4),
              ),
              for (final w in warnings) ...[
                const SizedBox(height: 10),
                Text('• $w', style: const TextStyle(color: AppColors.connecting, height: 1.4)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Sí, cambiar')),
        ],
      ),
    );
  }

  // --- Interfaz --------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final backup = _backup;

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
                          '${current?.mac != null ? '\nMAC: ${current!.mac}' : ''}'
                          '${_phoneIp != null ? '\nTu teléfono: $_phoneIp' : ''}',
                          style: const TextStyle(height: 1.5),
                        ),
                      ),
                      if (backup != null) ...[
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _restoreBackup,
                          icon: const Icon(Icons.restore),
                          label: Text('Restaurar configuración anterior (${backup['ip']})'),
                        ),
                      ],
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
                          decoration: fieldDecoration(
                            'IP nueva',
                            hint: '192.168.1.70',
                            suffix: IconButton(
                              tooltip: 'Sugerir IP libre',
                              icon: const Icon(Icons.auto_fix_high),
                              onPressed: _busy ? null : _suggestIp,
                            ),
                          ),
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
                        const SizedBox(height: 8),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Modo avanzado'),
                          subtitle: const Text(
                            'Permite poner una IP de otra red. Solo si sabes lo que haces: '
                            'tu teléfono podría dejar de verlo.',
                            style: TextStyle(color: AppColors.textMuted),
                          ),
                          value: _advanced,
                          onChanged: _busy ? null : (v) => setState(() => _advanced = v),
                        ),
                      ] else
                        const Text(
                          'El router le dará una IP al equipo. La app lo buscará por su MAC para '
                          'actualizar la dirección. Para que no cambie nunca, reserva esa IP en tu router.',
                          style: TextStyle(color: AppColors.textMuted, height: 1.45),
                        ),
                      const SizedBox(height: 20),
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
                      const SizedBox(height: 16),
                      const Text(
                        'Protecciones: la app revisa que la IP esté libre y en tu red, comprueba el '
                        'router, guarda un respaldo y, si el equipo no responde, lo busca por su MAC.',
                        style: TextStyle(color: AppColors.textMuted, fontSize: 12, height: 1.4),
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
