import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// One position reading from the phone's own receiver.
///
/// Coordinates are carried as strings because that is what the rest of the app
/// already speaks: `EventModel` stores `latitude`/`longitude` as text (they used
/// to arrive that way inside a `LOC:` frame) and `formatCoordinateStrings`
/// parses them back when it needs numbers. Converting here rather than at every
/// call site keeps one representation in the log.
@immutable
class PhoneFix {
  const PhoneFix({
    required this.latitude,
    required this.longitude,
    required this.accuracyMetres,
    required this.timestamp,
  });

  final double latitude;
  final double longitude;

  /// Radius the platform claims the true position lies within, in metres.
  ///
  /// Kept so a coarse network fix can be told apart from a satellite one. A
  /// cached reading good to 2 km is still worth stamping on an event — it names
  /// the right town — but it should not overwrite a later reading good to 8 m.
  final double accuracyMetres;

  final DateTime timestamp;

  String get latitudeText => latitude.toStringAsFixed(6);
  String get longitudeText => longitude.toStringAsFixed(6);

  /// True when this reading is older than [maxAge].
  bool isStale(Duration maxAge, {DateTime? now}) =>
      (now ?? DateTime.now()).difference(timestamp) > maxAge;

  /// True when [other] is a better reading than this one.
  ///
  /// Newer wins, except when the newer reading is markedly less accurate — a
  /// freshly-delivered 2 km network estimate should not replace a 10 m satellite
  /// fix taken twenty seconds ago. "Markedly" is a factor of two rather than any
  /// difference, because accuracy figures jitter between consecutive samples of
  /// the same quality.
  bool isImprovedBy(PhoneFix other) {
    if (other.timestamp.isBefore(timestamp)) return false;
    if (accuracyMetres <= 0) return true;
    if (other.accuracyMetres <= 0) return true;
    return other.accuracyMetres <= accuracyMetres * 2;
  }

  @override
  String toString() =>
      'PhoneFix($latitudeText, $longitudeText ±${accuracyMetres.round()}m)';
}

/// Why a position could not be produced. Surfaced so the UI can say something
/// specific instead of "no GPS".
enum PhoneLocationProblem {
  /// Location is switched off system-wide. The app cannot fix this itself.
  serviceDisabled,

  /// The owner refused, or Android refused on their behalf.
  permissionDenied,

  /// Refused permanently — only the system settings screen can undo it.
  permissionDeniedForever,

  /// The receiver was asked and did not answer in time. Ordinary indoors.
  timedOut,

  /// Anything else the platform threw.
  unavailable,
}

/// The phone's own location, used in place of the keyholder's GPS module.
///
/// The keyholder's receiver can only be read while there is a BLE link to ask
/// over — which is exactly not the case at the moment the link drops, the
/// instant a position is most wanted. `requestLocation()` used to write
/// `GETLOC` to the characteristic, so a disconnect event was stamped with
/// whatever coordinates happened to be left over from the last successful
/// reading. This service asks the phone instead, which is present at precisely
/// the moments that matter: the link coming up, the link going down, and either
/// end pinging the other.
///
/// No internet is needed. Satellite and network positioning both run on the
/// phone; a connection would only be required to turn coordinates into a place
/// name.
class PhoneLocationService {
  /// How long a reading stays good enough to stamp on an event without asking
  /// the receiver again.
  ///
  /// Two minutes is a compromise. A disconnect has to be logged *now* — waiting
  /// for satellites would mean the row appears seconds after the thing it
  /// describes, or not at all if the app is being killed — so something cached
  /// has to be available. Beyond a couple of minutes the phone may well be in a
  /// different street, and a wrong position is worse than none.
  static const Duration freshEnough = Duration(minutes: 2);

  /// Ceiling on a single fix attempt.
  ///
  /// Indoors a high-accuracy request can hang until the OS gives up. Ten seconds
  /// is long enough for a warm receiver to answer and short enough that the
  /// refinement pass is over before the owner has finished reading the row it
  /// will update.
  static const Duration _fixTimeout = Duration(seconds: 10);

  PhoneFix? _lastFix;
  PhoneLocationProblem? _lastProblem;

  /// Guards against overlapping requests. Connect, ping and disconnect can all
  /// land inside a second or two, and three concurrent high-accuracy requests
  /// would cost battery to produce three nearly identical answers.
  Future<PhoneFix?>? _inFlight;

  /// The most recent reading, or null if there has never been one.
  PhoneFix? get lastFix => _lastFix;

  /// Why the last attempt produced nothing, or null if it succeeded.
  PhoneLocationProblem? get lastProblem => _lastProblem;

