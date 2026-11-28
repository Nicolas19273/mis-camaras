import 'package:flutter/material.dart';

import '../models/device.dart';
import '../services/app_store.dart';
import '../services/camera_http.dart';
import '../services/device_api.dart';
import '../services/discovery.dart';
import '../services/link_doctor.dart';
import '../services/network_config.dart';
import '../services/nvr_channels.dart';
import '../theme.dart';

/// Por qué el NVR no encuentra una cámara (por su configuración).
enum NvrLinkIssue { pickCamera, ipChanged, otherSubnet, badGateway, wrongPort, unknown }

/// Diagnóstico por configuración (función pura para poder probarla).
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

/// Pasos que puede hacer la reparación.
enum RepairStep { useCameraIp, fixCameraNetwork, newFreeIp, fixPort, fixProtocol, credentials, reconnect }

/// Arma el plan de reparación según lo que se encontró (función pura).
List<RepairStep> buildRepairPlan({
  required NvrLinkIssue issue,
  required bool conflictSuspected,
  required bool dropsAfterSeconds,
  required bool protocolWrong,
  required bool? nvrConnected,
  required bool cameraKnown,
}) {
  if (!cameraKnown) return const [RepairStep.reconnect];
  final steps = <RepairStep>[];
  // Una IP nueva y libre arregla a la vez: IP repetida, IP cambiada y red mal puesta.
  final newIp = conflictSuspected || dropsAfterSeconds;
  if (newIp) {
    steps.add(RepairStep.newFreeIp);
  } else {
    if (issue == NvrLinkIssue.otherSubnet || issue == NvrLinkIssue.badGateway) {
      steps.add(RepairStep.fixCameraNetwork);
    }
    if (issue == NvrLinkIssue.ipChanged) steps.add(RepairStep.useCameraIp);
  }
  if (issue == NvrLinkIssue.wrongPort) steps.add(RepairStep.fixPort);
  if (protocolWrong) steps.add(RepairStep.fixProtocol);
  if (nvrConnected != true) steps.add(RepairStep.credentials);
  steps.add(RepairStep.reconnect);
  return steps;
}

/// Repara de verdad la conexión entre el NVR y una cámara cuando el monitor
/// dice "Falló búsqueda de host de red" o la imagen aparece y se corta:
/// analiza a fondo (IP repetida, estabilidad, red, puerto, protocolo, si el
/// NVR está conectado visto desde la cámara), arregla todo de una vez y
/// comprueba durante 90 segundos que la conexión se mantenga.
class NvrRepairScreen extends StatefulWidget {
  const NvrRepairScreen({super.key, required this.store, this.nvr, this.channel, this.camera});

  final AppStore store;
  final Device? nvr;
  final int? channel;
  final Device? camera;

  @override
  State<NvrRepairScreen> createState() => _NvrRepairScreenState();
}

enum _Lvl { wait, ok, warn, bad, info }

class _Line {
  _Line(this.level, this.text);
  _Lvl level;
  String text;
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

  /// Lo que la persona ve en el monitor: true = "aparece y se corta".
  bool _drops = false;

  // Análisis a fondo.
  bool _analyzing = false;
  int _probeDone = 0;
  StabilityResult? _probe;
  bool? _scanConflict;
  Set<String> _scanMacs = {};
  List<FoundDevice> _scanAll = [];
  List<String>? _activeUsers;
  bool _analyzed = false;

  // Reparación.
  final _enabled = <RepairStep>{};
  bool _repairing = false;
  final _log = <_Line>[];
  String? _final;
  bool? _finalOk;

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

  // --- Carga --------------------------------------------------------------------------

