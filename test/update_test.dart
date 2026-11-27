import 'package:flutter_test/flutter_test.dart';
import 'package:mis_camaras/services/update_service.dart';

/// Pruebas de la lectura de versiones publicadas en GitHub.
void main() {
  test('Lee número de compilación y APK de la última versión', () {
    final info = UpdateService.parseRelease({
      'tag_name': 'v0.2.15',
      'body': 'Notas',
      'assets': [
        {'name': 'otro.txt', 'browser_download_url': 'https://x/otro.txt', 'size': 1},
        {
          'name': 'MisCamaras-v0.2.15.apk',
          'browser_download_url': 'https://x/MisCamaras-v0.2.15.apk',
          'size': 90000000,
        },
      ],
    });
    expect(info, isNotNull);
    expect(info!.buildNumber, 15);
    expect(info.version, '0.2.15');
    expect(info.apkUrl, 'https://x/MisCamaras-v0.2.15.apk');
    expect(info.notes, 'Notas');
  });

  test('Sin APK no hay actualización', () {
    final info = UpdateService.parseRelease({
      'tag_name': 'v0.2.3',
      'assets': <dynamic>[],
    });
    expect(info, isNull);
  });

  test('La descarga recuerda la versión si la app se cierra', () {
    const info = ReleaseInfo(
      buildNumber: 9,
      version: '0.3.9',
      apkUrl: 'https://x/a.apk',
      apkSize: 1234,
      notes: 'Notas',
    );
    final back = ReleaseInfo.fromMeta(info.toMeta(), info.apkUrl);
    expect(back!.buildNumber, 9);
    expect(back.version, '0.3.9');
    expect(back.apkSize, 1234);
    expect(ReleaseInfo.fromMeta('basura', 'u'), isNull);
  });
}
