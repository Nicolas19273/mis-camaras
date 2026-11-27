import 'package:flutter/material.dart';

import '../models/camera_group.dart';
import '../models/device.dart';
import '../services/app_store.dart';
import '../theme.dart';
import '../widgets/brand_badge.dart';

/// Crear o editar un grupo: nombre, color y qué cámaras lo forman.
/// Se marcan varias cámaras a la vez, o todas las de un grabador de un toque.
class GroupEditorScreen extends StatefulWidget {
  const GroupEditorScreen({
    super.key,
    required this.store,
    this.group,
    this.preselected = const [],
  });

  final AppStore store;

  /// null = grupo nuevo.
  final CameraGroup? group;

  /// Cámaras que ya vienen marcadas (por ejemplo, desde En vivo).
  final List<CameraRef> preselected;

  @override
  State<GroupEditorScreen> createState() => _GroupEditorScreenState();
}

class _GroupEditorScreenState extends State<GroupEditorScreen> {
  late final TextEditingController _name;
  final _search = TextEditingController();
  late int _color;
  late final Set<String> _selected;
  String _query = '';
  bool _saving = false;

  bool get _isEdit => widget.group != null;

  static String _key(CameraRef c) => CameraGroup.keyOfCamera(c);

  @override
  void initState() {
    super.initState();
    final g = widget.group;
    _name = TextEditingController(text: g?.name ?? '');
    _color = g?.colorIndex ?? widget.store.groups.length % accentOptions.length;
    _selected = {
      ...?g?.members,
      for (final c in widget.preselected) _key(c),
    };
  }

  @override
  void dispose() {
    _name.dispose();
    _search.dispose();
    super.dispose();
  }

  bool _matches(CameraRef c) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return c.label.toLowerCase().contains(q) ||
        c.device.name.toLowerCase().contains(q) ||
        c.device.host.contains(q);
  }

  void _toggle(CameraRef c, bool on) => setState(() => on ? _selected.add(_key(c)) : _selected.remove(_key(c)));

  void _setMany(Iterable<CameraRef> cameras, bool on) => setState(() {
        for (final c in cameras) {
          on ? _selected.add(_key(c)) : _selected.remove(_key(c));
        }
      });

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ponle un nombre al grupo, por ejemplo "Patio".')),
      );
      return;
    }
    setState(() => _saving = true);
    // Se mantiene el orden que ya tenía el grupo; las nuevas van al final,
    // en el mismo orden que la lista de Equipos.
    final existing = widget.store.allCameras.map(_key).toList();
    final original = widget.group?.members ?? const <String>[];
    final members = [
      for (final k in original)
        if (_selected.contains(k) && existing.contains(k)) k,
      for (final k in existing)
        if (_selected.contains(k) && !original.contains(k)) k,
    ];
    final group = (widget.group ?? CameraGroup(id: AppStore.newId(), name: name))
        .copyWith(name: name, colorIndex: _color, members: members);
    await widget.store.saveGroup(group);
    if (mounted) Navigator.of(context).pop(group);
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final all = store.allCameras;
    final visible = all.where(_matches).toList();
    final selectedCount = all.where((c) => _selected.contains(_key(c))).length;
    final allVisibleSelected = visible.isNotEmpty && visible.every((c) => _selected.contains(_key(c)));

    final blocks = <Widget>[];
    for (final d in store.devices) {
      final cameras = visible.where((c) => c.device.id == d.id).toList();
      if (cameras.isNotEmpty) blocks.add(_deviceBlock(d, cameras));
    }

    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Editar grupo' : 'Nuevo grupo')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          TextField(
            controller: _name,
            autofocus: !_isEdit && widget.preselected.isEmpty,
            textCapitalization: TextCapitalization.sentences,
            decoration: fieldDecoration('Nombre del grupo', hint: 'Ej: Patio, Local, Entradas'),
          ),
          const SizedBox(height: 16),
          const Text('Color', style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              for (var i = 0; i < accentOptions.length; i++)
                _ColorDot(
                  color: accentOptions[i],
                  selected: i == _color,
                  onTap: () => setState(() => _color = i),
                ),
            ],
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Cámaras · $selectedCount ${selectedCount == 1 ? 'elegida' : 'elegidas'}',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
              if (visible.isNotEmpty)
                TextButton(
                  onPressed: () => _setMany(visible, !allVisibleSelected),
                  child: Text(allVisibleSelected ? 'Quitar todas' : 'Marcar todas'),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (all.length > 8) ...[
            TextField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v.trim()),
              decoration: fieldDecoration('Buscar cámara o equipo', suffix: const Icon(Icons.search)),
            ),
            const SizedBox(height: 12),
          ],
          if (all.isEmpty)
            const _Hint('Todavía no hay cámaras. Agrega un equipo primero en la pestaña Equipos.')
          else if (blocks.isEmpty)
            const _Hint('Ninguna cámara coincide con la búsqueda.')
          else
            ...blocks,
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.check),
            label: Text(_isEdit ? 'Guardar cambios' : 'Crear grupo · $selectedCount'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          ),
        ),
      ),
    );
  }

  /// Un equipo con sus cámaras. En grabadores, la casilla de arriba marca todas.
  Widget _deviceBlock(Device d, List<CameraRef> cameras) {
    final chosen = cameras.where((c) => _selected.contains(_key(c))).length;
    const muted = TextStyle(color: AppColors.textMuted, fontSize: 12.5);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: !d.isRecorder
            ? CheckboxListTile(
                value: chosen > 0,
                onChanged: (v) => _toggle(cameras.first, v ?? false),
                secondary: BrandBadge(brand: d.brand, size: 34),
                title: Text(cameras.first.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('${d.brand.shortLabel} · ${d.host}', style: muted),
              )
            : Column(
                children: [
                  CheckboxListTile(
                    tristate: true,
                    value: chosen == 0 ? false : (chosen == cameras.length ? true : null),
                    onChanged: (_) => _setMany(cameras, chosen != cameras.length),
                    secondary: BrandBadge(brand: d.brand, size: 34),
                    title: Text(d.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text('Grabador · $chosen de ${cameras.length}', style: muted),
                  ),
                  const Divider(height: 1),
                  for (final c in cameras)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.only(left: 28, right: 16),
                      value: _selected.contains(_key(c)),
                      onChanged: (v) => _toggle(c, v ?? false),
                      title: Text(
                        (d.channelNames[c.channel]?.trim().isNotEmpty ?? false)
                            ? d.channelNames[c.channel]!.trim()
                            : 'Cámara ${c.channel}',
                        style: const TextStyle(fontSize: 14.5),
                      ),
                      subtitle: d.hiddenChannels.contains(c.channel)
                          ? const Text('Oculta en En vivo', style: muted)
                          : null,
                    ),
                ],
              ),
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color, required this.selected, required this.onTap});

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: selected ? Colors.white : Colors.transparent, width: 2.5),
        ),
        child: selected ? const Icon(Icons.check, size: 18, color: Colors.black87) : null,
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppColors.textMuted, height: 1.4),
      ),
    );
  }
}
