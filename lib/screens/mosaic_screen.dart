import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../brands/brand_adapter.dart';
import '../models/device.dart';
import '../services/app_store.dart';
import '../widgets/camera_tile.dart';
import '../widgets/layout_chip.dart';
import '../widgets/live_clock.dart';
import 'camera_view_screen.dart';

/// Mosaico a pantalla completa y en horizontal, como el monitor de un NVR.
/// Desliza para cambiar de página si hay más cámaras que cuadros.
class MosaicScreen extends StatefulWidget {
  const MosaicScreen({super.key, required this.store, required this.cameras});

  final AppStore store;
  final List<CameraRef> cameras;

  @override
  State<MosaicScreen> createState() => _MosaicScreenState();
}

class _MosaicScreenState extends State<MosaicScreen> {
  final _pages = PageController();
  late int _columns = widget.store.gridColumns;
  int _pageIndex = 0;
  bool _videoActive = true;

  int get _perPage => _columns * _columns;
  int get _pageCount => math.max(1, (widget.cameras.length / _perPage).ceil());

  @override
  void initState() {
    super.initState();
    _enterFullscreen();
  }

  void _enterFullscreen() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    _pages.dispose();
    SystemChrome.setPreferredOrientations(const []);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _setColumns(int columns) {
    setState(() {
      _columns = columns;
      _pageIndex = 0;
    });
    if (_pages.hasClients) _pages.jumpToPage(0);
    widget.store.setGridColumns(columns);
  }

  void _cycleColumns() => _setColumns(_columns % 4 + 1);

  Future<void> _openCamera(int index) async {
    setState(() => _videoActive = false);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CameraViewScreen(
          cameras: widget.cameras,
          initialIndex: index,
          restoreSystemUi: false,
          store: widget.store,
        ),
      ),
    );
    if (!mounted) return;
    _enterFullscreen();
    setState(() => _videoActive = true);
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final quality = (_columns == 1 || store.gridHd) ? StreamQuality.main : StreamQuality.sub;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pages,
            itemCount: _pageCount,
            onPageChanged: (i) => setState(() => _pageIndex = i),
            itemBuilder: (context, page) => _buildPage(page, quality),
          ),
          // Controles discretos abajo, para no tapar los nombres de arriba.
          Positioned(
            left: 12,
            right: 12,
            bottom: 10,
            child: Row(
              children: [
                _RoundButton(
                  icon: Icons.fullscreen_exit,
                  tooltip: 'Salir',
                  onTap: () => Navigator.of(context).pop(),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const LiveClock(),
                      if (_pageCount > 1) ...[
                        const SizedBox(width: 12),
                        Text(
                          '${_pageIndex + 1} / $_pageCount',
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                ),
                const Spacer(),
                LayoutChip(
                  columns: _columns,
                  selected: false,
                  dark: true,
                  onTap: _cycleColumns,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPage(int page, StreamQuality quality) {
    final start = page * _perPage;
    return Column(
      children: [
        for (var r = 0; r < _columns; r++)
          Expanded(
            child: Row(
              children: [
                for (var c = 0; c < _columns; c++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(1),
                      child: _buildCell(start + r * _columns + c, quality),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildCell(int index, StreamQuality quality) {
    if (index >= widget.cameras.length) {
      return const ColoredBox(color: Color(0xFF0B0C0F));
    }
    final camera = widget.cameras[index];
    return CameraTile(
      key: ValueKey('mosaico-${camera.device.id}-${camera.channel}-$_columns'),
      camera: camera,
      active: _videoActive,
      showLabel: widget.store.showLabels,
      quality: quality,
      onTap: () => _openCamera(index),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.onTap, this.tooltip});

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black45,
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: tooltip,
        icon: Icon(icon, color: Colors.white),
        onPressed: onTap,
      ),
    );
  }
}
