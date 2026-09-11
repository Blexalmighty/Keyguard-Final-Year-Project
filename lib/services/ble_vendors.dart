/// Turning a nameless advertisement into something a person can read.
///
/// Most BLE radios in a room never broadcast a name. Android only fills
/// `BluetoothDevice.platformName` for devices the phone has *bonded* with, and a
/// large share of peripherals leave the Complete Local Name out of both the
/// advertisement and the scan response to save airtime. The result, in the first
/// build, was a scan list where nearly every row said
/// `Unknown device (A4:C1:38…)` — which is why the Scan tab looked like it was
/// finding nothing with a name.
///
/// An advertisement that carries no name still carries other things, and two of
/// them are worth reading:
///
///   * **Manufacturer Specific Data** is prefixed with a 16-bit Bluetooth SIG
///     company identifier. That tells us who made the radio even when it refuses
///     to say what it is, which is how "Apple device" appears for AirPods that
///     are in a case, or for any nearby iPhone's Continuity beacon.
///   * **Service UUIDs** in the advertisement say what the device is *for*. A
///     0x180D means it is a heart rate sensor whether or not it introduces
///     itself.
///
/// Neither is a name, so they are returned as a separate hint rather than being
/// dressed up as one — the UI shows "Unnamed device" in muted type with the hint
/// beneath it. Inventing a name would be the same class of dishonesty as the
/// phantom `KG-9921` card this app was rewritten to remove.
library;

/// Bluetooth SIG company identifiers, keyed by the value that appears at the
/// front of the manufacturer data payload.
///
/// The registry has thousands of entries; this is the short list that actually
/// turns up in a room in Ile-Ife — phones, laptops, earbuds and trackers. An
/// unknown identifier is reported by number rather than guessed at.
const Map<int, String> _companyNames = {
  0x0006: 'Microsoft',
  0x004C: 'Apple',
  0x0075: 'Samsung',
  0x00E0: 'Google',
  0x0087: 'Garmin',
  0x00D2: 'Bose',
  0x0157: 'Huawei',
  0x038F: 'Xiaomi',
  0x02E5: 'Realme',
  0x01D7: 'OnePlus',
  0x0499: 'Ruuvi',
  0x0171: 'Amazon',
  0x0131: 'Cypress',
  0x000F: 'Broadcom',
  0x0059: 'Nordic Semiconductor',
  0x02FF: 'Silicon Labs',
  0x05A7: 'Sonos',
  0x0110: 'Tile',
  0x0822: 'Adafruit',
  0x07B2: 'Anker / soundcore',
  0x008A: 'Bang & Olufsen',
  0x0154: 'JBL / Harman',
  0x012D: 'Sony',
  0x03DA: 'Fitbit',
};

/// 16-bit GATT service UUIDs worth naming, as they appear in an advertisement.
///
/// Matched on the short form: a 16-bit UUID is expanded by the Bluetooth base
/// UUID into `0000xxxx-0000-1000-8000-00805f9b34fb`, so the four hex digits at
/// offset 4 are what identify it.
const Map<String, String> _serviceNames = {
  '1800': 'Generic Access',
  '180a': 'Device Information',
  '180d': 'Heart Rate Monitor',
  '180f': 'Battery Service',
  '1812': 'Input Device',
  '1826': 'Fitness Machine',
  'fd5a': 'Samsung accessory',
  'fddf': 'Health thermometer',
  'fe2c': 'Google Fast Pair',
  'fe9f': 'Google service',
  'feaa': 'Eddystone beacon',
  'fef3': 'Google device',
};

/// What can be said about a radio that did not introduce itself.
///
/// Returns `null` when the advertisement carries nothing useful — better an
/// honest blank than a fabricated label.
String? describeUnnamed({
  required Map<int, List<int>> manufacturerData,
  required List<String> serviceUuids,
}) {
  final vendor = _vendorFrom(manufacturerData);
  final purpose = _purposeFrom(serviceUuids);

  if (vendor != null && purpose != null) return '$vendor · $purpose';
  return vendor ?? purpose;
}

String? _vendorFrom(Map<int, List<int>> manufacturerData) {
  if (manufacturerData.isEmpty) return null;

  // Some devices advertise several company blocks. Take the first one we can
  // name, and only fall back to the raw identifier if none is recognised —
  // "Company 0x0A5C" is still more informative than nothing, because it tells
  // the user two radios with the same blank name are different products.
  for (final id in manufacturerData.keys) {
    final known = _companyNames[id];
    if (known != null) return known;
  }
  final first = manufacturerData.keys.first;
  return 'Company 0x${first.toRadixString(16).toUpperCase().padLeft(4, '0')}';
}

String? _purposeFrom(List<String> serviceUuids) {
  for (final uuid in serviceUuids) {
    final lower = uuid.toLowerCase();

    // Both the bare 16-bit form ("180d") and the fully-expanded 128-bit form
    // turn up depending on the platform, so handle each.
    final short = lower.length == 4
        ? lower
        : (lower.length >= 8 ? lower.substring(4, 8) : null);
    if (short == null) continue;

    final named = _serviceNames[short];
    // Generic Access is on almost everything, so it is not worth showing on its
    // own — it would label half the room identically.
    if (named != null && short != '1800') return named;
  }
  return null;
}
