/// The FindX BLE wire contract.
///
/// This file is the single source of truth for every UUID, command string and
/// response prefix exchanged with the keyholder. It has a mirror-image set of
/// `#define`s at the top of `firmware/keyguard_esp32c3/keyguard_esp32c3.ino` —
/// **if you change anything here, change it there too**, or the app and the
/// board will stop understanding each other.
///
/// The service UUID and the data characteristic UUID are unchanged from the
/// original project handout so the thesis text stays accurate. The auth and
/// provisioning characteristics are additions.
library;

/// GATT identifiers.
class BleUuids {
  BleUuids._();

  /// Primary service. Also placed in the advertising packet by the firmware so
  /// the app can scan with a service filter instead of matching on name.
  static const String service = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';

  /// Data / control channel: GPS, battery, ping events. read + write + notify.
  static const String dataChar = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';

  /// Ownership handshake channel. write + notify.
  static const String authChar = 'beb5483e-36e1-4688-b7f5-ea07361b26a9';

  // There was a third characteristic here, `provChar`, carrying Wi-Fi
  // credentials to the keyholder. It is gone: the keyholder is a Bluetooth
  // device and nothing else now, so the app never writes to it. The firmware
  // still exposes the characteristic for older phones; leaving the UUID
  // undeclared here is what stops this app from using it.
}

/// Advertised device name.
class BleNames {
  BleNames._();

  /// The single name a keyholder advertises, in either ownership state.
  ///
  /// Deliberately generic — it carries no per-unit identifier, so a passer-by
  /// cannot single out *this* keyholder (and by extension its owner) from a
  /// scan. See docs/SECURITY_MODEL.md.
  ///
  /// Six characters, and the ceiling is eight. A legacy advertisement is 31
  /// bytes: 18 for the 128-bit service UUID, 3 for the flags, leaving 10 for a
  /// 2-byte AD header plus the name. Firmware that advertised a longer name had
  /// it silently relegated to the scan response by the ESP32 BLE library —
  /// which is why such a device turned up in the scan list as a row with no
  /// name at all. `test/auth_test.dart` holds that budget.
  static const String keyholder = 'FindMe';

  /// What firmware older than the rename advertised.
  ///
  /// Kept because a board already flashed with it is still the owner's board.
  /// Dropping it would leave working hardware unrecognised until it was
  /// reflashed, and "the app stopped seeing my device" is a worse outcome than
  /// carrying one extra string. Nothing infers ownership from it.
  static const String legacyKeyguard = 'KeyGuard';

  /// The spaced spelling, which shipped briefly between `KeyGuard` and
  /// [keyholder].
  ///
  /// One character apart from the current name and easy to dismiss as
  /// cosmetic — but BLE matches advertised names byte for byte, so a board
  /// flashed during that window is invisible to an app that only knows
  /// `FindMe`. Same reasoning as [legacyKeyguard]: a string costs nothing,
  /// hardware that has stopped being recognised costs an afternoon.
  static const String legacySpaced = 'Find Me';

  /// What firmware older than the single-name change advertised while unclaimed.
  ///
  /// Kept only so those units are still recognised as keyholders; nothing infers
  /// ownership from it any more. See [BleAdvState].
  static const String legacyUnclaimed = 'BLE-Keyholder';

  /// Names that may be a keyholder, used as a fallback when a device's
  /// advertising packet omits the service UUID.
  static const List<String> candidates = [
    keyholder,
    legacyKeyguard,
    legacySpaced,
    legacyUnclaimed,
  ];
}

/// Claim state, advertised as one byte of service data under
/// [BleUuids.service] in the scan response.
///
/// The advertising packet itself is full to the byte, so this rides in the scan
/// response's separate 31 bytes. It exists because the name no longer changes on
/// claiming: without it the app could not tell an unclaimed keyholder from
/// somebody else's before connecting, and would have to offer pairing on a
/// device that will refuse it.
///
/// Absent from the advertisement entirely on firmware that predates it — treat
/// that as "no information", not as a claim. See `applyAdvertisedIdentity()` in
/// firmware/keyguard_esp32c3/keyguard_esp32c3.ino.
class BleAdvState {
  BleAdvState._();

  static const int unclaimed = 0x00;
  static const int claimed = 0x01;
}

/// Commands the app writes to the keyholder.
class BleCommands {
  BleCommands._();

  // --- Data characteristic (require an authenticated session) ---
  static const String findKey = 'FIND_KEY';
  static const String stop = 'STOP';
  static const String getLoc = 'GET_LOC';

  /// Choose the buzzer cadence used by [findKey] and by the low-battery warning.
  /// Format: `ALERT_SET:<token>` where the token is an
  /// `AlertPattern.wireName` — `CONT`, `STEADY`, `TRIPLE`, `URGENT`,
  /// `DISCREET` or `SILENT`.
  ///
  /// A *name* rather than raw millisecond values, so that retuning a pattern is
  /// a firmware change alone. If the app sent `ALERT_SET:250:250:1` the two sides
  /// would have to agree on timing forever.
  ///
  /// The keyholder stores the choice in NVS, so the pattern survives a reboot and
  /// is used even when the phone is nowhere near — which matters for the
  /// low-battery chirp.
  static const String alertSetPrefix = 'ALERT_SET:';

