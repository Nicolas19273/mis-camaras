import 'package:flutter/material.dart';

import '../models/device.dart';
import '../services/app_store.dart';
import '../services/auto_setup.dart';
import '../services/discovery.dart';
import '../theme.dart';
import '../widgets/brand_badge.dart';
import 'device_form_screen.dart';

/// "Buscar en mi red": encuentra equipos Hikvision y Dahua en el WiFi
/// y los agrega pidiendo la contraseña una sola vez.
class DiscoveryScreen extends StatefulWidget {
  const DiscoveryScreen({super.key, required this.store});

  final AppStore store;

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends State<DiscoveryScreen> {
  final _discovery = DiscoveryService();
  List<FoundDevice> _devices = [];
  final _selected = <String>{};
  final _seen = <String>{};
  bool _scanning = false;
  bool _noWifi = false;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _discovery.stop();
    super.dispose();
  }

  bool _isAdded(FoundDevice d) =>
      widget.store.devices.any((x) => x.host == d.ip && widget.store.isHere(x));

  /// Grabador ya agregado que muestra esta cámara (para no verla repetida).
  Device? _inRecorder(FoundDevice d) => d.isRecorder ? null : widget.store.recorderShowing(d.ip);

  bool _canAdd(FoundDevice d) =>
      d.brand != null && d.activated && !_isAdded(d) && _inRecorder(d) == null;

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _noWifi = false;
      _devices = [];
      _selected.clear();
      _seen.clear();
    });
    final result = await _discovery.scan(
      onUpdate: (list) {
        if (!mounted) return;
        setState(() {
          _devices = list;
          for (final d in list) {
            // Los compatibles aparecen marcados la primera vez que se ven.
            if (_canAdd(d) && _seen.add(d.ip)) _selected.add(d.ip);
          }
        });
      },
    );
    if (!mounted) return;
    setState(() {
      _devices = result;
      _scanning = false;
      _noWifi = _discovery.localIp == null;
    });
  }

  Future<void> _openForm(FoundDevice d) async {
    final template = Device(
      id: '',
      name: d.title,
      brand: d.brand ?? Brand.hikvision,
      host: d.ip,
      httpPort: d.httpPort,
      channels: d.channels ?? 1,
    );
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DeviceFormScreen(store: widget.store, template: template),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _addSelected() async {
    final targets = _devices.where((d) => _selected.contains(d.ip) && _canAdd(d)).toList();
    if (targets.isEmpty) return;
    final credentials = await showModalBottomSheet<(String, String)>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (_) => _CredentialsSheet(count: targets.length),
    );
    if (credentials == null || !mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: AppColors.surface,
      builder: (_) => _SetupProgressSheet(
        store: widget.store,
        targets: targets,
        username: credentials.$1,
        password: credentials.$2,
        onFixManually: _openForm,
      ),
    );
    if (mounted) {
      setState(() => _selected.removeWhere((ip) => targets.any((t) => t.ip == ip && _isAdded(t))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectable = _devices.where(_canAdd).toList();
    final count = selectable.where((d) => _selected.contains(d.ip)).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Buscar en mi red'),
        actions: [
          if (!_scanning)
            IconButton(
              tooltip: 'Buscar de nuevo',
              icon: const Icon(Icons.refresh),
              onPressed: _scan,
            ),
        ],
      ),
      body: Column(
        children: [
          _StatusBar(
            scanning: _scanning,
            found: _devices.length,
            localIp: _discovery.localIp,
          ),
          Expanded(
            child: _devices.isEmpty
                ? _EmptyResult(scanning: _scanning, noWifi: _noWifi, onRetry: _scan)
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 120),
                    itemCount: _devices.length,
                    separatorBuilder: (context, index) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final d = _devices[i];
                      return _FoundTile(
                        device: d,
                        added: _isAdded(d),
                        inRecorder: _inRecorder(d)?.name,
                        selected: _selected.contains(d.ip),
                        onToggle: _canAdd(d)
                            ? () => setState(() {
                                  _selected.contains(d.ip)
                                      ? _selected.remove(d.ip)
                                      : _selected.add(d.ip);
                                })
                            : null,
                        onOpen: d.brand != null && !_isAdded(d) ? () => _openForm(d) : null,
                      );
                    },
                  ),
          ),
        ],
      ),
      bottomNavigationBar: selectable.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  onPressed: count == 0 ? null : _addSelected,
                  icon: const Icon(Icons.add),
                  label: Text(count == 1 ? 'Agregar 1 equipo' : 'Agregar $count equipos'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                ),
              ),
            ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.scanning, required this.found, this.localIp});

  final bool scanning;
  final int found;
  final String? localIp;

  @override
  Widget build(BuildContext context) {
    final network = localIp == null
        ? ''
        : ' · red ${localIp!.substring(0, localIp!.lastIndexOf('.'))}.x';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        children: [
          if (scanning)
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          else
            const Icon(Icons.check_circle_outline, size: 18, color: AppColors.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              scanning
                  ? 'Buscando en tu WiFi…$network'
                  : 'Búsqueda terminada: ${found == 1 ? '1 equipo' : '$found equipos'}$network',
              style: const TextStyle(color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _FoundTile extends StatelessWidget {
  const _FoundTile({
    required this.device,
    required this.added,
    this.inRecorder,
    required this.selected,
    required this.onToggle,
    required this.onOpen,
  });

  final FoundDevice device;
  final bool added;

  /// Nombre del grabador que ya muestra esta cámara.
  final String? inRecorder;
  final bool selected;
  final VoidCallback? onToggle;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final d = device;
    final kind = d.isRecorder
        ? (d.channels != null ? 'Grabador · ${d.channels} canales' : 'Grabador')
        : 'Cámara';
    String? badge;
    Color badgeColor = AppColors.textMuted;
    if (added) {
      badge = 'Ya agregado';
    } else if (inRecorder != null) {
      badge = 'Ya se ve dentro de "$inRecorder"';
    } else if (!d.activated) {
      badge = 'Sin activar';
      badgeColor = AppColors.connecting;
    } else if (d.brand == null) {
      badge = 'Marca no compatible';
    }

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onToggle ?? onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            children: [
              d.brand != null
                  ? BrandBadge(brand: d.brand!, size: 40)
                  : const SizedBox(
                      width: 40,
                      height: 40,
                      child: Icon(Icons.device_unknown_outlined, color: AppColors.textMuted),
                    ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      d.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${d.brand?.label ?? 'Otra marca'} · $kind\n${d.ip}${d.httpPort != 80 ? ':${d.httpPort}' : ''}',
                      style: const TextStyle(color: AppColors.textMuted, fontSize: 13, height: 1.35),
                    ),
                    if (badge != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        badge,
                        style: TextStyle(color: badgeColor, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ],
                ),
              ),
              if (onOpen != null)
                IconButton(
                  tooltip: 'Agregar a mano',
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  onPressed: onOpen,
                ),
              if (onToggle != null)
                Checkbox(value: selected, onChanged: (_) => onToggle!()),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyResult extends StatelessWidget {
  const _EmptyResult({required this.scanning, required this.noWifi, required this.onRetry});

  final bool scanning;
  final bool noWifi;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (scanning) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Buscando cámaras y grabadores Hikvision y Dahua…\nTarda unos segundos.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textMuted, height: 1.5),
          ),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(noWifi ? Icons.wifi_off : Icons.search_off, size: 48, color: AppColors.textMuted),
            const SizedBox(height: 16),
            Text(
              noWifi ? 'No estás conectado a un WiFi' : 'No se encontraron equipos',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              'Conecta el teléfono al mismo WiFi que las cámaras. Si tu router separa a los '
              'dispositivos (modo "invitados" o "aislamiento"), la búsqueda no los verá: '
              'agrégalos a mano con su IP.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMuted, height: 1.45),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Buscar de nuevo'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pide usuario y contraseña una sola vez para todos los equipos elegidos.
class _CredentialsSheet extends StatefulWidget {
  const _CredentialsSheet({required this.count});

  final int count;

  @override
  State<_CredentialsSheet> createState() => _CredentialsSheetState();
}

class _CredentialsSheetState extends State<_CredentialsSheet> {
  final _user = TextEditingController(text: 'admin');
  final _pass = TextEditingController();
  bool _hide = true;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  void _submit() {
    if (_user.text.trim().isEmpty) return;
    Navigator.of(context).pop((_user.text.trim(), _pass.text));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.count == 1 ? 'Datos de acceso' : 'Datos de acceso para los ${widget.count} equipos',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          const Text(
            'Los mismos con los que entras a la app oficial o a la página del equipo. '
            'Si alguno usa otra contraseña, después lo agregas a mano.',
            style: TextStyle(color: AppColors.textMuted, height: 1.4),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _user,
            autocorrect: false,
            decoration: fieldDecoration('Usuario'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pass,
            obscureText: _hide,
            autocorrect: false,
            enableSuggestions: false,
            autofocus: true,
            onSubmitted: (_) => _submit(),
            decoration: fieldDecoration(
              'Contraseña',
              suffix: IconButton(
                icon: Icon(_hide ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _hide = !_hide),
              ),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _submit,
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
              child: const Text('Conectar y agregar'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Muestra el avance mientras se registra cada equipo.
class _SetupProgressSheet extends StatefulWidget {
  const _SetupProgressSheet({
    required this.store,
    required this.targets,
    required this.username,
    required this.password,
    required this.onFixManually,
  });

  final AppStore store;
  final List<FoundDevice> targets;
  final String username;
  final String password;
  final Future<void> Function(FoundDevice) onFixManually;

  @override
  State<_SetupProgressSheet> createState() => _SetupProgressSheetState();
}

class _SetupProgressSheetState extends State<_SetupProgressSheet> {
  final _results = <String, SetupOutcome>{};
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final setup = AutoSetup(widget.store);
    // Primero los grabadores: así las cámaras que ya se ven dentro de ellos
    // no se agregan repetidas. De a uno, para no saturar la red.
    final ordered = [
      ...widget.targets.where((d) => d.isRecorder),
      ...widget.targets.where((d) => !d.isRecorder),
    ];
    for (final d in ordered) {
      final outcome = await setup.register(d, widget.username, widget.password);
      if (!mounted) return;
      setState(() => _results[d.ip] = outcome);
    }
    if (mounted) setState(() => _done = true);
  }

  @override
  Widget build(BuildContext context) {
    final added = _results.values.where((r) => r.result == SetupResult.added).length;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _done
                  ? (added == 1 ? '1 equipo agregado' : '$added equipos agregados')
                  : 'Conectando…',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            for (final d in widget.targets) _row(d),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _done ? () => Navigator.of(context).pop() : null,
                child: Text(_done ? 'Listo' : 'Espera un momento…'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(FoundDevice d) {
    final outcome = _results[d.ip];
    Widget icon = const SizedBox.shrink();
    var text = '';
    Color color = AppColors.textMuted;
    switch (outcome?.result) {
      case null:
        icon = const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2));
        text = 'Conectando…';
      case SetupResult.added:
        icon = const Icon(Icons.check_circle, color: AppColors.live, size: 20);
        final dev = outcome!.device!;
        text = dev.channels > 1 ? 'Agregado como "${dev.name}" · ${dev.channels} cámaras' : 'Agregado como "${dev.name}"';
        color = AppColors.text;
      case SetupResult.wrongPassword:
        icon = const Icon(Icons.lock_outline, color: AppColors.connecting, size: 20);
        text = 'Usuario o contraseña incorrectos';
        color = AppColors.connecting;
      case SetupResult.notActivated:
        icon = const Icon(Icons.info_outline, color: AppColors.connecting, size: 20);
        text = 'Sin activar: actívalo primero con SADP o la app oficial';
      case SetupResult.unsupported:
        icon = const Icon(Icons.block, color: AppColors.textMuted, size: 20);
        text = 'Marca no compatible';
      case SetupResult.inRecorder:
        icon = const Icon(Icons.check_circle_outline, color: AppColors.textMuted, size: 20);
        text = 'No se agregó: ya se ve dentro de "${outcome!.detail}"';
      case SetupResult.unreachable:
        icon = const Icon(Icons.error_outline, color: AppColors.offline, size: 20);
        text = 'No respondió. Revisa que esté encendido.';
        color = AppColors.offline;
    }
    final canFix = outcome != null &&
        (outcome.result == SetupResult.wrongPassword || outcome.result == SetupResult.unreachable);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(width: 24, child: Center(child: icon)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${d.title} · ${d.ip}', style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(text, style: TextStyle(color: color, fontSize: 13)),
              ],
            ),
          ),
          if (canFix && _done)
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                widget.onFixManually(d);
              },
              child: const Text('A mano'),
            ),
        ],
      ),
    );
  }
}