  bool get hasFix => _lastFix != null;

  /// A reading good enough to stamp on an event happening right now, without
  /// waiting for the receiver.
  ///
  /// Null when the cache is empty or too old to trust. Callers pair this with
  /// [refresh]: log immediately with whatever this returns, then correct the row
  /// when the accurate answer arrives.
  PhoneFix? get usableCachedFix {
    final fix = _lastFix;
    if (fix == null) return null;
    return fix.isStale(freshEnough) ? null : fix;
  }

  /// Asks the receiver for a current position.
  ///
  /// Returns null and records [lastProblem] if it cannot. A fix that arrives is
  /// cached, so the next event logged within [freshEnough] gets it for free.
  /// Concurrent calls share one platform request.
  Future<PhoneFix?> refresh() {
    final existing = _inFlight;
    if (existing != null) return existing;

    final request = _fetch();
    _inFlight = request;
    // Cleared in a `whenComplete` rather than after the await, so a throw inside
    // `_fetch` cannot leave a finished future latched here forever — which would
    // make every later call return the same stale result.
    request.whenComplete(() {
      if (identical(_inFlight, request)) _inFlight = null;
    });
    return request;
  }

  /// A position for an event: the cached one if it is fresh, otherwise a new
  /// reading.
  ///
  /// For callers that can afford to wait. The BLE event path deliberately cannot
  /// — see [usableCachedFix].
  Future<PhoneFix?> currentFix() async {
    final cached = usableCachedFix;
    if (cached != null) return cached;
    return refresh();
  }

  Future<PhoneFix?> _fetch() async {
    if (kIsWeb) {
      // The browser geolocation API exists, but nothing in this project runs on
      // web for real and a permission prompt there would be noise.
      _lastProblem = PhoneLocationProblem.unavailable;
      return null;
    }

    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _lastProblem = PhoneLocationProblem.serviceDisabled;
        return null;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        // `BleService` already asks for location as part of its permission
        // chain, because Android ties BLE scanning to it. Asking again here is
        // for the case where that chain was refused and the owner has since
        // changed their mind.
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        _lastProblem = PhoneLocationProblem.permissionDeniedForever;
        return null;
      }
      if (permission == LocationPermission.denied) {
        _lastProblem = PhoneLocationProblem.permissionDenied;
        return null;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: _fixTimeout,
        ),
      );
      return _adopt(position);
    } on TimeoutException {
      // Nothing from the satellites in time. The platform often still holds a
      // usable older reading from another app's request, which beats giving up.
      return _fallBackToLastKnown(PhoneLocationProblem.timedOut);
    } catch (e) {
      debugPrint('PhoneLocationService: fix failed: $e');
      return _fallBackToLastKnown(PhoneLocationProblem.unavailable);
    }
  }

  Future<PhoneFix?> _fallBackToLastKnown(PhoneLocationProblem problem) async {
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return _adopt(last);
    } catch (_) {
      // Nothing to add: the caller is already being told the attempt failed.
    }
    _lastProblem = problem;
    return null;
  }

  PhoneFix? _adopt(Position position) {
    final fix = PhoneFix(
      latitude: position.latitude,
      longitude: position.longitude,
      accuracyMetres: position.accuracy,
      // Some platforms hand back a timestamp of zero. Treated as "now", since
      // the reading did just arrive.
      timestamp: position.timestamp.millisecondsSinceEpoch == 0
          ? DateTime.now()
          : position.timestamp.toLocal(),
    );

    // 0,0 is the Gulf of Guinea and is what a receiver with nothing reports. The
    // keyholder's NEO-6M did this and it is rejected on that path too.
    if (fix.latitude == 0 && fix.longitude == 0) {
      _lastProblem = PhoneLocationProblem.unavailable;
      return null;
    }

    final previous = _lastFix;
    if (previous == null || previous.isImprovedBy(fix)) {
      _lastFix = fix;
    }
    _lastProblem = null;
    return _lastFix;
  }

  /// Opens the system location settings, for the "turn location on" prompt.
  Future<void> openLocationSettings() async {
    if (kIsWeb) return;
    try {
      await Geolocator.openLocationSettings();
    } catch (e) {
      debugPrint('PhoneLocationService: could not open settings: $e');
    }
  }

  /// Opens the app's own settings page, for a permanent refusal.
  Future<void> openAppSettings() async {
    if (kIsWeb) return;
    try {
      await Geolocator.openAppSettings();
    } catch (e) {
      debugPrint('PhoneLocationService: could not open app settings: $e');
    }
  }
}
