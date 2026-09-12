import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../models/ble_device.dart';
import '../models/event_model.dart';
import '../models/paired_device.dart';
import 'ble_protocol.dart';
import 'ble_service.dart';
import 'owner_identity.dart';

/// Where the pairing flow currently is, for the UI to render.
enum PairingStage {
  /// Nothing happening.
  idle,

  /// Connected to an unclaimed keyholder; waiting for the user to hold its
  /// button and confirm.
  awaitingButtonHold,

  /// `CLAIM:` sent; waiting for `CLAIM_OK:` or `CLAIM_DENIED`.
  claiming,

  /// Claim refused — almost always because the button was not held.
  claimDenied,

  /// Claim succeeded and the key is stored.
  claimed,

  /// A challenge arrived and we are answering it.
  authenticating,

  /// Challenge passed. Commands are accepted.
  authenticated,

  /// Challenge failed, or the keyholder does not recognise this phone.
  authFailed,

  /// The keyholder is refusing connections after repeated failures.
  lockedOut,

  /// Ownership released.
  released,
}

/// Drives the ownership handshake: claiming an unclaimed keyholder, and proving
/// ownership on every later connection.
///
/// **What this class can and cannot do.** It cannot enforce anything. A BLE
/// peripheral accepts whatever connects to it, so the lock is enforced entirely
/// by the firmware — `PairingService` is the *client* side of that protocol. Its
/// job is to answer challenges correctly, to store the key safely, and to report
/// honestly when the keyholder refuses us.
///
/// **The handshake.** On connecting to a claimed keyholder the firmware sends
/// `AUTH_REQ:<nonce>` and starts a 10-second timer. We reply
///
/// ```
///   AUTH:<ownerId hex>:<hmac hex>
///   hmac = HMAC-SHA256(ownerKey, nonce ‖ ownerId)   truncated to 16 bytes
/// ```
///
/// The nonce is fresh per connection, which is what makes a captured `AUTH:`
/// frame useless on replay — the single most important property here. The key
/// itself never crosses the link after the moment of claiming.
class PairingService extends ChangeNotifier {
  PairingService({
    required BleService bleService,
    OwnerIdentity? identity,
  })  : _ble = bleService,
        _identity = identity ?? OwnerIdentity() {
    _authSubscription = _ble.authFrames.listen(
      _onAuthFrame,
      onError: (Object e) => debugPrint('PairingService: auth stream: $e'),
    );
    _ble.addListener(_onBleChanged);
    unawaited(_identity.warmUp());
    unawaited(refreshOwnedDevices());
  }

  final BleService _ble;
  final OwnerIdentity _identity;

  StreamSubscription<String>? _authSubscription;

  PairingStage _stage = PairingStage.idle;
  String _message = '';
  int _lockoutSecondsRemaining = 0;
  Timer? _lockoutTimer;
  bool _wasConnected = false;

  List<PairedDevice> _ownedDevices = const [];

  /// Guards against answering the same challenge twice if the notification is
  /// redelivered, and against a stale answer arriving after a reconnect.
  String? _activeNonceHex;

  // ===========================================================================
  // Public surface
  // ===========================================================================

  PairingStage get stage => _stage;

  /// Human-readable explanation of [stage], safe to show directly.
  String get message => _message;

  /// Seconds left on a keyholder lockout, or 0.
  int get lockoutSecondsRemaining => _lockoutSecondsRemaining;

  /// Keyholders this phone holds a key for.
  List<PairedDevice> get ownedDevices => List.unmodifiable(_ownedDevices);

  bool get isBusy =>
      _stage == PairingStage.claiming || _stage == PairingStage.authenticating;

  /// True once the connected keyholder has accepted our proof of ownership.
  bool get isAuthenticated => _stage == PairingStage.authenticated;

  /// True when the connected keyholder has no owner and can be claimed.
  bool get canClaim => _stage == PairingStage.awaitingButtonHold;

  Future<void> refreshOwnedDevices() async {
    final ids = await _identity.ownedDeviceIds();
    final devices = <PairedDevice>[];
    for (final id in ids) {
      devices.add(PairedDevice(
        deviceId: id,
        name: await _identity.nameFor(id) ?? BleNames.keyholder,
        claimedAt: await _identity.claimedAt(id),
      ));
    }
    _ownedDevices = devices;
    notifyListeners();
  }

