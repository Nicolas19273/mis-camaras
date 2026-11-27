import 'package:flutter/material.dart';

import '../models/device.dart';
import '../services/app_store.dart';
import '../services/camera_http.dart';
import '../services/device_api.dart';
import '../services/network_config.dart';
import '../services/nvr_channels.dart';
import '../theme.dart';

/// Por qué el NVR no encuentra una cámara.
enum NvrLinkIssue { pickCamera, ipChanged, otherSubnet, badGateway, wrongPort, unknown }

/// Diagnóstico (función pura para poder probarla).
NvrLinkIssue diagnoseNvrLink({
  required NvrChannel channel,
  required Device? camera,
  NetSettings? cameraNet,
  NetSettings? nvrNet,
  int? cameraTcpPort,
}) {
  if (camera == null) return NvrLinkIssue.pickCamera;
  if (camera.host != channel.address) return NvrLinkIssue.ipChanged;
  if (cameraNet != null && nvrNet != null) {
    final ok = [cameraNet.ip, cameraNet.mask, nvrNet.ip, nvrNet.mask].every(isValidIpv4);
    if (ok &&
        (!sameSubnet(cameraNet.ip, nvrNet.ip, nvrNet.mask) || !sameSubnet(cameraNet.ip, nvrNet.ip, cameraNet.mask))) {
      return NvrLinkIssue.otherSubnet;
    }
    final gw = cameraNet.gateway;
    if (ok && (!isValidIpv4(gw) || !sameSubnet(gw, cameraNet.ip, cameraNet.mask))) {
      return NvrLinkIssue.badGateway;
    }
  }
  final protocol = (channel.protocol ?? '').toLowerCase();
  final privateProtocol = protocol.isEmpty || protocol.contains('dahua') || protocol.contains('private');
  if (camera.brand == Brand.dahua &&
      privateProtocol &&
      cameraTcpPort != null &&
      channel.port != null &&
      channel.port != cameraTcpPort) {
    return NvrLinkIssue.wrongPort;
  }
  return NvrLinkIssue.unknown;
}

/// Repara la conexión entre el NVR y una de sus cámaras cuando el NVR dice
/// "Falló búsqueda de host de red" (no la encuentra en la IP que tiene guardada).
class NvrRepairScreen extends StatefulWidget {
  const NvrRepairScreen({super.key, required this.store, this.nvr, this.channel, this.camera});

  final AppStore store;
  final Device? nvr;
  final int? channel;
  final Device? camera;

  @override
  State<NvrRepairScreen> createState() => _NvrRepairScreenState();
}

class _NvrRepairScreenState extends State<NvrRepairScreen> {
  Device? _nvr;
  List<NvrChannel> _channels = [];
  final _reach = <int, bool>{};
  NvrChannel? _selected;
  Device? _camera;
  NetSettings? _camNet;
  NetSettings? _nvrNet;
  int? _camTcpPort;
  String? _error;
  bool _loading = true;
  String? _busy;
  String? _result;
  bool? _resultOk;

  AppStore get store => widget.store;

  List<Device> get _nvrs => store.activeDevices.where(NvrChannels.supports).toList();
  List<Device> get _cameras => store.activeDevices.where((d) => !d.isRecorder).toList();

  @override
  void initState() {
    super.initState();
    _nvr = widget.nvr ?? (_nvrs.isEmpty ? null : _nvrs.first);
    _camera = widget.camera;
    _load();
  }

