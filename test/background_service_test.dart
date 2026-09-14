import 'package:flutter_test/flutter_test.dart';
import 'package:keyguard/services/background_service.dart';
import 'package:keyguard/services/ble_service.dart';

/// `BackgroundService` promises, in its own doc comment, that every method is a
/// no-op off Android "so callers need no platform checks". That promise is what
/// lets `BleService` call into it unguarded from `_loadSettings`, from both
/// link-state transitions and from `dispose`.
///
/// These tests run on the desktop VM, where [BackgroundService.isSupported] is
/// false — which is exactly the platform the promise is about. A regression here
/// would not be a failed background service; it would be a `MissingPluginException`
/// thrown out of `dispose()` on every developer's machine and every CI run.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every entry point is a no-op where there is no foreground service', () async {
    expect(BackgroundService.isSupported, isFalse,
        reason: 'these tests are only meaningful off Android');

    // None of these may throw, and none may claim to have done anything.
    expect(await BackgroundService.isRunning, isFalse);
    expect(await BackgroundService.hasNotificationPermission, isFalse);
    expect(await BackgroundService.requestNotificationPermission(), isFalse);
    expect(await BackgroundService.isBatteryOptimisationDisabled, isFalse);
    expect(await BackgroundService.requestDisableBatteryOptimisation(), isFalse);
    expect(
      await BackgroundService.start(connected: true, deviceName: 'Find Me'),
      isFalse,
    );
    expect(await BackgroundService.stop(), isFalse);

    // These return void, so the assertion is simply that they survive.
    BackgroundService.configure();
    await BackgroundService.updateLinkState(
        connected: false, deviceName: 'Find Me');
    BackgroundService.listenForStopRequest(() {});
    BackgroundService.stopListeningForStopRequest();
  });

  test('the settings switch does not lie about an unsupported platform', () async {
    // Deliberately not disposed — see error_banner_test.dart for why.
    final ble = BleService();

    expect(ble.backgroundRunningSupported, isFalse);

    // Turning it off where it was never running must not report success, or the
    // Settings screen would render a switch whose position means nothing. The
    // stored default is true, and it stays true precisely because nothing on
    // this platform can act on it.
    await ble.setBackgroundRunningEnabled(false);
    expect(ble.backgroundRunningEnabled, isTrue);
  });
}
