import 'package:flutter_test/flutter_test.dart';
import 'package:mis_camaras/widgets/paged_grid.dart';

/// Pruebas del mosaico por páginas (como en el NVR).
void main() {
  test('Vista 4 con 8 cámaras: 2 páginas de 4', () {
    final pages = buildGridPages(8, 4);
    expect(pages.length, 2);
    expect(pages[0].indices, [0, 1, 2, 3]);
    expect(pages[1].indices, [4, 5, 6, 7]);
  });

  test('Vista 16 con 8 cámaras: una página (los otros 8 cuadros quedan vacíos)', () {
    final pages = buildGridPages(8, 16);
    expect(pages.length, 1);
    expect(pages.single.indices.length, 8);
  });

  test('Vista 1: una cámara por página', () {
    expect(buildGridPages(3, 1).map((p) => p.indices), [
      [0],
      [1],
      [2],
    ]);
  });

  test('Separadas por marca: cada marca empieza en su página', () {
    final brands = ['H', 'H', 'D', 'D', 'D', 'D', 'D', 'D'];
    final pages = buildGridPages(8, 4, sectionOf: (i) => brands[i]);
    expect(pages.map((p) => p.section), ['H', 'D', 'D']);
    expect(pages.map((p) => p.indices.length), [2, 4, 2]);
  });

  test('Sin cámaras no hay páginas', () {
    expect(buildGridPages(0, 4), isEmpty);
  });
}