  Future<void> _load({bool analyze = true}) async {
    final nvr = _nvr;
    if (nvr == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = NvrChannels(nvr);
    try {
      final list = await api.list();
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
        final keep = _selected?.channel;
        _selected = keep != null ? list.where((c) => c.channel == keep).firstOrNull : null;
        _selected ??= _pickChannel(list);
        _camera = _camera == null ? _pickCamera(_selected) : (store.deviceById(_camera!.id) ?? _camera);
      });
      await _readNetworks();
      if (analyze) await _analyze();
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
        final h = CameraHttp(cam);
        try {
          final r = await h.get('/cgi-bin/configManager.cgi?action=getConfig&name=Network');
          if (r.statusCode == 200) {
            tcp = int.tryParse(parseDahuaTable(r.body, 'table.Network.')['TcpPort'] ?? '');
          }
        } catch (_) {
        } finally {
          h.close();
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

  // --- Análisis a fondo ---------------------------------------------------------------

  Future<void> _analyze() async {
    final ch = _selected;
    if (ch == null || _analyzing) return;
    setState(() {
      _analyzing = true;
      _analyzed = false;
      _probe = null;
      _probeDone = 0;
      _scanConflict = null;
      _activeUsers = null;
      _final = null;
    });
    final cam = _camera;
    if (cam != null) {
      final users = await LinkDoctor.activeUsers(cam);
      if (mounted) setState(() => _activeUsers = users);
    }
    final probe = await LinkDoctor.probe(
      ch.address,
      port: cam?.httpPort ?? 80,
      onProgress: (n) {
        if (mounted) setState(() => _probeDone = n);
      },
    );
    if (!mounted) return;
    setState(() => _probe = probe);
    final scan = await LinkDoctor.scan(ch.address);
    if (!mounted) return;
    setState(() {
      _scanConflict = scan.conflict;
      _scanMacs = scan.macs;
      _scanAll = scan.all;
      _analyzing = false;
      _analyzed = true;
      _enabled
        ..clear()
        ..addAll(_plan);
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

  bool? get _nvrConnected {
    final users = _activeUsers;
    if (users == null) return null;
    final ips = {_nvr?.host, _nvrNet?.ip};
    return users.any(ips.contains);
  }

  /// MAC de la cámara (según la propia cámara) vs. las que contestaron en la IP.
  bool get _otherMacAtIp {
    final mac = _camNet?.mac;
    if (mac == null || _scanMacs.isEmpty) return false;
    final mine = mac.toLowerCase().replaceAll(RegExp('[^0-9a-f]'), '');
    return mine.length == 12 && !_scanMacs.contains(mine);
  }

  bool get _conflictSuspected {
    final p = _probe;
    return _scanConflict == true ||
        _otherMacAtIp ||
        (p != null && (p.mixedAnswers || (p.intermittent && p.loss >= 0.1)));
  }

  String? get _protocolFix {
    final ch = _selected;
    final cam = _camera;
    final nvr = _nvr;
    if (ch == null || cam == null || nvr == null) return null;
    return suggestedProtocol(ch, cam, nvr.brand, _channels);
  }

  List<RepairStep> get _plan {
    final issue = _issue;
    if (issue == null) return const [];
    return buildRepairPlan(
      issue: issue,
      conflictSuspected: _conflictSuspected,
      dropsAfterSeconds: _drops,
      protocolWrong: _protocolFix != null,
      nvrConnected: _nvrConnected,
      cameraKnown: _camera != null,
    );
  }

  // --- Reparación ---------------------------------------------------------------------

  Future<void> _repairAll() async {
    final steps = _plan.where(_enabled.contains).toList();
    setState(() {
      _repairing = true;
      _log.clear();
      _final = null;
      _finalOk = null;
    });
    for (final step in steps) {
      final line = _Line(_Lvl.wait, _stepTitle(step));
      setState(() => _log.add(line));
      try {
        final text = await _exec(step, line);
        setState(() {
          line.level = _Lvl.ok;
          line.text = text;
        });
      } catch (e) {
        setState(() {
          line.level = _Lvl.bad;
          line.text = '${_stepTitle(step)}: $e';
        });
      }
    }

    var result = await _watch(const [15, 45, 90]);
    if (result.ok < result.total || result.total == 0) {
      // Último recurso: reiniciar la cámara y volver a conectar.
      final cam = _camera;
      if (cam != null && cam.brand.hasFullApi) {
        final line = _Line(_Lvl.wait, 'Reiniciando la cámara (último recurso)…');
        setState(() => _log.add(line));
        try {
          final api = DeviceApi(cam);
          try {
            await api.reboot();
          } finally {
            api.close();
          }
          await NetworkConfig.waitFor(cam, cam.host, timeout: const Duration(seconds: 120));
          await _exec(RepairStep.reconnect, line);
          setState(() {
            line.level = _Lvl.ok;
            line.text = 'Cámara reiniciada y NVR reconectado.';
          });
          result = await _watch(const [20, 60, 90]);
        } catch (_) {
          setState(() {
            line.level = _Lvl.bad;
            line.text = 'No se pudo reiniciar la cámara.';
          });
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _repairing = false;
      if (result.total == 0) {
        _finalOk = null;
        _final = 'Se aplicaron los arreglos, pero desde aquí no se puede confirmar si el NVR ya la ve. '
            'Mira el monitor en 1–2 minutos.';
      } else if (result.ok == result.total) {
        _finalOk = true;
        _final = 'Listo: el NVR está conectado a la cámara y se mantuvo así en las ${result.total} '
            'revisiones. Revisa el monitor.';
      } else if (result.ok > 0) {
        _finalOk = false;
        _final = 'El NVR se conecta pero se corta (${result.ok} de ${result.total} revisiones). Si ya se le '
            'puso una IP nueva, lo que queda es físico: revisa el cable, la fuente o el puerto PoE de esa '
            'cámara (a veces falla al prenderse la luz infrarroja de noche, porque consume más).';
      } else {
        _finalOk = false;
        _final = 'El NVR todavía no se conecta. Toca "Analizar de nuevo". Si sigue igual, borra la cámara '
            'en el NVR y vuelve a agregarla desde su búsqueda de dispositivos.';
      }
    });
    await _load(analyze: false);
  }

  /// Revisa en esos segundos si el NVR sigue conectado.
  Future<({int ok, int total})> _watch(List<int> seconds) async {
    var ok = 0;
    var total = 0;
    var elapsed = 0;
    final line = _Line(_Lvl.wait, 'Comprobando que se mantenga conectado…');
    setState(() => _log.add(line));
    final marks = <String>[];
    for (final t in seconds) {
      while (elapsed < t) {
        await Future<void>.delayed(const Duration(seconds: 1));
        elapsed++;
        if (mounted) setState(() => line.text = 'Comprobando que se mantenga conectado… ${seconds.last - elapsed} s');
      }
      final c = await _isConnected();
      if (c != null) {
        total++;
        if (c) ok++;
      }
      marks.add('$t s ${c == true ? '✓' : c == false ? '✗' : '?'}');
    }
    if (mounted) {
      setState(() {
        line.level = total == 0
            ? _Lvl.info
            : ok == total
                ? _Lvl.ok
                : _Lvl.bad;
        line.text = 'NVR conectado a la cámara: ${marks.join(' · ')}';
      });
    }
    return (ok: ok, total: total);
  }

  Future<bool?> _isConnected() async {
    final nvr = _nvr!;
    final cam = _camera;
    if (cam != null) {
      final users = await LinkDoctor.activeUsers(cam);
      if (users != null) return users.any({nvr.host, _nvrNet?.ip}.contains);
    }
    final api = NvrChannels(nvr);
    try {
      return await api.hasImage(_selected!.channel);
    } finally {
      api.close();
    }
  }

  String _stepTitle(RepairStep s) => switch (s) {
        RepairStep.newFreeIp => 'Dar a la cámara una IP nueva, libre y fija',
        RepairStep.useCameraIp => 'Poner en el NVR la IP actual de la cámara',
        RepairStep.fixCameraNetwork => 'Igualar la red de la cámara con la del NVR',
        RepairStep.fixPort => 'Corregir el puerto en el NVR',
        RepairStep.fixProtocol => 'Corregir el protocolo en el NVR',
        RepairStep.credentials => 'Poner en el NVR el usuario y contraseña de la cámara',
        RepairStep.reconnect => 'Hacer que el NVR se vuelva a conectar',
      };

  String _stepDetail(RepairStep s) {
    final cam = _camera;
    final ch = _selected;
    return switch (s) {
      RepairStep.newFreeIp =>
        'Busca una IP que nadie use (probándola varias veces), se la deja fija a la cámara con la red del NVR '
            'y se la pone al NVR. Arregla la IP repetida, que es lo que hace que aparezca y se corte.',
      RepairStep.useCameraIp => 'El NVR la busca en ${ch?.address}; la cámara está en ${cam?.host}.',
      RepairStep.fixCameraNetwork => 'Misma máscara y puerta de enlace que el NVR; la IP no cambia.',
      RepairStep.fixPort => 'El NVR usa el ${ch?.port}; la cámara usa el $_camTcpPort.',
      RepairStep.fixProtocol => 'El NVR usa "${ch?.protocol}"; para esta cámara corresponde "$_protocolFix".',
      RepairStep.credentials => 'Por si se cambió la contraseña de la cámara y el NVR quedó con la antigua.',
      RepairStep.reconnect => 'Apaga y prende ese canal en el NVR para que se conecte de cero.',
    };
  }

  Future<String> _exec(RepairStep step, _Line line) async {
    final nvr = _nvr!;
    final ch = _selected!;
    final cam = _camera;
    switch (step) {
      case RepairStep.newFreeIp:
        return _moveToFreeIp(line);
      case RepairStep.useCameraIp:
        final c = cam!;
        var fixed = false;
        final net = _camNet;
        if (net != null && net.dhcp && c.brand.hasFullApi) {
          final cfg = NetworkConfig(c);
          try {
            await cfg.read();
            await cfg.apply(NetSettings(dhcp: false, ip: c.host, mask: net.mask, gateway: net.gateway));
            fixed = true;
          } catch (_) {
          } finally {
            cfg.close();
          }
        }
        await _updateChannel(address: c.host);
        return 'El NVR ahora busca la cámara en ${c.host}${fixed ? ' (y la cámara quedó con esa IP fija)' : ''}.';
      case RepairStep.fixCameraNetwork:
        final nvrNet = _nvrNet!;
        final config = NetworkConfig(cam!);
        try {
          await config.read();
          await config.apply(NetSettings(dhcp: false, ip: cam.host, mask: nvrNet.mask, gateway: nvrNet.gateway));
        } finally {
          config.close();
        }
        return 'La cámara quedó con máscara ${nvrNet.mask} y puerta de enlace ${nvrNet.gateway}.';
      case RepairStep.fixPort:
        await _updateChannel(port: _camTcpPort);
        return 'El NVR ahora se conecta por el puerto $_camTcpPort.';
      case RepairStep.fixProtocol:
        final protocol = _protocolFix;
        await _updateChannel(protocol: protocol, port: cam!.httpPort);
        return 'El NVR ahora usa el protocolo "$protocol" (puerto ${cam.httpPort}).';
      case RepairStep.credentials:
        await _updateChannel(user: cam!.username, password: cam.password);
        return 'El NVR ahora usa el usuario "${cam.username}" con la contraseña que funciona en la app.';
      case RepairStep.reconnect:
        final channels = NvrChannels(nvr);
        try {
          await channels.reconnect(ch);
        } finally {
          channels.close();
        }
        return 'El NVR volvió a conectarse a ese canal.';
    }
  }

  Future<void> _updateChannel({String? address, int? port, String? user, String? password, String? protocol}) async {
    final api = NvrChannels(_nvr!);
    try {
      await api.update(_selected!, address: address, port: port, user: user, password: password, protocol: protocol);
    } finally {
      api.close();
    }
    if (mounted) {
      setState(() => _selected = _selected!.copyWith(address: address, port: port, protocol: protocol));
    }
  }

  /// Le da a la cámara una IP libre y fija, y se la pone al NVR y a la app.
  Future<String> _moveToFreeIp(_Line line) async {
    final cam = _camera!;
    final nvr = _nvr!;
    final ch = _selected!;
    if (!cam.brand.hasFullApi) {
      throw NetworkConfigException('Cambiar la IP desde la app solo funciona con cámaras Hikvision y Dahua.');
    }
    final ref = _nvrNet?.ip ?? nvr.host;
    final subnet = ref.substring(0, ref.lastIndexOf('.'));
    final net = store.netInfo;
    final used = <String>{
      for (final d in store.devices) d.host,
      for (final c in _channels) c.address,
      for (final f in _scanAll) f.ip,
      nvr.host,
      if (_nvrNet != null) _nvrNet!.gateway,
      if (net?.ip != null) net!.ip!,
      if (net?.gateway != null) net!.gateway!,
      '$subnet.1',
      '$subnet.254',
    };
    final ip = await LinkDoctor.findFreeIp(subnet, used, onTry: (candidate) {
      if (mounted) setState(() => line.text = 'Buscando una IP libre… probando $candidate');
    });
    if (ip == null) throw NetworkConfigException('No encontré una IP libre en la red $subnet.x.');

    final mask = _nvrNet?.mask ?? _camNet?.mask ?? '255.255.255.0';
    final gateway = _nvrNet?.gateway ?? _camNet?.gateway ?? '$subnet.1';
    if (mounted) setState(() => line.text = 'Poniéndole a la cámara la IP $ip…');
    final cfg = NetworkConfig(cam);
    try {
      await cfg.read();
      await cfg.apply(NetSettings(dhcp: false, ip: ip, mask: mask, gateway: gateway));
    } finally {
      cfg.close();
    }
    if (mounted) setState(() => line.text = 'Esperando que la cámara responda en $ip…');
    final ok = await NetworkConfig.waitFor(cam, ip, timeout: const Duration(seconds: 90));
    if (!ok) {
      throw NetworkConfigException(
          'La cámara no respondió en $ip. Búscala con "Buscar equipo perdido" en sus Herramientas.');
    }
    final moved = cam.copyWith(host: ip);
    await store.saveDevice(moved);
    _camera = moved;

    await _updateChannel(address: ip);
    final current = store.deviceById(nvr.id);
    if (current != null) {
      await store.saveDevice(current.copyWith(channelHosts: {...current.channelHosts, ch.channel: ip}));
      _nvr = store.deviceById(nvr.id);
    }
    return 'La cámara ahora tiene la IP fija $ip (nadie más la usa) y el NVR la busca ahí.';
  }

  // --- Interfaz -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_nvr == null) {
      body = const _Center(
        text: 'No hay un NVR Hikvision o Dahua en esta red. Esta herramienta arregla cámaras que el NVR no '
            'encuentra o que se le cortan.',
      );
    } else if (_loading && _channels.isEmpty) {
      body = const _Center(text: 'Leyendo las cámaras del NVR…', loading: true);
    } else if (_error != null && _channels.isEmpty) {
      body = _Center(text: _error!, action: FilledButton(onPressed: _load, child: const Text('Reintentar')));
    } else {
      body = ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
        children: [
          ..._selectors(),
          const SizedBox(height: 16),
          if (_selected != null) _analysisCard(),
          if (_analyzed && _selected != null) ...[
            const SizedBox(height: 14),
            _planCard(),
          ],
          if (_log.isNotEmpty) ...[
            const SizedBox(height: 14),
            _logCard(),
          ],
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Reparar cámara en el NVR')),
      body: body,
    );
  }

  List<Widget> _selectors() {
    final busy = _repairing || _analyzing;
    return [
      if (_nvrs.length > 1) ...[
        DropdownButtonFormField<String>(
          key: ValueKey('nvr-${_nvr?.id}'),
          initialValue: _nvr!.id,
          decoration: fieldDecoration('NVR'),
          items: [for (final n in _nvrs) DropdownMenuItem(value: n.id, child: Text(n.name))],
          onChanged: busy
              ? null
              : (id) {
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
        key: ValueKey('canal-${_nvr?.id}-${_selected?.channel}-${_selected?.address}'),
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
        onChanged: busy
            ? null
            : (v) async {
                setState(() {
                  _selected = _channels.firstWhere((c) => c.channel == v);
                  _camera = widget.camera ?? _pickCamera(_selected);
                  _log.clear();
                });
                await _readNetworks();
                await _analyze();
              },
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String?>(
        key: ValueKey('camara-${_selected?.channel}-${_camera?.id}-${_camera?.host}'),
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
        onChanged: busy
            ? null
            : (id) async {
                setState(() {
                  _camera = id == null ? null : _cameras.firstWhere((d) => d.id == id);
                  _log.clear();
                });
                await _readNetworks();
                await _analyze();
              },
      ),
      const SizedBox(height: 14),
      const Text('¿Qué pasa en el monitor del NVR?', style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
      const SizedBox(height: 6),
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: false, label: Text('No se ve')),
          ButtonSegment(value: true, label: Text('Se ve y se corta')),
        ],
        selected: {_drops},
        showSelectedIcon: false,
        onSelectionChanged: busy
            ? null
            : (v) => setState(() {
                  _drops = v.first;
                  _enabled
                    ..clear()
                    ..addAll(_plan);
                }),
      ),
    ];
  }

  String _conflictText(StabilityResult? p) {
    if (_scanMacs.length > 1) return 'responden ${_scanMacs.length} aparatos distintos en esa IP';
    if (p != null && p.mixedAnswers) return 'contestan aparatos distintos en esa IP';
    if (_otherMacAtIp) return 'en esa IP contesta un aparato que no es la cámara';
    return 'a veces contesta y a veces no';
  }

  Widget _analysisCard() {
    final ch = _selected!;
    final cam = _camera;
    final p = _probe;
    final issue = _issue!;
    final camNet = _camNet;
    final nvrNet = _nvrNet;
    final connected = _nvrConnected;
    final checking = _scanConflict == null && p == null;

    final rows = <(_Lvl, String, String)>[
      (
        _Lvl.info,
        'El NVR la busca en',
        '${ch.address}${ch.port != null ? ':${ch.port}' : ''}${ch.protocol != null ? ' · ${ch.protocol}' : ''}',
      ),
      (
        cam == null ? _Lvl.warn : (issue == NvrLinkIssue.ipChanged ? _Lvl.bad : _Lvl.ok),
        'La cámara en la app',
        cam == null
            ? 'Elige arriba cuál es'
            : '${cam.host}${camNet != null ? ' · ${camNet.dhcp ? 'IP automática (puede cambiar)' : 'IP fija'}' : ''}'
                '${issue == NvrLinkIssue.ipChanged ? ' · ¡distinta a la del NVR!' : ''}',
      ),
      (
        connected == null ? _Lvl.info : (connected ? _Lvl.ok : _Lvl.bad),
        '¿El NVR está conectado ahora?',
        connected == null
            ? (_analyzing && _activeUsers == null ? 'Revisando…' : 'No se puede saber desde esta cámara')
            : connected
                ? 'Sí (la cámara lo tiene conectado)'
                : 'No: la cámara no tiene al NVR conectado (${_activeUsers!.length} conexiones abiertas)',
      ),
      (
        p == null ? _Lvl.wait : (p.failures == 0 ? _Lvl.ok : (p.loss >= 0.15 ? _Lvl.bad : _Lvl.warn)),
        'Estabilidad en ${ch.address}',
        p == null
            ? 'Probando… $_probeDone de 16'
            : '${p.attempts - p.failures} de ${p.attempts} respuestas'
                '${p.medianMs != null ? ' · ${p.medianMs} ms' : ''}${p.failures > 0 ? ' · se corta' : ''}',
      ),
      (
        checking ? _Lvl.wait : (_conflictSuspected ? _Lvl.bad : _Lvl.ok),
        '¿Otro aparato usa esa IP?',
        checking
            ? 'Revisando…'
            : _conflictSuspected
                ? 'Probablemente sí: ${_conflictText(p)}. Por eso el NVR la ve unos segundos y la pierde.'
                : 'No se ve nadie más con esa IP',
      ),
      (
        camNet == null || nvrNet == null
            ? _Lvl.info
            : (issue == NvrLinkIssue.otherSubnet || issue == NvrLinkIssue.badGateway ? _Lvl.bad : _Lvl.ok),
        'Red de la cámara y del NVR',
        camNet == null || nvrNet == null
            ? 'No se pudo leer'
            : 'Cámara ${camNet.mask} · ${camNet.gateway.isEmpty ? 'sin enlace' : camNet.gateway} | '
                'NVR ${nvrNet.mask} · ${nvrNet.gateway}',
      ),
      (
        issue == NvrLinkIssue.wrongPort || _protocolFix != null ? _Lvl.bad : _Lvl.ok,
        'Puerto y protocolo',
        issue == NvrLinkIssue.wrongPort
            ? 'El NVR usa el ${ch.port}; la cámara, el $_camTcpPort'
            : _protocolFix != null
                ? 'El NVR usa "${ch.protocol}"; para esta cámara va "$_protocolFix"'
                : 'Correctos',
      ),
    ];

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Análisis a fondo', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                ),
                TextButton.icon(
                  onPressed: _analyzing || _repairing ? null : _analyze,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Analizar de nuevo'),
                ),
              ],
            ),
            for (final r in rows) _row(r.$1, r.$2, r.$3),
          ],
        ),
      ),
    );
  }

