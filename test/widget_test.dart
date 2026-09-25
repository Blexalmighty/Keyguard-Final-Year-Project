import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keyguard/main.dart';
import 'package:keyguard/models/event_model.dart';
import 'package:keyguard/models/history_retention.dart';

void main() {
  // BleService reaches for shared_preferences and the Bluetooth adapter on
  // construction. Neither exists in a unit-test VM, so those calls fail
  // silently by design — the app has to boot without them.
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('boots and reports itself Disconnected', (tester) async {
    // FindXProviders rather than a hand-rolled provider tree: when the app
    // gained PairingService, a local copy of the graph here broke both widget
    // tests with ProviderNotFoundException. Sharing the real one means the test
    // cannot drift from production wiring again.
    await tester.pumpWidget(const FindXProviders(child: FindXApp()));
    await tester.pump();

    // 'FindX' is the app; the hardware is 'FindMe'. The wordmark also
    // dropped the transport when the Bluetooth-vs-Wi-Fi split was removed: the
    // app no longer presents a radio as something the user chooses, so naming
    // one in the title was the last place that framing survived.
    expect(find.text('FindX'), findsWidgets);

    // The previous version of this test asserted findsWidgets on 'Connected'.
    // It passed only because BleService set `_isConnected = true` in its field
    // initialiser, so the app claimed a live link to hardware that did not
    // exist. Asserting the opposite is the whole point.
    expect(find.text('Disconnected'), findsWidgets);
    expect(find.text('Connected'), findsNothing);
  });

  testWidgets('gives the screen body almost all of the height', (tester) async {
    // This test exists because the whole suite passed while the app rendered as
    // four blank tabs with a floating navigation strip.
    //
    // `find.text` walks the element tree, so it finds a widget whether or not
    // that widget has any size on screen. The nav bar was wrapped in `Center`,
    // which happily expanded to the full screen height inside the loose
    // constraints Scaffold gives its bottom bar, squeezing the body to nothing.
    // Every text assertion still passed. Only measured geometry catches it.
    await tester.pumpWidget(const FindXProviders(child: FindXApp()));
    await tester.pump();

    final screen = tester.getSize(find.byType(MaterialApp));
    final navBar = tester.getRect(find.byType(NavigationBar));

    // Position, not size. `NavigationBar` is 64 px tall either way — it was the
    // `Center` *around* it that swelled to fill the loose constraints, floating
    // the strip in the middle of the screen and leaving the body no room. So the
    // assertion has to be about where the bar sits, not how tall it is.
    expect(
      navBar.bottom,
      closeTo(screen.height, 1.0),
      reason: 'the navigation bar must sit against the bottom of the screen',
    );

    // And the body must actually get the rest. The Home screen's own header is
    // the first thing in it, so if that is not above the bar, the body was
    // squeezed to nothing.
    expect(tester.getRect(find.text('FindX').first).top,
        lessThan(navBar.top));
  });

  testWidgets('never simulates a device, in any state', (tester) async {
    await tester.pumpWidget(const FindXProviders(child: FindXApp()));
    await tester.pump();

    // Demo mode is gone, not merely defaulted off. It fed invented battery
    // levels, distances and events through the same fields as the real ones, so
    // the only way to know whether a reading was true was to remember which
    // switch was flipped. This guards the removal rather than the default: if
    // the banner can ever appear again, the switch has come back with it.
    expect(
      find.textContaining('DEMO MODE'),
      findsNothing,
      reason: 'nothing in FindX may present simulated readings as real ones',
    );
  });

  testWidgets('owns no keyholder on a fresh install', (tester) async {
    // The ownership card must not imply a paired device before anything is
    // paired — the class of false claim this rewrite exists to remove.
    await tester.pumpWidget(const FindXProviders(child: FindXApp()));
    await tester.pump();

    expect(find.textContaining('YOUR DEVICE'), findsNothing);
    expect(find.textContaining('OWNER VERIFIED'), findsNothing);
  });

  group('EventModel', () {
    test('survives a JSON round trip', () {
      final original = EventModel(
        id: 'e1',
        type: EventType.intruderBlocked,
        latitude: '7.5227',
        longitude: '4.5198',
        timestamp: DateTime.utc(2026, 9, 1, 14, 30),
        bleConnected: true,
        locationName: 'OAU Campus',
      );

      final restored = EventModel.fromJson(original.toJson());

      expect(restored.id, original.id);
      expect(restored.type, EventType.intruderBlocked);
      expect(restored.latitude, '7.5227');
      expect(restored.longitude, '4.5198');
      expect(restored.timestamp.toUtc(), original.timestamp.toUtc());
      expect(restored.bleConnected, isTrue);
      expect(restored.locationName, 'OAU Campus');
    });

    test('security events are flagged so history can highlight them', () {
      EventModel at(EventType type) => EventModel(
            id: 'x',
            type: type,
            latitude: '',
            longitude: '',
            timestamp: DateTime.utc(2026, 9, 1),
          );

      expect(at(EventType.intruderBlocked).isSecurityEvent, isTrue);
      expect(at(EventType.ownershipClaimed).isSecurityEvent, isTrue);
      expect(at(EventType.ownershipReleased).isSecurityEvent, isTrue);

      // Pings and disconnects are security events too. A ping is the owner
      // commanding the hardware and a disconnect is the moment the lock stops
      // being enforceable from this phone, so both belong in the audit trail
      // even though neither is a failure.
      expect(at(EventType.phonePingedKey).isSecurityEvent, isTrue);
      expect(at(EventType.keyPingedPhone).isSecurityEvent, isTrue);
      expect(at(EventType.disconnected).isSecurityEvent, isTrue);

      // Connecting stays out: it is the normal, expected state of the system,
      // and a Security tab that lists every successful connection is a Security
      // tab nobody reads.
      expect(at(EventType.connected).isSecurityEvent, isFalse);
    });

    test('reports no GPS fix rather than inventing a place name', () {
      // The old model defaulted locationName to 'San Francisco, CA', so an
      // event logged in Ile-Ife with no fix at all was labelled California.
      final noFix = EventModel(
        id: 'x',
        type: EventType.disconnected,
        latitude: '',
        longitude: '',
        timestamp: DateTime.utc(2026, 9, 1),
      );

      expect(noFix.hasLocation, isFalse);
      expect(noFix.coordinatesFormatted, 'No GPS fix');
      expect(noFix.displayLocation, 'No GPS fix');
      expect(noFix.displayLocation, isNot(contains('San Francisco')));
    });

    test('formats a real fix with the correct hemispheres', () {
      final fix = EventModel(
        id: 'x',
        type: EventType.connected,
        latitude: '7.5227',
        longitude: '4.5198',
        timestamp: DateTime.utc(2026, 9, 1),
      );

      expect(fix.hasLocation, isTrue);
      expect(fix.coordinatesFormatted, contains('N'));
      expect(fix.coordinatesFormatted, contains('E'));
      expect(fix.coordinatesFormatted, isNot(contains('W')));
    });
  });

  group('HistoryRetention', () {
    test('defaults to keeping everything', () {
      // The default matters more than the rest of this file: it decides whether
      // an app update silently deletes history the owner never agreed to lose.
      expect(HistoryRetention.fromStorage(null), HistoryRetention.forever);
      expect(HistoryRetention.fromStorage(''), HistoryRetention.forever);
      expect(
        HistoryRetention.fromStorage('something_removed_later'),
        HistoryRetention.forever,
      );
    });

    test('round-trips through storage by name, not index', () {
      for (final r in HistoryRetention.values) {
        expect(HistoryRetention.fromStorage(r.storageValue), r);
      }
    });

    test('cutoff is null only when nothing should be deleted', () {
      final now = DateTime.utc(2026, 9, 12);

      expect(HistoryRetention.forever.cutoffFrom(now), isNull);
      expect(HistoryRetention.forever.prunes, isFalse);

      expect(HistoryRetention.week.cutoffFrom(now), DateTime.utc(2026, 9, 5));
      expect(
        HistoryRetention.fortnight.cutoffFrom(now),
        DateTime.utc(2026, 8, 29),
      );
      expect(HistoryRetention.month.cutoffFrom(now), DateTime.utc(2026, 8, 13));
    });
  });
}
