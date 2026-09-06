/// A keyholder this phone owns.
///
/// Held in `flutter_secure_storage` via `OwnerIdentity`; this class is only the
/// in-memory view of it. The 32-byte key is deliberately **not** a field —
/// nothing outside `OwnerIdentity` and `PairingService` should be able to reach
/// it, and a model object tends to end up in logs, `toString()` output and
/// error reports.
class PairedDevice {
  const PairedDevice({
    required this.deviceId,
    required this.name,
    this.claimedAt,
  });

  /// BLE remote id — a MAC address on Android, a system UUID on iOS.
  final String deviceId;

  /// Friendly name at the time of claiming.
  final String name;

  final DateTime? claimedAt;

  /// e.g. `Claimed 2 September 2026`. Empty when unknown.
  String get claimedOnDisplay {
    final at = claimedAt;
    if (at == null) return '';
    final local = at.toLocal();
    return 'Claimed ${local.day} ${_months[local.month - 1]} ${local.year}';
  }

  static const List<String> _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  @override
  String toString() => 'PairedDevice($deviceId, $name)';
}