  Widget _planCard() {
    final plan = _plan;
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 14, 8, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text('Qué va a hacer la reparación', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            ),
            for (final s in plan)
              CheckboxListTile(
                dense: true,
                value: _enabled.contains(s),
                onChanged: _repairing
                    ? null
                    : (v) => setState(() => v == true ? _enabled.add(s) : _enabled.remove(s)),
                title: Text(_stepTitle(s), style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(_stepDetail(s), style: const TextStyle(color: AppColors.textMuted, height: 1.3)),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 2, 16, 10),
              child: Text(
                'Después comprueba durante 90 segundos que el NVR siga conectado. Si se corta, reinicia la '
                'cámara y vuelve a comprobar.',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12.5, height: 1.35),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: FilledButton.icon(
                onPressed: _repairing || _analyzing ? null : _repairAll,
                icon: _repairing
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.build),
                label: Text(_repairing ? 'Reparando…' : 'Reparar todo'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _logCard() {
    final color = _finalOk == true
        ? AppColors.live
        : _finalOk == false
            ? AppColors.connecting
            : AppColors.textMuted;
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Reparación', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            for (final l in _log) _row(l.level, null, l.text),
            if (_final != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(_final!, style: const TextStyle(height: 1.4)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(_Lvl level, String? label, String text) {
    final (IconData icon, Color color) = switch (level) {
      _Lvl.wait => (Icons.more_horiz, AppColors.textMuted),
      _Lvl.ok => (Icons.check_circle, AppColors.live),
      _Lvl.warn => (Icons.warning_amber_rounded, AppColors.connecting),
      _Lvl.bad => (Icons.cancel, AppColors.offline),
      _Lvl.info => (Icons.info_outline, AppColors.textMuted),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: level == _Lvl.wait
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (label != null)
                  Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                Text(
                  text,
                  style: TextStyle(
                    color: label != null ? AppColors.textMuted : AppColors.text,
                    fontSize: 12.5,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
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
