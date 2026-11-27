import 'package:flutter_test/flutter_test.dart';
import 'package:mis_camaras/services/network_config.dart';

/// Pruebas del cambio de IP.
void main() {
  const hikXml = '<?xml version="1.0" encoding="UTF-8"?>'
      '<IPAddress version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">'
      '<ipVersion>dual</ipVersion><addressingType>static</addressingType>'
      '<ipAddress>192.168.1.64</ipAddress><subnetMask>255.255.255.0</subnetMask>'
      '<DefaultGateway><ipAddress>192.168.1.1</ipAddress></DefaultGateway>'
      '<PrimaryDNS><ipAddress>8.8.8.8</ipAddress></PrimaryDNS></IPAddress>';

  test('Lee la red de Hikvision', () {
    expect(xmlTag(hikXml, 'ipAddress'), '192.168.1.64');
    expect(xmlTag(hikXml, 'addressingType'), 'static');
    expect(hikvisionGateway(hikXml), '192.168.1.1');
  });

  test('Cambia solo la IP del equipo, no la del router ni el DNS', () {
    final xml = buildHikvisionIpXml(
      hikXml,
      const NetSettings(dhcp: false, ip: '192.168.1.70', mask: '255.255.255.0', gateway: '192.168.1.254'),
    );
    expect(xmlTag(xml, 'ipAddress'), '192.168.1.70');
    expect(hikvisionGateway(xml), '192.168.1.254');
    expect(xml, contains('<PrimaryDNS><ipAddress>8.8.8.8</ipAddress></PrimaryDNS>'));
  });

  test('Pasar a DHCP no toca las direcciones', () {
    final xml = buildHikvisionIpXml(
      hikXml,
      const NetSettings(dhcp: true, ip: '', mask: '', gateway: ''),
    );
    expect(xmlTag(xml, 'addressingType'), 'dynamic');
    expect(xmlTag(xml, 'ipAddress'), '192.168.1.64');
  });

  test('Lee la red de Dahua', () {
    final kv = parseDahuaTable(
      'table.Network.DefaultInterface=eth0\r\n'
      'table.Network.eth0.IPAddress=192.168.1.108\r\n'
      'table.Network.eth0.DhcpEnable=false\r\n'
      'table.Network.eth0.PhysicalAddress=3c:ef:8c:00:11:22\r\n',
      'table.Network.',
    );
    expect(kv['DefaultInterface'], 'eth0');
    expect(kv['eth0.IPAddress'], '192.168.1.108');
    expect(kv['eth0.DhcpEnable'], 'false');
  });

  test('Validaciones', () {
    expect(isValidIpv4('192.168.1.70'), isTrue);
    expect(isValidIpv4('192.168.1.256'), isFalse);
    expect(isValidIpv4('192.168.01.7'), isFalse);
    expect(isValidMask('255.255.255.0'), isTrue);
    expect(isValidMask('255.255.0.255'), isFalse);
    expect(sameSubnet('192.168.1.70', '192.168.1.1', '255.255.255.0'), isTrue);
    expect(sameSubnet('192.168.2.70', '192.168.1.1', '255.255.255.0'), isFalse);
    expect(normalizeMac('C0-56-E3-3D-19-5B'), normalizeMac('c0:56:e3:3d:19:5b'));
  });
}
