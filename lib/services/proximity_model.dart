import 'dart:collection';
import 'dart:math' as math;

/// Converts BLE signal strength into a distance estimate.
///
/// The previous implementation used `1.2 + ((-42 - rssi) * 0.04)`, a linear
/// fudge with no physical basis. This uses the standard **log-distance path
/// loss model**, which is what the literature on RSSI ranging actually
/// describes (and what a supervisor will expect you to defend):
///
/// ```
///   RSSI = txPower - 10 * n * log10(d)
/// ```
///
/// Rearranged for distance:
///
/// ```
///   d = 10 ^ ((txPower - RSSI) / (10 * n))
/// ```
///
/// where:
///  * `txPower` is the RSSI measured at a reference distance of exactly 1 metre
///    (negative, in dBm). This is device- and orientation-specific, which is
///    why it is calibratable from the Settings screen rather than hardcoded.
///  * `n` is the path loss exponent: ~2.0 in free space, ~2.5–3.5 indoors where
///    walls, furniture and human bodies absorb and reflect the signal.
///
/// Both parameters are exposed so the reading can be calibrated against the
/// actual keyholder — hold it at 1 m, read the raw dBm, set that as [txPower].
class ProximityModel {
  /// RSSI in dBm at a reference distance of 1 metre.
  ///
  /// -59 dBm is a reasonable starting point for an ESP32-C3 with a PCB antenna;
  /// calibrate per unit for better accuracy.
  static const int defaultTxPower = -59;

  /// Path loss exponent. 2.5 suits a typical indoor environment.
  static const double defaultPathLossExponent = 2.5;

  /// Distances beyond this are not meaningful for a BLE proximity alert, and
  /// reporting them invites false confidence.
  static const double maxReportedMetres = 30.0;

  const ProximityModel({
    this.txPower = defaultTxPower,
    this.pathLossExponent = defaultPathLossExponent,
  });

  final int txPower;
  final double pathLossExponent;

  /// Estimated distance in metres for a given [rssi] in dBm.
  ///
  /// Returns null for [rssi] values that cannot be real — flutter_blue_plus
  /// reports 0 or 127 when it has no reading, and treating those as "very
  /// close" would light up the proximity alert for no reason.
  double? distanceFor(int rssi) {
    if (rssi >= 0 || rssi < -127) return null;

    final double exponent = (txPower - rssi) / (10 * pathLossExponent);
    final double metres = math.pow(10, exponent).toDouble();

    if (!metres.isFinite) return null;
    return metres.clamp(0.1, maxReportedMetres);
  }

  /// Human-readable signal band. Thresholds match the original UI copy so the
  /// Home screen keeps reading the same way.
  static String qualityFor(int rssi) {
    if (rssi >= -55) return 'Excellent';
    if (rssi >= -70) return 'Good';
    if (rssi >= -85) return 'Fair';
    return 'Weak';
  }
}

/// A short rolling window of real RSSI samples.
///
/// RSSI is genuinely noisy — 10 dBm of swing while standing still is normal, so
/// a raw feed makes the distance readout jitter unusably. This keeps the last
/// [capacity] samples and exposes a median, which rejects the occasional wild
/// outlier far better than a mean does.
///
/// It also drives the 8-bar visualiser: [barHeights] maps the window onto the
/// 0–100 scale `widgets/signal_bar.dart` already expects, so that widget needs
/// no changes now that the values are real rather than generated.
class RssiWindow {
  RssiWindow({this.capacity = 8});

  final int capacity;
  final Queue<int> _samples = Queue<int>();

  /// Weakest and strongest RSSI mapped to 0% and 100% bar height. Chosen to
  /// cover the usable range of a BLE link without clipping in normal use.
  static const int _floorDbm = -100;
  static const int _ceilingDbm = -35;

  bool get isEmpty => _samples.isEmpty;

  int get length => _samples.length;

  void add(int rssi) {
    if (rssi >= 0 || rssi < -127) return;
    _samples.addLast(rssi);
    while (_samples.length > capacity) {
      _samples.removeFirst();
    }
  }

  void clear() => _samples.clear();

  /// Median of the window, or null if no samples have arrived yet.
  int? get median {
    if (_samples.isEmpty) return null;
    final sorted = _samples.toList()..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return ((sorted[mid - 1] + sorted[mid]) / 2).round();
  }

  /// Most recent sample, or null if empty.
  int? get latest => _samples.isEmpty ? null : _samples.last;

  /// The window as bar heights in the range 20–95, oldest first.
  ///
  /// Slots with no sample yet render at the 20% floor rather than 0 so the
  /// visualiser doesn't look broken while the first samples arrive.
  List<double> get barHeights {
    final List<double> bars = List<double>.filled(capacity, 20.0);
    final samples = _samples.toList();
    final int offset = capacity - samples.length;
    for (int i = 0; i < samples.length; i++) {
      bars[offset + i] = _toPercent(samples[i]);
    }
    return bars;
  }

  static double _toPercent(int rssi) {
    final double t = (rssi - _floorDbm) / (_ceilingDbm - _floorDbm);
    return (t * 100).clamp(20.0, 95.0);
  }
}
