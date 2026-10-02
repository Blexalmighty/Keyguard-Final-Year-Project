/// Keeps the app alive after the owner leaves the screen.
///
/// # Why this exists
///
/// An Android app with no foreground service is a *cached process*: the first
/// thing the system reclaims when memory is short. Leaving the app therefore
/// killed it within seconds on a busy phone, and with it went the BLE link, the
/// RSSI polling behind the proximity warning, and every notification this app
/// exists to post. From the owner's side it looked like the app had closed
/// itself.
///
/// # What it does, and what it deliberately does not
///
/// `flutter_foreground_task` is used here **only to hold the process open**.
/// The package can run a second isolate, and that is the usual reason to reach
/// for it — but a second isolate is exactly what this app must not use. Isolates
/// share no memory, so a `BleService` living in one would be a different object
/// with a different radio handle from the one the UI is bound to. Two of them
/// would fight over the adapter.
///
/// Instead: the foreground service runs in the *same process* as the main
/// isolate. Holding the process open is sufficient on its own — Dart timers,
/// stream subscriptions and the native GATT connection inside flutter_blue_plus
/// all keep running, because nothing ever tore them down. [_KeepAliveHandler] is
/// consequently almost empty, and that emptiness is the design, not an omission.
///
/// There is exactly one exception, and it is the case the rule does not cover.
/// After a reboot Android starts this service from its boot receiver, with no
/// Activity and therefore **no main isolate** — so the reasoning above inverts:
/// there is no other `BleService` to collide with, and an empty handler would
/// mean a phone that restarted overnight simply stopped watching. The handler
/// re-arms the connection itself in that one case. See
/// `_KeepAliveHandler._reconnectAfterSystemStart`.
///
/// # Platform reality
///
/// Android is where this works. iOS has no equivalent — an app there is
/// suspended shortly after backgrounding no matter what, and the only way to be
/// woken is `bluetooth-central` background mode, which is declared in
/// Info.plist and is CoreBluetooth's business, not this file's. Every method
/// here is a no-op off Android rather than an error, so callers need no
/// platform checks.
library;

import 'dart:io' show Platform;
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Entry point for the service's isolate.
///
/// Must be top-level and annotated, because the engine looks it up by symbol
/// name when it spawns the isolate — a closure or a method would not survive
/// tree-shaking in a release build.
@pragma('vm:entry-point')
void startBackgroundCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveHandler());
}

