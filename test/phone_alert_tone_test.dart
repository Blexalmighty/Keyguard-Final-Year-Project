import 'package:flutter_test/flutter_test.dart';
import 'package:keyguard/models/phone_alert_tone.dart';

/// Tests for the phone-side ringtone choice.
///
/// The interesting cases here are all about *persistence* and *audibility*, not
/// about playback — the audio itself needs a real device. What can be checked
/// without hardware is that a stored choice survives, and that the promise each
/// option makes about silent mode is the one the service will act on.
void main() {
  group('wire names', () {
    test('are unique across every tone', () {
      final names = PhoneAlertTone.values.map((t) => t.wireName).toSet();
      expect(names.length, PhoneAlertTone.values.length,
          reason: 'Two tones sharing a token means one of them can never be '
              'read back from settings.');
    });

    test('are non-empty and contain no separator characters', () {
      for (final tone in PhoneAlertTone.values) {
        expect(tone.wireName, isNotEmpty);
        // `:` and `|` are field separators in the BLE protocol. These tokens are
        // only ever stored locally today, but a token that cannot survive being
        // put on the wire is a trap for the next person to need it there.
        expect(tone.wireName.contains(':'), isFalse);
        expect(tone.wireName.contains('|'), isFalse);
      }
    });

    test('round-trip through fromWireName', () {
      for (final tone in PhoneAlertTone.values) {
        expect(PhoneAlertTone.fromWireName(tone.wireName), tone);
      }
    });
  });

  group('fromWireName fallback', () {
    test('null becomes the fallback tone', () {
      // The first-launch case: nothing stored yet.
      expect(PhoneAlertTone.fromWireName(null), PhoneAlertTone.fallback);
    });

    test('an unrecognised token becomes the fallback tone', () {
      // The downgrade case: a build that knew about a tone this one does not.
      expect(PhoneAlertTone.fromWireName('SOME_FUTURE_TONE'),
          PhoneAlertTone.fallback);
      expect(PhoneAlertTone.fromWireName(''), PhoneAlertTone.fallback);
    });

    test('matching is exact, not case-insensitive or partial', () {
      expect(PhoneAlertTone.fromWireName('ringtone'), PhoneAlertTone.fallback);
      expect(PhoneAlertTone.fromWireName('RINGTONE_2'), PhoneAlertTone.fallback);
    });

    test('the fallback needs no file', () {
      // Load-bearing. `_resolveTone` falls back to this when a custom file has
      // vanished; if the fallback itself needed a file, that path would recurse
      // into playing nothing — the exact failure it exists to prevent.
      expect(PhoneAlertTone.fallback.needsFile, isFalse);
    });

    test('the fallback is audible in silent mode', () {
      expect(PhoneAlertTone.fallback.overridesSilentMode, isTrue);
    });
  });

  group('needsFile', () {
    test('exactly one tone requires a file', () {
      final withFile =
          PhoneAlertTone.values.where((t) => t.needsFile).toList();
      expect(withFile, [PhoneAlertTone.customFile]);
    });
  });

  group('overridesSilentMode', () {
    test('only the notification chime stays quiet when silenced', () {
      // Encodes the deliberate asymmetry: the loud options are alarms so a
      // silenced phone can still be found, and the discreet option is honest
      // about being discreet.
      final quiet = PhoneAlertTone.values
          .where((t) => !t.overridesSilentMode)
          .toList();
      expect(quiet, [PhoneAlertTone.systemNotification]);
    });

    test('the chime describes its own limitation', () {
      // If the copy ever stops saying so, the setting becomes a silent trap for
      // the one user who most needed to hear the phone.
      expect(PhoneAlertTone.systemNotification.description.toLowerCase(),
          contains('quiet'));
    });
  });

  group('presentation', () {
    test('every tone has a label and a description', () {
      for (final tone in PhoneAlertTone.values) {
        expect(tone.label, isNotEmpty, reason: '${tone.name} has no label');
        expect(tone.description, isNotEmpty,
            reason: '${tone.name} has no description');
      }
    });

    test('labels are unique', () {
      final labels = PhoneAlertTone.values.map((t) => t.label).toSet();
      expect(labels.length, PhoneAlertTone.values.length);
    });
  });
}
