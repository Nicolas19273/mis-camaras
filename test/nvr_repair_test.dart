import 'package:flutter_test/flutter_test.dart';
import 'package:mis_camaras/models/device.dart';
import 'package:mis_camaras/screens/nvr_repair_screen.dart';
import 'package:mis_camaras/services/network_config.dart';
import 'package:mis_camaras/services/nvr_channels.dart';

/// Pruebas de "Reparar cámara en el NVR".
void main() {
  group('Lista de cámaras del NVR', () {
    test('Dahua: lee IP, puerto y prefijo; salta vacías y apagadas', () {
      const body = 'table.RemoteDevice.uuid:System_CONFIG_NETCAMERA_INFO_0.Address=192.168.1.111\n'
          'table.RemoteDevice.uuid:System_CONFIG_NETCAMERA_INFO_0.Port=37777\n'
          'table.RemoteDevice.uuid:System_CONFIG_NETCAMERA_INFO_0.Enable=true\n'
          'table.RemoteDevice.uuid:System_CONFIG_NETCAMERA_INFO_0.ProtocolType=Dahua2\n'
          'table.RemoteDevice.uuid:System_CONFIG_NETCAMERA_INFO_0.VideoInputs[0].Name=x\n'
          'table.RemoteDevice.uuid:System_CONFIG_NETCAMERA_INFO_1.Address=192.168.0.0\n'
          'table.RemoteDevice.uuid:System_CONFIG_NETCAMERA_INFO_1.Enable=false\n'
          'table.RemoteDevice.uuid:System_CONFIG_NETCAMERA_INFO_2.Address=192.168.1.112\n'
          'table.RemoteDevice.uuid:System_CONFIG_NETCAMERA_INFO_2.Port=80\n'
          'table.RemoteDevice.uuid:System_CONFIG_NETCAMERA_INFO_2.ProtocolType=Onvif\n';
      final list = parseDahuaNvrChannels(body);
      expect(list.length, 2);
      expect(list[0].channel, 1);
      expect(list[0].address, '192.168.1.111');
      expect(list[0].port, 37777);
      expect(list[0].key, 'RemoteDevice.uuid:System_CONFIG_NETCAMERA_INFO_0');
      expect(list[1].channel, 3);
      expect(list[1].protocol, 'Onvif');
    });

    test('Dahua: arma el cambio de IP', () {
      final p = dahuaNvrChannelParams('RemoteDevice.NETCAMERA_INFO_0', address: '192.168.1.115');
      expect(p, ['RemoteDevice.NETCAMERA_INFO_0.Address=192.168.1.115', 'RemoteDevice.NETCAMERA_INFO_0.Enable=true']);
    });

    test('Hikvision: lee y cambia IP, puerto y contraseña', () {
      const xml = '<InputProxyChannel version="2.0"><id>2</id><name>Patio</name><sourceInputPortDescriptor>'
          '<proxyProtocol>HIKVISION</proxyProtocol><addressingFormatType>ipaddress</addressingFormatType>'
          '<ipAddress>192.168.1.64</ipAddress><managePortNo>8000</managePortNo><srcInputPort>1</srcInputPort>'
          '<userName>admin</userName></sourceInputPortDescriptor></InputProxyChannel>';
      final list = parseHikvisionNvrChannels('<InputProxyChannelList>$xml</InputProxyChannelList>');
      expect(list.single.channel, 2);
      expect(list.single.port, 8000);
      final out = buildHikvisionNvrChannelXml(xml, address: '192.168.1.70', password: 'a<b');
      expect(out, contains('<ipAddress>192.168.1.70</ipAddress>'));
      expect(out, contains('<userName>admin</userName><password>a&lt;b</password>'));
    });
  });

  group('Diagnóstico', () {
    const ch = NvrChannel(channel: 1, address: '192.168.1.111', key: 'k', port: 37777);
    const cam = Device(id: 'c', name: 'Entrada', brand: Brand.dahua, host: '192.168.1.111');
    const nvrNet = NetSettings(dhcp: false, ip: '192.168.1.108', mask: '255.255.255.0', gateway: '192.168.1.1');

    test('Sin cámara elegida', () {
      expect(diagnoseNvrLink(channel: ch, camera: null), NvrLinkIssue.pickCamera);
    });
    test('La cámara cambió de IP', () {
      expect(diagnoseNvrLink(channel: ch, camera: cam.copyWith(host: '192.168.1.115')), NvrLinkIssue.ipChanged);
    });
    test('Máscara distinta', () {
      const net = NetSettings(dhcp: false, ip: '192.168.1.111', mask: '255.255.255.128', gateway: '192.168.1.1');
      const nvrFar = NetSettings(dhcp: false, ip: '192.168.1.200', mask: '255.255.255.0', gateway: '192.168.1.1');
      expect(diagnoseNvrLink(channel: ch, camera: cam, cameraNet: net, nvrNet: nvrFar), NvrLinkIssue.otherSubnet);
    });
    test('Puerta de enlace de otra red', () {
      const net = NetSettings(dhcp: false, ip: '192.168.1.111', mask: '255.255.255.0', gateway: '192.168.0.1');
      expect(diagnoseNvrLink(channel: ch, camera: cam, cameraNet: net, nvrNet: nvrNet), NvrLinkIssue.badGateway);
    });
    test('Puerto distinto', () {
      const net = NetSettings(dhcp: false, ip: '192.168.1.111', mask: '255.255.255.0', gateway: '192.168.1.1');
      expect(
        diagnoseNvrLink(channel: ch, camera: cam, cameraNet: net, nvrNet: nvrNet, cameraTcpPort: 37778),
        NvrLinkIssue.wrongPort,
      );
      expect(
        diagnoseNvrLink(channel: ch, camera: cam, cameraNet: net, nvrNet: nvrNet, cameraTcpPort: 37777),
        NvrLinkIssue.unknown,
      );
    });
  });
}
