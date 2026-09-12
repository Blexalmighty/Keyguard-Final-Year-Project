import 'package:flutter_test/flutter_test.dart';
import 'package:keyguard/models/ble_device.dart';
import 'package:keyguard/services/scan_list_diff.dart';

/// The scan list is only redrawn when [scanListChanged] says something visible
/// moved. That makes this the guard against the worst failure mode in the Scan
/// tab — a list that has quietly stopped updating while the radar still spins,
/// which looks exactly like working software.
void main() {
  BleDevice device({
    String id = 'AA:BB:CC:DD:EE:FF',
    String name = 'KeyGuard',
    int rssi = -60,
    bool isConnected = false,
    BleDeviceType type = BleDeviceType.keyholder,
    OwnershipState ownership = OwnershipState.unknown,
    String? hint,
  }) =>
      BleDevice(
        id: id,
        name: name,
        rssi: rssi,
        macAddress: id,
        deviceType: type,
        isConnected: isConnected,
        ownership: ownership,
        hint: hint,
      );

  test('ignores signal noise smaller than one bar', () {
    expect(
      scanListChanged([device(rssi: -60)], [device(rssi: -61)]),
      isFalse,
    );
    expect(
      scanListChanged([device(rssi: -60)], [device(rssi: -62)]),
      isFalse,
    );
  });

  test('redraws once the signal moves a full bar', () {
    expect(
      scanListChanged([device(rssi: -60)], [device(rssi: -63)]),
      isTrue,
    );
    expect(
      scanListChanged([device(rssi: -60)], [device(rssi: -57)]),
      isTrue,
    );
  });

  test('a device walking slowly out of range is not ignored forever', () {
    // The regression this protects against: comparing each sample against the
    // *previous sample* would let a device drift away 1 dBm at a time without
    // ever tripping the threshold. Compared against what is on screen — which is
    // how BleService calls it — the drift accumulates and does trip.
    var displayed = [device(rssi: -60)];
    var redraws = 0;

    for (var step = 1; step <= 10; step++) {
      final sample = [device(rssi: -60 - step)];
      if (scanListChanged(displayed, sample)) {
        displayed = sample;
        redraws++;
      }
    }

    expect(redraws, greaterThan(0));
    expect(displayed.single.rssi, lessThanOrEqualTo(-63));
  });

  test('notices a device appearing or disappearing', () {
    expect(scanListChanged([], [device()]), isTrue);
    expect(scanListChanged([device()], []), isTrue);
  });

  test('notices identity and state changes at an unchanged signal', () {
    final base = [device()];

    expect(scanListChanged(base, [device(id: 'ZZ:ZZ:ZZ:ZZ:ZZ:ZZ')]), isTrue);
    expect(scanListChanged(base, [device(name: 'Ife’s keys')]), isTrue);
    expect(scanListChanged(base, [device(isConnected: true)]), isTrue);
    expect(
      scanListChanged(base, [device(ownership: OwnershipState.claimedByMe)]),
      isTrue,
    );
    expect(
      scanListChanged(base, [device(type: BleDeviceType.headphones)]),
      isTrue,
    );
    expect(scanListChanged(base, [device(hint: 'Apple')]), isTrue);
  });

  test('an unchanged list is not redrawn', () {
    expect(scanListChanged([device()], [device()]), isFalse);
  });
}
