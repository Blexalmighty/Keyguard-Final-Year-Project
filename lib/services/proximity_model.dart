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
/// actual keyholder. [RssiCalibrator] does that measurement automatically; the
/// sliders in Settings remain as a manual override.
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

  /// Bounds on both constants, shared by the sliders and by the solvers below.
  ///
  /// They are not cosmetic limits on a widget: a value outside them describes a
  /// radio that does not exist, so a solved result that lands outside is taken
  /// as evidence the measurement was bad rather than as a new calibration.
  static const int minTxPower = -90;
  static const int maxTxPower = -30;
  static const double minPathLossExponent = 1.6;
  static const double maxPathLossExponent = 4.0;

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

  /// The [txPower] implied by a measurement taken at a known distance, holding
  /// [pathLossExponent] as it is.
  ///
  /// Rearranging the model for the reference term gives
  /// `txPower = RSSI + 10·n·log10(d)`. At d = 1 m the logarithm is zero and this
  /// reduces to "txPower is whatever you measured", which is exactly the manual
  /// procedure — so the automatic measurement is the same calibration, with the
  /// human removed from the part humans are bad at.
  ///
  /// Taking a distance argument at all is what makes it usable: nobody holds a
  /// measured metre accurately, but most people can stand at a doorway they know
  /// is two metres off, and the logarithm corrects for it exactly.
  int txPowerFrom(RssiCalibrationSample sample) {
    final double reference =
        sample.medianDbm + 10 * pathLossExponent * _log10(sample.metres);
    return reference.round().clamp(minTxPower, maxTxPower);
  }

  /// Solves for **both** constants from two measurements at different distances.
  ///
  /// Subtracting the model at two distances eliminates the reference term:
  ///
  /// ```
  ///   rssiA - rssiB = -10·n·log10(dA / dB)
  ///     =>  n = (rssiB - rssiA) / (10 · log10(dA / dB))
  /// ```
  ///
  /// and substituting back gives `txPower`. This is the refinement that adapts
  /// the model to the *room* as well as to the board: a corridor and a furnished
  /// office have genuinely different exponents, and no single-point calibration
  /// can discover that.
  ///
  /// Returns null when the pair cannot support the inference — the two distances
  /// are too close together to divide by, or the solved constants fall outside
  /// the physical bounds, which happens when multipath made the farther reading
  /// the stronger one. A null here means "keep the previous calibration", never
  /// "apply a nonsense one".
  static ProximityModel? solveFromPair(
    RssiCalibrationSample a,
    RssiCalibrationSample b,
  ) {
    final near = a.metres <= b.metres ? a : b;
    final far = a.metres <= b.metres ? b : a;

    if (near.metres <= 0 || far.metres <= 0) return null;
    // A ratio below this leaves the distance difference buried in the noise: at
    // n = 2.5 a 1.5x ratio is under 5 dB, which is less than the spread of a
    // single measurement.
    if (far.metres / near.metres < minimumDistanceRatio) return null;

    final double ratioLog = _log10(near.metres / far.metres);
    if (ratioLog == 0) return null;

    final double n = (far.medianDbm - near.medianDbm) / (10 * ratioLog);
    if (!n.isFinite ||
        n < minPathLossExponent ||
        n > maxPathLossExponent) {
      return null;
    }

    final double reference = near.medianDbm + 10 * n * _log10(near.metres);
    final int txPower = reference.round();
    if (txPower < minTxPower || txPower > maxTxPower) return null;

    return ProximityModel(
      txPower: txPower,
      // One decimal, matching the slider's granularity and the precision the
      // measurement can actually justify.
      pathLossExponent: double.parse(n.toStringAsFixed(1)),
    );
  }

  /// How much farther the second calibration point has to be than the first
  /// before solving for the exponent is defensible.
  static const double minimumDistanceRatio = 2.0;

  static double _log10(double x) => math.log(x) / math.ln10;
}

/// One finished calibration measurement: the median of many RSSI readings taken
/// while the phone was held at a distance the owner stated.
class RssiCalibrationSample {
  const RssiCalibrationSample({
    required this.metres,
    required this.medianDbm,
    required this.spreadDbm,
    required this.sampleCount,
  });

  /// The distance the owner said they were holding the phone at.
  final double metres;

  /// Median of the samples. The median, not the mean, because multipath produces
  /// occasional readings 15 dB off the true value and a mean carries them into
  /// the answer in proportion to how wrong they are.
  final int medianDbm;

  /// Strongest minus weakest sample, in dB. Reported because it is the honest
  /// measure of how much to trust the median — and because showing it teaches
  /// the owner something true about the radio that no amount of UI copy would.
  final int spreadDbm;

  final int sampleCount;

  /// Above this the environment was too reflective for the measurement to mean
  /// much. 12 dB corresponds to roughly a 3x distance error at n = 2.5.
  static const int noisySpreadDbm = 12;

  bool get isNoisy => spreadDbm > noisySpreadDbm;
}

/// Collects raw RSSI readings and reduces them to one defensible figure.
///
/// This is the statistical answer to automatic calibration. The intuitive
/// alternative — have the phone's own sensors measure out one metre as the owner
/// walks it — cannot work: a pedometer quantises to a step of about 0.7 m, GPS is
/// accurate to about 5 m, and accelerometer dead reckoning accumulates error
/// quadratically. Every available sensor has an error larger than the quantity
/// being measured. Sampling the radio itself has no such problem, because the
/// radio is the thing being calibrated.
///
/// Deliberately fed from **raw** `readRssi()` results rather than from
/// [RssiWindow]: that window already publishes a median, and a median of medians
/// would both narrow the apparent spread and hide the outliers this measurement
/// exists to average away.
class RssiCalibrator {
  RssiCalibrator({required this.metres});

  /// Distance the owner is holding the phone at, in metres.
  final double metres;

  final List<int> _samples = <int>[];

  /// How many readings to take. At the 250 ms sampling interval this is about
  /// six seconds — long enough for body movement and passing people to average
  /// out, short enough that the owner will hold still for all of it.
  static const int targetSamples = 24;

  /// Below this the median is not worth having, and applying it would be worse
  /// than leaving the previous calibration alone.
  static const int minimumSamples = 8;

  int get sampleCount => _samples.length;

  bool get hasEnough => _samples.length >= minimumSamples;

  double get progress => (_samples.length / targetSamples).clamp(0.0, 1.0);

  bool get isComplete => _samples.length >= targetSamples;

  /// Adds a reading, ignoring the platform sentinels. A failed read is simply a
  /// sample that never arrives, which is why the loop counts samples rather than
  /// elapsed time.
  void add(int rssi) {
    if (rssi >= 0 || rssi < -127) return;
    _samples.add(rssi);
  }

  /// The measurement, or null if too few readings survived.
  RssiCalibrationSample? finish() {
    if (!hasEnough) return null;
    final sorted = List<int>.of(_samples)..sort();
    final mid = sorted.length ~/ 2;
    final int median = sorted.length.isOdd
        ? sorted[mid]
        : ((sorted[mid - 1] + sorted[mid]) / 2).round();

    return RssiCalibrationSample(
      metres: metres,
      medianDbm: median,
      spreadDbm: sorted.last - sorted.first,
      sampleCount: sorted.length,
    );
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
