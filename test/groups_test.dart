import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mis_camaras/models/camera_group.dart';
import 'package:mis_camaras/models/device.dart';

/// Pruebas de los grupos de cámaras. Se ejecutan con: flutter test
void main() {
  const nvr = Device(id: '100', name: 'NVR Casa', brand: Brand.dahua, host: '192.168.1.108', channels: 4);
  const cam = Device(id: '200', name: 'Portón', brand: Brand.hikvision, host: '192.168.1.64');

  test('Junta cámaras de distintos equipos en el orden del grupo', () {
    final g = CameraGroup(
      id: 'g1',
      name: 'Patio',
      members: [CameraGroup.keyOf('200', 1), CameraGroup.keyOf('100', 3), CameraGroup.keyOf('100', 1)],
    );
    final list = g.resolve(const [nvr, cam]);
    expect(list.map((c) => '${c.device.id}:${c.channel}'), ['200:1', '100:3', '100:1']);
    expect(g.contains(const CameraRef(nvr, 3)), isTrue);
    expect(g.contains(const CameraRef(nvr, 2)), isFalse);
  });

  test('Ignora cámaras que ya no existen y repetidas', () {
    final g = CameraGroup(id: 'g', name: 'X', members: [
      CameraGroup.keyOf('100', 9), // el NVR solo tiene 4 canales
      CameraGroup.keyOf('999', 1), // equipo eliminado
      CameraGroup.keyOf('200', 1),
      CameraGroup.keyOf('200', 1),
      'basura',
    ]);
    expect(g.resolve(const [nvr, cam]).length, 1);
  });

  test('Al eliminar un equipo salen sus cámaras', () {
    final g = CameraGroup(id: 'g', name: 'X', members: [
      CameraGroup.keyOf('100', 1),
      CameraGroup.keyOf('200', 1),
      CameraGroup.keyOf('1000', 1), // otro equipo cuyo id empieza igual
    ]);
    expect(g.withoutDevice('100').members, [CameraGroup.keyOf('200', 1), CameraGroup.keyOf('1000', 1)]);
  });

  test('Guardar y leer un grupo', () {
    final g = CameraGroup(id: 'g9', name: 'Local', colorIndex: 3, members: [CameraGroup.keyOf('100', 2)]);
    final back = CameraGroup.fromJson(jsonDecode(jsonEncode(g.toJson())) as Map<String, dynamic>);
    expect(back.id, 'g9');
    expect(back.name, 'Local');
    expect(back.colorIndex, 3);
    expect(back.members, ['100#2']);
    expect(CameraGroup.fromJson({'id': 'z', 'name': '  '}).name, 'Grupo');
  });
}
