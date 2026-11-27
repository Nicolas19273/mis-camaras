import 'package:flutter/material.dart';

import '../brands/brand_adapter.dart';
import '../brands/brands.dart';
import '../models/device.dart';
import '../onvif/onvif_client.dart';
import '../services/app_store.dart';
import '../theme.dart';
import '../widgets/live_video.dart';
import 'device_tools_screen.dart';

/// Formulario para agregar o editar un equipo.
class DeviceFormScreen extends StatefulWidget {
  const DeviceFormScreen({super.key, required this.store, this.device, this.template});

  final AppStore store;

  /// null = equipo nuevo.
  final Device? device;

  /// Datos para rellenar un equipo nuevo (por ejemplo, encontrado en la red).
  final Device? template;

  @override
  State<DeviceFormScreen> createState() => _DeviceFormScreenState();
}

class _DeviceFormScreenState extends State<DeviceFormScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _rtspPort;
  late final TextEditingController _httpPort;
  late final TextEditingController _user;
  late final TextEditingController _pass;
  late final TextEditingController _channels;
  late final TextEditingController _rtspMain;
  late final TextEditingController _rtspSub;
  late Brand _brand;
  bool _hidePass = true;
  bool _saving = false;
  bool _detecting = false;
  bool _showAdvanced = false;

  bool get _isEdit => widget.device != null;

  @override
  void initState() {
    super.initState();
    final d = widget.device ?? widget.template;
    _brand = d?.brand ?? Brand.hikvision;
    _name = TextEditingController(text: d?.name ?? '');
    _host = TextEditingController(text: d?.host ?? '');
    _rtspPort = TextEditingController(text: '${d?.rtspPort ?? 554}');
    _httpPort = TextEditingController(text: '${d?.httpPort ?? 80}');
    _user = TextEditingController(text: d?.username ?? 'admin');
    _pass = TextEditingController(text: d?.password ?? '');
    _channels = TextEditingController(text: '${d?.channels ?? 1}');
    _rtspMain = TextEditingController(text: d?.rtspMain ?? '');
    _rtspSub = TextEditingController(text: d?.rtspSub ?? '');
    _showAdvanced = (d?.rtspMain ?? '').isNotEmpty;
  }

  @override
  void dispose() {
    for (final c in [_name, _host, _rtspPort, _httpPort, _user, _pass, _channels, _rtspMain, _rtspSub]) {
      c.dispose();
    }
    super.dispose();
  }

  Device _buildDevice() {
    // Se conserva lo que no está en el formulario (nombres de cámaras,
    // ocultas, MAC, "no es PTZ"), para no perderlo al editar.
    final base = widget.device ?? widget.template;
    String? path(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    return Device(
      id: widget.device?.id ?? AppStore.newId(),
      name: _name.text.trim(),
      brand: _brand,
      host: _host.text.trim(),
      rtspPort: int.tryParse(_rtspPort.text.trim()) ?? 554,
      httpPort: int.tryParse(_httpPort.text.trim()) ?? 80,
      username: _user.text.trim(),
      password: _pass.text,
      channels: int.tryParse(_channels.text.trim()) ?? 1,
      mac: base?.mac,
      channelNames: base?.channelNames ?? const {},
      hiddenChannels: base?.hiddenChannels ?? const {},
      noPtzChannels: base?.noPtzChannels ?? const {},
      rtspMain: path(_rtspMain),
      rtspSub: path(_rtspSub),
    );
  }

  /// Le pregunta a la cámara por ONVIF cuáles son sus rutas de video.
  Future<void> _detectOnvif() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_host.text.trim().isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Primero escribe la IP del equipo.')));
      return;
    }
    setState(() => _detecting = true);
    final client = OnvifClient(_buildDevice());
    try {
      final streams = await client.detectStreams();
      if (!mounted) return;
      setState(() {
        _rtspMain.text = streams.main;
        _rtspSub.text = streams.sub;
        _rtspPort.text = '${streams.port}';
        _showAdvanced = true;
      });
      messenger.showSnackBar(const SnackBar(content: Text('Listo: la cámara informó sus rutas de video.')));
    } catch (e) {
      final text = e is OnvifException
          ? e.message
          : 'No respondió por ONVIF. Revisa la IP, el puerto HTTP y que ONVIF esté activado en la cámara.';
      messenger.showSnackBar(SnackBar(content: Text(text)));
    } finally {
      client.close();
      if (mounted) setState(() => _detecting = false);
    }
  }

  // --- Validaciones -------------------------------------------------------

  String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Obligatorio' : null;

  String? _validateHost(String? v) {
    final t = v?.trim() ?? '';
    if (t.isEmpty) return 'Obligatorio';
    if (t.contains('://') || t.contains('/') || t.contains(' ')) {
      return 'Solo la IP o dominio, ej: 192.168.1.64';
    }
    return null;
  }

  String? _validatePort(String? v) {
    final n = int.tryParse(v?.trim() ?? '');
    return (n == null || n < 1 || n > 65535) ? 'Puerto inválido' : null;
  }

  String? _validateChannels(String? v) {
    final n = int.tryParse(v?.trim() ?? '');
    return (n == null || n < 1 || n > 64) ? 'Entre 1 y 64' : null;
  }

  // --- Acciones -----------------------------------------------------------

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    await widget.store.saveDevice(_buildDevice());
    if (mounted) Navigator.of(context).pop();
  }

  /// Abre las herramientas del equipo (IP, cámaras, rescate, reinicio).
  Future<void> _openTools() async {
    final device = widget.device;
    if (device == null) return;
    final newHost = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => DeviceToolsScreen(store: widget.store, device: device)),
    );
    if (newHost != null && mounted) setState(() => _host.text = newHost);
  }

  Future<void> _test() async {
    if (!_form.currentState!.validate()) return;
    final device = _buildDevice();
    final url = adapterFor(device.brand).rtspUrl(device, 1, StreamQuality.sub);

    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Probando canal 1',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: LiveVideo(url: url, compact: false),
                ),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cerrar'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Interfaz -----------------------------------------------------------

  /// Rutas de video propias (para cámaras que no usan la ruta típica de su marca).
  Widget _advancedSection() {
    final open = _showAdvanced || _brand == Brand.onvif;
    final detectButton = OutlinedButton.icon(
      onPressed: _detecting ? null : _detectOnvif,
      icon: _detecting
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.travel_explore),
      label: Text(_detecting ? 'Preguntando a la cámara…' : 'Detectar video con ONVIF'),
      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_brand.hasFullApi) ...[detectButton, const SizedBox(height: 4)],
        if (_brand != Brand.onvif)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _showAdvanced = !_showAdvanced),
              icon: Icon(open ? Icons.expand_less : Icons.expand_more),
              label: const Text('Rutas de video (avanzado)'),
            ),
          ),
        if (open) ...[
          const SizedBox(height: 8),
          TextFormField(
            controller: _rtspMain,
            decoration: fieldDecoration(
              'Ruta principal',
              hint: _brand == Brand.onvif ? '/stream1' : adapterFor(_brand).rtspPath(1, StreamQuality.main),
              helper: 'Vacía = la típica de la marca. Solo para cámaras de 1 canal.',
            ),
            autocorrect: false,
            keyboardType: TextInputType.url,
            validator: (v) => _brand == Brand.onvif && (v == null || v.trim().isEmpty)
                ? 'Toca "Detectar video con ONVIF" o escribe la ruta'
                : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _rtspSub,
            decoration: fieldDecoration(
              'Ruta secundaria (liviana)',
              hint: _brand == Brand.onvif ? '/stream2' : adapterFor(_brand).rtspPath(1, StreamQuality.sub),
              helper: 'Para la cuadrícula. Vacía = usa la principal.',
            ),
            autocorrect: false,
            keyboardType: TextInputType.url,
          ),
          if (_brand.hasFullApi) ...[const SizedBox(height: 12), detectButton],
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 14);

    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Editar equipo' : 'Nuevo equipo')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('Marca', style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final b in Brand.values)
                  ChoiceChip(
                    label: Text(b.label),
                    selected: _brand == b,
                    showCheckmark: false,
                    onSelected: (_) => setState(() {
                      _brand = b;
                      if (b == Brand.onvif) _showAdvanced = true;
                    }),
                  ),
              ],
            ),
            if (!_brand.hasFullApi) ...[
              const SizedBox(height: 8),
              Text(
                _brand == Brand.onvif
                    ? 'Funciona con casi cualquier cámara compatible con ONVIF. '
                        'Toca "Detectar con ONVIF" para que la app encuentre el video.'
                    : 'Video y PTZ por ONVIF. Cambiar la IP y leer nombres de cámaras '
                        'por ahora solo está para Hikvision y Dahua.',
                style: const TextStyle(color: AppColors.textMuted, fontSize: 12.5, height: 1.35),
              ),
            ],
            gap,
            TextFormField(
              controller: _name,
              decoration: fieldDecoration('Nombre', hint: 'Ej: Patio, Casa, Bodega'),
              textCapitalization: TextCapitalization.sentences,
              validator: _required,
            ),
            gap,
            TextFormField(
              controller: _host,
              decoration: fieldDecoration('IP o dominio', hint: '192.168.1.64'),
              keyboardType: TextInputType.url,
              autocorrect: false,
              validator: _validateHost,
            ),
            gap,
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _rtspPort,
                    decoration: fieldDecoration('Puerto RTSP'),
                    keyboardType: TextInputType.number,
                    validator: _validatePort,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _httpPort,
                    decoration: fieldDecoration('Puerto HTTP'),
                    keyboardType: TextInputType.number,
                    validator: _validatePort,
                  ),
                ),
              ],
            ),
            gap,
            TextFormField(
              controller: _user,
              decoration: fieldDecoration('Usuario'),
              autocorrect: false,
              validator: _required,
            ),
            gap,
            TextFormField(
              controller: _pass,
              obscureText: _hidePass,
              autocorrect: false,
              enableSuggestions: false,
              decoration: fieldDecoration(
                'Contraseña',
                suffix: IconButton(
                  icon: Icon(_hidePass ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _hidePass = !_hidePass),
                ),
              ),
            ),
            gap,
            TextFormField(
              controller: _channels,
              decoration: fieldDecoration(
                'Canales',
                helper: 'Cámara sola = 1. NVR/DVR = cantidad de cámaras conectadas.',
              ),
              keyboardType: TextInputType.number,
              validator: _validateChannels,
            ),
            const SizedBox(height: 8),
            _advancedSection(),
            const SizedBox(height: 20),
            _UrlPreview(
              listenable: Listenable.merge([_host, _rtspPort, _user, _pass, _rtspMain, _channels]),
              urlBuilder: () => adapterFor(_brand)
                  .rtspUrl(_buildDevice(), 1, StreamQuality.main, hidePassword: true),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _saving ? null : _test,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Probar'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.check),
                    label: const Text('Guardar'),
                  ),
                ),
              ],
            ),
            if (_isEdit) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _saving ? null : _openTools,
                icon: const Icon(Icons.build_outlined),
                label: const Text('Herramientas del equipo'),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Muestra la dirección RTSP que usará la app (con la contraseña oculta).
/// Sirve para revisar que todo esté bien o para probarla en VLC.
class _UrlPreview extends StatelessWidget {
  const _UrlPreview({required this.listenable, required this.urlBuilder});

  final Listenable listenable;
  final String Function() urlBuilder;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Dirección de video (canal 1)',
            style: TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 6),
          ListenableBuilder(
            listenable: listenable,
            builder: (context, child) => SelectableText(
              urlBuilder(),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
