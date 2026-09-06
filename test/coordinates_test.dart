import 'package:flutter_test/flutter_test.dart';
import 'package:keyguard/utils/coordinate_format.dart';

/// Regression tests for the hemisphere bug.
///
/// The original code formatted every coordinate as `'$lat° N, $lng° W'` with the
/// suffixes hardcoded. That is wrong everywhere east of Greenwich, which
/// includes the entire test site — so every reading the project would ever
/// produce was mislabelled.
void main() {
  group('formatLatitude', () {
    test('northern latitudes get N', () {
      expect(formatLatitude(7.5227), '7.522700° N');
    });

    test('southern latitudes get S and lose the minus sign', () {
      expect(formatLatitude(-33.8688), '33.868800° S');
    });

    test('the equator is not negative', () {
      expect(formatLatitude(0), '0.000000° N');
    });
  });

  group('formatLongitude', () {
    test('Ile-Ife is EAST of Greenwich — this is the original bug', () {
      // Obafemi Awolowo University, Ile-Ife. The old code rendered this as
      // "4.5198° W", placing it in the Atlantic roughly 500 km off Liberia.
      expect(formatLongitude(4.5198), '4.519800° E');
      expect(formatLongitude(4.5198), isNot(contains('W')));
    });

    test('western longitudes get W', () {
      expect(formatLongitude(-122.4148), '122.414800° W');
    });
  });

  group('formatLatLng', () {
    test('formats the OAU campus correctly', () {
      expect(formatLatLng(7.5227, 4.5198), '7.522700° N, 4.519800° E');
    });

    test('handles all four quadrants', () {
      expect(formatLatLng(1, 1), contains('N'));
      expect(formatLatLng(1, 1), contains('E'));
      expect(formatLatLng(-1, -1), contains('S'));
      expect(formatLatLng(-1, -1), contains('W'));
    });
  });

  group('formatCoordinateStrings', () {
    test('parses the text form the keyholder actually sends', () {
      // The wire format is LOC:<lat>,<lng>, so both arrive as strings.
      expect(formatCoordinateStrings('7.5227', '4.5198'),
          '7.522700° N, 4.519800° E');
    });

    test('tolerates surrounding whitespace', () {
      expect(formatCoordinateStrings(' 7.5227 ', ' 4.5198 '),
          '7.522700° N, 4.519800° E');
    });

    test('echoes unparseable input instead of inventing a position', () {
      expect(formatCoordinateStrings('nan-ish', 'rubbish'), 'nan-ish, rubbish');
    });
  });

  group('isPlausibleFix', () {
    test('accepts a real fix', () {
      expect(isPlausibleFix('7.5227', '4.5198'), isTrue);
    });

    test('rejects 0,0 — what a NEO-6M reports before it has a fix', () {
      // "Null island". Without this guard the map pins the keyholder into the
      // Gulf of Guinea and the history log records it as a real sighting.
      expect(isPlausibleFix('0', '0'), isFalse);
      expect(isPlausibleFix('0.0', '0.0'), isFalse);
    });

    test('rejects empty strings', () {
      expect(isPlausibleFix('', ''), isFalse);
    });

    test('rejects out-of-range values', () {
      expect(isPlausibleFix('91', '0'), isFalse);
      expect(isPlausibleFix('0', '181'), isFalse);
      expect(isPlausibleFix('-90.1', '10'), isFalse);
    });

    test('accepts the poles and the antimeridian', () {
      expect(isPlausibleFix('90', '180'), isTrue);
      expect(isPlausibleFix('-90', '-180'), isTrue);
    });
  });
}