  Future<void> _load() async {
    final nvr = _nvr;
    if (nvr == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _result = null;
    });
    final api = NvrChannels(nvr);
    try {
      final list = await api.list();
      // ¿Responde algo en la IP de cada canal (desde el teléfono)?
      final reach = <int, bool>{};
      await Future.wait(list.map((c) async {
        reach[c.channel] = await NetworkConfig.hostResponds(
          c.address,
          [if (c.port != null) c.port!, 80, 554],
          timeout: const Duration(milliseconds: 1200),
        );
      }));
      if (!mounted) return;
      setState(() {
        _channels = list;
        _reach
          ..clear()
          ..addAll(reach);
        _selected = _pickChannel(list);
        _camera ??= _pickCamera(_selected);
      });
      await _readNetworks();
    } on NvrChannelException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'El NVR no responde. Revisa que esté encendido y en tu WiFi.');
    } finally {
      api.close();
      if (mounted) setState(() => _loading = false);
    }
  }

  String _title(NvrChannel c) {
    final name = _nvr?.channelNames[c.channel]?.trim() ?? '';
    return name.isNotEmpty ? name : 'Cámara ${c.channel}';
  }

  NvrChannel? _pickChannel(List<NvrChannel> list) {
    if (list.isEmpty) return null;
    final wanted = widget.channel;
    if (wanted != null) {
      for (final c in list) {
        if (c.channel == wanted) return c;
      }
    }
    final cam = _camera;
    if (cam != null) {
      for (final c in list) {
        if (c.address == cam.host) return c;
      }
      final n = cam.name.toLowerCase();
      for (final c in list) {
        final t = _title(c).toLowerCase();
        if (t.length > 2 && (n.contains(t) || t.contains(n))) return c;
      }
    }
    for (final c in list) {
      if (_reach[c.channel] == false) return c;
    }
    return list.first;
  }

  Device? _pickCamera(NvrChannel? c) {
    if (c == null) return null;
    for (final d in _cameras) {
      if (d.host == c.address) return d;
    }
    final t = _title(c).toLowerCase();
    if (t.length > 2) {
      for (final d in _cameras) {
        final n = d.name.toLowerCase();
        if (n.contains(t) || t.contains(n)) return d;
      }
    }
    return null;
  }

  /// Lee la red de la cámara y del NVR para comparar.
  Future<void> _readNetworks() async {
    final nvr = _nvr;
    final cam = _camera;
    NetSettings? camNet;
    NetSettings? nvrNet;
    int? tcp;
    if (nvr != null && nvr.brand.hasFullApi) {
      final c = NetworkConfig(nvr);
      try {
        nvrNet = await c.read();
      } catch (_) {
      } finally {
        c.close();
      }
    }
    if (cam != null && cam.brand.hasFullApi) {
      final c = NetworkConfig(cam);
      try {
        camNet = await c.read();
      } catch (_) {
      } finally {
        c.close();
      }
      if (cam.brand == Brand.dahua) {
        final http = CameraHttp(cam);
        try {
          final r = await http.get('/cgi-bin/configManager.cgi?action=getConfig&name=Network');
          if (r.statusCode == 200) {
            tcp = int.tryParse(parseDahuaTable(r.body, 'table.Network.')['TcpPort'] ?? '');
          }
        } catch (_) {
        } finally {
          http.close();
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _nvrNet = nvrNet;
      _camNet = camNet;
      _camTcpPort = tcp;
    });
  }

  NvrLinkIssue? get _issue {
    final ch = _selected;
    if (ch == null) return null;
    return diagnoseNvrLink(
      channel: ch,
      camera: _camera,
      cameraNet: _camNet,
      nvrNet: _nvrNet,
      cameraTcpPort: _camTcpPort,
    );
  }

  // --- Arreglos ---------------------------------------------------------------------

  Future<void> _run(String text, Future<String> Function() action) async {
    setState(() {
      _busy = text;
      _result = null;
    });
    try {
      final msg = await action();
      if (!mounted) return;
      setState(() => _busy = 'Esperando que el NVR se conecte a la cámara…');
      await Future<void>.delayed(const Duration(seconds: 20));
      final ok = await _verify();
      if (!mounted) return;
      setState(() {
        _resultOk = ok;
        _result = ok == true
            ? '$msg\n\nListo: el NVR ya recibe imagen de esta cámara. Revisa el monitor.'
            : '$msg\n\nTodavía no se puede confirmar desde aquí. Mira el monitor en 1–2 minutos; '
                'si sigue el error, prueba la siguiente solución.';
      });
      await _load();
    } on NvrChannelException catch (e) {
      if (mounted) setState(() => _fail(e.message));
    } on NetworkConfigException catch (e) {
      if (mounted) setState(() => _fail(e.message));
    } on DeviceApiException catch (e) {
      if (mounted) setState(() => _fail(e.message));
    } catch (_) {
      if (mounted) setState(() => _fail('No se pudo hacer el cambio. Revisa que el equipo esté encendido.'));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  void _fail(String message) {
    _resultOk = false;
    _result = message;
  }

  Future<bool?> _verify() async {
    final nvr = _nvr;
    final ch = _selected;
    if (nvr == null || ch == null) return null;
    final api = NvrChannels(nvr);
    try {
      return await api.hasImage(ch.channel);
    } finally {
      api.close();
    }
  }

  /// La cámara cambió de IP: se deja fija donde está y se le avisa al NVR.
  Future<String> _fixIp() async {
    final cam = _camera!;
    final ch = _selected!;
    var fixed = false;
    final net = _camNet;
    if (net != null && net.dhcp && cam.brand.hasFullApi) {
      final c = NetworkConfig(cam);
      try {
        await c.read();
        await c.apply(NetSettings(dhcp: false, ip: cam.host, mask: net.mask, gateway: net.gateway));
        fixed = true;
      } catch (_) {
        // Si no se puede dejar fija, igual se corrige el NVR.
      } finally {
        c.close();
      }
    }
    final api = NvrChannels(_nvr!);
    try {
      await api.update(ch, address: cam.host);
    } finally {
      api.close();
    }
    return 'El NVR ahora busca la cámara en ${cam.host}.'
        '${fixed ? ' Además la cámara quedó con esa IP fija, para que no vuelva a cambiar.' : ''}';
  }

  /// Máscara y puerta de enlace de la cámara iguales a las del NVR (la IP no cambia).
  Future<String> _fixNetwork() async {
    final cam = _camera!;
    final nvrNet = _nvrNet!;
    final c = NetworkConfig(cam);
    try {
      await c.read();
      await c.apply(NetSettings(dhcp: false, ip: cam.host, mask: nvrNet.mask, gateway: nvrNet.gateway));
    } finally {
      c.close();
    }
    return 'La cámara quedó con máscara ${nvrNet.mask} y puerta de enlace ${nvrNet.gateway}, '
        'igual que el NVR.';
  }

  Future<String> _fixPort() async {
    final api = NvrChannels(_nvr!);
    try {
      await api.update(_selected!, port: _camTcpPort);
    } finally {
      api.close();
    }
    return 'El NVR ahora se conecta por el puerto $_camTcpPort, el que usa la cámara.';
  }

  Future<String> _fixCredentials() async {
    final cam = _camera!;
    final api = NvrChannels(_nvr!);
    try {
      await api.update(_selected!, user: cam.username, password: cam.password);
    } finally {
      api.close();
    }
    return 'El NVR ahora usa el mismo usuario y contraseña con que la app ve la cámara.';
  }

  Future<String> _rebootCamera() async {
    final api = DeviceApi(_camera!);
    try {
      await api.reboot();
    } finally {
      api.close();
    }
    await Future<void>.delayed(const Duration(seconds: 40));
    return 'La cámara se reinició.';
  }

  // --- Interfaz --------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_nvr == null) {
      body = const _Center(
        text: 'No hay un NVR Hikvision o Dahua en esta red. Esta herramienta corrige cámaras que el NVR no '
            'encuentra.',
      );
    } else if (_loading && _channels.isEmpty) {
      body = const _Center(text: 'Leyendo las cámaras del NVR…', loading: true);
    } else if (_error != null && _channels.isEmpty) {
      body = _Center(text: _error!, action: FilledButton(onPressed: _load, child: const Text('Reintentar')));
    } else {
      body = ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          const Text(
            'Si el monitor del NVR dice "Falló búsqueda de host de red", el NVR no encuentra la cámara en la '
            'IP que tiene guardada. Aquí se ve por qué y se arregla.',
            style: TextStyle(color: AppColors.textMuted, height: 1.4),
          ),
          const SizedBox(height: 16),
          if (_nvrs.length > 1) ...[
            DropdownButtonFormField<String>(
              initialValue: _nvr!.id,
              decoration: fieldDecoration('NVR'),
              items: [for (final n in _nvrs) DropdownMenuItem(value: n.id, child: Text(n.name))],
              onChanged: (id) {
                setState(() {
                  _nvr = _nvrs.firstWhere((n) => n.id == id);
                  _channels = [];
                  _selected = null;
                });
                _load();
              },
            ),
            const SizedBox(height: 12),
          ],
          DropdownButtonFormField<int>(
            key: ValueKey('canal-${_nvr?.id}-${_selected?.channel}'),
            initialValue: _selected?.channel,
            isExpanded: true,
            decoration: fieldDecoration('Cámara en el NVR'),
            items: [
              for (final c in _channels)
                DropdownMenuItem(
                  value: c.channel,
                  child: Text(
                    '${_title(c)} · ${c.address}${_reach[c.channel] == false ? ' (no responde)' : ''}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) {
              setState(() {
                _selected = _channels.firstWhere((c) => c.channel == v);
                _camera = widget.camera ?? _pickCamera(_selected);
                _result = null;
              });
              _readNetworks();
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            key: ValueKey('camara-${_selected?.channel}-${_camera?.id}'),
            initialValue: _camera?.id,
            isExpanded: true,
            decoration: fieldDecoration('¿Cuál es esa cámara en la app?',
                helper: 'La que sí se ve en la app (conectada directo).'),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('No sé / no está en la app')),
              for (final d in _cameras)
                DropdownMenuItem<String?>(
                  value: d.id,
                  child: Text('${d.name} · ${d.host}', overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (id) {
              setState(() {
                _camera = id == null ? null : _cameras.firstWhere((d) => d.id == id);
                _result = null;
              });
              _readNetworks();
            },
          ),
          const SizedBox(height: 18),
          if (_selected != null) _diagnosis(),
          if (_result != null) ...[
            const SizedBox(height: 14),
            Material(
              color: (_resultOk == true ? AppColors.live : AppColors.connecting).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(_result!, style: const TextStyle(height: 1.4)),
              ),
            ),
          ],
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reparar cámara en el NVR'),
        actions: [
          IconButton(
            tooltip: 'Revisar de nuevo',
            icon: const Icon(Icons.refresh),
            onPressed: _loading || _busy != null ? null : _load,
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(child: body),
          if (_busy != null)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black54,
                child: Center(
                  child: Card(
                    color: AppColors.surface,
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 16),
                          Text(_busy!, textAlign: TextAlign.center),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _diagnosis() {
    final ch = _selected!;
    final cam = _camera;
    final reach = _reach[ch.channel];
    final issue = _issue!;
    final camNet = _camNet;
    final nvrNet = _nvrNet;

    String title;
    String detail;
    final actions = <Widget>[];
    Widget fix(String label, Future<String> Function() run, {bool primary = true}) {
      final onPressed = _busy != null ? null : () => _run(label, run);
      final button = primary
          ? FilledButton(onPressed: onPressed, child: Text(label, textAlign: TextAlign.center))
          : OutlinedButton(onPressed: onPressed, child: Text(label, textAlign: TextAlign.center));
      return Padding(padding: const EdgeInsets.only(top: 8), child: SizedBox(width: double.infinity, child: button));
    }

    switch (issue) {
      case NvrLinkIssue.pickCamera:
        title = reach == false ? 'No hay nada en ${ch.address}' : 'Elige la cámara';
        detail = reach == false
            ? 'El NVR busca "${_title(ch)}" en ${ch.address}, pero ahí no responde nada: lo más probable es '
                'que la cámara haya cambiado de IP (pasa mucho después de un corte de luz). Elige arriba cuál '
                'cámara de la app es, para darle al NVR su IP nueva.'
            : 'Elige arriba cuál cámara de la app es "${_title(ch)}" para revisar su conexión con el NVR.';
      case NvrLinkIssue.ipChanged:
        title = 'La cámara cambió de IP';
        detail = 'El NVR la busca en ${ch.address}, pero ahora está en ${cam!.host}. Se arregla poniéndole '
            'la IP nueva al NVR${camNet?.dhcp == true ? ' y dejando la IP fija en la cámara para que no vuelva a cambiar' : ''}.';
        actions.add(fix('Arreglar: usar ${cam.host} en el NVR', _fixIp));
      case NvrLinkIssue.otherSubnet:
        title = 'La cámara y el NVR están en redes distintas';
        detail = 'Cámara: ${camNet!.ip} / ${camNet.mask}. NVR: ${nvrNet!.ip} / ${nvrNet.mask}. '
            'El teléfono la ve, pero el NVR no. Se arregla dejando en la cámara la misma máscara y puerta de '
            'enlace que el NVR (la IP no cambia).';
        actions.add(fix('Arreglar la red de la cámara', _fixNetwork));
      case NvrLinkIssue.badGateway:
        title = 'La puerta de enlace de la cámara está mal';
        detail = 'La cámara tiene puerta de enlace "${camNet!.gateway.isEmpty ? 'vacía' : camNet.gateway}", '
            'que no corresponde a su red. Se arregla poniendo la del NVR (${nvrNet!.gateway}).';
        actions.add(fix('Arreglar la red de la cámara', _fixNetwork));
      case NvrLinkIssue.wrongPort:
        title = 'El NVR usa otro puerto';
        detail = 'El NVR se conecta por el puerto ${ch.port}, pero la cámara usa el $_camTcpPort.';
        actions.add(fix('Arreglar: usar el puerto $_camTcpPort', _fixPort));
      case NvrLinkIssue.unknown:
        title = 'La IP y la red están bien';
        detail = 'El NVR busca la cámara en la IP correcta (${ch.address}) y están en la misma red. '
            'Suele ser la contraseña guardada en el NVR (si se cambió en la cámara) o la cámara trabada.';
        actions
          ..add(fix('Poner en el NVR la contraseña de la app', _fixCredentials))
          ..add(fix('Reiniciar la cámara', _rebootCamera, primary: false));
    }

    final rows = [
      'NVR busca en: ${ch.address}${ch.port != null ? ':${ch.port}' : ''}'
          '${reach == null ? '' : reach ? ' · responde' : ' · no responde'}',
      if (cam != null) 'Cámara en la app: ${cam.host}${camNet != null ? ' · ${camNet.dhcp ? 'IP automática' : 'IP fija'}' : ''}',
      if (camNet != null) 'Red de la cámara: máscara ${camNet.mask} · enlace ${camNet.gateway.isEmpty ? '—' : camNet.gateway}',
      if (nvrNet != null) 'Red del NVR: ${nvrNet.ip} · máscara ${nvrNet.mask} · enlace ${nvrNet.gateway}',
    ];

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(detail, style: const TextStyle(color: AppColors.textMuted, height: 1.4)),
            const SizedBox(height: 10),
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(r, style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace')),
              ),
            ...actions,
          ],
        ),
      ),
    );
  }
}

class _Center extends StatelessWidget {
  const _Center({required this.text, this.loading = false, this.action});

  final String text;
  final bool loading;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading) const CircularProgressIndicator(),
            if (loading) const SizedBox(height: 16),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textMuted, height: 1.4)),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
