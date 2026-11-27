/// Marcas soportadas. Para agregar otra marca después, se suma aquí
/// y se crea su adaptador en lib/brands/.
enum Brand { hikvision, dahua }

extension BrandLabel on Brand {
  String get label => switch (this) {
        Brand.hikvision => 'Hikvision',
        Brand.dahua => 'Dahua',
      };
}

/// Un equipo: una cámara suelta (1 canal) o un NVR/DVR (varios canales).
class Device {
  const Device({
    required this.id,
    required this.name,
    required this.brand,
    required this.host,
    this.rtspPort = 554,
    this.httpPort = 80,
    this.username = 'admin',
    this.password = '',
    this.channels = 1,
  });

  final String id;
  final String name;
  final Brand brand;

  /// IP o dominio, sin "http://" ni rutas. Ej: 192.168.1.64
  final String host;

  /// Puerto del video en vivo (casi siempre 554).
  final int rtspPort;

  /// Puerto web del equipo. Se usará para la configuración (ISAPI / API Dahua).
  final int httpPort;

  final String username;

  /// La contraseña NO se guarda junto al resto: va en el almacenamiento
  /// seguro del teléfono (ver AppStore).
  final String password;

  /// 1 para una cámara, o la cantidad de canales del NVR.
  final int channels;

  bool get isRecorder => channels > 1;

  String channelLabel(int channel) => isRecorder ? '$name · Cám $channel' : name;

  Device copyWith({
    String? name,
    Brand? brand,
    String? host,
    int? rtspPort,
    int? httpPort,
    String? username,
    String? password,
    int? channels,
  }) {
    return Device(
      id: id,
      name: name ?? this.name,
      brand: brand ?? this.brand,
      host: host ?? this.host,
      rtspPort: rtspPort ?? this.rtspPort,
      httpPort: httpPort ?? this.httpPort,
      username: username ?? this.username,
      password: password ?? this.password,
      channels: channels ?? this.channels,
    );
  }

  /// Datos que se guardan en el teléfono (sin contraseña).
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'brand': brand.name,
        'host': host,
        'rtspPort': rtspPort,
        'httpPort': httpPort,
        'username': username,
        'channels': channels,
      };

  factory Device.fromJson(Map<String, dynamic> json) {
    return Device(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Equipo',
      brand: Brand.values.byName(json['brand'] as String? ?? 'hikvision'),
      host: json['host'] as String? ?? '',
      rtspPort: json['rtspPort'] as int? ?? 554,
      httpPort: json['httpPort'] as int? ?? 80,
      username: json['username'] as String? ?? 'admin',
      channels: json['channels'] as int? ?? 1,
    );
  }
}

/// Una cámara concreta para mostrar en pantalla: un equipo + un canal.
class CameraRef {
  const CameraRef(this.device, this.channel);

  final Device device;
  final int channel;

  String get label => device.channelLabel(channel);
}
