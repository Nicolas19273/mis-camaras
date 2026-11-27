import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mis_camaras/models/device.dart';
import 'package:mis_camaras/services/discovery.dart';

/// Pruebas de la lectura de respuestas de búsqueda en la red.
void main() {
  test('SADP de un NVR Hikvision', () {
    const xml = '<?xml version="1.0" encoding="UTF-8" ?><ProbeMatch>'
        '<Uuid>377581D7</Uuid><Types>inquiry</Types><DeviceType>41343</DeviceType>'
        '<DeviceDescription>DS-7816N-E2</DeviceDescription>'
        '<DeviceSN>DS-7816N-E21620150203AARR503146794WCVU</DeviceSN>'
        '<CommandPort>8000</CommandPort><HttpPort>8080</HttpPort>'
        '<MAC>c0-56-e3-3d-19-5b</MAC><IPv4Address>192.168.1.211</IPv4Address>'
        '<DigitalChannelNum>16</DigitalChannelNum><AnalogChannelNum>0</AnalogChannelNum>'
        '<Activated>true</Activated></ProbeMatch>';
    final d = parseSadp(xml, '192.168.1.211')!;
    expect(d.brand, Brand.hikvision);
    expect(d.ip, '192.168.1.211');
    expect(d.model, 'DS-7816N-E2');
    expect(d.httpPort, 8080);
    expect(d.isRecorder, isTrue);
    expect(d.channels, 16);
    expect(d.activated, isTrue);
  });

  test('SADP ignora nuestra propia consulta', () {
    expect(parseSadp('<Probe><Uuid>x</Uuid><Types>inquiry</Types></Probe>', '1.1.1.1'), isNull);
  });

  test('Paquete de búsqueda Dahua', () {
    final p = buildDhipSearch();
    expect(p.sublist(0, 8), [0x20, 0, 0, 0, 0x44, 0x48, 0x49, 0x50]);
    final len = ByteData.sublistView(Uint8List.fromList(p)).getUint32(16, Endian.little);
    expect(len, p.length - 32);
    expect(utf8.decode(p.sublist(32)), contains('DHDiscover.search'));
  });

  test('Respuesta Dahua', () {
    final json = jsonEncode({
      'method': 'client.notifyDevInfo',
      'params': {
        'deviceInfo': {
          'DeviceClass': 'NVR',
          'DeviceType': 'DHI-NVR4108HS-4KS2',
          'HttpPort': 80,
          'IPv4Address': {'IPAddress': '192.168.1.108', 'SubnetMask': '255.255.255.0'},
          'Mac': '3c:ef:8c:00:11:22',
          'Vendor': 'Dahua',
          'VideoInputChannels': 0,
          'RemoteVideoInputChannels': 8,
        },
      },
    });
    final data = [...List<int>.filled(32, 0), ...utf8.encode(json)];
    final d = parseDhip(data, '192.168.1.108')!;
    expect(d.brand, Brand.dahua);
    expect(d.ip, '192.168.1.108');
    expect(d.model, 'DHI-NVR4108HS-4KS2');
    expect(d.isRecorder, isTrue);
    expect(d.channels, 8);
  });

  test('Respuesta ONVIF con scopes', () {
    const xml = '<SOAP-ENV:Envelope><SOAP-ENV:Body><d:ProbeMatches><d:ProbeMatch>'
        '<d:Scopes>onvif://www.onvif.org/type/video_encoder onvif://www.onvif.org/name/HIKVISION '
        'onvif://www.onvif.org/hardware/DS-2CD2143G2-I onvif://www.onvif.org/MAC/24:0f:9b:aa:bb:cc</d:Scopes>'
        '<d:XAddrs>http://192.168.1.64/onvif/device_service http://[fe80::1]/onvif/device_service</d:XAddrs>'
        '</d:ProbeMatch></d:ProbeMatches></SOAP-ENV:Body></SOAP-ENV:Envelope>';
    final d = parseOnvif(xml, '192.168.1.64')!;
    expect(d.brand, Brand.hikvision);
    expect(d.model, 'DS-2CD2143G2-I');
    expect(d.ip, '192.168.1.64');
    expect(d.isRecorder, isFalse);
  });

  test('Marca por texto', () {
    expect(brandFromText('Dahua IPC-HDW2431T'), Brand.dahua);
    expect(brandFromText('Lorex N841'), Brand.dahua);
    expect(brandFromText('DS-7608NI-K2'), Brand.hikvision);
    expect(brandFromText('Axis M3045'), isNull);
  });

  test('Huella HTTP', () {
    expect(looksLikeDahua(401, 'Digest realm="Login to 4K0123456", qop="auth"'), isTrue);
    expect(looksLikeDahua(401, 'Basic realm="router"'), isFalse);
    expect(
      looksLikeHikvision(401, 'Digest realm="IP Camera(C6150)"', ''),
      isTrue,
    );
    expect(
      looksLikeHikvision(401, 'Digest realm="Login to 4K0123456"', '<userCheck>'),
      isFalse,
    );
    expect(looksLikeHikvision(401, 'Basic realm="TP-Link"', 'Unauthorized'), isFalse);
  });

  test('IPs privadas', () {
    expect(isPrivateIp('192.168.0.10'), isTrue);
    expect(isPrivateIp('10.1.2.3'), isTrue);
    expect(isPrivateIp('172.20.1.1'), isTrue);
    expect(isPrivateIp('8.8.8.8'), isFalse);
  });
}
