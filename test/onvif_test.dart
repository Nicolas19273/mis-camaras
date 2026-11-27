import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mis_camaras/brands/brand_adapter.dart';
import 'package:mis_camaras/brands/brands.dart';
import 'package:mis_camaras/models/device.dart';
import 'package:mis_camaras/onvif/onvif_client.dart';
import 'package:mis_camaras/services/device_api.dart';
import 'package:mis_camaras/services/discovery.dart';

/// Pruebas de las marcas nuevas y de ONVIF. Se ejecutan con: flutter test
void main() {
  Device cam(Brand brand, {int channels = 1, String? main, String? sub}) => Device(
        id: 'x',
        name: 'Cam',
        brand: brand,
        host: '192.168.1.90',
        password: 'clave',
        channels: channels,
        rtspMain: main,
        rtspSub: sub,
      );

  String url(Device d, int ch, StreamQuality q) => adapterFor(d.brand).rtspUrl(d, ch, q);

  group('Rutas RTSP por marca', () {
    test('Vivotek', () {
      expect(url(cam(Brand.vivotek), 1, StreamQuality.main), 'rtsp://admin:clave@192.168.1.90:554/live.sdp');
      expect(url(cam(Brand.vivotek), 1, StreamQuality.sub), endsWith('/live2.sdp'));
    });

    test('Axis', () {
      expect(url(cam(Brand.axis), 1, StreamQuality.main), endsWith('/axis-media/media.amp?camera=1&videocodec=h264'));
      expect(url(cam(Brand.axis), 1, StreamQuality.sub), contains('resolution=640x480'));
    });

    test('Hanwha cámara y NVR', () {
      expect(url(cam(Brand.hanwha), 1, StreamQuality.main), endsWith('/profile2/media.smp'));
      final nvr = cam(Brand.hanwha, channels: 8);
      expect(url(nvr, 1, StreamQuality.main), endsWith('/LiveChannel/0/media.smp/profile=1'));
      expect(url(nvr, 5, StreamQuality.sub), endsWith('/LiveChannel/4/media.smp/profile=3'));
    });

    test('Uniview cámara y NVR', () {
      expect(url(cam(Brand.uniview), 1, StreamQuality.sub), endsWith('/media/video2'));
      final nvr = cam(Brand.uniview, channels: 4);
      expect(url(nvr, 3, StreamQuality.main), endsWith('/unicast/c3/s0/live'));
      expect(url(nvr, 3, StreamQuality.sub), endsWith('/unicast/c3/s1/live'));
    });

    test('Rutas detectadas por ONVIF tienen prioridad en cámaras', () {
      final d = cam(Brand.onvif, main: '/stream1', sub: 'stream2');
      expect(url(d, 1, StreamQuality.main), 'rtsp://admin:clave@192.168.1.90:554/stream1');
      expect(url(d, 1, StreamQuality.sub), endsWith(':554/stream2'));
      // Sin secundaria: usa la principal.
      expect(url(cam(Brand.axis, main: '/a'), 1, StreamQuality.sub), endsWith(':554/a'));
    });

    test('En grabadores se ignoran las rutas propias', () {
      final nvr = cam(Brand.hikvision, channels: 4, main: '/x');
      expect(url(nvr, 2, StreamQuality.main), endsWith('/Streaming/Channels/201'));
    });
  });

  group('Marcas', () {
    test('Todas tienen adaptador, letra y nombre', () {
      for (final b in Brand.values) {
        expect(adapterFor(b), isNotNull);
        expect(b.letter.length, 1);
        expect(b.label, isNotEmpty);
        expect(b.shortLabel, isNotEmpty);
      }
      expect(Brand.hikvision.hasFullApi, isTrue);
      expect(Brand.dahua.hasFullApi, isTrue);
      expect(Brand.axis.hasFullApi, isFalse);
    });

    test('Guardar y leer conserva rutas propias; marca desconocida → ONVIF', () {
      final d = cam(Brand.hanwha, main: '/profile2/media.smp', sub: '/profile3/media.smp');
      final back = Device.fromJson(jsonDecode(jsonEncode(d.toJson())) as Map<String, dynamic>);
      expect(back.brand, Brand.hanwha);
      expect(back.rtspMain, '/profile2/media.smp');
      expect(back.rtspSub, '/profile3/media.smp');
      final json = d.toJson()..['brand'] = 'marca-del-futuro';
      expect(Device.fromJson(json).brand, Brand.onvif);
    });

    test('Modelos de otras marcas no se juzgan con reglas de Dahua', () {
      expect(isFixedCameraModel(Brand.axis, 'IPC-HFW2431T'), isNull);
      expect(isFixedCameraModel(Brand.dahua, 'IPC-HFW2431T'), isTrue);
    });
  });

  group('ONVIF', () {
    test('Firma WS-Security (ejemplo oficial de ONVIF)', () {
      final nonce = base64Decode('LKqI6G/AikKCQrN0zqZFlg==');
      expect(wsseDigest(nonce, '2010-09-16T07:50:45Z', 'userpassword'), 'tuOSpGlFlIXsozq4HFNeeGeFLEI=');
    });

    test('Lee perfiles con resolución y PTZ', () {
      const xml = '''
<s:Envelope><s:Body><trt:GetProfilesResponse>
  <trt:Profiles token="Profile_1" fixed="true">
    <tt:Name>mainStream</tt:Name>
    <tt:VideoEncoderConfiguration token="V1">
      <tt:Encoding>H264</tt:Encoding>
      <tt:Resolution><tt:Width>2560</tt:Width><tt:Height>1440</tt:Height></tt:Resolution>
    </tt:VideoEncoderConfiguration>
    <tt:PTZConfiguration token="PTZ1"><tt:Name>PTZ</tt:Name></tt:PTZConfiguration>
  </trt:Profiles>
  <trt:Profiles token="Profile_2" fixed="true">
    <tt:VideoEncoderConfiguration token="V2">
      <tt:Encoding>H264</tt:Encoding>
      <tt:Resolution><tt:Width>640</tt:Width><tt:Height>360</tt:Height></tt:Resolution>
    </tt:VideoEncoderConfiguration>
  </trt:Profiles>
</trt:GetProfilesResponse></s:Body></s:Envelope>''';
      final list = parseOnvifProfiles(xml);
      expect(list.length, 2);
      expect(list[0].token, 'Profile_1');
      expect(list[0].pixels, 2560 * 1440);
      expect(list[0].hasPtz, isTrue);
      expect(list[1].hasPtz, isFalse);
      expect(list[1].width, 640);
    });

    test('Lee la dirección de cada servicio', () {
      const xml = '<tds:Capabilities>'
          '<tt:Device><tt:XAddr>http://192.168.1.90/onvif/device_service</tt:XAddr></tt:Device>'
          '<tt:Media><tt:XAddr>http://192.168.1.90/onvif/Media</tt:XAddr></tt:Media>'
          '<tt:PTZ><tt:XAddr>http://192.168.1.90/onvif/PTZ</tt:XAddr></tt:PTZ>'
          '</tds:Capabilities>';
      expect(onvifSectionXAddr(xml, 'Media'), 'http://192.168.1.90/onvif/Media');
      expect(onvifSectionXAddr(xml, 'PTZ'), 'http://192.168.1.90/onvif/PTZ');
      expect(onvifSectionXAddr(xml, 'Imaging'), isNull);
    });

    test('Lee la hora UTC de la cámara', () {
      const xml = '<tt:UTCDateTime><tt:Time><tt:Hour>14</tt:Hour><tt:Minute>5</tt:Minute>'
          '<tt:Second>9</tt:Second></tt:Time><tt:Date><tt:Year>2026</tt:Year><tt:Month>11</tt:Month>'
          '<tt:Day>27</tt:Day></tt:Date></tt:UTCDateTime>';
      expect(parseOnvifUtc(xml), DateTime.utc(2026, 11, 27, 14, 5, 9));
      expect(parseOnvifUtc('<x/>'), isNull);
    });

    test('Búsqueda ONVIF: marca por "scopes" o genérica', () {
      String probe(String scopes) => '<d:ProbeMatches><d:ProbeMatch>'
          '<d:Scopes>$scopes</d:Scopes><d:XAddrs>http://192.168.1.77/onvif/device_service</d:XAddrs>'
          '</d:ProbeMatch></d:ProbeMatches>';
      final axis = parseOnvif(probe('onvif://www.onvif.org/name/AXIS onvif://www.onvif.org/hardware/M3045-V'), '192.168.1.77');
      expect(axis?.brand, Brand.axis);
      expect(axis?.ip, '192.168.1.77');
      final other = parseOnvif(probe('onvif://www.onvif.org/name/IPCAM onvif://www.onvif.org/hardware/X1'), '192.168.1.77');
      expect(other?.brand, Brand.onvif);
    });

    test('Una marca concreta gana sobre la genérica al juntar resultados', () {
      final a = FoundDevice(ip: '192.168.1.5')..brand = Brand.onvif;
      final b = FoundDevice(ip: '192.168.1.5')..brand = Brand.dahua;
      a.mergeFrom(b);
      expect(a.brand, Brand.dahua);
    });
  });
}
