import 'package:flutter_test/flutter_test.dart';
import 'package:keyguard/services/proximity_model.dart';

/// Tests for the log-distance path loss model that replaced the invented
/// linear formula `1.2 + ((-42 - rssi) * 0.04)`.
///
/// The model is `d = 10 ^ ((txPower - RSSI) / (10 * n))`. The assertions below
/// are derived from that equation rather than from the implementation, so they
/// would catch a sign error or a misplaced factor of 10.
void main() {
  const model = ProximityModel();

  group('distanceFor', () {
    test('reads exactly 1 m at the reference RSSI', () {
      // At RSSI == txPower the exponent is 0, so d = 10^0 = 1.
      final d = model.distanceFor(ProximityModel.defaultTxPower);
      expect(d, isNotNull);
      expect(d!, closeTo(1.0, 0.001));
    });

    test('one decade of path loss gives a ten-fold distance', () {
      // 10 * n dB of extra loss must multiply distance by 10.
      // n = 2.5, so that is 25 dB: -59 → -84 should read ~10 m.
      final near = model.distanceFor(-59)!;
      final far = model.distanceFor(-84)!;
      expect(far / near, closeTo(10.0, 0.01));
    });

    test('stronger signal always means shorter distance (monotonic)', () {
      // The sweep starts at -35 dBm, not higher: at the default calibration
      // d = 0.1 m when RSSI = txPower + 10n = -59 + 25 = -34, so everything
      // above that clamps to the 0.1 m floor and is deliberately flat.
      double? previous;
      for (int rssi = -35; rssi >= -95; rssi--) {
        final d = model.distanceFor(rssi)!;
        if (previous != null) {
          expect(d, greaterThan(previous),
              reason: 'distance must increase as RSSI falls (at $rssi dBm)');
        }
        previous = d;
      }
    });

    test('clamps to the 0.1 m floor rather than reporting millimetres', () {
      // Pressed against the antenna the model implies centimetres, which BLE
      // RSSI cannot resolve. Both of these sit above the -34 dBm floor point.
      expect(model.distanceFor(-30), 0.1);
      expect(model.distanceFor(-10), 0.1);
    });

    test('a plausible indoor reading lands in a plausible range', () {
      // -70 dBm on the default calibration: (-59 - -70) / 25 = 0.44
      // → 10^0.44 ≈ 2.75 m. This is the number the Home screen shows, so it is
      // worth pinning: the old formula returned 1.2 + (28 * 0.04) = 2.32 m from
      // a coefficient with no derivation behind it.
      expect(model.distanceFor(-70)!, closeTo(2.754, 0.01));
    });

    test('clamps at the reporting ceiling instead of claiming kilometres', () {
      // A very weak signal mathematically implies a huge distance, which BLE
      // ranging cannot support. Reporting it would be false confidence.
      expect(model.distanceFor(-120), ProximityModel.maxReportedMetres);
    });

    test('never returns a negative or zero distance', () {
      // RSSI stronger than the 1 m reference (very close, or hard against the
      // antenna) drives the exponent negative but never below the floor.
      expect(model.distanceFor(-20)!, greaterThanOrEqualTo(0.1));
      expect(model.distanceFor(-1)!, greaterThanOrEqualTo(0.1));
    });

    group('rejects the sentinel values flutter_blue_plus uses for "no reading"',
        () {
      test('0 is not "extremely close"', () {
        expect(model.distanceFor(0), isNull);
      });

      test('positive RSSI is impossible', () {
        expect(model.distanceFor(127), isNull);
        expect(model.distanceFor(1), isNull);
      });

      test('absurdly negative RSSI is rejected', () {
        expect(model.distanceFor(-128), isNull);
      });
    });

    test('calibration changes the answer, which is the point of exposing it',
        () {
      const calibrated = ProximityModel(txPower: -65, pathLossExponent: 3.0);
      // (-65 - -70) / 30 = 0.1667 → 10^0.1667 ≈ 1.47 m
      expect(calibrated.distanceFor(-70)!, closeTo(1.468, 0.01));
      expect(calibrated.distanceFor(-70), isNot(model.distanceFor(-70)));
    });
  });

  group('qualityFor', () {
    test('maps the bands the UI copy describes', () {
      expect(ProximityModel.qualityFor(-40), 'Excellent');
      expect(ProximityModel.qualityFor(-55), 'Excellent');
      expect(ProximityModel.qualityFor(-56), 'Good');
      expect(ProximityModel.qualityFor(-70), 'Good');
      expect(ProximityModel.qualityFor(-71), 'Fair');
      expect(ProximityModel.qualityFor(-85), 'Fair');
      expect(ProximityModel.qualityFor(-86), 'Weak');
    });
  });

  group('RssiWindow', () {
    test('starts empty with no median', () {
      final w = RssiWindow();
      expect(w.isEmpty, isTrue);
      expect(w.median, isNull);
      expect(w.latest, isNull);
    });

    test('median rejects a single wild outlier', () {
      final w = RssiWindow();
      // Four steady samples plus one absurd spike. A mean would be dragged to
      // about -76; the median holds at the real signal level.
      for (final r in [-60, -62, -61, -59, -140]) {
        w.add(r);
      }
      // -140 is out of range and never enters the window at all.
      expect(w.length, 4);
      expect(w.median, closeTo(-60.5, 1));
    });

    test('drops the oldest sample past capacity', () {
      final w = RssiWindow(capacity: 3);
      w.add(-90);
      w.add(-70);
      w.add(-60);
      w.add(-50);
      expect(w.length, 3);
      expect(w.latest, -50);
      expect(w.median, -60);
    });

    test('ignores the no-reading sentinels', () {
      final w = RssiWindow();
      w.add(0);
      w.add(127);
      w.add(-200);
      expect(w.isEmpty, isTrue);
    });

    test('barHeights always fills the visualiser without clipping', () {
      final w = RssiWindow();
      // Unfilled slots sit at the 20% floor so the widget does not look broken.
      expect(w.barHeights, List<double>.filled(8, 20.0));

      w.add(-35);
      w.add(-100);
      final bars = w.barHeights;
      expect(bars.length, 8);
      expect(bars.every((b) => b >= 20.0 && b <= 95.0), isTrue);
      // Oldest first: the strong sample precedes the weak one.
      expect(bars[6], greaterThan(bars[7]));
    });

    test('clear resets it', () {
      final w = RssiWindow();
      w.add(-60);
      w.clear();
      expect(w.isEmpty, isTrue);
      expect(w.median, isNull);
    });
  });
}
