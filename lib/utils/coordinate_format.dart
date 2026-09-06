/// Hemisphere-correct formatting for GPS coordinates.
///
/// The previous code hardcoded the hemisphere suffixes:
///
/// ```dart
/// String get coordinatesFormatted => '$_lastLat° N, $_lastLng° W';
/// ```
///
/// That happened to suit the placeholder San Francisco coordinates it shipped
/// with, but it is wrong everywhere east of Greenwich. Ile-Ife sits at roughly
/// 7.52 N, 4.52 **E**, so every real reading from this project rendered with the
/// wrong hemisphere. The suffix has to come from the sign of the value.
library;

/// Decimal places to render. GPS from a NEO-6M is good to about 6 decimal
/// places (~0.1 m); showing more implies precision that isn't there.
const int _decimalPlaces = 6;

/// Formats a signed latitude as e.g. `7.522700° N` / `33.868800° S`.
String formatLatitude(double latitude) {
  final hemisphere = latitude.isNegative ? 'S' : 'N';
  return '${latitude.abs().toStringAsFixed(_decimalPlaces)}° $hemisphere';
}

/// Formats a signed longitude as e.g. `4.519800° E` / `122.414800° W`.
String formatLongitude(double longitude) {
  final hemisphere = longitude.isNegative ? 'W' : 'E';
  return '${longitude.abs().toStringAsFixed(_decimalPlaces)}° $hemisphere';
}

/// Formats a coordinate pair as e.g. `7.522700° N, 4.519800° E`.
String formatLatLng(double latitude, double longitude) =>
    '${formatLatitude(latitude)}, ${formatLongitude(longitude)}';

/// Formats coordinates that arrived over BLE as strings.
///
/// The keyholder sends `LOC:<lat>,<lng>` as text, so the values reach us
/// unparsed. If either side cannot be read as a number the raw text is echoed
/// back rather than guessed at — a visible `LOC:` parse problem is much easier
/// to diagnose than a confidently wrong coordinate.
String formatCoordinateStrings(String latitude, String longitude) {
  final lat = double.tryParse(latitude.trim());
  final lng = double.tryParse(longitude.trim());
  if (lat == null || lng == null) return '$latitude, $longitude';
  return formatLatLng(lat, lng);
}

/// True if the pair parses and falls inside valid GPS ranges.
///
/// A NEO-6M with no fix reports 0,0 — the "null island" off West Africa. That
/// parses fine but is never a real position, so it is rejected here to stop the
/// map from confidently pinning the keyholder into the Atlantic.
bool isPlausibleFix(String latitude, String longitude) {
  final lat = double.tryParse(latitude.trim());
  final lng = double.tryParse(longitude.trim());
  if (lat == null || lng == null) return false;
  if (lat.abs() > 90 || lng.abs() > 180) return false;
  if (lat == 0 && lng == 0) return false;
  return true;
}
