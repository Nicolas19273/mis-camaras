import 'package:flutter/material.dart';

import '../models/device.dart';
import '../recording/recording.dart';
import '../recording/recording_api.dart';
import '../recording/recording_monitor.dart';
import '../services/app_store.dart';
import '../theme.dart';
import '../widgets/rec_badge.dart';

/// Grabación de un equipo: dónde guarda (disco o tarjeta SD), cómo graba
/// y si de verdad está grabando (busca el último video guardado).
class RecordingScreen extends StatefulWidget {
  const RecordingScreen({super.key, required this.store, required this.device});

  final AppStore store;
  final Device device;

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends State<RecordingScreen> {
  RecordingReport? _report;
  String? _error;
  bool _loading = true;
  String? _busy;
  RecordMode _choice = RecordMode.continuous;
  bool _choiceTouched = false;
  bool _keep = true;

  RecordingMonitor get _monitor => RecordingMonitor.instance;

  /// Estado que se muestra (el mismo que el "● REC" de las cámaras).
  RecState _state(int channel) => _monitor.stateOf(_device, channel);

  Device get _device => widget.store.deviceById(widget.device.id) ?? widget.device;
  bool get _supported => RecordingApi.supports(_device);

  @override
  void initState() {
    super.initState();
    // Por defecto activado; si ya se configuró antes, se respeta lo elegido.
    _keep = _monitor.keeps(widget.device) || !_monitor.configured(widget.device);
    _load();
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _load({bool quiet = false}) async {
    if (!_supported) {
      setState(() => _loading = false);
      return;
    }
    if (!quiet) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final api = RecordingApi.forDevice(_device)!;
    try {
      final r = await api.report();
      _monitor.update(_device, r);
      if (!mounted) return;
      setState(() {
        _report = r;
        _error = null;
        if (!_choiceTouched) {
          final modes = r.modes.values.toSet();
          if (modes.length == 1 && modes.first != RecordMode.custom) _choice = modes.first;
        }
      });
    } on RecordingException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'No responde. Revisa que esté encendido y en tu WiFi.');
    } finally {
      api.close();
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _apply(List<int> channels, RecordMode mode) async {
    setState(() => _busy = 'Guardando en el equipo…');
    final api = RecordingApi.forDevice(_device)!;
    try {
      final res = await api.apply(channels, mode);
      if (res.ok.isNotEmpty) _monitor.markApplied(_device, res.ok, mode, keep: _keep);
      if (res.ok.isNotEmpty && mode != RecordMode.off) {
        if (mounted) setState(() => _busy = 'Comprobando que empiece a grabar…');
        await Future<void>.delayed(const Duration(seconds: 10));
      }
      await _load(quiet: true);
      if (!mounted) return;
      await _showResult(res, mode, channels.length);
    } on RecordingException catch (e) {
      if (mounted) _snack(e.message);
    } catch (_) {
      if (mounted) _snack('No se pudo guardar. Revisa que el equipo esté encendido y en tu WiFi.');
    } finally {
      api.close();
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _showResult(ApplyResult res, RecordMode mode, int total) async {
    final d = _device;
    final lines = <String>[
      if (res.ok.isNotEmpty)
        mode == RecordMode.off
            ? 'Grabación apagada en ${_count(res.ok.length)}.'
            : '${mode.label}: listo en ${_count(res.ok.length)}.',
      for (final e in res.failed.entries) '${d.channelLabel(e.key)}: ${e.value}.',
      ...res.warnings,
    ];
    final r = _report;
    if (r != null && mode != RecordMode.off && res.ok.isNotEmpty) {
      final now = r.deviceNow;
      final fresh = res.ok.where((c) {
        final t = r.lastEnd[c];
        return t != null && now.difference(t).inMinutes < 15;
      }).length;
      lines.add(fresh == res.ok.length
          ? 'Comprobado: ya hay video nuevo guardado.'
          : 'Queda grabando. El video nuevo puede tardar en aparecer en la búsqueda '
              '(en Dahua hasta 1 hora), pero mientras tanto verás el ● REC.');
      if (_keep) {
        lines.add('Mantener siempre así: si el equipo cambia o apaga la grabación, '
            'la app la vuelve a activar cuando esté abierta.');
      }
    }
    if (r != null && r.storageOk == false && mode != RecordMode.off) {
      lines.add('Ojo: el equipo no tiene un disco o tarjeta SD funcionando, así que no podrá guardar video.');
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(res.failed.isEmpty ? 'Listo' : 'Se aplicó en parte'),
        content: Text(lines.join('\n\n'), style: const TextStyle(height: 1.4)),
        actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Entendido'))],
      ),
    );
  }

  String _count(int n) => _device.isRecorder ? (n == 1 ? '1 cámara' : '$n cámaras') : 'la cámara';

  Future<void> _format(StorageDisk disk) async {
    var understood = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text('Formatear ${disk.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Un disco o tarjeta nuevos necesitan formatearse una vez para poder grabar. '
                'Se borra todo lo que tengan.',
                style: TextStyle(height: 1.4),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: understood,
                onChanged: (v) => setLocal(() => understood = v ?? false),
                title: const Text('Entiendo que se borra todo'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancelar')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: understood ? () => Navigator.of(ctx).pop(true) : null,
              child: const Text('Formatear'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = 'Formateando…');
    final api = RecordingApi.forDevice(_device)!;
    try {
      await api.format(disk);
      // Espera a que termine (máximo 10 minutos).
      final end = DateTime.now().add(const Duration(minutes: 10));
      await Future<void>.delayed(const Duration(seconds: 3));
      while (DateTime.now().isBefore(end)) {
        final p = await api.formatProgress(disk);
        if (p == null) break;
        if (mounted) setState(() => _busy = 'Formateando… $p%');
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      await Future<void>.delayed(const Duration(seconds: 5));
      await _load(quiet: true);
      if (mounted) {
        _snack(_report?.storageOk == true
            ? 'Listo: ${disk.name} ya está lista para grabar.'
            : 'Formateo enviado. Si sigue sin funcionar, reinicia el equipo.');
      }
    } on RecordingException catch (e) {
      if (mounted) _snack(e.message);
    } catch (_) {
      if (mounted) _snack('No se pudo formatear.');
    } finally {
      api.close();
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _pickForChannel(int channel) async {
    final r = _report;
    final current = r?.modes[channel];
    final mode = await showModalBottomSheet<RecordMode>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                _device.channelLabel(channel),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            for (final m in _options)
              ListTile(
                leading: Icon(m.icon, color: current == m.mode ? Theme.of(ctx).colorScheme.primary : null),
                title: Text(m.title),
                subtitle: Text(m.subtitle, style: const TextStyle(color: AppColors.textMuted)),
                trailing: current == m.mode ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(ctx).pop(m.mode),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (mode != null && mounted) await _apply([channel], mode);
  }

  // --- Interfaz -----------------------------------------------------------------------

  static const _options = [
    (
      mode: RecordMode.continuous,
      icon: Icons.fiber_manual_record,
      title: 'Siempre (24/7)',
      subtitle: 'Graba todo el día, todos los días. Lo más seguro. Recomendado.',
    ),
    (
      mode: RecordMode.motion,
      icon: Icons.directions_run,
      title: 'Con movimiento',
      subtitle: 'Graba solo cuando algo se mueve. Ahorra disco.',
    ),
    (
      mode: RecordMode.off,
      icon: Icons.stop_circle_outlined,
      title: 'No grabar',
      subtitle: 'Apaga la grabación.',
    ),
  ];

  String _ago(DateTime t) {
    final m = DateTime.now().difference(t).inMinutes;
    if (m < 1) return 'recién';
    if (m < 60) return 'hace $m min';
    final h = m ~/ 60;
    return h < 24 ? 'hace $h h' : 'hace ${h ~/ 24} días';
  }

  String _when(DateTime? t, DateTime now) {
    if (t == null) return 'sin video en las últimas 24 horas';
    final diff = now.difference(t);
    if (diff.inMinutes < 2) return 'ahora mismo';
    if (diff.inMinutes < 60) return 'hace ${diff.inMinutes} min';
    String hm(DateTime x) => '${x.hour.toString().padLeft(2, '0')}:${x.minute.toString().padLeft(2, '0')}';
    final today = DateTime(now.year, now.month, now.day);
    if (!t.isBefore(today)) return 'hoy a las ${hm(t)}';
    if (!t.isBefore(today.subtract(const Duration(days: 1)))) return 'ayer a las ${hm(t)}';
    return '${t.day}/${t.month} a las ${hm(t)}';
  }

  @override
  Widget build(BuildContext context) {
    final r = _report;
    Widget body;
    if (!_supported) {
      body = const _Message(
        icon: Icons.info_outline,
        text: 'Configurar la grabación desde la app por ahora funciona con Hikvision y Dahua. '
            'En esta marca hazlo desde la página web del equipo.',
      );
    } else if (r == null && _loading) {
      body = const _Message(icon: null, text: 'Revisando discos y grabaciones…');
    } else if (r == null) {
      body = _Message(
        icon: Icons.wifi_off,
        text: _error ?? 'No se pudo revisar.',
        action: FilledButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('Reintentar')),
      );
    } else {
      body = RefreshIndicator(
        onRefresh: () => _load(quiet: true),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
          children: [
            _summary(r),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Text(_error!, style: const TextStyle(color: AppColors.connecting, fontSize: 12.5)),
              ),
            const SectionLabel('Dónde se guarda'),
            ..._storage(r),
            const SectionLabel('Cómo grabar'),
            for (final o in _options) _option(o.mode, o.icon, o.title, o.subtitle),
            const SizedBox(height: 4),
            FilledButton.icon(
              onPressed: _busy != null ? null : () => _apply(List.generate(_device.channels, (i) => i + 1), _choice),
              icon: const Icon(Icons.check),
              label: Text(_device.isRecorder ? 'Aplicar a las ${_device.channels} cámaras' : 'Aplicar'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              value: _keep,
              onChanged: (v) {
                setState(() => _keep = v);
                if (!v) {
                  _monitor.setKeep(_device, false, const {});
                } else if (_monitor.inGrace(_device) || r.modes.isNotEmpty) {
                  _monitor.setKeep(_device, true, r.modes);
                }
              },
              title: const Text('Mantener siempre así'),
              subtitle: const Text(
                'Si el equipo cambia o apaga la grabación, la app la vuelve a activar.',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12.5),
              ),
            ),
            if (_device.isRecorder) ...[
              const SectionLabel('Cada cámara'),
              for (var ch = 1; ch <= _device.channels; ch++) _channelRow(r, ch),
            ],
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 16, 8, 0),
              child: Text(
                'Cuando el disco se llena, el equipo borra lo más antiguo y sigue grabando '
                '(viene así de fábrica). El "● REC" sobre cada cámara se actualiza cada 5 minutos.',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12, height: 1.4),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Grabación'),
        actions: [
          if (_supported)
            IconButton(
              tooltip: 'Volver a revisar',
              icon: const Icon(Icons.refresh),
              onPressed: _loading || _busy != null ? null : _load,
            ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(child: body),
          if (_loading && r != null) const Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator()),
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

  /// Tarjeta grande de arriba: ¿está grabando?
  Widget _summary(RecordingReport r) {
    final d = _device;
    final channels = List.generate(d.channels, (i) => i + 1);
    final states = {for (final c in channels) c: _state(c)};
    final recording = states.values.where((s) => s == RecState.recording).length;
    final armed = states.values.where((s) => s == RecState.armed).length;
    final off = states.values.where((s) => s == RecState.off).length;

    RecState main;
    String title;
    String detail;
    if (r.disks != null && r.disks!.isEmpty) {
      main = RecState.problem;
      title = 'No tiene dónde grabar';
      detail = d.isRecorder
          ? 'No se encontró un disco duro instalado en el grabador.'
          : 'Inserta una tarjeta microSD en la cámara (o usa un grabador).';
    } else if (r.storageOk == false) {
      main = RecState.problem;
      title = 'El disco no está listo';
      detail = (r.disks ?? const <StorageDisk>[]).any((x) => x.needsFormat)
          ? 'Hay que formatearlo una vez para que pueda grabar (abajo).'
          : 'El disco o la tarjeta tiene un problema. Revisa que esté bien puesto o cámbialo.';
    } else if (off == channels.length) {
      main = RecState.off;
      title = 'Grabación apagada';
      detail = 'Elige abajo cómo quieres que grabe y toca "Aplicar".';
    } else if (recording == channels.length) {
      main = RecState.recording;
      title = 'Grabando';
      final last = r.lastEnd[1];
      detail = d.isRecorder
          ? 'Las ${channels.length} cámaras están guardando video.'
          : last == null
              ? 'La cámara está grabando.'
              : 'Último video guardado: ${_when(last, r.deviceNow)}.';
    } else if (recording > 0) {
      main = RecState.recording;
      title = 'Grabando $recording de ${channels.length}';
      detail = 'Revisa abajo las cámaras que no están grabando.';
    } else if (armed > 0) {
      main = RecState.armed;
      title = 'Lista para grabar';
      detail = 'Graba cuando detecta movimiento o según su horario.';
    } else {
      main = RecState.problem;
      title = 'No está grabando';
      detail = 'Debería grabar, pero no hay video reciente. Prueba "Siempre (24/7)" y "Aplicar", '
          'o reinicia el equipo.';
    }
    final style = recStateStyle(main);
    final extra = <String>[
      if (_monitor.lastCheck(d) != null) 'Revisado ${_ago(_monitor.lastCheck(d)!)}.',
      if (_monitor.enforcedAt(d) != null &&
          DateTime.now().difference(_monitor.enforcedAt(d)!) < const Duration(days: 1))
        'El equipo había cambiado la grabación y la app la volvió a activar ${_ago(_monitor.enforcedAt(d)!)}.',
      if (_monitor.gaveUp(d))
        'El equipo vuelve a cambiar la grabación solo. Revisa en su página web si hay otro programa '
            'o usuario que la modifique.',
    ];
    if (extra.isNotEmpty) detail = '$detail\n\n${extra.join('\n')}';
    return Material(
      color: style.color.withValues(alpha: main == RecState.recording ? 0.14 : 0.10),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Icon(style.icon, color: style.color, size: 34),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(detail, style: const TextStyle(color: AppColors.textMuted, height: 1.35)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _storage(RecordingReport r) {
    final disks = r.disks;
    if (disks == null) {
      return [
        _card(
          child: const ListTile(
            leading: Icon(Icons.help_outline),
            title: Text('No se pudo leer el disco ahora'),
            subtitle: Text(
              'Se vuelve a revisar solo. Si hay video reciente, el disco está funcionando.',
              style: TextStyle(color: AppColors.textMuted),
            ),
          ),
        ),
      ];
    }
    if (disks.isEmpty) {
      return [
        _card(
          child: ListTile(
            leading: const Icon(Icons.sd_card_alert_outlined, color: AppColors.connecting),
            title: Text(_device.isRecorder ? 'Sin disco duro' : 'Sin tarjeta SD'),
            subtitle: const Text(
              'Instala uno para poder grabar. Después vuelve aquí y toca actualizar.',
              style: TextStyle(color: AppColors.textMuted),
            ),
          ),
        ),
      ];
    }
    return [
      for (final disk in disks)
        _card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _device.isRecorder ? Icons.storage : Icons.sd_card_outlined,
                      color: disk.ok ? AppColors.live : AppColors.connecting,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(disk.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    Text(
                      disk.statusLabel,
                      style: TextStyle(
                        color: disk.ok ? AppColors.live : AppColors.connecting,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                if (disk.capacityMB > 0) ...[
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: disk.usedFraction,
                      minHeight: 6,
                      backgroundColor: AppColors.surfaceHigh,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${_size(disk.freeMB)} libres de ${_size(disk.capacityMB)}',
                    style: const TextStyle(color: AppColors.textMuted, fontSize: 12.5),
                  ),
                ],
                if (disk.needsFormat || (disk.status == 'error' && !_device.isRecorder)) ...[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _busy != null ? null : () => _format(disk),
                    icon: const Icon(Icons.cleaning_services_outlined),
                    label: const Text('Formatear para poder grabar'),
                  ),
                ],
              ],
            ),
          ),
        ),
    ];
  }

  static String _size(double mb) {
    if (mb >= 1024 * 1024) return '${(mb / (1024 * 1024)).toStringAsFixed(1)} TB';
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(mb >= 100 * 1024 ? 0 : 1)} GB';
    return '${mb.toStringAsFixed(0)} MB';
  }

  Widget _option(RecordMode mode, IconData icon, String title, String subtitle) {
    final selected = _choice == mode;
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? accent.withValues(alpha: 0.12) : AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: selected ? accent : Colors.transparent, width: 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          contentPadding: const EdgeInsets.fromLTRB(14, 4, 10, 4),
          leading: Icon(icon, color: mode == RecordMode.continuous ? AppColors.danger : (selected ? accent : null)),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(subtitle, style: const TextStyle(color: AppColors.textMuted, height: 1.3)),
          trailing: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: selected ? accent : AppColors.textMuted),
          onTap: () => setState(() {
            _choice = mode;
            _choiceTouched = true;
          }),
        ),
      ),
    );
  }

  Widget _channelRow(RecordingReport r, int ch) {
    final state = _state(ch);
    final style = recStateStyle(state);
    final mode = r.modes[ch];
    final parts = [
      mode?.label ?? 'Sin datos',
      if (mode != null && mode != RecordMode.off && r.lastEnd.containsKey(ch))
        'último video: ${_when(r.lastEnd[ch], r.deviceNow)}',
    ];
    return _card(
      child: ListTile(
        leading: Icon(style.icon, color: style.color),
        title: Text(_device.channelLabel(ch), maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${style.text} · ${parts.join(' · ')}',
          style: const TextStyle(color: AppColors.textMuted, fontSize: 12.5),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: _busy != null ? null : () => _pickForChannel(ch),
      ),
    );
  }

  Widget _card({required Widget child}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: child,
        ),
      );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});

  final IconData? icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon == null) const CircularProgressIndicator() else Icon(icon, size: 40, color: AppColors.textMuted),
            const SizedBox(height: 16),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textMuted, height: 1.4)),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
