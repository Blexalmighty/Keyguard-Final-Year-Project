import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keyguard/services/ble_protocol.dart';
import 'package:keyguard/services/owner_identity.dart';
import 'package:keyguard/services/pairing_service.dart';

/// Tests for the ownership challenge–response.
///
/// This is the part of the project the security claim actually rests on, so it
/// is tested without any BLE stack: `computeAuthResponse` is a static pure
/// function precisely so it can be checked here, and so the same vectors can be
/// replayed against the ESP32's `mbedtls_md_hmac` implementation on real
/// hardware.
void main() {
  Uint8List bytes(List<int> v) => Uint8List.fromList(v);

  /// 16 bytes, distinguishable in failure output.
  Uint8List filled(int value, [int length = 16]) =>
      Uint8List.fromList(List<int>.filled(length, value));

  group('computeAuthResponse — known answer', () {
    // RFC 4231 test case 2 for HMAC-SHA256:
    //   key  = "Jefe"
    //   data = "what do ya want for nothing?"
    //   mac  = 5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843
    //
    // `computeAuthResponse` computes HMAC(key, nonce ‖ ownerId), so splitting
    // that data string across the two arguments must reproduce the published
    // digest. This is the anchor: if this test passes, the Dart side implements
    // real HMAC-SHA256 and not something that merely looks like it, and the
    // firmware can be checked against the same published vector.
    test('matches the published RFC 4231 vector when the message is split '
        'across nonce and ownerId', () {
      final key = Uint8List.fromList(utf8.encode('Jefe'));
      final data = utf8.encode('what do ya want for nothing?');

      final mac = PairingService.computeAuthResponse(
        key: key,
        nonce: Uint8List.fromList(data.sublist(0, 10)),
        ownerId: Uint8List.fromList(data.sublist(10)),
      );

      // Truncated to 16 bytes, so the expected value is the first 32 hex chars.
      expect(OwnerIdentity.toHex(mac), '5bdcc146bf60754e6a042426089575c7');
    });

    test('is truncated to exactly the length the wire format expects', () {
      final mac = PairingService.computeAuthResponse(
        key: filled(0x01, BleAuthParams.ownerKeyBytes),
        nonce: filled(0x02, BleAuthParams.nonceBytes),
        ownerId: filled(0x03, BleAuthParams.ownerIdBytes),
      );

      expect(mac.length, BleAuthParams.hmacBytes);
      expect(mac.length, 16);
      // 16 bytes → 32 hex characters. The whole AUTH frame is then
      // 'AUTH:' + 32 + ':' + 32 = 70 bytes, which fits a 247-byte MTU with room
      // to spare but would be truncated at the 23-byte default.
      expect(OwnerIdentity.toHex(mac).length, 32);
    });
  });

  group('computeAuthResponse — the properties the lock depends on', () {
    final key = filled(0xAB, BleAuthParams.ownerKeyBytes);
    final ownerId = filled(0xCD, BleAuthParams.ownerIdBytes);

    test('is deterministic, so the honest owner always answers correctly', () {
      final nonce = filled(0x11, BleAuthParams.nonceBytes);

      final first =
          PairingService.computeAuthResponse(key: key, nonce: nonce, ownerId: ownerId);
      final second =
          PairingService.computeAuthResponse(key: key, nonce: nonce, ownerId: ownerId);

      expect(OwnerIdentity.toHex(first), OwnerIdentity.toHex(second));
    });

    test('a different nonce gives a different answer — this is what defeats '
        'replay', () {
      // The whole reason the firmware sends a fresh nonce on every connection.
      // If an eavesdropper captures a valid AUTH frame and replays it on the
      // next connection, the nonce has changed, so the captured MAC is wrong.
      final a = PairingService.computeAuthResponse(
          key: key, nonce: filled(0x11), ownerId: ownerId);
      final b = PairingService.computeAuthResponse(
          key: key, nonce: filled(0x12), ownerId: ownerId);

      expect(OwnerIdentity.toHex(a), isNot(OwnerIdentity.toHex(b)));
    });

    test('one flipped bit in the nonce changes the answer', () {
      final nonce = filled(0x11, BleAuthParams.nonceBytes);
      final flipped = Uint8List.fromList(nonce)..[15] ^= 0x01;

      final a = PairingService.computeAuthResponse(
          key: key, nonce: nonce, ownerId: ownerId);
      final b = PairingService.computeAuthResponse(
          key: key, nonce: flipped, ownerId: ownerId);

      expect(OwnerIdentity.toHex(a), isNot(OwnerIdentity.toHex(b)));
    });

    test('a different key gives a different answer — this is what stops a '
        'stranger', () {
      // A second phone knows the nonce (it arrives in the clear) and can invent
      // an ownerId, but it does not have the 32-byte key, so it cannot produce
      // the MAC. That is the entire ownership lock in one assertion.
      final nonce = filled(0x11, BleAuthParams.nonceBytes);

      final owner = PairingService.computeAuthResponse(
          key: key, nonce: nonce, ownerId: ownerId);
      final stranger = PairingService.computeAuthResponse(
          key: filled(0xAC, BleAuthParams.ownerKeyBytes),
          nonce: nonce,
          ownerId: ownerId);

      expect(OwnerIdentity.toHex(owner), isNot(OwnerIdentity.toHex(stranger)));
    });

    test('the ownerId is bound into the MAC, so it cannot be swapped in a '
        'captured frame', () {
      // The ownerId travels beside the MAC in the clear. If it were not also
      // inside the MAC, an attacker could take a valid frame, substitute their
      // own id and be recorded as the owner.
      final nonce = filled(0x11, BleAuthParams.nonceBytes);

      final a = PairingService.computeAuthResponse(
          key: key, nonce: nonce, ownerId: filled(0xCD));
      final b = PairingService.computeAuthResponse(
          key: key, nonce: nonce, ownerId: filled(0xCE));

      expect(OwnerIdentity.toHex(a), isNot(OwnerIdentity.toHex(b)));
    });

    test('nonce and ownerId are not interchangeable', () {
      // Concatenation order matters. If the firmware hashed ownerId ‖ nonce
      // while the app hashed nonce ‖ ownerId, every authentication would fail
      // and it would look like a key-storage bug. This pins the order down.
      final x = filled(0x33, BleAuthParams.nonceBytes);
      final y = filled(0x44, BleAuthParams.ownerIdBytes);

      final forward =
          PairingService.computeAuthResponse(key: key, nonce: x, ownerId: y);
      final reversed =
          PairingService.computeAuthResponse(key: key, nonce: y, ownerId: x);

      expect(OwnerIdentity.toHex(forward), isNot(OwnerIdentity.toHex(reversed)));
    });

    test('a captured frame verifies against its own nonce and no other', () {
      // Simulates the attack directly: capture the owner's answer on connection
      // one, then replay it on connection two.
      final nonce1 = filled(0x01, BleAuthParams.nonceBytes);
      final nonce2 = filled(0x02, BleAuthParams.nonceBytes);

      final captured = PairingService.computeAuthResponse(
          key: key, nonce: nonce1, ownerId: ownerId);

      final expectedNow = PairingService.computeAuthResponse(
          key: key, nonce: nonce2, ownerId: ownerId);

      expect(PairingService.constantTimeEquals(captured, expectedNow), isFalse,
          reason: 'A replayed AUTH frame must not verify against a fresh nonce');

      final expectedThen = PairingService.computeAuthResponse(
          key: key, nonce: nonce1, ownerId: ownerId);
      expect(PairingService.constantTimeEquals(captured, expectedThen), isTrue);
    });
  });

  group('constantTimeEquals', () {
    test('accepts identical byte strings', () {
      expect(
          PairingService.constantTimeEquals(
              bytes([1, 2, 3, 4]), bytes([1, 2, 3, 4])),
          isTrue);
    });

    test('rejects a difference in the last byte', () {
      // The case a naive early-return comparison is slowest to reject, and so
      // the one that leaks the most timing information.
      expect(
          PairingService.constantTimeEquals(
              bytes([1, 2, 3, 4]), bytes([1, 2, 3, 5])),
          isFalse);
    });

    test('rejects a difference in the first byte', () {
      expect(
          PairingService.constantTimeEquals(
              bytes([9, 2, 3, 4]), bytes([1, 2, 3, 4])),
          isFalse);
    });

    test('rejects mismatched lengths', () {
      expect(
          PairingService.constantTimeEquals(bytes([1, 2, 3]), bytes([1, 2, 3, 4])),
          isFalse);
    });

    test('accepts two empty strings', () {
      expect(PairingService.constantTimeEquals(bytes([]), bytes([])), isTrue);
    });

    test('rejects a MAC that matches only on a prefix', () {
      // A byte-at-a-time forgery attack works by finding the longest matching
      // prefix. Every one of these must be rejected identically.
      final target = filled(0x00, 16);
      for (int correctBytes = 0; correctBytes < 16; correctBytes++) {
        final guess = Uint8List(16);
        guess[correctBytes] = 0xFF; // first wrong byte at this position
        expect(PairingService.constantTimeEquals(target, guess), isFalse,
            reason: 'forgery with $correctBytes correct leading bytes');
      }
    });
  });

  group('hex encoding — the wire format', () {
    test('round-trips every byte value', () {
      final all = Uint8List.fromList(List<int>.generate(256, (i) => i));
      final decoded = OwnerIdentity.fromHex(OwnerIdentity.toHex(all));

      expect(decoded, isNotNull);
      expect(decoded!.length, 256);
      for (int i = 0; i < 256; i++) {
        expect(decoded[i], i);
      }
    });

    test('pads single-digit bytes', () {
      // Without padLeft, byte 0x05 would encode as "5" and shift every
      // subsequent byte by one nibble — a decode failure that looks like a
      // crypto failure.
      expect(OwnerIdentity.toHex(bytes([0x00, 0x05, 0x0F])), '00050f');
    });

    test('rejects an odd number of characters', () {
      // What a truncated notification looks like.
      expect(OwnerIdentity.fromHex('abc'), isNull);
    });

    test('rejects non-hex characters', () {
      expect(OwnerIdentity.fromHex('zz'), isNull);
      expect(OwnerIdentity.fromHex('00ff0g'), isNull);
    });

    test('rejects an empty string', () {
      expect(OwnerIdentity.fromHex(''), isNull);
    });

    test('tolerates surrounding whitespace and upper case', () {
      // The firmware terminates frames with a newline in some paths.
      final decoded = OwnerIdentity.fromHex('  AABBCC\n');
      expect(decoded, isNotNull);
      expect(decoded, bytes([0xAA, 0xBB, 0xCC]));
    });

    test('a full-length key decodes to exactly the expected size', () {
      final keyHex = 'a' * (BleAuthParams.ownerKeyBytes * 2);
      expect(OwnerIdentity.fromHex(keyHex)!.length, BleAuthParams.ownerKeyBytes);
    });

    test('a key truncated by a small MTU does not decode to a full key', () {
      // 20 usable payload bytes at the default 23-byte ATT MTU: 'CLAIM_OK:' eats
      // 9 of them, leaving 11 hex characters of the 64 needed. OwnerIdentity
      // must refuse this rather than store a short key.
      final truncated = ('a' * 64).substring(0, 11);
      final decoded = OwnerIdentity.fromHex(truncated);
      expect(decoded == null || decoded.length != BleAuthParams.ownerKeyBytes,
          isTrue);
    });
  });

  group('base64 helper', () {
    // Kept after Wi-Fi provisioning was removed because `toBase64` is still the
    // app's one way of putting arbitrary text into a colon-delimited frame, and
    // these two cases are what make it safe to do so.
    test('encodes text containing a colon without breaking the frame', () {
      // Every frame in this protocol is colon-delimited, so a colon inside a
      // value would split it in the wrong place. Base64's alphabet has no
      // colon in it.
      final encoded = OwnerIdentity.toBase64('pa:ss:word');
      expect(encoded, isNot(contains(':')));
      expect(utf8.decode(base64.decode(encoded)), 'pa:ss:word');
    });

    test('round-trips non-ASCII text', () {
      const text = 'Àwọn Kéyì';
      expect(utf8.decode(base64.decode(OwnerIdentity.toBase64(text))), text);
    });
  });

  group('protocol constants', () {
    test('the auth parameters match what the firmware is written against', () {
      // These four numbers are duplicated as #defines in
      // firmware/keyguard_esp32c3. If anyone changes one side, this test is the
      // reminder to change the other.
      expect(BleAuthParams.ownerIdBytes, 16);
      expect(BleAuthParams.ownerKeyBytes, 32);
      expect(BleAuthParams.nonceBytes, 16);
      expect(BleAuthParams.hmacBytes, 16);
    });

    test('the negotiated MTU floor is large enough for the claim frame', () {
      // 'CLAIM_OK:' (9) + 64 hex characters = 73 bytes of payload, and ATT
      // reserves 3 bytes of header.
      final claimFrameSize =
          BleResponses.claimOkPrefix.length + BleAuthParams.ownerKeyBytes * 2;
      expect(claimFrameSize, 73);
      expect(BleAuthParams.minimumUsableMtu, greaterThan(claimFrameSize + 3));
    });

    test('the auth and data characteristics are different', () {
      // A copy-paste slip here would put the handshake and the command traffic
      // on one characteristic, and an unauthenticated write of FIND_KEY would
      // be indistinguishable from an auth attempt.
      expect(BleUuids.authChar, isNot(BleUuids.dataChar));
      // There was a third UUID here, `provChar`, for Wi-Fi credentials. The
      // app no longer declares it: the keyholder is a Bluetooth device and
      // nothing else.
    });
  });

  group('advertising budget', () {
    // A legacy advertising packet carries 31 bytes, and every AD field inside
    // it is [length][type][data]. The ESP32 BLE library discards any field that
    // would overflow, silently — and when the name is what overflows, it is
    // moved to the scan response, which a phone may never read. The visible
    // result is a keyholder sitting in the app's scan list as a row with no
    // name on it, which is exactly the bug this budget exists to prevent.
    const packetBytes = 31;
    const flagsField = 3; //             [2][0x01][flags]
    const serviceUuidField = 2 + 16; //  [17][0x07][128-bit UUID]
    const adFieldHeader = 2; //          [length][type]

    test('the advertised name fits beside the service UUID', () {
      final nameField = adFieldHeader + BleNames.keyholder.length;

      expect(
        flagsField + serviceUuidField + nameField,
        lessThanOrEqualTo(packetBytes),
        reason: '"${BleNames.keyholder}" cannot ride in the advertising packet '
            'alongside the service UUID, so the firmware will move it to the '
            'scan response and the app will show a nameless device',
      );
    });

    test('the name the old firmware advertised is why the rule exists', () {
      // Not hypothetical: 3 + 18 + 15 = 36, five bytes over, and that overflow
      // is what produced the nameless keyholder in the first place.
      final legacyNameField = adFieldHeader + BleNames.legacyUnclaimed.length;

      expect(flagsField + serviceUuidField + legacyNameField,
          greaterThan(packetBytes));
    });

    test('claim state is carried out of band, so one name serves both states',
        () {
      // The name is identical whether or not the keyholder has an owner — that
      // is the anti-stalking property — so ownership has to be advertised
      // separately, as a byte of service data in the scan response.
      expect(BleAdvState.unclaimed, isNot(BleAdvState.claimed));
    });
  });
}
