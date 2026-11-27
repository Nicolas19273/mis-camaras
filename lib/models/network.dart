/// La red a la que está conectado el teléfono ahora.
class NetInfo {
  const NetInfo({required this.wifi, this.ssid, this.ip, this.gateway, this.locationOn = true});

  /// Conectado a WiFi (o cable). false = datos móviles o sin red.
  final bool wifi;

  /// Nombre del WiFi (null si Android no lo deja ver: falta el permiso).
  final String? ssid;
  final String? ip;
  final String? gateway;

  /// Android solo muestra el nombre del WiFi con la ubicación encendida.
  final bool locationOn;

  /// "192.168.1" (los tres primeros números de la IP).
  String? get subnet {
    final p = ip?.split('.');
    if (p == null || p.length != 4) return null;
    return '${p[0]}.${p[1]}.${p[2]}';
  }

  bool get hasNetwork => wifi && subnet != null;
}

/// Una red donde hay equipos (la casa, el trabajo...).
class KnownNetwork {
  const KnownNetwork({
    required this.id,
    required this.name,
    required this.subnet,
    this.ssid,
    this.gateway,
  });

  final String id;
  final String name;
  final String subnet;
  final String? ssid;
  final String? gateway;

  static String defaultName(NetInfo info) => info.ssid ?? 'Red ${info.subnet}.x';

  KnownNetwork copyWith({String? name, String? ssid, String? gateway, String? subnet}) => KnownNetwork(
        id: id,
        name: name ?? this.name,
        subnet: subnet ?? this.subnet,
        ssid: ssid ?? this.ssid,
        gateway: gateway ?? this.gateway,
      );

  /// Completa lo que faltaba con la red actual (por ejemplo, el nombre del WiFi).
  KnownNetwork adopt(NetInfo info) {
    var n = this;
    if (ssid == null && info.ssid != null) {
      final autoName = name == 'Red $subnet.x';
      n = n.copyWith(ssid: info.ssid, name: autoName ? info.ssid : name);
    }
    if (gateway == null && info.gateway != null) n = n.copyWith(gateway: info.gateway);
    return n;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'subnet': subnet,
        if (ssid != null) 'ssid': ssid,
        if (gateway != null) 'gateway': gateway,
      };

  factory KnownNetwork.fromJson(Map<String, dynamic> j) => KnownNetwork(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Red',
        subnet: j['subnet'] as String? ?? '',
        ssid: j['ssid'] as String?,
        gateway: j['gateway'] as String?,
      );
}

/// ¿Cuál de las redes conocidas es la actual?
/// Primero por el nombre del WiFi; si no se puede ver, por los números de la red.
KnownNetwork? matchNetwork(List<KnownNetwork> networks, NetInfo info) {
  if (!info.hasNetwork) return null;
  final ssid = info.ssid;
  if (ssid != null) {
    for (final n in networks) {
      if (n.ssid == ssid) return n;
    }
    // Una red guardada sin nombre de WiFi y con los mismos números.
    for (final n in networks) {
      if (n.ssid == null && n.subnet == info.subnet) return n;
    }
    return null;
  }
  for (final n in networks) {
    if (n.subnet != info.subnet) continue;
    if (info.gateway != null && n.gateway != null && n.gateway != info.gateway) continue;
    return n;
  }
  return null;
}