  /// `PHONE_LOC:<lat>,<lng>` — where the *phone* is, pushed to the keyholder.
  ///
  /// This is the frame that makes the keyholder's own screen useful. The board
  /// has no GPS module of its own on most builds, so without this its location
  /// screen has nothing to show and sits on "NO GPS FIX" forever — which is
  /// exactly how it behaved before this existed.
  ///
  /// The direction is worth being clear about: every other position in this
  /// protocol travels keyholder → phone. This one goes phone → keyholder, and
  /// it answers a different question. "Where are my keys" is answered by the
  /// app; "where was my phone last" is answered by the little screen on the
  /// keyholder, which is what you read when the phone is the thing you have
  /// lost. Six decimal places, matching [BleResponses.locPrefix], so the two
  /// sides parse identically.
  ///
  /// Requires an authenticated session, like every other data command — the
  /// owner's position is not something an unpaired stranger may write.
  static const String phoneLocPrefix = 'PHONE_LOC:';

  /// `LOCATION_NAME:<place>` — what the coordinates in [phoneLocPrefix] are
  /// called.
  ///
  /// Coordinates are the record; a name is what a person can read. The
  /// keyholder's screen is 72×40 pixels and is read by someone who has lost
  /// their phone, so "Amphitheatre, OAU" is worth far more there than
  /// 7.521834, 4.526901 — they cannot look the numbers up, because the thing
  /// they would look them up on is the thing they are trying to find.
  ///
  /// Sent after [phoneLocPrefix], never instead of it: the name comes from a
  /// reverse-geocoding lookup that needs internet and may never arrive, and a
  /// keyholder that was told a name but no position would have nothing to fall
  /// back on. The board stores it in NVS, so it survives the phone walking away.
  static const String locationNamePrefix = 'LOCATION_NAME:';

  /// `SET_DIST:<metres>` — the distance past which the keyholder should sound.
  /// `SET_DIST:0` switches the limit off.
  ///
  /// Pushed so the *board* knows the owner's limit rather than only the app
  /// knowing it. It is displayed on the keyholder when it changes, which is how
  /// the owner confirms the setting reached the hardware, and it is kept in NVS
  /// so the number on the screen is still right after a battery change.
  static const String setDistancePrefix = 'SET_DIST:';

  /// `DIST_EXCEEDED:<metres>` — the keyholder is further away than the owner's
  /// maximum allowance, as measured by the app.
  ///
  /// The app does the measuring because only the app has both positions. This
  /// frame is the instruction that follows: sound the buzzer and say why.
  ///
  /// Distinct from [findKey] on purpose. `FIND_KEY` means "the owner is looking
  /// for these keys and pressed a button"; this means "these keys have left the
  /// area their owner allowed", which is a different event, shows different text
  /// on the screen, and is not something the owner asked for at that instant.
  /// Both are ended by [stop].
  static const String distanceExceededPrefix = 'DIST_EXCEEDED:';


  // --- Auth characteristic ---
  /// Take ownership of an unclaimed keyholder. Accepted only while the physical
  /// button is held down. Format: `CLAIM:<ownerId hex>`.
  static const String claimPrefix = 'CLAIM:';

  /// Answer to an [BleResponses.authReqPrefix] challenge.
  /// Format: `AUTH:<ownerId hex>:<hmac hex>`.
  static const String authPrefix = 'AUTH:';

  /// Release ownership. Requires an authenticated session.
  static const String unclaim = 'UNCLAIM';
}

/// Notifications the keyholder sends to the app.
class BleResponses {
  BleResponses._();

  // --- Data characteristic ---
  static const String ready = 'READY';

  /// `LOC:<lat>,<lng>`
  static const String locPrefix = 'LOC:';

  /// `BAT:<percent>`
  static const String batPrefix = 'BAT:';

  /// `FIND_PHONE|LOC:<lat>,<lng>` — the button on the keyholder was pressed.
  static const String findPhonePrefix = 'FIND_PHONE|LOC:';

  /// `ALERT:<token>` — the cadence the keyholder is actually using.
  ///
  /// Sent on connect and after every accepted [BleCommands.alertSetPrefix], so
  /// the Settings screen shows what the *device* is set to rather than what this
  /// phone last asked for. Those diverge the moment a second phone owns the
  /// device, or the app is reinstalled.
  static const String alertPrefix = 'ALERT:';

  // --- Auth characteristic ---
  /// `STATUS:UNCLAIMED` — sent on connect when the keyholder has no owner, so
  /// the app knows to offer the pairing flow rather than wait for a challenge.
  static const String statusUnclaimed = 'STATUS:UNCLAIMED';

  /// `AUTH_REQ:<nonce hex>` — sent on connect to a claimed keyholder. The app
  /// must answer within [BleAuthParams.authTimeout] or it is disconnected.
  static const String authReqPrefix = 'AUTH_REQ:';

