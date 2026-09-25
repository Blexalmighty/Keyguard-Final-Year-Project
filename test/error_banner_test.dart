import 'package:flutter_test/flutter_test.dart';
import 'package:keyguard/services/ble_service.dart';

/// The red banner on the Scan tab has one job: say what went wrong. It had no
/// way off the screen, so a message about a connect attempt that failed minutes
/// ago sat there in red while the keyholder was found, connected and working —
/// which is indistinguishable, to the person holding the phone, from an app
/// that is broken right now.
void main() {
  // BleService reaches for shared_preferences and the Bluetooth adapter in its
  // constructor. Neither exists in a unit-test VM; both fail silently by
  // design, which is what lets the service be built here at all.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an error can be dismissed', () async {
    // Deliberately not disposed: the constructor's `_init` is asynchronous and
    // its permission check notifies listeners after it returns, which on a
    // disposed ChangeNotifier is an assertion failure rather than a no-op.
    final ble = BleService();

    // Connecting to an id that was never discovered is the cheapest real error
    // path — it needs no radio, so it works in a test VM.
    await ble.connectDevice('never-scanned');
    expect(ble.lastError, isNotEmpty);

    var notifications = 0;
    ble.addListener(() => notifications++);

    ble.clearError();
    expect(ble.lastError, isEmpty);
    expect(notifications, 1);
  });

  test('dismissing nothing does not redraw the screen', () async {
    // `notifyListeners` on a no-op would rebuild the whole Scan tab every time
    // the widget tree happened to call this.
    final ble = BleService();

    var notifications = 0;
    ble.addListener(() => notifications++);

    ble.clearError();
    expect(notifications, 0);
  });
}