/// Does almost nothing, on purpose — with one exception, after a reboot.
///
/// While the app has been launched, the service's value is the process it keeps
/// alive, not the code it runs: `onRepeatEvent` never fires, the main isolate
/// still holds the one [BleService], and this isolate costs a thread sitting
/// idle. Putting routine BLE work here would mean a second [BleService] on the
/// other side of an isolate boundary, which is the bug this design avoids.
///
/// The exception is a start that came from the *system* rather than from the
/// app — a reboot, or an app update. There is no Activity in that case and so
/// **no main isolate at all**: nothing has constructed a [BleService], nothing
/// is scanning, and an owner who restarted their phone overnight would find the
/// keyholder unwatched until they next opened the app. Since there is no main
/// isolate to collide with, this one can safely re-establish the link itself.
/// See [_reconnectAfterSystemStart].
class _KeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('BackgroundService: process held open (${starter.name})');

    // Started by the app: the main isolate owns the radio and is already
    // connecting. Touching BLE from here would be the two-instance bug.
    if (starter == TaskStarter.developer) return;

    await _reconnectAfterSystemStart();
  }

  /// Re-establishes the keyholder link with no UI and no main isolate.
  ///
  /// Deliberately not a [BleService]: this makes three plugin calls and then
  /// gets out of the way. The moment the owner opens the app, the main isolate
  /// constructs the real service and becomes the single owner of the adapter —
  /// so anything stateful built here would have to be torn down again, and the
  /// window in which both exist is exactly where a two-instance bug would live.
  ///
  /// `autoConnect: true` is what makes this work at boot specifically. A reboot
  /// is the one moment the keyholder is least likely to be in range — the phone
  /// may be charging in another room — so a scan would find nothing and give
  /// up. With autoConnect the request is handed to the Android Bluetooth stack,
  /// which holds it open and completes the connection whenever the keyholder
  /// next appears, at no cost in app-side battery. It is also why no scan is
  /// started here: the stack does the waiting.
  Future<void> _reconnectAfterSystemStart() async {
    if (!BackgroundService.isSupported) return;

    // This isolate was spawned by the engine, not by the app, so the plugin
    // registrant has not run. Without this, every plugin call below throws
    // MissingPluginException.
    DartPluginRegistrant.ensureInitialized();

    try {
      final prefs = await SharedPreferences.getInstance();

      // The owner's own Disconnect is a decision, not a fault to recover from,
      // and it has to outlive a reboot to mean anything. This flag is the whole
      // reason the reconnect is conditional: everything else here is automatic.
      if (prefs.getBool('user_disconnected') ?? false) {
        debugPrint('BackgroundService: boot reconnect skipped — owner '
            'disconnected and has not reconnected since');
        return;
      }

      // Nothing has ever been paired, so there is nothing to go back to.
      final deviceId = prefs.getString('last_device_id');
      if (deviceId == null || deviceId.isEmpty) return;

      // The adapter comes up some seconds after the rest of the phone. Waiting
      // for it rather than reading it once is the difference between
      // reconnecting at boot and reconnecting never.
      if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
        await FlutterBluePlus.adapterState
            .where((s) => s == BluetoothAdapterState.on)
            .first
            .timeout(const Duration(seconds: 30));
      }

      // mtu must be null alongside autoConnect — flutter_blue_plus asserts on
      // it, because the MTU exchange cannot be scheduled for a connection that
      // has not happened yet. BleService raises the MTU once the app is open.
      await BluetoothDevice.fromId(deviceId).connect(
        autoConnect: true,
        mtu: null,
      );
      debugPrint('BackgroundService: boot reconnect armed for $deviceId');
    } catch (e) {
      // A reboot is not a moment to surface anything to anybody: there is no UI
      // to surface it to. The owner opening the app starts a normal scan, which
      // is the recovery path.
      debugPrint('BackgroundService: boot reconnect failed — $e');
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    debugPrint('BackgroundService: released (timeout: $isTimeout)');
  }

  /// Tapping the notification returns to the app rather than launching a second
  /// copy — `launchMode="singleTop"` in the manifest is what makes that reuse
  /// the existing activity.
  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp('/');
  }

  /// The Stop button.
  ///
  /// Stopping the service here is only half the job: this isolate cannot reach
  /// the owner's saved preference, so without the relay the app would start
  /// monitoring again on next launch and the owner's "stop" would have lasted
  /// until they next opened the app. [BackgroundService.onStopRequested]
  /// receives this in the main isolate and turns the setting off for good.
  @override
  void onNotificationButtonPressed(String id) {
    if (id != BackgroundService.stopButtonId) return;
    FlutterForegroundTask.sendDataToMain(BackgroundService.stopButtonId);
    FlutterForegroundTask.stopService();
  }
}

/// Starts, stops and re-labels the foreground service.
///
/// Static because there is exactly one service per process and the plugin's own
/// API is static; an instance would imply you could hold two.
class BackgroundService {
  BackgroundService._();

  /// Identifies this service to the platform. Any stable integer will do; it
  /// only has to stay the same across calls.
  static const int _serviceId = 411;

  /// Notification button that ends the service.
  ///
  /// The owner asked for background running to stop only when *they* stop it,
  /// so there has to be a way to stop it that does not involve hunting through
  /// Settings. An ongoing notification cannot be swiped away, which makes this
  /// button the only honest exit.
  static const String stopButtonId = 'stop_background';

  /// True on platforms where a foreground service is a real thing.
  ///
  /// `kIsWeb` is checked first because `Platform.isAndroid` throws in a browser.
  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  static bool _initialised = false;