  Future<bool> ownsConnectedDevice() async {
    final id = _ble.connectedDevice?.remoteId.str;
    if (id == null) return false;
    return _identity.owns(id);
  }

  // ===========================================================================
  // Claiming
  // ===========================================================================

  /// Takes ownership of the connected, unclaimed keyholder.
  ///
  /// The firmware only accepts this **while the physical button on GPIO 7 is
  /// held down**, which is the point: it binds the right to claim to physical
  /// possession of the device. Someone scanning from across the car park cannot
  /// claim your keyholder, because they cannot press its button.
  Future<bool> claimConnectedDevice() async {
    final device = _ble.connectedDevice;
    if (device == null) {
      _fail('Connect to the keyholder before claiming it.');
      return false;
    }

    // The owner key arrives in a single 73-byte notification. At the default
    // 23-byte ATT MTU it would be silently cut short, and a truncated key
    // produces a device that seems to pair and then refuses us forever.
    if (_ble.negotiatedMtu > 0 &&
        _ble.negotiatedMtu < BleAuthParams.minimumUsableMtu) {
      _fail('The Bluetooth link negotiated only ${_ble.negotiatedMtu} bytes, '
          'which is too small to carry the ownership key safely. Disconnect '
          'and try again.');
      return false;
    }

    _set(PairingStage.claiming, 'Claiming this keyholder — keep the button '
        'held down.');

    final ownerIdHex = await _identity.ownerIdHex();
    final sent =
        await _ble.writeAuthFrame('${BleCommands.claimPrefix}$ownerIdHex');

    if (!sent) {
      _fail(_ble.lastError.isNotEmpty
          ? _ble.lastError
          : 'Could not send the claim to the keyholder.');
      return false;
    }
    return true;
  }

  /// Releases ownership so somebody else can pair.
  ///
  /// Without this a keyholder whose owner lost their phone would be permanently
  /// unusable — a security feature that bricks the product is a bug. The
  /// physical 10-second button hold is the fallback when the app is gone.
  Future<bool> releaseOwnership() async {
    final device = _ble.connectedDevice;
    if (device == null) {
      _fail('Connect to the keyholder before releasing it.');
      return false;
    }
    if (!isAuthenticated) {
      _fail('Only the verified owner can release this keyholder.');
      return false;
    }

    final sent = await _ble.writeAuthFrame(BleCommands.unclaim);
    if (!sent) {
      _fail(_ble.lastError.isNotEmpty
          ? _ble.lastError
          : 'Could not send the release command.');
      return false;
    }
    return true;
  }

  /// Deletes the stored key for a keyholder **without** telling the device.
  ///
  /// For the case where the keyholder was factory-reset with its button: it is
  /// already unclaimed, so the key here is dead weight that would otherwise make
  /// the device look owned when it is not.
  Future<void> forgetLocally(String deviceId) async {
    await _identity.forget(deviceId);
    await refreshOwnedDevices();
    _set(PairingStage.released,
        'This phone has forgotten that keyholder. The device itself still '
        'needs its button held for 10 seconds if it was never released.');
  }

  // ===========================================================================
  // Incoming auth frames
  // ===========================================================================

