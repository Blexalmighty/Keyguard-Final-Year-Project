import 'dart:math';

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

  // ===========================================================================
  // Automatic calibration
  // ===========================================================================
  //
  // The assertions here are derived from the model equation, not from the
  // implementation: `txPower = RSSI + 10*n*log10(d)` and, for a pair,
  // `n = (rssiFar - rssiNear) / (10 * log10(dNear/dFar))`. A sign error or a
  // misplaced factor of ten would fail them.

  group('RssiCalibrator', () {
    RssiCalibrator feed(List<int> samples, {double metres = 1.0}) {
      final c = RssiCalibrator(metres: metres);
      for (final s in samples) {
        c.add(s);
      }
      return c;
    }

    test('refuses to finish below the minimum sample count', () {
      final c = feed(List<int>.filled(RssiCalibrator.minimumSamples - 1, -60));
      expect(c.hasEnough, isFalse);
      expect(c.finish(), isNull);
    });

    test('takes the median, not the mean', () {
      // Eleven readings at -60 and one wild multipath outlier. The mean is
      // dragged to about -62; the median does not move at all. This is the
      // entire justification for the scheme.
      final c = feed(<int>[-60, -60, -60, -60, -60, -60, -60, -60, -60, -60, -60, -85]);
      final sample = c.finish()!;
      expect(sample.medianDbm, -60);
      final mean = (-60 * 11 + -85) / 12;
      expect(mean, lessThan(-61));
    });

    test('rejects the platform sentinels instead of averaging them in', () {
      final c = feed(<int>[-60, -61, -59, -60, -60, -61, -59, -60, 0, 127, -200]);
      final sample = c.finish()!;
      expect(sample.sampleCount, 8);
      expect(sample.medianDbm, closeTo(-60, 1));
    });

    test('reports the spread honestly and flags a noisy room', () {
      final clean = feed(List<int>.filled(12, -60))..add(-62);
      expect(clean.finish()!.isNoisy, isFalse);

      final noisy = feed(<int>[-50, -52, -54, -56, -58, -60, -62, -64, -70, -72]);
      final sample = noisy.finish()!;
      expect(sample.spreadDbm, 22);
      expect(sample.isNoisy, isTrue);
    });

    test('progress runs 0..1 and completes at the target', () {
      final c = RssiCalibrator(metres: 1.0);
      expect(c.progress, 0.0);
      for (int i = 0; i < RssiCalibrator.targetSamples; i++) {
        c.add(-60);
      }
      expect(c.progress, 1.0);
      expect(c.isComplete, isTrue);
      // Extra samples cannot push progress past 1.
      c.add(-60);
      expect(c.progress, 1.0);
    });
  });

  group('txPowerFrom', () {
    RssiCalibrationSample sampleAt(double metres, int median) =>
        RssiCalibrationSample(
            metres: metres, medianDbm: median, spreadDbm: 2, sampleCount: 24);

    test('at one metre the reference is the measurement itself', () {
      // log10(1) == 0, so the correction term vanishes. This is the manual
      // procedure, which is what makes the automatic one a drop-in replacement.
      expect(model.txPowerFrom(sampleAt(1.0, -64)), -64);
    });

    test('corrects a measurement taken farther away', () {
      // n = 2.5, d = 3 m: txPower = -70 + 25*log10(3) = -70 + 11.9 = -58.1
      expect(model.txPowerFrom(sampleAt(3.0, -70)), -58);
    });

    test('corrects a measurement taken closer than a metre', () {
      // d = 0.5 m: txPower = -50 + 25*log10(0.5) = -50 - 7.5 = -57.5
      expect(model.txPowerFrom(sampleAt(0.5, -50)), -58);
    });

    test('round-trips: the calibrated model reads back the stated distance', () {
      for (final metres in <double>[0.5, 1.0, 3.0]) {
        const measured = -67;
        final calibrated = ProximityModel(
          txPower: model.txPowerFrom(sampleAt(metres, measured)),
          pathLossExponent: model.pathLossExponent,
        );
        // Within 10% — the rounding of txPower to a whole dBm is the only error.
        expect(calibrated.distanceFor(measured)!, closeTo(metres, metres * 0.1));
      }
    });

    test('clamps to the physical bounds rather than emitting nonsense', () {
      expect(model.txPowerFrom(sampleAt(1.0, -120)), ProximityModel.minTxPower);
      expect(model.txPowerFrom(sampleAt(1.0, -20)), ProximityModel.maxTxPower);
    });
  });

  group('solveFromPair', () {
    RssiCalibrationSample at(double metres, int median) => RssiCalibrationSample(
        metres: metres, medianDbm: median, spreadDbm: 2, sampleCount: 24);

    test('recovers the constants it was given', () {
      // Synthesise two readings from a known model, then check the solver finds
      // it again. n = 3.0, txPower = -62.
      const truth = ProximityModel(txPower: -62, pathLossExponent: 3.0);
      int rssiAt(double d) =>
          (truth.txPower - 10 * truth.pathLossExponent * (log(d) / ln10))
              .round();

      final solved = ProximityModel.solveFromPair(
          at(1.0, rssiAt(1.0)), at(4.0, rssiAt(4.0)))!;
      expect(solved.pathLossExponent, closeTo(3.0, 0.1));
      expect(solved.txPower, closeTo(-62, 1));
    });

    test('order of the pair does not matter', () {
      final a = at(1.0, -60);
      final b = at(4.0, -75);
      final forward = ProximityModel.solveFromPair(a, b)!;
      final backward = ProximityModel.solveFromPair(b, a)!;
      expect(forward.txPower, backward.txPower);
      expect(forward.pathLossExponent, backward.pathLossExponent);
    });

    test('refuses a pair taken too close together', () {
      // 1 m and 1.5 m is under the 2x ratio: at any plausible exponent the
      // difference is smaller than the spread of a single measurement.
      expect(ProximityModel.solveFromPair(at(1.0, -60), at(1.5, -64)), isNull);
    });

    test('refuses a pair where the farther reading was stronger', () {
      // Multipath can genuinely do this. The solved exponent would be negative,
      // which is not a radio. Null means "keep the previous calibration".
      expect(ProximityModel.solveFromPair(at(1.0, -70), at(4.0, -60)), isNull);
    });

    test('refuses an implausibly steep or shallow fit', () {
      // 40 dB over a 4x ratio implies n = 6.6, beyond any real environment.
      expect(ProximityModel.solveFromPair(at(1.0, -50), at(4.0, -90)), isNull);
      // 2 dB over a 4x ratio implies n = 0.33, below free space.
      expect(ProximityModel.solveFromPair(at(1.0, -60), at(4.0, -62)), isNull);
    });

    test('rejects a zero or negative distance', () {
      expect(ProximityModel.solveFromPair(at(0.0, -60), at(4.0, -75)), isNull);
    });

    test('the solved model reads back both stated distances', () {
      final near = at(1.0, -61);
      final far = at(4.0, -79);
      final solved = ProximityModel.solveFromPair(near, far)!;
      expect(solved.distanceFor(near.medianDbm)!, closeTo(1.0, 0.15));
      expect(solved.distanceFor(far.medianDbm)!, closeTo(4.0, 0.6));
    });
  });
}
