/// Datos que GitHub inserta al compilar (ver .github/workflows/compilar-apk.yml).
/// Si compilas en tu PC sin estos datos, la app se considera "versión de desarrollo".
class AppConfig {
  /// Número de compilación. Sirve para saber si hay una versión más nueva.
  static const buildNumber = int.fromEnvironment('BUILD_NUMBER');

  /// Versión legible, ej. "0.2.7".
  static const versionName =
      String.fromEnvironment('VERSION_NAME', defaultValue: 'desarrollo');

  /// Repositorio de donde se descargan las actualizaciones.
  static const githubRepo =
      String.fromEnvironment('GITHUB_REPO', defaultValue: 'Nicolas19273/mis-camaras');

  static bool get isDevBuild => buildNumber == 0;
}
