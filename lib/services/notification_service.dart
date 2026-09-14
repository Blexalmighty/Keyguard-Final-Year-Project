import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

/// System notifications: the things this app needs to say while the owner is not
/// looking at it.
///
/// Four messages, and deliberately no more — the keyholder moving away, the
/// keyholder past the distance the owner set, and the link coming up or going
/// down. Each one is posted from exactly one place in [BleService] and replaces
/// its own previous copy rather than stacking, because an object locator that
/// fills the shade gets its notifications switched off, at which point it cannot
/// warn about anything.
///
/// The restraint is load-bearing. Anything that is merely interesting goes in
/// History instead, where the owner can go and look for it; a notification has to
/// earn an interruption.
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

  /// Connect and disconnect notices share a channel, separate from proximity.
  ///
  /// Two channels rather than one because they are different kinds of message
  /// and Android lets the owner say so: a link notice is a fact about state, and
  /// somebody who finds "Connected" in the shade every morning can silence just
  /// that without also silencing the warning that their keys are walking away.
  /// Collapsing both into one channel would make muting the noisy half mute the
  /// important half too.
  static const String _linkChannelId = 'keyguard_link';
  static const int _linkId = 1002;

  /// Posted when the keyholder passes the owner's *configured* alert distance,
  /// as distinct from the halfway warning. Its own id so the two can sit in the
  /// shade together — the halfway notice is advice, this one is the event the
  /// owner actually set a threshold for.
  static const int _outOfRangeId = 1003;

  /// Posted when the keyholder passes the owner's maximum allowance — the
  /// outermost of the three boundaries. Its own id again, so the escalation is
  /// visible in the shade as three rows rather than one row rewriting itself.
  static const int _maxAllowanceId = 1004;

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
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          _linkChannelId,
          'Connection status',
          description:
              'Tells you when your keyholder connects or disconnects.',
          // Deliberately below the proximity channel. A connection notice should
          // appear in the shade without interrupting whatever the owner is
          // doing; only "your keys are getting away" has earned a heads-up.
          importance: Importance.defaultImportance,
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

  /// The keyholder connected or disconnected.
  ///
  /// One notification id for both, so the shade holds the *current* state rather
  /// than a history of every transition. A phone that spends an afternoon at the
  /// edge of range would otherwise stack a dozen alternating notices, which is
  /// the fastest way to teach somebody to swipe this app away without reading it.
  ///
  /// The disconnect case is the one that matters: it is posted at the moment the
  /// owner has most likely walked away from their keys, and unlike the proximity
  /// warning it does not depend on having a distance estimate — there is no link
  /// left to measure one on.
  Future<void> showLinkState({
    required String deviceName,
    required bool connected,
  }) async {
    if (!supported || !_permitted) return;
    if (!_ready) await init();

    try {
      await _plugin.show(
        _linkId,
        connected ? '$deviceName connected' : '$deviceName disconnected',
        connected
            ? 'In range and responding.'
            : 'Out of range or switched off. Find X is looking for it.',
        NotificationDetails(
          android: AndroidNotificationDetails(
            _linkChannelId,
            'Connection status',
            channelDescription:
                'Tells you when your keyholder connects or disconnects.',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            playSound: false,
            onlyAlertOnce: true,
            category: AndroidNotificationCategory.status,
          ),
        ),
      );
    } catch (e) {
      debugPrint('NotificationService: link notice failed: $e');
    }
  }

  /// The keyholder has passed the alert distance the owner configured.
  ///
  /// Distinct from [showProximityWarning], which fires at *half* that distance
  /// as an early nudge. This one is the threshold itself being crossed, so it is
  /// allowed to make a sound: the halfway notice said "you are walking away from
  /// your keys" and was ignored, and this is the last quiet moment before the
  /// link drops entirely.
  Future<void> showOutOfRange({
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
        _outOfRangeId,
        '$deviceName is out of range',
        'About $metres m away, past your '
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
            playSound: true,
            onlyAlertOnce: true,
            category: AndroidNotificationCategory.alarm,
          ),
        ),
      );
    } catch (e) {
      debugPrint('NotificationService: out-of-range notice failed: $e');
    }
  }

  Future<void> cancelOutOfRange() async {
    if (!supported) return;
    try {
      await _plugin.cancel(_outOfRangeId);
    } catch (e) {
      debugPrint('NotificationService: cancel failed: $e');
    }
  }

  /// The keyholder has passed the owner's maximum allowance.
  ///
  /// The third and last boundary. Half the alert distance is advice, the alert
  /// distance is the warning the owner configured, and this is the line they
  /// said should never be crossed — "my keys are further away than I would ever
  /// deliberately leave them". It gets its own id so it does not overwrite the
  /// out-of-range notice, and `fullScreenIntent` so it can get past a locked
  /// screen: by definition the owner is not looking at the phone, since if they
  /// were they would have acted on the two notices before this one.
  Future<void> showMaxAllowanceExceeded({
    required String deviceName,
    required double distanceMetres,
    required double allowanceMetres,
  }) async {
    if (!supported || !_permitted) return;
    if (!_ready) await init();

    final metres = distanceMetres < 10
        ? distanceMetres.toStringAsFixed(1)
        : distanceMetres.round().toString();

    try {
      await _plugin.show(
        _maxAllowanceId,
        '$deviceName has gone too far',
        'About $metres m away — past the '
            '${allowanceMetres.toStringAsFixed(allowanceMetres < 10 ? 1 : 0)} m '
            'limit you set. Its last position has been saved.',
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'Proximity warnings',
            channelDescription:
                'Warns you when your keyholder is moving out of range.',
            importance: Importance.max,
            priority: Priority.max,
            playSound: true,
            // Not `onlyAlertOnce`, unlike the two notices below it. This one
            // fires once per departure anyway — the service latches it — and the
            // whole point is that it should be hard to miss.
            category: AndroidNotificationCategory.alarm,
            fullScreenIntent: true,
          ),
        ),
      );
    } catch (e) {
      debugPrint('NotificationService: max-allowance notice failed: $e');
    }
  }

  Future<void> cancelMaxAllowanceExceeded() async {
    if (!supported) return;
    try {
      await _plugin.cancel(_maxAllowanceId);
    } catch (e) {
      debugPrint('NotificationService: cancel failed: $e');
    }
  }
}
