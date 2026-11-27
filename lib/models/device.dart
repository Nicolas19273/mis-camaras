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
    this.network,
    this.channelHosts = const {},
    this.keepDuplicate = false,
  });

  /// Valor de [network] para "se ve desde cualquier red" (acceso remoto).
  static const anyNetwork = '*';

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

  /// Red WiFi a la que pertenece (id de una red conocida).
  /// null = todavía no se sabe; [anyNetwork] = se ve desde cualquier red.
  final String? network;

  /// En grabadores: IP de la cámara conectada a cada canal (para detectar
  /// cámaras agregadas dos veces: sola y dentro del grabador).
  final Map<int, String> channelHosts;

  /// true = mostrarla aunque también se vea dentro de un grabador.
  final bool keepDuplicate;

  /// true si la dirección es de una red local (192.168.x.x, 10.x.x.x...).
  bool get isLocalHost {
    final p = host.split('.').map((e) => int.tryParse(e) ?? -1).toList();
    if (p.length != 4 || p.any((x) => x < 0 || x > 255)) return false;
    return p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && p[1] >= 16 && p[1] <= 31);
  }

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
    String? network,
    bool clearNetwork = false,
    Map<int, String>? channelHosts,
    bool? keepDuplicate,
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
      network: clearNetwork ? null : (network ?? this.network),
      channelHosts: channelHosts ?? this.channelHosts,
      keepDuplicate: keepDuplicate ?? this.keepDuplicate,
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
        if (network != null) 'network': network,
        if (channelHosts.isNotEmpty)
          'channelHosts': {for (final e in channelHosts.entries) '${e.key}': e.value},
        if (keepDuplicate) 'keepDuplicate': true,
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

    final hosts = <int, String>{};
    final rawHosts = json['channelHosts'];
    if (rawHosts is Map) {
      rawHosts.forEach((k, v) {
        final ch = int.tryParse('$k');
        if (ch != null && v is String) hosts[ch] = v;
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
      network: json['network'] as String?,
      channelHosts: hosts,
      keepDuplicate: json['keepDuplicate'] as bool? ?? false,
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
