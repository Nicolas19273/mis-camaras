import 'package:flutter/material.dart';

import '../models/device.dart';
import '../recording/recording.dart';
import '../recording/recording_api.dart';
import '../recording/recording_monitor.dart';
import '../services/app_store.dart';
import '../services/device_api.dart';
import '../services/device_clock.dart';
import '../services/network_config.dart';
import '../services/nvr_channels.dart';
import '../theme.dart';
import '../widgets/brand_badge.dart';
import 'nvr_repair_screen.dart';
import 'recording_screen.dart';

enum _Level { running, ok, warn, bad, info }

class _Item {
  _Item(this.label);

  final String label;
  _Level level = _Level.running;
  String text = 'Revisando…';
  String? fixLabel;
  Future<void> Function()? fix;

  void put(_Level l, String t, {String? fixLabel, Future<void> Function()? fix}) {
    level = l;
    text = t;
    this.fixLabel = fixLabel;
    this.fix = fix;
  }
}

class _DeviceCheck {
  _DeviceCheck(this.device);

  final Device device;
  final conn = _Item('Conexión');
  final auth = _Item('Usuario y contraseña');
  final time = _Item('Hora');
  final rec = _Item('Grabación');
  final disk = _Item('Disco');
  final nvrCams = _Item('Cámaras del NVR');

  bool get supportsRecording => RecordingApi.supports(device);

  List<_Item> get items => [
        conn,
        auth,
        if (DeviceClock.supports(device)) time,
        if (supportsRecording) rec,
        if (supportsRecording) disk,
        if (NvrChannels.supports(device)) nvrCams,
      ];
}

/// Chequeo general: revisa de un toque todos los equipos de la red actual
/// (conexión, contraseña, hora, grabación y disco) y ofrece arreglar lo que
/// se pueda desde aquí, como la hora mal puesta.
class HealthScreen extends StatefulWidget {
  const HealthScreen({super.key, required this.store});

  final AppStore store;

