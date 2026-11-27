import 'package:flutter_test/flutter_test.dart';
import 'package:mis_camaras/models/device.dart';
import 'package:mis_camaras/ptz/ptz.dart';
import 'package:mis_camaras/services/device_api.dart';

/// Pruebas de la detección PTZ por modelo y de las herramientas del equipo.
void main() {
  group('PTZ por modelo', () {
    test('Cámara fija Hikvision no muestra joystick', () {
      expect(isFixedCameraModel(Brand.hikvision, 'DS-2CD2143G2-I'), isTrue);
      expect(
        applyModelRules(Brand.hikvision, 'DS-2CD2143G2-I', (panTilt: true, zoom: true)),
        isNull,
      );
    });

    test('Fija con lente motorizado: solo zoom', () {
      final caps = applyModelRules(Brand.hikvision, 'DS-2CD2646G2-IZS', (panTilt: true, zoom: true));
      expect(caps!.panTilt, isFalse);
      expect(caps.zoom, isTrue);
    });

    test('Domo PTZ Hikvision sí', () {
      expect(isFixedCameraModel(Brand.hikvision, 'DS-2DE4425IW-DE'), isFalse);
      final caps = applyModelRules(Brand.hikvision, 'DS-2DE4425IW-DE', (panTilt: true, zoom: true));
      expect(caps!.panTilt, isTrue);
    });

    test('Dahua fija con RS-485 no muestra joystick', () {
      expect(isFixedCameraModel(Brand.dahua, 'IPC-HFW2431S-S-S2'), isTrue);
      expect(isFixedCameraModel(Brand.dahua, 'DH-IPC-HDW2431T-AS'), isTrue);
      expect(
        applyModelRules(Brand.dahua, 'IPC-HFW2431S-S-S2', (panTilt: true, zoom: false)),
        isNull,
      );
    });

    test('Dahua speed dome sí', () {
      expect(isFixedCameraModel(Brand.dahua, 'DH-SD49225XA-HNR'), isFalse);
      expect(isFixedCameraModel(Brand.dahua, 'SD22404T-GN'), isFalse);
    });

    test('Modelo desconocido: se confía en el equipo', () {
      final caps = applyModelRules(Brand.dahua, null, (panTilt: true, zoom: true));
      expect(caps!.panTilt, isTrue);
    });

    test('Hikvision ya no asume PTZ si no lo declara', () {
      expect(parseHikvisionPtzCaps('<PTZChanelCap><AbsolutePanTiltPositionSpace/></PTZChanelCap>'), isNull);
    });

    test('Dahua necesita giro horizontal y vertical', () {
      expect(parseDahuaPtzCaps('caps.Pan=true\ncaps.Tile=false\ncaps.Zoom=false'), isNull);
    });
  });

  group('Nombres de cámaras', () {
    test('Nombres genéricos se ignoran', () {
      expect(isGenericChannelName('Camera 01'), isTrue);
      expect(isGenericChannelName('IPCamera 02'), isTrue);
      expect(isGenericChannelName('CH3'), isTrue);
      expect(isGenericChannelName('Patio trasero'), isFalse);
    });

    test('Títulos Dahua (desde 0) pasan a canales desde 1', () {
      final names = parseDahuaChannelTitles(
        'table.ChannelTitle[0].Name=Entrada\r\ntable.ChannelTitle[1].Name=Channel2\r\n'
        'table.ChannelTitle[2].Name=Bodega\r\n',
      );
      expect(names, {1: 'Entrada', 3: 'Bodega'});
    });

    test('Modelos de cámaras de un NVR Dahua', () {
      final models = dahuaRemoteModels(
        'table.RemoteDevice.uuid:System_CONFIG_NETCAMERA_INFO_0.DeviceType=IPC-HFW2431S\r\n'
        'table.RemoteDevice.uuid:System_CONFIG_NETCAMERA_INFO_3.DeviceType=SD49225XA-HNR\r\n',
      );
      expect(models[1], 'IPC-HFW2431S');
      expect(models[4], 'SD49225XA-HNR');
    });
  });

  test('Equipo guarda nombres, ocultos y "no es PTZ"', () {
    const d = Device(
      id: '1',
      name: 'NVR',
      brand: Brand.dahua,
      host: '192.168.1.108',
      channels: 4,
      mac: '3c:ef:8c:00:11:22',
      channelNames: {2: 'Patio'},
      hiddenChannels: {4},
      noPtzChannels: {1},
    );
    final back = Device.fromJson(d.toJson());
    expect(back.channelLabel(2), 'Patio');
    expect(back.channelLabel(3), 'NVR · Cám 3');
    expect(back.hiddenChannels, {4});
    expect(back.noPtzChannels, {1});
    expect(back.mac, '3c:ef:8c:00:11:22');
  });
}