  /// Registered by [listenForStopRequest]; held because the plugin removes
  /// listeners by object identity.
  static DataCallback? _stopRequestHandler;

  /// Configures the service. Safe to call more than once.
  ///
  /// Separate from [start] because the plugin requires initialisation before
  /// any other call, including the permission checks the Settings screen makes
  /// while the service is switched off.
  static void configure() {
    if (!isSupported || _initialised) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        // A channel of its own, distinct from the two in NotificationService.
        // Android shows this channel in system settings, and an owner who mutes
        // "FindX is running" must not thereby mute "your keys are moving away".
        channelId: 'findx_background',
        channelName: 'Background monitoring',
        channelDescription:
            'Shown while FindX is watching your keyholder in the background.',
        // LOW: visible in the shade, never a sound or a heads-up banner. This
        // notification is a status line, not an alert — the alerts are the
        // other two channels' job.
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        enableVibration: false,
        playSound: false,
        showWhen: false,
        onlyAlertOnce: true,
      ),
      // iOS gets nothing from this plugin, and showing a notification there
      // would be a promise the platform does not keep.
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // No repeating callback: see [_KeepAliveHandler].
        eventAction: ForegroundTaskEventAction.nothing(),
        // Come back after a reboot. This is what "keeps working like WhatsApp"
        // means in practice: a phone that restarts overnight must not quietly
        // stop watching the keyholder, leaving the owner to discover at noon
        // that the app has been off since 3am.
        //
        // It is not as presumptuous as it looks. The plugin's boot receiver only
        // starts the service if the service was running when the phone went
        // down, so an owner who never switched background monitoring on gets
        // nothing started on their behalf — the switch is still the switch. The
        // permission and the receiver are declared by the plugin's own
        // manifest; RECEIVE_BOOT_COMPLETED is named in ours as well so the
        // reason it is there is written down somewhere.
        autoRunOnBoot: true,
        // ...but an app *update* should not silently stop the monitoring the
        // owner switched on.
        autoRunOnMyPackageReplaced: true,
        // The CPU may sleep between BLE callbacks; the radio wakes it. Holding
        // a wake lock would cost battery for nothing.
        allowWakeLock: false,
        allowWifiLock: false,
        // Swiping the app out of Recents must NOT stop the service. This is the
        // exact behaviour the owner asked for: only the notification's Stop
        // button or the Settings toggle ends it. Not a swipe, and — since
        // autoRunOnBoot above — not a reboot either.
        stopWithTask: false,
      ),
    );
    _initialised = true;
  }

  static Future<bool> get isRunning async {
    if (!isSupported) return false;
    return FlutterForegroundTask.isRunningService;
  }

  /// Whether the owner has granted permission to post the ongoing notification.
  ///
  /// Android 13+ will start a foreground service without it, but the service
  /// then has no visible notification, and the system treats such a service as
  /// a candidate for removal. In practice: no notification permission, no
  /// reliable background running.
  static Future<bool> get hasNotificationPermission async {
    if (!isSupported) return false;
    final status = await FlutterForegroundTask.checkNotificationPermission();
    return status == NotificationPermission.granted;
  }

  static Future<bool> requestNotificationPermission() async {
    if (!isSupported) return false;
    final status = await FlutterForegroundTask.requestNotificationPermission();
    return status == NotificationPermission.granted;
  }

  /// Whether the phone has been told to leave this app alone.
  ///
  /// The one that matters most in practice. Stock Android honours a foreground
  /// service; several large manufacturers — Xiaomi, Oppo, Vivo, Huawei, Samsung
  /// to a lesser degree — run additional battery managers that will kill even a
  /// foreground service unless the app is exempted. On those phones this is the
  /// difference between the feature working and not.
  static Future<bool> get isBatteryOptimisationDisabled async {
    if (!isSupported) return false;
    return FlutterForegroundTask.isIgnoringBatteryOptimizations;
  }

  /// Opens the system dialog asking to be exempted from battery optimisation.
  ///
  /// Returns whether the exemption is in place afterwards. Refusing is a
  /// perfectly reasonable answer, so nothing here treats a false as an error.
  static Future<bool> requestDisableBatteryOptimisation() async {
    if (!isSupported) return false;
    await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    return FlutterForegroundTask.isIgnoringBatteryOptimizations;
  }

  /// Starts the service, or updates its text if it is already running.
  ///
  /// [connected] and [deviceName] only choose the wording. Returns false if the
  /// platform refused — most often because notification permission was denied.
  static Future<bool> start({
    required bool connected,
    required String deviceName,
  }) async {
    if (!isSupported) return false;
    configure();

    final title = _title(connected: connected);
    final text = _text(connected: connected, deviceName: deviceName);

    if (await FlutterForegroundTask.isRunningService) {
      final updated = await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text,
      );
      return updated is ServiceRequestSuccess;
    }

    final result = await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      // `connectedDevice` rather than `dataSync`, and the difference is not
      // cosmetic: from Android 15, a dataSync service is capped at roughly six
      // hours in any 24, after which the system stops it. A key finder that
      // quietly gives up after six hours would be worse than one that never
      // claimed to watch at all. This app genuinely is interacting with a
      // connected device, so the honest type is also the one without the cap.
      serviceTypes: [ForegroundServiceTypes.connectedDevice],
      notificationTitle: title,
      notificationText: text,
      notificationButtons: [
        const NotificationButton(id: stopButtonId, text: 'Stop'),
      ],
      notificationInitialRoute: '/',
      callback: startBackgroundCallback,
    );
    if (result is ServiceRequestFailure) {
      debugPrint('BackgroundService: start refused — ${result.error}');
      return false;
    }
    return true;
  }

  static Future<bool> stop() async {
    if (!isSupported) return false;
    final result = await FlutterForegroundTask.stopService();
    return result is ServiceRequestSuccess;
  }

  /// The main isolate's half of the Stop button.
  ///
  /// [_KeepAliveHandler.onNotificationButtonPressed] runs in the service's
  /// isolate, which can see neither `SettingsStore` nor the live `BleService`.
  /// All it can do is send a token down the port that
  /// `initCommunicationPort()` opened in `main()`; this is what turns that
  /// token into the thing the owner actually meant — the preference off, the
  /// Settings switch off, and no service on next launch.
  ///
  /// The handler is held here rather than returned to the caller because there
  /// is exactly one service per process, so there is never a second listener to
  /// tell apart. Registering twice replaces the first.
  static void listenForStopRequest(VoidCallback onStop) {
    if (!isSupported) return;
    stopListeningForStopRequest();
    void handler(Object data) {
      if (data == stopButtonId) onStop();
    }

    _stopRequestHandler = handler;
    FlutterForegroundTask.addTaskDataCallback(handler);
  }

  static void stopListeningForStopRequest() {
    final handler = _stopRequestHandler;
    if (!isSupported || handler == null) return;
    FlutterForegroundTask.removeTaskDataCallback(handler);
    _stopRequestHandler = null;
  }

  /// Re-labels a running service. A no-op when it is not running, so callers
  /// can fire it on every link change without checking first.
  static Future<void> updateLinkState({
    required bool connected,
    required String deviceName,
  }) async {
    if (!isSupported) return;
    if (!await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: _title(connected: connected),
      notificationText: _text(connected: connected, deviceName: deviceName),
    );
  }

  static String _title({required bool connected}) =>
      connected ? 'Keyholder connected' : 'Watching for your keyholder';

  /// Wording matters here: this notification is permanently in the owner's
  /// shade, so it should say something true and useful rather than "service
  /// running". When disconnected it says what the app is doing about it.
  static String _text({required bool connected, required String deviceName}) =>
      connected
          ? '$deviceName is in range. FindX is watching for it moving away.'
          : 'FindX is looking for $deviceName and will alert you when it '
              'reconnects.';
}
