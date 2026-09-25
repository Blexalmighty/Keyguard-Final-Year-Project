import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../utils/coordinate_format.dart';

enum EventType {
  connected,
  disconnected,
  phonePingedKey,
  keyPingedPhone,

  // --- Security audit events ---
  // These exist so the ownership lock leaves a visible trail. "Someone tried to
  // pair with my keyholder and was refused" is exactly the kind of evidence the
  // History screen should surface, and it doubles as evaluation data for the
  // thesis.
  ownershipClaimed,
  ownershipReleased,
  intruderBlocked,

  /// The keyholder passed the owner's maximum allowance while still connected.
  ///
  /// Recorded rather than only notified, because it is the last position
  /// measured over a live link before the keyholder leaves. A disconnect row can
  /// be minutes and streets later; this one is the real "where it went" answer.
  maxAllowanceExceeded,
}

class EventModel {
  final String id;
  final EventType type;
  final String latitude;
  final String longitude;
  final DateTime timestamp;
  final bool bleConnected;

  /// Human-readable place name, when one is known.
  ///
  /// Previously defaulted to the literal `"San Francisco, CA"`, which meant
  /// every event in the log claimed to have happened in California. Now null
  /// unless something actually resolved a name — [displayLocation] falls back
  /// to the coordinates.
  final String? locationName;

  /// Which keyholder this event was about.
  ///
  /// A log of "Connected / Disconnected / Connected" says nothing once a phone
  /// has met more than one keyholder — and even with one, the owner's own name
  /// for it ("Ife's keys") is what makes a row readable at a glance. Stored as
  /// the display name at the time the event happened, so renaming a device later
  /// does not rewrite history.
  ///
  /// Null for events logged before this field existed, which is why every reader
  /// has to tolerate its absence.
  final String? deviceName;

  EventModel({
    required this.id,
    required this.type,
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.bleConnected = true,
    this.locationName,
    this.deviceName,
  });

  /// Returns a copy with the given fields replaced.
  ///
  /// Exists for the GPS refinement pass. An event is logged the instant it
  /// happens, with whatever cached position is to hand, because a disconnect row
  /// that waits for satellites is a row that appears well after the event or not
  /// at all. The accurate fix lands a few seconds later and replaces the
  /// coordinates on the row already in the list, found by [id].
  ///
  /// [clearLocationName] exists because a null argument cannot mean "remove it"
  /// here — `locationName ?? this.locationName` would keep the old value. New
  /// coordinates invalidate the name that described the old ones, so the caller
  /// needs a way to say so.
  EventModel copyWith({
    String? latitude,
    String? longitude,
    String? locationName,
    bool clearLocationName = false,
    String? deviceName,
  }) =>
      EventModel(
        id: id,
        type: type,
        latitude: latitude ?? this.latitude,
        longitude: longitude ?? this.longitude,
        timestamp: timestamp,
        bleConnected: bleConnected,
        locationName:
            clearLocationName ? null : (locationName ?? this.locationName),
        deviceName: deviceName ?? this.deviceName,
      );

  String get typeString {
    switch (type) {
      case EventType.connected:
        return 'connected';
      case EventType.disconnected:
        return 'disconnected';
      case EventType.phonePingedKey:
        return 'phone_pinged_key';
      case EventType.keyPingedPhone:
        return 'key_pinged_phone';
      case EventType.ownershipClaimed:
        return 'ownership_claimed';
      case EventType.ownershipReleased:
        return 'ownership_released';
      case EventType.intruderBlocked:
        return 'intruder_blocked';
      case EventType.maxAllowanceExceeded:
        return 'max_allowance_exceeded';
    }
  }

  static EventType typeFromString(String value) {
    switch (value) {
      case 'disconnected':
        return EventType.disconnected;
      case 'phone_pinged_key':
        return EventType.phonePingedKey;
      case 'key_pinged_phone':
        return EventType.keyPingedPhone;
      case 'ownership_claimed':
        return EventType.ownershipClaimed;
      case 'ownership_released':
        return EventType.ownershipReleased;
      case 'intruder_blocked':
        return EventType.intruderBlocked;
      // 'wifi_provisioned' rows may still sit in an older phone's stored log.
      // They fall through to the default below rather than being listed: the
      // keyholder is a Bluetooth device now and there is no such event to
      // record any more.
      case 'max_allowance_exceeded':
        return EventType.maxAllowanceExceeded;
      case 'connected':
      default:
        return EventType.connected;
    }
  }

  String get displayTitle {
    switch (type) {
      case EventType.connected:
        return 'Connected';
      case EventType.disconnected:
        return 'Disconnected';
      case EventType.phonePingedKey:
        return 'Phone pinged key';
      case EventType.keyPingedPhone:
        return 'Key pinged phone';
      case EventType.ownershipClaimed:
        return 'Ownership claimed';
      case EventType.ownershipReleased:
        return 'Ownership released';
      case EventType.intruderBlocked:
        return 'Unauthorised pairing blocked';
      case EventType.maxAllowanceExceeded:
        return 'Went past your limit';
    }
  }