  /// The session is now authenticated; data commands are accepted.
  static const String authOk = 'AUTH_OK';

  /// The challenge answer was wrong, or did not arrive in time.
  static const String authFail = 'AUTH_FAIL';

  /// Too many failed attempts; the keyholder is refusing connections.
  /// Format: `LOCKED:<seconds remaining>`.
  static const String lockedPrefix = 'LOCKED:';

  /// `CLAIM_OK:<32-byte owner key, hex>` — sent exactly once, at the moment of
  /// claiming. The key is never transmitted again.
  static const String claimOkPrefix = 'CLAIM_OK:';

  /// The claim was refused — almost always because the physical button was not
  /// being held, but also sent if the keyholder is already owned.
  static const String claimDenied = 'CLAIM_DENIED';

  /// Ownership released; the keyholder is now claimable by anyone.
  static const String unclaimOk = 'UNCLAIM_OK';

  /// A command was sent before the session was authenticated.
  static const String notAuthed = 'ERR_NOT_AUTHED';

  // ---------------------------------------------------------------------------
  // Single-channel firmware
  // ---------------------------------------------------------------------------
  //
  // Some boards expose only the data characteristic and announce their claim
  // state on it, using `AUTH:`-prefixed words instead of the frames above. That
  // is not a broken device — it is a simpler protocol, and it is what is on the
  // hardware in the field.
  //
  // Recognising these strings is what makes the keyholder's own screen work on
  // such a board. Until it was added, the app never learned the claim state, so
  // every data write — including the phone's position — was withheld as
  // "possibly unauthenticated", and the board's location page sat on "No GPS"
  // forever while the app sat on a perfectly good fix. See
  // BleService.pushPhoneLocation.

  /// The board has no owner stored. Equivalent to [statusUnclaimed].
  static const String simpleAuthUnpaired = 'AUTH:unpaired';

  /// The board has an owner stored and is waiting for a token.
  static const String simpleAuthRegistered = 'AUTH:registered';

  /// The token matched. Equivalent to [authOk].
  static const String simpleAuthOk = 'AUTH:ok';

  /// There was nothing to match against, so the session is allowed.
  static const String simpleAuthOkUnpaired = 'AUTH:ok_unpaired';

  /// The token did not match. Equivalent to [authFail].
  static const String simpleAuthDenied = 'AUTH:denied';

  /// `LOCATION_NAME:` was stored.
  static const String nameOk = 'NAME:ok';

  /// `LOCATION_NAME:` carried nothing usable.
  static const String nameInvalid = 'NAME:invalid';

  /// `DIST_SET:ok:<metres>` — the limit the board has adopted.
  static const String distSetPrefix = 'DIST_SET:ok:';

  /// `DIST_THRESH:<metres>` — announced on connect, so the app can tell whether
  /// the board is still carrying a limit set by some earlier session.
  static const String distThreshPrefix = 'DIST_THRESH:';

  /// `LOW_POWER:on` / `LOW_POWER:off` — whether the keyholder has dropped its
  /// clock and is light-sleeping between radio events.
  ///
  /// Worth surfacing rather than hiding. Resting is the normal state of a key
  /// finder that has been sitting in a pocket for ten minutes, and an owner who
  /// can see that the device chose to rest reads a longer battery life rather
  /// than a device that has gone quiet on them. The BLE link is unaffected: the
  /// radio keeps its connection, only the CPU slows.
  static const String lowPowerPrefix = 'LOW_POWER:';
  static const String lowPowerOn = 'LOW_POWER:on';
}

/// Sizes and timings that both sides must agree on.
class BleAuthParams {
  BleAuthParams._();

  /// Length of the owner identifier the app generates, in bytes.
  static const int ownerIdBytes = 16;

  /// Length of the shared secret the keyholder generates, in bytes.
  static const int ownerKeyBytes = 32;

  /// Length of the per-connection challenge, in bytes.
  static const int nonceBytes = 16;

  /// HMAC-SHA256 output truncated to this many bytes before transmission.
  ///
  /// 128 bits is far beyond brute-force reach and keeps the frame short enough
  /// to be comfortable even if MTU negotiation lands lower than requested.
  static const int hmacBytes = 16;

  /// How long the keyholder waits for a challenge answer before disconnecting.
  static const Duration authTimeout = Duration(seconds: 10);

  /// Failed attempts tolerated before the keyholder stops accepting
  /// connections for [lockoutDuration].
  static const int maxAuthFailures = 3;

  static const Duration lockoutDuration = Duration(seconds: 30);

  /// ATT MTU requested after connecting.
  ///
  /// This matters: `CLAIM_OK:` plus 64 hex characters is 73 bytes, and the
  /// default 23-byte MTU leaves only 20 bytes of payload. Without a larger MTU
  /// the owner key is silently truncated and pairing fails in a way that looks
  /// like a crypto bug.
  static const int desiredMtu = 247;

  /// Smallest MTU that can carry the longest frame in the protocol.
  static const int minimumUsableMtu = 87;
}