  Future<void> _onAuthFrame(String frame) async {
    // Never print the frame wholesale — CLAIM_OK carries the owner key.
    debugPrint('PairingService: auth frame '
        '${frame.split(':').first}${frame.contains(':') ? ':…' : ''}');

    if (frame == BleResponses.statusUnclaimed) {
      _activeNonceHex = null;
      _ble.setOwnershipState(OwnershipState.unclaimed);
      _set(
        PairingStage.awaitingButtonHold,
        'This keyholder has no owner yet. Hold the button on the device, then '
        'tap Claim.',
      );
      return;
    }

    if (frame.startsWith(BleResponses.authReqPrefix)) {
      await _answerChallenge(
          frame.substring(BleResponses.authReqPrefix.length).trim());
      return;
    }

    if (frame == BleResponses.authOk) {
      _activeNonceHex = null;
      _ble.setOwnershipState(OwnershipState.authenticated);
      _ble.logSecurityEvent(EventType.connected);
      _set(PairingStage.authenticated,
          'Ownership verified. This keyholder is yours.');
      return;
    }

    if (frame == BleResponses.authFail) {
      _activeNonceHex = null;
      _ble.setOwnershipState(OwnershipState.authFailed);
      // From this phone's point of view a rejection means the keyholder belongs
      // to somebody else. From the *keyholder's* point of view we were the
      // intruder — and its own OLED and event log record it that way.
      _ble.logSecurityEvent(EventType.intruderBlocked);
      _set(
        PairingStage.authFailed,
        'This keyholder refused this phone. It belongs to another owner, or it '
        'was reset and needs claiming again.',
      );
      return;
    }

    if (frame.startsWith(BleResponses.lockedPrefix)) {
      final seconds =
          int.tryParse(frame.substring(BleResponses.lockedPrefix.length).trim());
      _activeNonceHex = null;
      _ble.setOwnershipState(OwnershipState.lockedOut);
      _startLockoutCountdown(
          seconds ?? BleAuthParams.lockoutDuration.inSeconds);
      return;
    }

    if (frame.startsWith(BleResponses.claimOkPrefix)) {
      await _onClaimOk(frame.substring(BleResponses.claimOkPrefix.length).trim());
      return;
    }

    if (frame == BleResponses.claimDenied) {
      _set(
        PairingStage.claimDenied,
        'The keyholder refused the claim. Hold its button down *before* tapping '
        'Claim and keep holding until it confirms. If it already has an owner, '
        'they must release it first.',
      );
      return;
    }

    if (frame == BleResponses.unclaimOk) {
      final id = _ble.connectedDevice?.remoteId.str;
      if (id != null) await _identity.forget(id);
      await refreshOwnedDevices();
      _activeNonceHex = null;
      _ble.setOwnershipState(OwnershipState.unclaimed);
      _ble.logSecurityEvent(EventType.ownershipReleased);
      _set(
        PairingStage.released,
        'Ownership released. Anyone can now claim this keyholder, so keep hold '
        'of it until you have paired it again.',
      );
      return;
    }

    debugPrint('PairingService: unrecognised auth frame');
  }

  /// Answers `AUTH_REQ:<nonce>` with `AUTH:<ownerId>:<hmac>`.
  Future<void> _answerChallenge(String nonceHex) async {
    final device = _ble.connectedDevice;
    if (device == null) return;

    final nonce = OwnerIdentity.fromHex(nonceHex);
    if (nonce == null || nonce.length != BleAuthParams.nonceBytes) {
      // A malformed challenge means the link is corrupt or the firmware is a
      // different version. Answering it with garbage would burn one of the
      // three attempts before lockout, so say nothing.
      _fail('The keyholder sent a challenge this app could not read. Check '
          'that the firmware and app versions match.');
      return;
    }

    // Replay guard on our own side: if the same nonce arrives twice, the second
    // is either a duplicated notification or something replaying at us.
    if (_activeNonceHex == nonceHex) {
      debugPrint('PairingService: ignoring a repeated challenge');
      return;
    }
    _activeNonceHex = nonceHex;

    final key = await _identity.keyFor(device.remoteId.str);
    if (key == null) {
      // We do not own this device. Do not guess — a wrong answer counts toward
      // the keyholder's lockout, and locking out a stranger's device for 30
      // seconds is rude at best.
      _ble.setOwnershipState(OwnershipState.claimedByOther);
      _set(
        PairingStage.authFailed,
        'This keyholder already has an owner, and it is not this phone. Its '
        'owner must release it before you can pair.',
      );
      return;
    }

    _ble.setOwnershipState(OwnershipState.authenticating);
    _set(PairingStage.authenticating, 'Proving ownership…');

    final ownerId = await _identity.ownerId();
    final mac = computeAuthResponse(key: key, nonce: nonce, ownerId: ownerId);

    final sent = await _ble.writeAuthFrame(
      '${BleCommands.authPrefix}${OwnerIdentity.toHex(ownerId)}:'
      '${OwnerIdentity.toHex(mac)}',
    );
    if (!sent) {
      _fail('Could not answer the keyholder\'s challenge in time.');
    }
  }

