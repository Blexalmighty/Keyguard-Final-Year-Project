import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

/// System notifications, for the one thing this app needs to say while the
/// owner is not looking at it: *your keys are getting away from you*.
///
/// Deliberately narrow. There is exactly one notification in this app, and it is
/// posted from one place ([BleService._evaluateProximityWarning]). A general
/// notification helper would invite the app to start talking, and an object
/// locator that cries wolf gets its notifications switched off, at which point
/// it cannot warn about anything.
///
/// **Why POST_NOTIFICATIONS is now declared.** It was deliberately left out of
/// the manifest when the app posted nothing — declaring a permission that is
/// never exercised trains the owner to dismiss prompts. This class is the reason
/// it earns its place.
class NotificationService {
  NotificationService();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _ready = false;
  bool _permitted = false;

  /// True once Android has agreed to show notifications from this app.
  bool get permitted => _permitted;

  /// Notifications are Android-only here. iOS is not a target for this project
  /// (the BLE ownership flow depends on Android's pairing dialog), and pretending
  /// otherwise would mean shipping an untested code path.
  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static const String _channelId = 'keyguard_proximity';
  static const int _proximityId = 1001;

  Future<void> init() async {
    if (!supported || _ready) return;

    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );

    try {
      await _plugin.initialize(settings);

      // The channel is created up front rather than on first post. Android
      // caches a channel's importance at creation time and ignores later changes
      // to it, so creating it lazily during an alert risks the first — and most
      // important — warning being filed at whatever importance a default channel
      // happens to have.
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelId,
          'Proximity warnings',
          description:
              'Warns you when your keyholder is moving out of range.',
          importance: Importance.high,
        ),
      );

      _ready = true;
      await _refreshPermission();
    } catch (e) {
      debugPrint('NotificationService: init failed: $e');
    }
  }

  Future<void> _refreshPermission() async {
    try {
      _permitted = await Permission.notification.isGranted;
    } catch (e) {
      debugPrint('NotificationService: permission check failed: $e');
    }
  }

  /// Ask for permission. Safe to call more than once; Android only shows the
  /// system dialog the first time.
  Future<bool> requestPermission() async {
    if (!supported) return false;
    if (!_ready) await init();
    try {
      final status = await Permission.notification.request();
      _permitted = status.isGranted;
    } catch (e) {
      debugPrint('NotificationService: permission request failed: $e');
      _permitted = false;
    }
    return _permitted;
  }

  /// Post the halfway warning.
  ///
  /// Silent by default (`playSound: false`). The keyholder's own buzzer is the
  /// loud part of this system; a phone that also shouts every time its owner
  /// walks to the far side of a room is a phone that gets muted.
  Future<void> showProximityWarning({
    required String deviceName,
    required double distanceMetres,
    required double thresholdMetres,
  }) async {
    if (!supported || !_permitted) return;
    if (!_ready) await init();

    final metres = distanceMetres < 10
        ? distanceMetres.toStringAsFixed(1)
        : distanceMetres.round().toString();

    try {
      await _plugin.show(
        _proximityId,
        '$deviceName is moving away',
        'About $metres m away — halfway to your '
            '${thresholdMetres.toStringAsFixed(thresholdMetres < 10 ? 1 : 0)} m '
            'alert distance.',
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'Proximity warnings',
            channelDescription:
                'Warns you when your keyholder is moving out of range.',
            importance: Importance.high,
            priority: Priority.high,
            playSound: false,
            // Replaced rather than stacked: this is a status, not a log. Ten
            // copies of "moving away" in the shade is noise, not information.
            onlyAlertOnce: true,
            category: AndroidNotificationCategory.status,
          ),
        ),
      );
    } catch (e) {
      debugPrint('NotificationService: show failed: $e');
    }
  }

  Future<void> cancelProximityWarning() async {
    if (!supported) return;
    try {
      await _plugin.cancel(_proximityId);
    } catch (e) {
      debugPrint('NotificationService: cancel failed: $e');
    }
  }
}
