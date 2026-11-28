import 'package:flutter/material.dart';

import '../theme.dart';

/// Una página del mosaico: qué cámaras muestra y de qué sección es.
class GridPage {
  const GridPage(this.indices, {this.section});

  /// Posiciones (en la lista de cámaras) que van en esta página.
  final List<int> indices;

  /// Sección (por ejemplo la marca) cuando se ven separadas; null si no.
  final Object? section;
}

/// Reparte las cámaras en páginas de [perPage]. Si [sectionOf] no es null,
/// una sección nueva empieza siempre en una página nueva.
List<GridPage> buildGridPages(int count, int perPage, {Object? Function(int index)? sectionOf}) {
  final pages = <GridPage>[];
  var current = <int>[];
  Object? section;
  for (var i = 0; i < count; i++) {
    final s = sectionOf?.call(i);
    final newSection = sectionOf != null && current.isNotEmpty && s != section;
    if (current.length == perPage || newSection) {
      pages.add(GridPage(current, section: section));
      current = <int>[];
    }
    if (current.isEmpty) section = s;
    current.add(i);
  }
  if (current.isNotEmpty) pages.add(GridPage(current, section: section));
  return pages;
}

/// Mosaico como el de un NVR: "4" muestra exactamente 4 cámaras (2×2),
/// "9" muestra 3×3, "16" muestra 4×4 y "1" una sola. Si hay más cámaras
/// que cuadros, se desliza de lado para pasar de página. Los cuadros que
/// sobran en la última página quedan oscuros, como en el monitor del NVR.
class PagedCameraGrid extends StatefulWidget {
  const PagedCameraGrid({
    super.key,
    required this.count,
    required this.columns,
    required this.tileBuilder,
    this.sectionOf,
    this.sectionHeader,
  });

  /// Cuántas cámaras hay.
  final int count;

  /// 1, 2, 3 o 4 (cuadros de 1, 4, 9 o 16).
  final int columns;

  final Widget Function(BuildContext context, int index) tileBuilder;

  /// Sección de cada cámara (para verlas separadas por marca).
  final Object? Function(int index)? sectionOf;
  final Widget Function(Object section, int countInSection)? sectionHeader;

  @override
  State<PagedCameraGrid> createState() => _PagedCameraGridState();
}

class _PagedCameraGridState extends State<PagedCameraGrid> {
  final _controller = PageController();
  int _page = 0;

  int get _perPage => widget.columns * widget.columns;

  List<GridPage> get _pages => buildGridPages(widget.count, _perPage, sectionOf: widget.sectionOf);

  @override
  void didUpdateWidget(PagedCameraGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.columns == widget.columns && oldWidget.count == widget.count) return;
    // Al cambiar de vista, se queda en la página que tiene la misma primera cámara.
    final oldPages = buildGridPages(oldWidget.count, oldWidget.columns * oldWidget.columns,
        sectionOf: oldWidget.sectionOf);
    final first = _page < oldPages.length && oldPages[_page].indices.isNotEmpty ? oldPages[_page].indices.first : 0;
    final pages = _pages;
    var target = 0;
    for (var p = 0; p < pages.length; p++) {
      if (pages[p].indices.contains(first)) target = p;
    }
    if (target != _page) {
      _page = target;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_controller.hasClients) _controller.jumpToPage(target);
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _go(int page) {
    _controller.animateToPage(page, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final pages = _pages;
    if (_page >= pages.length && pages.isNotEmpty) _page = pages.length - 1;
    return PageView.builder(
      controller: _controller,
      itemCount: pages.length,
      onPageChanged: (p) => setState(() => _page = p),
      itemBuilder: (context, p) => _buildPage(context, pages, p),
    );
  }

  Widget _buildPage(BuildContext context, List<GridPage> pages, int p) {
    final page = pages[p];
    final cols = widget.columns;
    final section = page.section;
    final header = widget.sectionHeader;
    final inSection = section == null
        ? 0
        : List.generate(widget.count, (i) => i).where((i) => widget.sectionOf?.call(i) == section).length;

    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (section != null && header != null) header(section, inSection),
          for (var r = 0; r < cols; r++)
            Padding(
              padding: EdgeInsets.only(bottom: r == cols - 1 ? 0 : 2),
              child: Row(
                children: [
                  for (var c = 0; c < cols; c++)
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(right: c == cols - 1 ? 0 : 2),
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: () {
                            final slot = r * cols + c;
                            if (slot >= page.indices.length) return const ColoredBox(color: Color(0xFF0B0C0F));
                            return widget.tileBuilder(context, page.indices[slot]);
                          }(),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          if (pages.length > 1) _indicator(pages.length, p),
        ],
      ),
    );
  }

  Widget _indicator(int total, int current) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Página anterior',
            onPressed: current > 0 ? () => _go(current - 1) : null,
            icon: const Icon(Icons.chevron_left),
          ),
          for (var i = 0; i < total; i++)
            GestureDetector(
              onTap: () => _go(i),
              child: Container(
                width: i == current ? 18 : 7,
                height: 7,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: i == current ? accent : AppColors.border,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          const SizedBox(width: 8),
          Text('${current + 1} de $total', style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Página siguiente',
            onPressed: current < total - 1 ? () => _go(current + 1) : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}