  Future<void> _onClaimOk(String keyHex) async {
    final device = _ble.connectedDevice;
    if (device == null) return;

    final stored = await _identity.storeKey(
      deviceId: device.remoteId.str,
      keyHex: keyHex,
      deviceName: _ble.deviceName,
    );

    if (!stored) {
      // storeKey rejects a key of the wrong length. The usual cause is a small
      // ATT MTU truncating the frame, which is why it is named here.
      _fail('The keyholder sent an ownership key this phone could not store — '
          'it arrived incomplete. Disconnect, reconnect and claim again. '
          '(Negotiated MTU: ${_ble.negotiatedMtu} bytes.)');
      return;
    }

    await refreshOwnedDevices();
    _activeNonceHex = null;
    _ble.setOwnershipState(OwnershipState.claimedByMe);
    _ble.logSecurityEvent(EventType.ownershipClaimed);
    _set(
      PairingStage.claimed,
      'This keyholder is now yours. While you are connected it stops '
      'advertising, so no other phone can even see it — and once you '
      'disconnect it will refuse anyone who cannot prove ownership.',
    );
  }

  // ===========================================================================
  // Lockout countdown
  // ===========================================================================

  void _startLockoutCountdown(int seconds) {
    _lockoutTimer?.cancel();
    _lockoutSecondsRemaining = seconds;
    _set(PairingStage.lockedOut, _lockoutMessage());

    _lockoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _lockoutSecondsRemaining--;
      if (_lockoutSecondsRemaining <= 0) {
        timer.cancel();
        _lockoutSecondsRemaining = 0;
        _set(PairingStage.idle,
            'The keyholder is accepting connections again.');
        return;
      }
      _message = _lockoutMessage();
      notifyListeners();
    });
  }

  String _lockoutMessage() =>
      'This keyholder has locked itself for $_lockoutSecondsRemaining more '
      'seconds after repeated failed attempts.';

  // ===========================================================================
  // Connection lifecycle
  // ===========================================================================

  /// Resets the flow when the link drops.
  ///
  /// Leaving `authenticated` on screen after a disconnect would be exactly the
  /// class of lie this rewrite exists to remove.
  void _onBleChanged() {
    final connected = _ble.isConnected;
    if (_wasConnected && !connected) {
      _activeNonceHex = null;
      _lockoutTimer?.cancel();
      _lockoutSecondsRemaining = 0;
      if (_stage != PairingStage.idle) {
        _set(PairingStage.idle, '');
      }
    }
    _wasConnected = connected;
  }

  // ===========================================================================
  // Crypto
  // ===========================================================================

  /// `HMAC-SHA256(ownerKey, nonce ‖ ownerId)`, truncated to
  /// [BleAuthParams.hmacBytes].
  ///
  /// Static and dependency-free so `test/auth_test.dart` can check it against
  /// fixed vectors without a BLE stack. The firmware computes the identical
  /// value with `mbedtls_md_hmac`.
  ///
  /// The `ownerId` is inside the MAC as well as beside it on the wire, so an
  /// attacker cannot take a valid `AUTH:` frame and swap in a different id.
  static Uint8List computeAuthResponse({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List ownerId,
  }) {
    final message = Uint8List(nonce.length + ownerId.length)
      ..setRange(0, nonce.length, nonce)
      ..setRange(nonce.length, nonce.length + ownerId.length, ownerId);

    final digest = Hmac(sha256, key).convert(message).bytes;
    return Uint8List.fromList(digest.sublist(0, BleAuthParams.hmacBytes));
  }

  /// Compares two MACs without leaking which byte differed.
  ///
  /// The app does not strictly need this — the firmware is the side that
  /// verifies — but it is here so `test/auth_test.dart` can exercise the same
  /// constant-time logic the sketch uses, and so nobody later reaches for `==`.
  ///
  /// A plain byte-by-byte comparison that returns early leaks, through timing,
  /// how many leading bytes were correct; an attacker can then find a valid MAC
  /// one byte at a time instead of guessing all 16 at once. XOR-accumulating
  /// every byte takes the same time whatever the input.
  static bool constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  // ===========================================================================

  void _set(PairingStage stage, String message) {
    _stage = stage;
    _message = message;
    notifyListeners();
  }

  void _fail(String message) => _set(PairingStage.authFailed, message);

  @override
  void dispose() {
    _authSubscription?.cancel();
    _lockoutTimer?.cancel();
    _ble.removeListener(_onBleChanged);
    super.dispose();
  }
}