  @override
  State<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends State<HealthScreen> {
  List<_DeviceCheck> _checks = [];
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final devices = widget.store.activeDevices;
    setState(() {
      _running = true;
      _checks = [for (final d in devices) _DeviceCheck(d)];
    });
    // De a dos equipos a la vez, para no saturar la red.
    final queue = [..._checks];
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        await _check(queue.removeAt(0));
      }
    }

    await Future.wait([worker(), worker()]);
    if (mounted) setState(() => _running = false);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _check(_DeviceCheck c) async {
    final d = c.device;
    void skipRest(String why) {
      for (final i in c.items) {
        if (i.level == _Level.running) i.put(_Level.info, why);
      }
      _refresh();
    }

    // 1. ¿Responde?
    final reachable = await NetworkConfig.hostResponds(d.host, [d.httpPort, d.rtspPort]);
    if (!reachable) {
      c.conn.put(_Level.bad, 'No responde en ${d.host}. Revisa que esté encendido y conectado.');
      skipRest('Sin revisar (no responde)');
      return;
    }
    c.conn.put(_Level.ok, 'Responde en ${d.host}');
    _refresh();

    // 2. Usuario y contraseña.
    final api = DeviceApi(d);
    try {
      final info = await api.info();
      c.auth.put(_Level.ok, info.model != null ? 'Correctos · ${info.model}' : 'Correctos');
    } on DeviceApiException catch (e) {
      final wrong = e.message.contains('contraseña');
      c.auth.put(wrong ? _Level.bad : _Level.warn, e.message);
      if (wrong) {
        skipRest('Sin revisar (falta la contraseña correcta)');
        return;
      }
    } catch (_) {
      c.auth.put(_Level.warn, 'No se pudo comprobar');
    } finally {
      api.close();
    }
    _refresh();

    // 3. Hora.
    if (DeviceClock.supports(d)) await _checkTime(c);

    // 4 y 5. Grabación y disco.
    if (c.supportsRecording) await _checkRecording(c);

    // 6. En NVR: ¿cada cámara responde en la IP que tiene guardada el NVR?
    if (NvrChannels.supports(d)) await _checkNvrCameras(c);
  }

  Future<void> _checkNvrCameras(_DeviceCheck c) async {
    final d = c.device;
    final api = NvrChannels(d);
    try {
      final list = await api.list();
      final missing = <NvrChannel>[];
      await Future.wait(list.map((ch) async {
        final ok = await NetworkConfig.hostResponds(ch.address, [if (ch.port != null) ch.port!, 80, 554],
            timeout: const Duration(milliseconds: 1200));
        if (!ok) missing.add(ch);
      }));
      missing.sort((a, b) => a.channel.compareTo(b.channel));
      String name(NvrChannel ch) {
        final t = d.channelNames[ch.channel]?.trim() ?? '';
        return '${t.isEmpty ? 'Cámara ${ch.channel}' : t} (${ch.address})';
      }

      if (list.isEmpty) {
        c.nvrCams.put(_Level.info, 'El NVR no informó sus cámaras');
      } else if (missing.isEmpty) {
        c.nvrCams.put(
          _Level.ok,
          'Las ${list.length} cámaras responden en su IP. Si el monitor muestra "Falló búsqueda de host", '
          'usa Reparar desde esa cámara.',
        );
      } else {
        c.nvrCams.put(
          _Level.bad,
          'El NVR no las encuentra (probablemente cambiaron de IP): ${missing.map(name).join(', ')}',
          fixLabel: 'Reparar',
          fix: () async {
            await Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => NvrRepairScreen(store: widget.store, nvr: d, channel: missing.first.channel),
            ));
          },
        );
      }
    } on NvrChannelException catch (e) {
      c.nvrCams.put(_Level.warn, e.message);
    } catch (_) {
      c.nvrCams.put(_Level.info, 'No se pudo revisar');
    } finally {
      api.close();
    }
    _refresh();
  }

  Future<void> _checkTime(_DeviceCheck c) async {
    final clock = DeviceClock(c.device);
    try {
      final t = await clock.read();
      if (t == null) {
        c.time.put(_Level.info, 'No se pudo leer');
      } else {
        final diff = t.difference(DateTime.now());
        final minutes = diff.inMinutes.abs();
        if (diff.inSeconds.abs() < 120) {
          c.time.put(_Level.ok, 'Correcta');
        } else {
          final amount = minutes >= 60 * 24
              ? '${minutes ~/ (60 * 24)} días'
              : minutes >= 60
                  ? '${minutes ~/ 60} h ${minutes % 60} min'
                  : '$minutes min';
          c.time.put(
            _Level.warn,
            '${diff.isNegative ? 'Atrasada' : 'Adelantada'} $amount. Las grabaciones quedan con la hora '
            'equivocada.',
            fixLabel: 'Poner la hora del teléfono',
            fix: () => _fixTime(c),
          );
        }
      }
    } on ClockException catch (e) {
      c.time.put(_Level.warn, e.message);
    } catch (_) {
      c.time.put(_Level.info, 'No se pudo leer');
    } finally {
      clock.close();
    }
    _refresh();
  }

  Future<void> _fixTime(_DeviceCheck c) async {
    c.time.put(_Level.running, 'Poniendo la hora…');
    _refresh();
    final clock = DeviceClock(c.device);
    try {
      await clock.setToPhone();
    } on ClockException catch (e) {
      c.time.put(_Level.bad, e.message);
      _refresh();
      return;
    } catch (_) {
      c.time.put(_Level.bad, 'No se pudo cambiar la hora');
      _refresh();
      return;
    } finally {
      clock.close();
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    await _checkTime(c);
  }

  Future<void> _checkRecording(_DeviceCheck c) async {
    final d = c.device;
    final api = RecordingApi.forDevice(d)!;
    try {
      final r = await api.report(window: const Duration(hours: 4));
      final monitor = RecordingMonitor.instance..update(d, r);
      final states = [for (var ch = 1; ch <= d.channels; ch++) monitor.stateOf(d, ch)];
      final recording = states.where((s) => s == RecState.recording || s == RecState.armed).length;
      final problems = states.where((s) => s == RecState.problem).length;
      final off = states.where((s) => s == RecState.off).length;
      void open() => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => RecordingScreen(store: widget.store, device: d)),
          );
      Future<void> openFix() async => open();
      if (problems > 0) {
        c.rec.put(
          _Level.bad,
          d.isRecorder ? '$problems de ${d.channels} cámaras no están grabando' : 'No está grabando',
          fixLabel: 'Revisar grabación',
          fix: openFix,
        );
      } else if (off == states.length) {
        c.rec.put(_Level.warn, 'Grabación apagada', fixLabel: 'Activar grabación', fix: openFix);
      } else {
        c.rec.put(
          _Level.ok,
          d.isRecorder ? 'Grabando $recording de ${d.channels} cámaras' : 'Grabando',
        );
      }

      final disks = r.disks;
      if (disks == null) {
        c.disk.put(_Level.info, 'No se pudo leer');
      } else if (disks.isEmpty) {
        c.disk.put(_Level.bad, d.isRecorder ? 'No tiene disco duro' : 'No tiene tarjeta SD',
            fixLabel: 'Ver', fix: openFix);
      } else if (!disks.any((x) => x.ok)) {
        c.disk.put(_Level.bad, disks.map((x) => '${x.name}: ${x.statusLabel}').join(' · '),
            fixLabel: 'Ver', fix: openFix);
      } else {
        final total = disks.fold<double>(0, (s, x) => s + x.capacityMB);
        c.disk.put(_Level.ok, total > 0 ? '${_size(total)} · funcionando' : 'Funcionando');
      }
    } on RecordingException catch (e) {
      c.rec.put(_Level.warn, e.message);
      c.disk.put(_Level.info, 'Sin revisar');
    } catch (_) {
      c.rec.put(_Level.info, 'No se pudo revisar');
      c.disk.put(_Level.info, 'No se pudo revisar');
    } finally {
      api.close();
    }
    _refresh();
  }

  static String _size(double mb) {
    if (mb >= 1024 * 1024) return '${(mb / (1024 * 1024)).toStringAsFixed(1)} TB';
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(0)} GB';
    return '${mb.toStringAsFixed(0)} MB';
  }

  Future<void> _fixAllTimes() async {
    for (final c in _checks) {
      if (c.time.level == _Level.warn && c.time.fix != null) await _fixTime(c);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = [for (final c in _checks) ...c.items];
    final bad = items.where((i) => i.level == _Level.bad).length;
    final warn = items.where((i) => i.level == _Level.warn).length;
    final clocks = _checks.where((c) => c.time.level == _Level.warn && c.time.fix != null).length;
    final standby = widget.store.standbyDevices.length;

    final Color color;
    final IconData icon;
    final String title;
    if (_checks.isEmpty) {
      color = AppColors.textMuted;
      icon = Icons.info_outline;
      title = 'No hay equipos en esta red';
    } else if (_running) {
      color = AppColors.textMuted;
      icon = Icons.hourglass_top;
      title = 'Revisando ${_checks.length} ${_checks.length == 1 ? 'equipo' : 'equipos'}…';
    } else if (bad + warn == 0) {
      color = AppColors.live;
      icon = Icons.verified_outlined;
      title = 'Todo bien';
    } else {
      color = bad > 0 ? AppColors.offline : AppColors.connecting;
      icon = Icons.report_outlined;
      final n = bad + warn;
      title = n == 1 ? '1 cosa para revisar' : '$n cosas para revisar';
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chequeo general'),
        actions: [
          IconButton(
            tooltip: 'Revisar de nuevo',
            icon: const Icon(Icons.refresh),
            onPressed: _running ? null : _run,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
        children: [
          Material(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Icon(icon, color: color, size: 34),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 4),
                        Text(
                          [
                            'Conexión, contraseña, hora, grabación y disco de cada equipo de esta red.',
                            if (standby > 0) '$standby en espera (otras redes) no se revisan.',
                          ].join(' '),
                          style: const TextStyle(color: AppColors.textMuted, height: 1.35),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_running) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
          if (!_running && clocks > 1) ...[
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _fixAllTimes,
              icon: const Icon(Icons.schedule),
              label: Text('Poner la hora correcta en los $clocks equipos'),
            ),
          ],
          const SizedBox(height: 8),
          for (final c in _checks) _deviceCard(c),
        ],
      ),
    );
  }

  Widget _deviceCard(_DeviceCheck c) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  BrandBadge(brand: c.device.brand, size: 28),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(c.device.name,
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (final i in c.items) _row(i),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(_Item i) {
    final (IconData icon, Color color) = switch (i.level) {
      _Level.running => (Icons.more_horiz, AppColors.textMuted),
      _Level.ok => (Icons.check_circle, AppColors.live),
      _Level.warn => (Icons.warning_amber_rounded, AppColors.connecting),
      _Level.bad => (Icons.cancel, AppColors.offline),
      _Level.info => (Icons.remove_circle_outline, AppColors.textMuted),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: i.level == _Level.running
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(i.label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                Text(i.text, style: const TextStyle(color: AppColors.textMuted, fontSize: 12.5, height: 1.3)),
                if (i.fix != null && i.level != _Level.running)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                      onPressed: () => i.fix!(),
                      child: Text(i.fixLabel ?? 'Arreglar'),
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
