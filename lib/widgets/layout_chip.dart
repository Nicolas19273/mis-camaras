import 'package:flutter/material.dart';

import '../theme.dart';

/// Botón con el dibujo de la cuadrícula (1, 4, 9 o 16).
class LayoutChip extends StatelessWidget {
  const LayoutChip({
    super.key,
    required this.columns,
    required this.selected,
    required this.onTap,
    this.dark = false,
  });

  final int columns;
  final bool selected;
  final VoidCallback onTap;

  /// Versión para usar sobre video (fondo semitransparente).
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final fg = selected ? accent : (dark ? Colors.white70 : AppColors.textMuted);
    final bg = selected
        ? accent.withValues(alpha: 0.16)
        : (dark ? Colors.black45 : AppColors.surface);

    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GridGlyph(columns: columns, color: fg),
                const SizedBox(width: 6),
                Text(
                  '${columns * columns}',
                  style: TextStyle(
                    color: fg,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Pequeño dibujo de una cuadrícula de n × n.
class GridGlyph extends StatelessWidget {
  const GridGlyph({super.key, required this.columns, required this.color});

  final int columns;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 16,
      height: 12,
      child: Column(
        children: [
          for (var r = 0; r < columns; r++)
            Expanded(
              child: Row(
                children: [
                  for (var c = 0; c < columns; c++)
                    Expanded(
                      child: Container(
                        margin: const EdgeInsets.all(0.7),
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(0.8),
                        ),
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
