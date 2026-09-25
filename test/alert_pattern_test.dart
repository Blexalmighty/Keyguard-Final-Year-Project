import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keyguard/models/alert_pattern.dart';

/// Guards the alert-cadence contract, on both sides of the wire.
///
/// The interesting tests here are the last group: they read the Arduino sketch
/// and assert that its cadence table and the Dart enum still agree. Two files in
/// two languages describing the same rhythms is exactly the kind of pair that
/// drifts silently — someone retunes `STEADY` in the firmware, the app keeps
/// printing the old numbers, and the caption in Settings quietly becomes a lie.
///
/// It reads the `.ino` as text rather than compiling it, which is the only option
/// from a Dart test. That is enough: the failure being guarded against is a
/// mismatch in the literal values, and those are visible in the source.
void main() {
  group('AlertPattern', () {
    test('wire tokens are unique', () {
      final tokens = AlertPattern.values.map((p) => p.wireName).toSet();
      expect(tokens.length, AlertPattern.values.length);
    });

    test('round-trips through its wire token', () {
      for (final pattern in AlertPattern.values) {
        expect(AlertPattern.fromWireName(pattern.wireName), pattern);
      }
    });

    test('unknown and missing tokens fall back rather than throwing', () {
      // A preference written by a newer build, or a pattern a future firmware
      // drops, must not stop the alert from working at all.
      expect(AlertPattern.fromWireName(null), AlertPattern.fallback);
      expect(AlertPattern.fromWireName(''), AlertPattern.fallback);
      expect(AlertPattern.fromWireName('MARIMBA'), AlertPattern.fallback);
    });

    test('the default is the steady beep', () {
      expect(AlertPattern.fallback, AlertPattern.steady);
    });

    test('there are exactly two, and both make a noise', () {
      // The count is asserted, not just the contents: the point of trimming this
      // menu was that it is short, and a seventh option added without thought is
      // how it got long the first time. Silence is the alert-sound switch's job,
      // not a pattern's.
      expect(AlertPattern.values,
          [AlertPattern.continuous, AlertPattern.steady]);
    });

    test('every audible pattern has a non-zero beep', () {
      for (final pattern in AlertPattern.values) {
        expect(pattern.onMs, greaterThan(0), reason: pattern.wireName);
        expect(pattern.burst, greaterThanOrEqualTo(1), reason: pattern.wireName);
      }
    });

    test('a gap between beeps only exists where there are beeps to separate',
        () {
      for (final pattern in AlertPattern.values) {
        if (pattern.burst == 1) {
          expect(pattern.gapMs, 0, reason: pattern.wireName);
        } else {
          expect(pattern.gapMs, greaterThan(0), reason: pattern.wireName);
        }
      }
    });

    test('continuous is the only pattern with no silence at all', () {
      for (final pattern in AlertPattern.values) {
        final silentSomewhere = pattern.pauseMs > 0 || pattern.gapMs > 0;
        expect(silentSomewhere, pattern != AlertPattern.continuous,
            reason: pattern.wireName);
      }
    });

    test('a burst is followed by a pause longer than its internal gap', () {
      // Otherwise "three quick beeps, then a pause" is audibly just six evenly
      // spaced beeps, and the option stops meaning anything.
      for (final pattern in AlertPattern.values.where((p) => p.burst > 1)) {
        expect(pattern.pauseMs, greaterThan(pattern.gapMs),
            reason: pattern.wireName);
      }
    });

    test('the caption is derived from the timings, so it cannot drift', () {
      expect(AlertPattern.continuous.cadence, 'unbroken');
      expect(AlertPattern.steady.cadence, '250ms, 250ms gap');
    });
  });

  group('firmware parity', () {
    /// Parsed rows of the `ALERT_CADENCES[]` table in the sketch.
    late List<_FirmwareCadence> firmware;

    setUpAll(() {
      final sketch =
          File('firmware/keyguard_esp32c3/keyguard_esp32c3.ino').readAsStringSync();

      // Matches a row of the form:
      //   { "STEADY", 250UL, 0UL, 1, 250UL },
      final row = RegExp(
        r'\{\s*"([A-Z]+)"\s*,\s*(\d+)UL\s*,\s*(\d+)UL\s*,\s*(\d+)\s*,\s*(\d+)UL\s*\}',
      );

      firmware = row
          .allMatches(sketch)
          .map((m) => _FirmwareCadence(
                token: m.group(1)!,
                onMs: int.parse(m.group(2)!),
                gapMs: int.parse(m.group(3)!),
                burst: int.parse(m.group(4)!),
                pauseMs: int.parse(m.group(5)!),
              ))
          .toList();
    });

    test('the sketch table was found and parsed', () {
      // If this fails, the table was reformatted and the regex above needs
      // updating — not that the contract is broken. Kept as its own test so the
      // distinction is obvious from the failure message.
      expect(firmware, isNotEmpty,
          reason: 'ALERT_CADENCES[] not found in the sketch');
    });

    test('both sides define the same set of tokens, in the same order', () {
      // Order matters: the firmware persists the table INDEX to NVS, so
      // reordering one side would repoint a saved preference at a different
      // rhythm without anything else changing.
      expect(
        firmware.map((f) => f.token).toList(),
        AlertPattern.values.map((p) => p.wireName).toList(),
      );
    });

    test('every timing matches', () {
      for (var i = 0; i < AlertPattern.values.length; i++) {
        final dart = AlertPattern.values[i];
        final fw = firmware[i];
        expect(fw.onMs, dart.onMs, reason: '${dart.wireName} onMs');
        expect(fw.gapMs, dart.gapMs, reason: '${dart.wireName} gapMs');
        expect(fw.burst, dart.burst, reason: '${dart.wireName} burst');
        expect(fw.pauseMs, dart.pauseMs, reason: '${dart.wireName} pauseMs');
      }
    });

    test("the firmware's stored default is the app's fallback", () {
      // The sketch reads `prefs.getUChar("cadence", 1)`, so index 1 has to be the
      // pattern the app treats as the default, or a fresh device and a fresh
      // install disagree from the first boot.
      final defaultIndex =
          AlertPattern.values.indexOf(AlertPattern.fallback);
      expect(defaultIndex, 1);
      expect(firmware[1].token, AlertPattern.fallback.wireName);
    });
  });
}

class _FirmwareCadence {
  const _FirmwareCadence({
    required this.token,
    required this.onMs,
    required this.gapMs,
    required this.burst,
    required this.pauseMs,
  });

  final String token;
  final int onMs;
  final int gapMs;
  final int burst;
  final int pauseMs;
}
