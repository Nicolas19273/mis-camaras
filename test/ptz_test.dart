import 'package:flutter_test/flutter_test.dart';
import 'package:mis_camaras/ptz/ptz.dart';
import 'package:mis_camaras/services/camera_http.dart';

/// Pruebas del control PTZ y de la autenticación Digest.
void main() {
  group('Autenticación Digest', () {
    test('Ejemplo oficial del RFC 2617', () {
      final challenge = parseDigestChallenge(
        ' realm="testrealm@host.com", qop="auth,auth-int", '
        'nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", '
        'opaque="5ccc069c403ebaf9f0171e9517f40e41"',
      );
      expect(challenge['realm'], 'testrealm@host.com');
      expect(challenge['qop'], 'auth,auth-int');

      final header = buildDigestHeader(
        challenge: challenge,
        method: 'GET',
        uri: '/dir/index.html',
        username: 'Mufasa',
        password: 'Circle Of Life',
        nc: 1,
        cnonce: '0a4f113b',
      );
      expect(header, contains('response="6629fae49393a05397450978507c4ef1"'));
      expect(header, contains('nc=00000001'));
      expect(header, contains('opaque="5ccc069c403ebaf9f0171e9517f40e41"'));
    });

    test('Lee desafíos sin comillas', () {
      final c = parseDigestChallenge('realm="IP Camera", qop=auth, nonce="abc", stale=FALSE');
      expect(c['qop'], 'auth');
      expect(c['stale'], 'FALSE');
    });
  });

  group('Dahua', () {
    test('Direcciones del joystick', () {
      expect(dahuaDirection(1, 0), 'Right');
      expect(dahuaDirection(-1, 0), 'Left');
      expect(dahuaDirection(0, 1), 'Up');
      expect(dahuaDirection(0, -1), 'Down');
      expect(dahuaDirection(0.7, 0.7), 'RightUp');
      expect(dahuaDirection(-0.7, 0.7), 'LeftUp');
      expect(dahuaDirection(-0.7, -0.7), 'LeftDown');
      expect(dahuaDirection(0.7, -0.7), 'RightDown');
      expect(dahuaDirection(0.05, 0.05), isNull);
    });

    test('Capacidades PTZ', () {
      final caps = parseDahuaPtzCaps('caps.Pan=true\r\ncaps.Tile=true\r\ncaps.Zoom=true\r\n');
      expect(caps, isNotNull);
      expect(caps!.panTilt, isTrue);
      expect(caps.zoom, isTrue);

      final soloZoom = parseDahuaPtzCaps('caps.Pan=false\ncaps.Tile=false\ncaps.Zoom=true');
      expect(soloZoom!.panTilt, isFalse);
      expect(soloZoom.zoom, isTrue);

      expect(parseDahuaPtzCaps('Error\r\nBad Request!'), isNull);
    });
  });

  group('Hikvision', () {
    test('Capacidades PTZ', () {
      final caps = parseHikvisionPtzCaps(
        '<PTZChanelCap><ContinuousPanTiltSpace></ContinuousPanTiltSpace>'
        '<ContinuousZoomSpace></ContinuousZoomSpace></PTZChanelCap>',
      );
      expect(caps!.panTilt, isTrue);
      expect(caps.zoom, isTrue);

      expect(
        parseHikvisionPtzCaps('<ResponseStatus><statusCode>4</statusCode>'
            '<subStatusCode>notSupport</subStatusCode></ResponseStatus>'),
        isNull,
      );
    });
  });
}
