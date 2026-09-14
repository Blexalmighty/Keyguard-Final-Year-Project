import 'package:flutter_test/flutter_test.dart';
import 'package:keyguard/models/alert_distances.dart';
import 'package:keyguard/models/event_model.dart';
import 'package:keyguard/services/phone_location_service.dart';

/// Covers the pure logic behind the switch from the keyholder's GPS module to
/// this phone's receiver: which of two readings wins, whether a refined fix
/// actually replaces the one an event was logged with, and that the new
/// out-of-allowance event type survives storage.
void main() {
  PhoneFix fixAt(
    DateTime when, {
    double accuracy = 10,
    double lat = 6.5244,
    double lng = 3.3792,
  }) =>
      PhoneFix(
        latitude: lat,
        longitude: lng,
        accuracyMetres: accuracy,
        timestamp: when,
      );

  group('PhoneFix', () {
    final noon = DateTime.utc(2026, 1, 1, 12);

    test('formats coordinates to six decimals, not full float precision', () {
      // Six decimals is ~11 cm. The raw double prints 15 significant digits,
      // which would make every log row unreadable and imply a precision the
      // receiver does not have.
      final fix = fixAt(noon, lat: 6.524379999999999, lng: 3.379200000000001);
      expect(fix.latitudeText, '6.524380');
      expect(fix.longitudeText, '3.379200');
    });

    test('is stale only once it is older than the window', () {
      final fix = fixAt(noon);
      expect(
        fix.isStale(const Duration(minutes: 2),
            now: noon.add(const Duration(minutes: 1))),
        isFalse,
      );
      expect(
        fix.isStale(const Duration(minutes: 2),
            now: noon.add(const Duration(minutes: 3))),
        isTrue,
      );
      // Exactly at the boundary is not yet stale: the comparison is `>`, so a
      // reading taken precisely `maxAge` ago is still usable.
      expect(
        fix.isStale(const Duration(minutes: 2),
            now: noon.add(const Duration(minutes: 2))),
        isFalse,
      );
    });

    group('isImprovedBy', () {
      test('an older reading never wins', () {
        final current = fixAt(noon, accuracy: 50);
        final older =
            fixAt(noon.subtract(const Duration(seconds: 30)), accuracy: 5);
        expect(current.isImprovedBy(older), isFalse);
      });

      test('a newer reading of similar accuracy wins', () {
        final current = fixAt(noon, accuracy: 20);
        final newer =
            fixAt(noon.add(const Duration(seconds: 5)), accuracy: 25);
        expect(current.isImprovedBy(newer), isTrue);
      });

      test('a newer but far coarser reading does not replace a good one', () {
        // The case this guard exists for: a 10 m satellite fix should survive a
        // 2 km network estimate that arrives moments later.
        final satellite = fixAt(noon, accuracy: 10);
        final network =
            fixAt(noon.add(const Duration(seconds: 20)), accuracy: 2000);
        expect(satellite.isImprovedBy(network), isFalse);
      });

      test('within a factor of two is treated as the same quality', () {
        // Consecutive samples of equal quality jitter, so anything up to 2x is
        // accepted rather than thrashing between two readings.
        final current = fixAt(noon, accuracy: 10);
        expect(
          current.isImprovedBy(
              fixAt(noon.add(const Duration(seconds: 1)), accuracy: 20)),
          isTrue,
        );
        expect(
          current.isImprovedBy(
              fixAt(noon.add(const Duration(seconds: 1)), accuracy: 21)),
          isFalse,
        );
      });

      test('an unknown accuracy on either side defers to the newer reading', () {
        // Platforms can report 0 or a negative accuracy for "no idea". Treating
        // that as "infinitely precise" would freeze the cache forever.
        final unknown = fixAt(noon, accuracy: 0);
        expect(
          unknown.isImprovedBy(
              fixAt(noon.add(const Duration(seconds: 1)), accuracy: 500)),
          isTrue,
        );
        final known = fixAt(noon, accuracy: 8);
        expect(
          known.isImprovedBy(
              fixAt(noon.add(const Duration(seconds: 1)), accuracy: -1)),
          isTrue,
        );
      });
    });
  });

  group('EventModel.copyWith', () {
    EventModel sample() => EventModel(
          id: 'ev_1',
          type: EventType.disconnected,
          latitude: '6.524380',
          longitude: '3.379200',
          timestamp: DateTime.utc(2026, 1, 1, 12),
          locationName: 'Yaba, Lagos',
          deviceName: 'My keys',
        );

    test('refining the coordinates can drop the stale place name', () {
      // The whole reason `clearLocationName` exists: new coordinates invalidate
      // the name that described the old ones, and `locationName ?? this.x`
      // cannot express "remove it".
      final refined = sample().copyWith(
        latitude: '6.600000',
        longitude: '3.400000',
        clearLocationName: true,
      );
      expect(refined.latitude, '6.600000');
      expect(refined.longitude, '3.400000');
      expect(refined.locationName, isNull);
      // Falls back to the coordinates rather than showing the wrong suburb.
      expect(refined.displayLocation, refined.coordinatesFormatted);
    });

    test('identity and the rest of the row are preserved', () {
      // The refinement pass finds the row by id, so a copy that changed its id
      // would orphan the event it was meant to correct.
      final original = sample();
      final refined = original.copyWith(latitude: '6.600000');
      expect(refined.id, original.id);
      expect(refined.type, original.type);
      expect(refined.timestamp, original.timestamp);
      expect(refined.bleConnected, original.bleConnected);
      expect(refined.deviceName, original.deviceName);
      expect(refined.locationName, original.locationName);
    });
  });

  group('maxAllowanceExceeded', () {
    test('round-trips through storage by name', () {
      final event = EventModel(
        id: 'ev_2',
        type: EventType.maxAllowanceExceeded,
        latitude: '6.524380',
        longitude: '3.379200',
        timestamp: DateTime.utc(2026, 1, 1, 12),
      );
      final restored = EventModel.fromJson(event.toJson());
      expect(restored.type, EventType.maxAllowanceExceeded);
    });

    test('is a security event, so the Security filter shows it', () {
      expect(
        EventModel(
          id: 'ev_3',
          type: EventType.maxAllowanceExceeded,
          latitude: '0',
          longitude: '0',
          timestamp: DateTime.utc(2026, 1, 1, 12),
        ).isSecurityEvent,
        isTrue,
      );
    });
  });

  group('alert distance bounds', () {
    test('the stored default sits inside the slider it is shown on', () {
      // A stored value outside a Slider's min/max is an assertion failure, not a
      // silent clamp — which is why these live in one file rather than being
      // repeated at the widget.
      expect(kDefaultMaxAllowance, greaterThanOrEqualTo(kMinAlertDistance));
      expect(kDefaultMaxAllowance, lessThanOrEqualTo(kMaxAllowanceCeiling));
    });

    test('the allowance ceiling is beyond the alert range it escalates from',
        () {
      expect(kMaxAllowanceCeiling, greaterThan(kMaxAlertDistance));
      expect(kMinAlertDistance, lessThan(kMaxAlertDistance));
    });
  });
}