  /// Accent colour for this event, resolved against the active palette.
  ///
  /// This used to be a `Color get color` returning literals like `0xFF00562A` —
  /// a very dark green chosen to sit on a pale fill. In dark mode those same
  /// literals came out as near-black text on a glowing pastel chip. Taking the
  /// palette means each event type maps to a *semantic* role and the theme
  /// decides how to render it, which is also why the amber/blue cases collapse
  /// onto `warning` and `primary` rather than inventing two more hues.
  Color accent(AppPalette p) {
    switch (type) {
      case EventType.connected:
      case EventType.ownershipClaimed:
        return p.success;
      case EventType.disconnected:
      case EventType.intruderBlocked:
      case EventType.maxAllowanceExceeded:
        return p.danger;
      case EventType.ownershipReleased:
        return p.warning;
      case EventType.phonePingedKey:
      case EventType.keyPingedPhone:
        return p.primary;
    }
  }

  /// The soft fill behind [accent], from the same palette pair.
  Color fill(AppPalette p) {
    switch (type) {
      case EventType.connected:
      case EventType.ownershipClaimed:
        return p.successSoft;
      case EventType.disconnected:
      case EventType.intruderBlocked:
      case EventType.maxAllowanceExceeded:
        return p.dangerSoft;
      case EventType.ownershipReleased:
        return p.warningSoft;
      case EventType.phonePingedKey:
      case EventType.keyPingedPhone:
        return p.primarySoft;
    }
  }

  IconData get icon {
    switch (type) {
      case EventType.connected:
        return Icons.link_rounded;
      case EventType.disconnected:
        return Icons.link_off_rounded;
      case EventType.phonePingedKey:
        return Icons.notifications_active_rounded;
      case EventType.keyPingedPhone:
        return Icons.vpn_key_rounded;
      case EventType.ownershipClaimed:
        return Icons.verified_user_rounded;
      case EventType.ownershipReleased:
        return Icons.lock_open_rounded;
      case EventType.intruderBlocked:
        return Icons.gpp_bad_rounded;
      case EventType.maxAllowanceExceeded:
        return Icons.social_distance_rounded;
    }
  }

  /// True for events that record a security decision rather than normal use.
  ///
  /// The Security tab filters on this. It is deliberately broader than
  /// "something was refused": a ping is the owner commanding the hardware, and a
  /// disconnect is the moment the lock stops being enforceable from this phone,
  /// so both belong in an audit trail even though neither is a failure. The
  /// question the tab answers is *what has happened to my keyholder*, not *what
  /// went wrong*.
  bool get isSecurityEvent =>
      type == EventType.ownershipClaimed ||
      type == EventType.ownershipReleased ||
      type == EventType.intruderBlocked ||
      type == EventType.phonePingedKey ||
      type == EventType.keyPingedPhone ||
      type == EventType.disconnected ||
      type == EventType.maxAllowanceExceeded;

  /// True when this row can name the keyholder it happened to.
  bool get hasDeviceName =>
      deviceName != null && deviceName!.trim().isNotEmpty;

  /// The keyholder's name, phrased for the row it appears under: "from Ife's
  /// keys" reads better beneath *Disconnected* than a bare name would.
  String get displaySubject {
    final name = deviceName?.trim() ?? '';
    if (name.isEmpty) return '';
    switch (type) {
      case EventType.disconnected:
      case EventType.maxAllowanceExceeded:
        return 'from $name';
      case EventType.connected:
      case EventType.ownershipClaimed:
        return 'to $name';
      case EventType.phonePingedKey:
      case EventType.keyPingedPhone:
      case EventType.ownershipReleased:
      case EventType.intruderBlocked:
        return name;
    }
  }

  String get formattedTime {
    final hour = timestamp.hour.toString().padLeft(2, '0');
    final minute = timestamp.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  /// True when this event carries a usable GPS position.
  bool get hasLocation => isPlausibleFix(latitude, longitude);

  String get coordinatesFormatted =>
      hasLocation ? formatCoordinateStrings(latitude, longitude) : 'No GPS fix';

  /// Place name if known, otherwise the coordinates.
  String get displayLocation {
    final name = locationName;
    if (name != null && name.trim().isNotEmpty) return name;
    return coordinatesFormatted;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'event': typeString,
        'latitude': latitude,
        'longitude': longitude,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'ble_connected': bleConnected,
        if (locationName != null) 'location_name': locationName,
        if (deviceName != null) 'device_name': deviceName,
      };

  factory EventModel.fromJson(Map<String, dynamic> json) => EventModel(
        id: json['id']?.toString() ?? '',
        type: typeFromString(json['event']?.toString() ?? 'connected'),
        latitude: json['latitude']?.toString() ?? '0',
        longitude: json['longitude']?.toString() ?? '0',
        timestamp:
            DateTime.tryParse(json['timestamp']?.toString() ?? '')?.toLocal() ??
                DateTime.now(),
        bleConnected: json['ble_connected'] == true,
        locationName: json['location_name']?.toString(),
        deviceName: json['device_name']?.toString(),
      );
}
