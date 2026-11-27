/// Marcas soportadas. Para agregar otra marca después, se suma aquí
/// y se crea su adaptador en lib/brands/.
enum Brand { hikvision, dahua, vivotek, axis, hanwha, uniview, onvif }

extension BrandLabel on Brand {
  String get label => switch (this) {
        Brand.hikvision => 'Hikvision',
        Brand.dahua => 'Dahua',
        Brand.vivotek => 'Vivotek',
        Brand.axis => 'Axis',
        Brand.hanwha => 'Hanwha Wisenet',
        Brand.uniview => 'Uniview',
        Brand.onvif => 'Otra (ONVIF)',
      };

  /// Nombre corto para chips y listas.
  String get shortLabel => switch (this) {
        Brand.hanwha => 'Hanwha',
        Brand.onvif => 'ONVIF',
        _ => label,
      };

  /// Letra de la insignia de color.
  String get letter => switch (this) {
        Brand.hikvision => 'H',
        Brand.dahua => 'D',
        Brand.vivotek => 'V',
        Brand.axis => 'A',
        Brand.hanwha => 'W',
        Brand.uniview => 'U',
        Brand.onvif => 'O',
      };

  /// Marcas con API propia completa (cambio de IP, nombres de canales).
  bool get hasFullApi => this == Brand.hikvision || this == Brand.dahua;
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
    this.mac,
    this.channelNames = const {},
    this.hiddenChannels = const {},
    this.noPtzChannels = const {},
    this.rtspMain,
    this.rtspSub,
  });

  final String id;
  final String name;
  final Brand brand;

  /// IP o dominio, sin "http://" ni rutas. Ej: 192.168.1.64
  final String host;

  /// Puerto del video en vivo (casi siempre 554).
  final int rtspPort;

  /// Puerto web del equipo (ISAPI / API Dahua): PTZ, red, información.
  final int httpPort;

  final String username;

  /// La contraseña NO se guarda junto al resto: va en el almacenamiento
  /// seguro del teléfono (ver AppStore).
  final String password;

  /// 1 para una cámara, o la cantidad de canales del NVR.
  final int channels;

  /// MAC del equipo: sirve para encontrarlo si cambia de IP.
  final String? mac;

  /// Nombre propio de cada canal (ej. 3 → "Patio").
  final Map<int, String> channelNames;

  /// Canales que no se muestran en el mosaico.
  final Set<int> hiddenChannels;

  /// Canales marcados a mano como "no es PTZ".
  final Set<int> noPtzChannels;

  /// Ruta RTSP propia del flujo principal (ej. "/profile2/media.smp").
  /// Si está vacía se usa la de la marca. La llena ONVIF o la persona.
  final String? rtspMain;

  /// Ruta RTSP propia del flujo secundario.
  final String? rtspSub;

  bool get isRecorder => channels > 1;

  String channelLabel(int channel) {
    final custom = channelNames[channel]?.trim();
    if (custom != null && custom.isNotEmpty) return custom;
    return isRecorder ? '$name · Cám $channel' : name;
  }

  Device copyWith({
    String? name,
    Brand? brand,
    String? host,
    int? rtspPort,
    int? httpPort,
    String? username,
    String? password,
    int? channels,
    String? mac,
    Map<int, String>? channelNames,
    Set<int>? hiddenChannels,
    Set<int>? noPtzChannels,
    String? rtspMain,
    String? rtspSub,
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
      mac: mac ?? this.mac,
      channelNames: channelNames ?? this.channelNames,
      hiddenChannels: hiddenChannels ?? this.hiddenChannels,
      noPtzChannels: noPtzChannels ?? this.noPtzChannels,
      rtspMain: rtspMain ?? this.rtspMain,
      rtspSub: rtspSub ?? this.rtspSub,
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
        if (mac != null) 'mac': mac,
        if (channelNames.isNotEmpty)
          'channelNames': {for (final e in channelNames.entries) '${e.key}': e.value},
        if (hiddenChannels.isNotEmpty) 'hidden': hiddenChannels.toList()..sort(),
        if (noPtzChannels.isNotEmpty) 'noPtz': noPtzChannels.toList()..sort(),
        if (rtspMain != null && rtspMain!.isNotEmpty) 'rtspMain': rtspMain,
        if (rtspSub != null && rtspSub!.isNotEmpty) 'rtspSub': rtspSub,
      };

  factory Device.fromJson(Map<String, dynamic> json) {
    Set<int> intSet(Object? v) =>
        v is List ? v.map((e) => (e as num).toInt()).toSet() : <int>{};

    final names = <int, String>{};
    final rawNames = json['channelNames'];
    if (rawNames is Map) {
      rawNames.forEach((k, v) {
        final ch = int.tryParse('$k');
        if (ch != null && v is String) names[ch] = v;
      });
    }

    return Device(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Equipo',
      brand: Brand.values.asNameMap()[json['brand']] ?? Brand.onvif,
      host: json['host'] as String? ?? '',
      rtspPort: json['rtspPort'] as int? ?? 554,
      httpPort: json['httpPort'] as int? ?? 80,
      username: json['username'] as String? ?? 'admin',
      channels: json['channels'] as int? ?? 1,
      mac: json['mac'] as String?,
      channelNames: names,
      hiddenChannels: intSet(json['hidden']),
      noPtzChannels: intSet(json['noPtz']),
      rtspMain: json['rtspMain'] as String?,
      rtspSub: json['rtspSub'] as String?,
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
