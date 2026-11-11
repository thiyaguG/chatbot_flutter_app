/// Build-time settings. Override with `--dart-define`, e.g.
///
///   flutter run --dart-define=API_BASE_URL=http://192.168.1.20:5000
///
/// The default targets a Flask server on the development machine as seen from
/// the Android emulator (10.0.2.2 is the emulator's alias for the host).
class AppConfig {
  const AppConfig({required this.baseUrl, required this.tenantId});

  static const fromEnvironment = AppConfig(
    baseUrl: String.fromEnvironment(
      'API_BASE_URL',
      defaultValue: 'http://10.0.2.2:5000',
    ),
    tenantId: String.fromEnvironment('TENANT_ID', defaultValue: 'digisol'),
  );

  /// Scheme + host (+ port), no trailing slash.
  final String baseUrl;

  /// Backend tenant; every request goes to `/api/<tenantId>/...`.
  final String tenantId;

  Uri endpoint(String path) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$base/api/$tenantId/$path');
  }
}
