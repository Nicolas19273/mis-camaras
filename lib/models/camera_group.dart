import 'device.dart';

/// Un grupo de cámaras armado por la persona (ej. "Patio", "Local", "Casa").
/// Puede juntar cámaras de distintos equipos y de distintas marcas.
class CameraGroup {
  const CameraGroup({
    required this.id,
    required this.name,
    this.colorIndex = 0,
    this.members = const [],
  });

  final String id;
  final String name;

  /// Color del grupo (posición en la lista de colores de la app).
  final int colorIndex;

  /// Cámaras del grupo, en orden. Cada una es "idDelEquipo#canal".
  final List<String> members;

  static String keyOf(String deviceId, int channel) => '$deviceId#$channel';
  static String keyOfCamera(CameraRef camera) => keyOf(camera.device.id, camera.channel);

  bool contains(CameraRef camera) => members.contains(keyOfCamera(camera));

  CameraGroup copyWith({String? name, int? colorIndex, List<String>? members}) => CameraGroup(
        id: id,
        name: name ?? this.name,
        colorIndex: colorIndex ?? this.colorIndex,
        members: members ?? this.members,
      );

  /// Saca las cámaras de un equipo (cuando se elimina el equipo).
  CameraGroup withoutDevice(String deviceId) =>
      copyWith(members: members.where((m) => !m.startsWith('$deviceId#')).toList());

  /// Las cámaras del grupo que todavía existen, en el orden del grupo.
  List<CameraRef> resolve(List<Device> devices) {
    final byId = {for (final d in devices) d.id: d};
    final result = <CameraRef>[];
    final seen = <String>{};
    for (final key in members) {
      final i = key.lastIndexOf('#');
      if (i <= 0 || !seen.add(key)) continue;
      final device = byId[key.substring(0, i)];
      final channel = int.tryParse(key.substring(i + 1));
      if (device == null || channel == null || channel < 1 || channel > device.channels) continue;
      result.add(CameraRef(device, channel));
    }
    return result;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': colorIndex,
        'members': members,
      };

  factory CameraGroup.fromJson(Map<String, dynamic> json) => CameraGroup(
        id: json['id'] as String,
        name: (json['name'] as String?)?.trim().isNotEmpty == true ? json['name'] as String : 'Grupo',
        colorIndex: json['color'] as int? ?? 0,
        members: [
          for (final m in (json['members'] as List<dynamic>? ?? const []))
            if (m is String) m,
        ],
      );
}
