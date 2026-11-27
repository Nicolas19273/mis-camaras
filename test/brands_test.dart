import 'package:flutter_test/flutter_test.dart';
import 'package:mis_camaras/brands/brand_adapter.dart';
import 'package:mis_camaras/brands/brands.dart';
import 'package:mis_camaras/models/device.dart';

/// Pruebas de las direcciones RTSP. Se ejecutan con: flutter test
void main() {
  const hik = Device(
    id: '1',
    name: 'Patio',
    brand: Brand.hikvision,
    host: '192.168.1.64',
    password: 'clave123',
  );

  const dahua = Device(
    id: '2',
    name: 'NVR',
    brand: Brand.dahua,
    host: '192.168.1.108',
    password: 'clave123',
    channels: 8,
  );

  test('Hikvision canal 1 principal', () {
    expect(
      adapterFor(Brand.hikvision).rtspUrl(hik, 1, StreamQuality.main),
      'rtsp://admin:clave123@192.168.1.64:554/Streaming/Channels/101',
    );
  });

  test('Hikvision canal 12 secundario', () {
    expect(
      adapterFor(Brand.hikvision).rtspPath(12, StreamQuality.sub),
      '/Streaming/Channels/1202',
    );
  });

  test('Dahua canal 3 secundario', () {
    expect(
      adapterFor(Brand.dahua).rtspUrl(dahua, 3, StreamQuality.sub),
      'rtsp://admin:clave123@192.168.1.108:554/cam/realmonitor?channel=3&subtype=1',
    );
  });

  test('Contraseñas con símbolos se codifican', () {
    final d = hik.copyWith(password: 'a@b:c#1');
    expect(
      adapterFor(Brand.hikvision).rtspUrl(d, 1, StreamQuality.main),
      'rtsp://admin:a%40b%3Ac%231@192.168.1.64:554/Streaming/Channels/101',
    );
  });

  test('La contraseña se puede ocultar', () {
    final url = adapterFor(Brand.dahua)
        .rtspUrl(dahua, 1, StreamQuality.main, hidePassword: true);
    expect(url.contains('clave123'), isFalse);
  });

  test('Guardar y leer equipo no incluye la contraseña', () {
    final json = dahua.toJson();
    expect(json.containsKey('password'), isFalse);
    final back = Device.fromJson(json);
    expect(back.channels, 8);
    expect(back.brand, Brand.dahua);
  });
}
