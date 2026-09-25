/// What a discovered radio appears to be, used only to pick an icon.
///
/// There is no `wifi` member. There used to be, because the old scan fabricated
/// a Wi-Fi "device" from the phone's own network — but nothing on a Wi-Fi network
/// is a pairable device from this app's point of view, so the case never had a
/// real value to hold.
enum BleDeviceType { keyholder, headphones, watch, generic, bluetooth }

/// Where a keyholder stands with respect to ownership.
///
///
///
///
/// This is the state the security model turns on, so it is modelled explicitly
/// rather than inferred from a pile of booleans. Only [BleDeviceType.keyholder]
/// devices ever leave [unknown].
enum OwnershipState {
  /// Not a keyholder, or we have not talked to it yet.
  unknown,

  /// The keyholder has no owner. It can be claimed — but only while its
  /// physical button is held.
  unclaimed,

  /// Claimed, and the stored owner key on this phone matches.
  claimedByMe,

  /// Claimed by somebody else. The firmware will refuse us, so the UI must not
  /// offer a Connect button.
  claimedByOther,

  /// Challenge sent, waiting on the response.
  authenticating,

  /// Challenge passed; commands are accepted.
  authenticated,

  /// Challenge failed or timed out.
  authFailed,

  /// Too many failed attempts — the keyholder is refusing connections.
  lockedOut,
}

class BleDevice {
  final String id;

  /// What to show as the device's title.
  ///
  /// For a radio that advertised no name at all this is the literal string
  /// "Unnamed device" — see [hasAdvertisedName]. It is *not* a fabricated label:
  /// anything we merely inferred goes in [hint] instead, so the UI can render it
  /// as secondary information rather than as the device's identity.
  final String name;

  /// False when nothing in the advertisement carried a name, so the UI can style
  /// the title as a placeholder rather than as a fact.
  final bool hasAdvertisedName;

  /// What the advertisement implies, when it gave no name — "Apple", "Google
  /// Fast Pair", "Battery Service". Null when there was nothing to go on.
  ///
  /// Kept separate from [name] deliberately. A manufacturer identifier is
  /// evidence about a device, not its name, and collapsing the two is how a
  /// scan list starts telling small lies.
  final String? hint;

  final int rssi;
  final String macAddress;
  final BleDeviceType deviceType;
  final bool isConnected;
  final bool isPrimary;

  /// Ownership status, for keyholders.
  final OwnershipState ownership;

  BleDevice({
    required this.id,
    required this.name,
    required this.rssi,
    required this.macAddress,
    this.hasAdvertisedName = true,
    this.hint,
    this.deviceType = BleDeviceType.generic,
    this.isConnected = false,
    this.isPrimary = false,
    this.ownership = OwnershipState.unknown,
  });

  bool get isKeyholder => deviceType == BleDeviceType.keyholder;

  /// True when this keyholder is locked to a different owner, so pairing with it
  /// is impossible until that owner releases it.
  bool get isLockedToAnotherOwner => ownership == OwnershipState.claimedByOther;

  BleDevice copyWith({
    String? id,
    String? name,
    bool? hasAdvertisedName,
    String? hint,
    int? rssi,
    String? macAddress,
    BleDeviceType? deviceType,
    bool? isConnected,
    bool? isPrimary,
    OwnershipState? ownership,
  }) {
    return BleDevice(
      id: id ?? this.id,
      name: name ?? this.name,
      hasAdvertisedName: hasAdvertisedName ?? this.hasAdvertisedName,
      hint: hint ?? this.hint,
      rssi: rssi ?? this.rssi,
      macAddress: macAddress ?? this.macAddress,
      deviceType: deviceType ?? this.deviceType,
      isConnected: isConnected ?? this.isConnected,
      isPrimary: isPrimary ?? this.isPrimary,
      ownership: ownership ?? this.ownership,
    );
  }
}
