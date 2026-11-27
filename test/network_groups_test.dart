import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mis_camaras/models/device.dart';
import 'package:mis_camaras/models/network.dart';
import 'package:mis_camaras/services/app_store.dart';
import 'package:mis_camaras/services/device_api.dart';
import 'package:mis_camaras/services/device_clock.dart';

/// Pruebas de redes, cámaras repetidas y hora.
void main() {
  group('Redes', () {
    const casa = KnownNetwork(id: 'a', name: 'Casa', subnet: '192.168.1', ssid: 'MiCasa', gateway: '192.168.1.1');
    const oficina = KnownNetwork(id: 'b', name: 'Oficina', subnet: '192.168.1', ssid: 'Oficina5G');
    const sinNombre = KnownNetwork(id: 'c', name: 'Red 10.0.0.x', subnet: '10.0.0');

    test('Reconoce la red por el nombre del WiFi aunque usen los mismos números', () {
      final nets = [casa, oficina];
      expect(matchNetwork(nets, const NetInfo(wifi: true, ssid: 'Oficina5G', ip: '192.168.1.30'))?.id, 'b');
      expect(matchNetwork(nets, const NetInfo(wifi: true, ssid: 'MiCasa', ip: '192.168.1.30'))?.id, 'a');
      expect(matchNetwork(nets, const NetInfo(wifi: true, ssid: 'Otra', ip: '192.168.1.30')), isNull);
    });

    test('Sin el nombre del WiFi usa los números de la red', () {
      final nets = [casa, sinNombre];
      expect(matchNetwork(nets, const NetInfo(wifi: true, ip: '10.0.0.7'))?.id, 'c');
      expect(matchNetwork(nets, const NetInfo(wifi: true, ip: '192.168.1.7', gateway: '192.168.1.1'))?.id, 'a');
      expect(matchNetwork(nets, const NetInfo(wifi: true, ip: '192.168.1.7', gateway: '192.168.1.254')), isNull);
    });

    test('Con datos móviles no hay red local', () {
      expect(matchNetwork([casa], const NetInfo(wifi: false, ip: '10.20.30.40')), isNull);
    });

    test('Completa el nombre del WiFi cuando se puede ver', () {
      final n = sinNombre.adopt(const NetInfo(wifi: true, ssid: 'Taller', ip: '10.0.0.7'));
      expect(n.ssid, 'Taller');
      expect(n.name, 'Taller');
      final keep = sinNombre.copyWith(name: 'Bodega').adopt(const NetInfo(wifi: true, ssid: 'Taller', ip: '10.0.0.7'));
      expect(keep.name, 'Bodega');
      expect(matchNetwork([sinNombre], const NetInfo(wifi: true, ssid: 'Taller', ip: '10.0.0.9'))?.id, 'c');
    });

    test('Equipo con red y lista de cámaras se guarda y se lee', () {
      const d = Device(
        id: '1',
        name: 'NVR',
        brand: Brand.hikvision,
        host: '192.168.1.10',
        channels: 8,
        network: 'a',
        channelHosts: {1: '192.168.1.64', 2: '192.168.1.65'},
      );
      final back = Device.fromJson(jsonDecode(jsonEncode(d.toJson())) as Map<String, dynamic>);
      expect(back.network, 'a');
      expect(back.channelHosts[2], '192.168.1.65');
      expect(back.copyWith(clearNetwork: true).network, isNull);
      expect(d.isLocalHost, isTrue);
      expect(d.copyWith(host: 'micasa.ddns.net').isLocalHost, isFalse);
    });
  });

  group('Cámaras repetidas', () {
    const nvr = Device(
      id: 'nvr',
      name: 'NVR Casa',
      brand: Brand.hikvision,
      host: '192.168.1.10',
      channels: 4,
      network: 'a',
      channelHosts: {1: '192.168.1.64', 3: '192.168.1.66'},
    );
    const cam = Device(id: 'c1', name: 'Patio', brand: Brand.hikvision, host: '192.168.1.66', network: 'a');
    const other = Device(id: 'c2', name: 'Calle', brand: Brand.dahua, host: '192.168.1.80', network: 'a');

    test('Cámara suelta que ya se ve en el grabador', () {
      final dup = findDuplicate(const [nvr, cam, other], cam);
      expect(dup?.device.id, 'nvr');
      expect(dup?.channel, 3);
      expect(findDuplicate(const [nvr, cam, other], other), isNull);
      expect(findDuplicate(const [nvr, cam], nvr), isNull);
    });

    test('El grabador agregado también como cámara', () {
      const asCam = Device(id: 'x', name: 'NVR', brand: Brand.hikvision, host: '192.168.1.10', network: 'a');
      expect(findDuplicate(const [nvr, asCam], asCam)?.device.id, 'nvr');
    });

    test('Mismo equipo agregado dos veces: se oculta el segundo', () {
      const again = Device(id: 'c3', name: 'Patio 2', brand: Brand.hikvision, host: '192.168.1.66', network: 'a');
      expect(findDuplicate(const [cam, again], again)?.device.id, 'c1');
      expect(findDuplicate(const [cam, again], cam), isNull);
    });

    test('En otra red la misma IP es otra cámara', () {
      const elsewhere = Device(id: 'o', name: 'Oficina', brand: Brand.hikvision, host: '192.168.1.66', network: 'b');
      expect(findDuplicate(const [nvr, elsewhere], elsewhere), isNull);
    });

    test('"Mostrarla igual" la deja visible', () {
      final keep = cam.copyWith(keepDuplicate: true);
      expect(findDuplicate([nvr, keep], keep), isNull);
    });

    test('Lee la IP de cada canal del grabador', () {
      const hik = '<InputProxyChannelList><InputProxyChannel version="2.0"><id>1</id><name>Patio</name>'
          '<sourceInputPortDescriptor><proxyProtocol>HIKVISION</proxyProtocol>'
          '<addressingFormatType>ipaddress</addressingFormatType><ipAddress>192.168.1.64</ipAddress>'
          '<managePortNo>8000</managePortNo></sourceInputPortDescriptor></InputProxyChannel>'
          '<InputProxyChannel><id>2</id><sourceInputPortDescriptor><ipAddress>0.0.0.0</ipAddress>'
          '</sourceInputPortDescriptor></InputProxyChannel></InputProxyChannelList>';
      expect(parseHikvisionChannelAddresses(hik), {1: '192.168.1.64'});

      const dahua = 'table.RemoteDevice.NETCAMERA_INFO_0.Address=192.168.1.108\n'
          'table.RemoteDevice.NETCAMERA_INFO_0.Enable=true\n'
          'table.RemoteDevice.NETCAMERA_INFO_1.Address=192.168.1.109\n'
          'table.RemoteDevice.NETCAMERA_INFO_1.Enable=false\n'
          'table.RemoteDevice.NETCAMERA_INFO_2.Address=192.168.1.110\n';
      expect(parseDahuaChannelAddresses(dahua), {1: '192.168.1.108', 3: '192.168.1.110'});
    });
  });

  group('Hora', () {
    test('Hikvision: cambia la hora, conserva la zona y queda manual', () {
      const xml = '<Time version="2.0"><timeMode>NTP</timeMode>'
          '<localTime>2026-11-27T15:10:00-03:00</localTime><timeZone>CST+3:00:00</timeZone></Time>';
      final out = buildHikvisionTimeXml(xml, DateTime(2026, 11, 27, 19, 51, 7));
      expect(out, contains('<localTime>2026-11-27T19:51:07-03:00</localTime>'));
      expect(out, contains('<timeMode>manual</timeMode>'));
      expect(out, contains('<timeZone>CST+3:00:00</timeZone>'));
    });
  });
}
