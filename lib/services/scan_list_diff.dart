import '../models/ble_device.dart';

/// How much a device's signal has to move before the scan list is redrawn.
///
/// About the width of one bar on the signal indicator. Below this the reading is
/// inside the noise the smoothing already absorbs, so a repaint would change
/// nothing a user could see.
const int kRssiRepaintThresholdDbm = 3;

/// True when [next] differs from [current] in a way the scan list would show.
///
/// Extracted from `BleService` so it can be tested directly. Scanning runs with
/// `continuousUpdates`, which means the result callback fires several times a
/// second for the whole length of a scan, and nearly all of those passes differ
/// only by a dBm or two on a device nobody is looking at. Rebuilding the list
/// for that competes with the radar animation for the frame budget.
///
/// **This must be compared against what is currently displayed, not against the
/// previous sample.** Used that way it behaves as a deadband: a device sliding
/// steadily out of range accumulates one dBm at a time against the value on
/// screen and does eventually cross the threshold. Comparing consecutive samples
/// instead would reset the baseline every time and such a device would never
/// trigger a repaint at all.
bool scanListChanged(List<BleDevice> current, List<BleDevice> next) {
  if (current.length != next.length) return true;

  for (var i = 0; i < next.length; i++) {
    final a = current[i];
    final b = next[i];
    if (a.id != b.id ||
        a.name != b.name ||
        a.isConnected != b.isConnected ||
        a.ownership != b.ownership ||
        a.deviceType != b.deviceType ||
        a.hint != b.hint ||
        (a.rssi - b.rssi).abs() >= kRssiRepaintThresholdDbm) {
      return true;
    }
  }
  return false;
}
