import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'ble_protocol.dart';

/// Long-term secrets: who this phone is, and the shared key for each keyholder
/// it owns.
///
/// **Why this is not `shared_preferences`.** `SettingsStore` holds toggles and
/// calibration numbers — losing or leaking those costs nothing. What lives here
/// is different: the 32-byte `ownerKey` *is* proof of ownership. Anyone holding
/// it can authenticate to the keyholder, read its GPS history and sound its
/// buzzer. `shared_preferences` writes an XML file in the app sandbox that any
/// rooted device or ADB backup can read in plain text.
///
/// `flutter_secure_storage` instead puts it behind the **Android Keystore**: the
/// AES key that encrypts these entries is generated inside hardware-backed
/// storage and cannot be exported, only used. A dump of app data is then
/// useless without the device itself.
///
/// The split is deliberate and worth stating in the thesis: *secrets and
/// preferences do not belong in the same store.*
class OwnerIdentity {
  OwnerIdentity({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                // Keystore-backed encryption rather than the legacy
                // shared-preferences fallback.
                encryptedSharedPreferences: true,
              ),
              iOptions: IOSOptions(
                // The key must survive a reboot before first unlock is not
                // required — but it must never sync to iCloud, or ownership
                // would silently follow a restored backup onto another phone.
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  final FlutterSecureStorage _storage;

  static const String _kOwnerId = 'kg_owner_id';
  static const String _kKeyPrefix = 'kg_owner_key_';
  static const String _kNamePrefix = 'kg_device_name_';
  static const String _kClaimedAtPrefix = 'kg_claimed_at_';

  /// Cached so the pairing handshake does not await storage mid-challenge —
  /// the keyholder only gives us 10 seconds to answer.
  Uint8List? _ownerId;

  /// Cryptographically secure source. `Random()` is a linear congruential
  /// generator and must never be used for key material or nonces.
  final Random _random = Random.secure();

  // ===========================================================================
  // Owner identifier
  // ===========================================================================

  /// This phone's 16-byte identifier, generated once on first use.
  ///
  /// It is not a secret — it travels in the clear in every `AUTH:` frame — it is
  /// only a label saying *which* owner is answering. The secret is the key.
  Future<Uint8List> ownerId() async {
    final cached = _ownerId;
    if (cached != null) return cached;

    final stored = await _read(_kOwnerId);
    if (stored != null) {
      final decoded = _fromHex(stored);
      if (decoded != null && decoded.length == BleAuthParams.ownerIdBytes) {
        _ownerId = decoded;
        return decoded;
      }
      // Corrupt or truncated: regenerate rather than authenticate with garbage.
      debugPrint('OwnerIdentity: stored owner id was malformed, regenerating');
    }

    final fresh = _randomBytes(BleAuthParams.ownerIdBytes);
    await _write(_kOwnerId, _toHex(fresh));
    _ownerId = fresh;
    return fresh;
  }

  /// Hex form, as it goes on the wire.
  Future<String> ownerIdHex() async => _toHex(await ownerId());

  /// Loads the owner id into the cache so [ownerIdHex] is instant later.
  Future<void> warmUp() => ownerId();

  // ===========================================================================
  // Per-keyholder shared secret
  // ===========================================================================

  /// The 32-byte key shared with [deviceId], or null if this phone does not own
  /// that keyholder.
  Future<Uint8List?> keyFor(String deviceId) async {
    final stored = await _read(_kKeyPrefix + _sanitise(deviceId));
    if (stored == null) return null;

    final decoded = _fromHex(stored);
    if (decoded == null || decoded.length != BleAuthParams.ownerKeyBytes) {
      debugPrint('OwnerIdentity: stored key for $deviceId is malformed');
      return null;
    }
    return decoded;
  }

  /// True if this phone holds a key for [deviceId].
  Future<bool> owns(String deviceId) async =>
      (await keyFor(deviceId)) != null;

  /// Stores the key handed over by a successful `CLAIM_OK:`.
  ///
  /// Rejects anything that is not exactly [BleAuthParams.ownerKeyBytes] long.
  /// This is the MTU guard: if the ATT MTU were left at the 23-byte default the
  /// 64-hex-character key would arrive truncated, and storing a short key would
  /// produce a device that authenticates today and mysteriously fails later.
  /// Better to refuse the claim outright.
  Future<bool> storeKey({
    required String deviceId,
    required String keyHex,
    String? deviceName,
  }) async {
    final decoded = _fromHex(keyHex);
    if (decoded == null || decoded.length != BleAuthParams.ownerKeyBytes) {
      debugPrint('OwnerIdentity: refusing a key of '
          '${decoded?.length ?? 0} bytes (expected '
          '${BleAuthParams.ownerKeyBytes}) — check the negotiated MTU');
      return false;
    }

    final safe = _sanitise(deviceId);
    await _write(_kKeyPrefix + safe, _toHex(decoded));
    await _write(
        _kClaimedAtPrefix + safe, DateTime.now().toUtc().toIso8601String());
    if (deviceName != null && deviceName.isNotEmpty) {
      await _write(_kNamePrefix + safe, deviceName);
    }
    return true;
  }

  /// Forgets [deviceId] entirely.
  ///
  /// Called after a successful `UNCLAIM`, and also when the keyholder has been
  /// factory-reset by the 10-second button hold — in that case the key on this
  /// phone is dead weight that would otherwise make the device look owned when
  /// it is not.
  Future<void> forget(String deviceId) async {
    final safe = _sanitise(deviceId);
    await _delete(_kKeyPrefix + safe);
    await _delete(_kNamePrefix + safe);
    await _delete(_kClaimedAtPrefix + safe);
  }

  Future<String?> nameFor(String deviceId) =>
      _read(_kNamePrefix + _sanitise(deviceId));

  Future<DateTime?> claimedAt(String deviceId) async {
    final raw = await _read(_kClaimedAtPrefix + _sanitise(deviceId));
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  /// Every keyholder this phone owns, as raw device ids.
  Future<List<String>> ownedDeviceIds() async {
    try {
      final all = await _storage.readAll();
      return all.keys
          .where((k) => k.startsWith(_kKeyPrefix))
          .map((k) => k.substring(_kKeyPrefix.length))
          .toList();
    } catch (e) {
      debugPrint('OwnerIdentity: readAll failed: $e');
      return const [];
    }
  }

  /// Wipes the owner id and every stored key.
  ///
  /// This does **not** release ownership on any keyholder — those devices stay
  /// claimed and will refuse this phone afterwards, needing the physical
  /// 10-second button reset. Only for a deliberate "forget everything" action.
  Future<void> wipeEverything() async {
    for (final id in await ownedDeviceIds()) {
      await forget(id);
    }
    await _delete(_kOwnerId);
    _ownerId = null;
  }

  // ===========================================================================
  // Storage plumbing
  // ===========================================================================

  // Secure storage throws on some devices with a corrupted keystore entry.
  // A crash on launch would be worse than degrading to "not paired", so every
  // access is guarded.

  Future<String?> _read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e) {
      debugPrint('OwnerIdentity: read($key) failed: $e');
      return null;
    }
  }

  Future<void> _write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      debugPrint('OwnerIdentity: write($key) failed: $e');
    }
  }

  Future<void> _delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e) {
      debugPrint('OwnerIdentity: delete($key) failed: $e');
    }
  }

  /// BLE remote ids contain colons on Android and are UUIDs on iOS. Keys in
  /// secure storage are safest as plain alphanumerics.
  static String _sanitise(String deviceId) =>
      deviceId.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  Uint8List _randomBytes(int length) {
    final bytes = Uint8List(length);
    for (int i = 0; i < length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }

  // ===========================================================================
  // Hex helpers
  // ===========================================================================

  /// Lowercase hex, no separators — the format the firmware parses.
  static String toHex(Uint8List bytes) => _toHex(bytes);

  /// Parses hex, returning null on any non-hex character or an odd length.
  static Uint8List? fromHex(String hex) => _fromHex(hex);

  static String _toHex(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static Uint8List? _fromHex(String hex) {
    final clean = hex.trim().toLowerCase();
    if (clean.isEmpty || clean.length.isOdd) return null;

    final out = Uint8List(clean.length ~/ 2);
    for (int i = 0; i < out.length; i++) {
      final byte = int.tryParse(clean.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) return null;
      out[i] = byte;
    }
    return out;
  }

  /// Base64 without line breaks, for Wi-Fi provisioning in Phase 3.
  static String toBase64(String plain) => base64.encode(utf8.encode(plain));
}
