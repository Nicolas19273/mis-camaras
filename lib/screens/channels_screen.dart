import 'package:flutter/material.dart';

import '../models/device.dart';
import '../services/app_store.dart';
import '../services/device_api.dart';
import '../theme.dart';

/// Nombre, visibilidad y PTZ de cada cámara de un equipo.
class ChannelsScreen extends StatefulWidget {
  const ChannelsScreen({super.key, required this.store, required this.device});

  final AppStore store;
  final Device device;

  @override
  State<ChannelsScreen> createState() => _ChannelsScreenState();
}

class _ChannelsScreenState extends State<ChannelsScreen> {
  late final Map<int, TextEditingController> _names;
  late Set<int> _hidden;
  late Set<int> _noPtz;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    final d = widget.device;
    _names = {
      for (var ch = 1; ch <= d.channels; ch++)
        ch: TextEditingController(text: d.channelNames[ch] ?? ''),
    };
    _hidden = {...d.hiddenChannels};
    _noPtz = {...d.noPtzChannels};
  }

  @override
  void dispose() {
    for (final c in _names.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _import() async {
    setState(() => _importing = true);
    final api = DeviceApi(widget.device);
    try {
      final names = await api.channelNames();
      if (!mounted) return;
      var count = 0;
      names.forEach((ch, name) {
        final c = _names[ch];
        if (c != null) {
          c.text = name;
          count++;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(count == 0
            ? 'El equipo no tiene nombres propios guardados.'
            : 'Se trajeron $count nombres. Toca "Guardar" para conservarlos.'),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is DeviceApiException ? e.message : 'No se pudo leer el equipo.')),
      );
    } finally {
      api.close();
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _save() async {
    final names = <int, String>{
      for (final e in _names.entries)
        if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim(),
    };
    final current = widget.store.deviceById(widget.device.id) ?? widget.device;
    await widget.store.saveDevice(current.copyWith(
      channelNames: names,
      hiddenChannels: _hidden,
      noPtzChannels: _noPtz,
    ));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.device;
    return Scaffold(
      appBar: AppBar(
        title: Text(d.isRecorder ? 'Cámaras del grabador' : 'Cámara'),
        actions: [
          TextButton(onPressed: _save, child: const Text('Guardar')),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
        children: [
          OutlinedButton.icon(
            onPressed: _importing ? null : _import,
            icon: _importing
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.download_outlined),
            label: const Text('Traer nombres del equipo'),
          ),
          const SizedBox(height: 12),
          for (var ch = 1; ch <= d.channels; ch++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Material(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
                  child: Column(
                    children: [
                      TextField(
                        controller: _names[ch],
                        textCapitalization: TextCapitalization.sentences,
                        decoration: fieldDecoration(
                          d.isRecorder ? 'Canal $ch' : 'Nombre',
                          hint: d.isRecorder ? '${d.name} · Cám $ch' : d.name,
                        ),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('Mostrar en el mosaico'),
                        value: !_hidden.contains(ch),
                        onChanged: (v) => setState(() => v ? _hidden.remove(ch) : _hidden.add(ch)),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('Joystick si es PTZ'),
                        subtitle: const Text('Apágalo si es una cámara fija',
                            style: TextStyle(color: AppColors.textMuted)),
                        value: !_noPtz.contains(ch),
                        onChanged: (v) => setState(() => v ? _noPtz.remove(ch) : _noPtz.add(ch)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
