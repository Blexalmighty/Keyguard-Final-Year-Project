import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The scan control: three expanding rings, a rotating sweep, and a tappable
/// core that starts and stops the scan.
///
/// Colours come from [AppPalette] rather than the raw brand indigo, because the
/// brand value is too dark to see against the dark theme's background — the
/// rings were effectively invisible there before.
class RadarWidget extends StatefulWidget {
  const RadarWidget({
    super.key,
    required this.isScanning,
    required this.onTap,
    this.deviceCount = 0,
  });

  final bool isScanning;
  final VoidCallback onTap;

  /// Drawn as blips on the outer rings. Purely indicative — BLE gives no
  /// bearing, so their angles are fixed per index rather than pretending to be
  /// directions.
  final int deviceCount;

  @override
  State<RadarWidget> createState() => _RadarWidgetState();
}

class _RadarWidgetState extends State<RadarWidget>
    with TickerProviderStateMixin {
  /// Ring expansion. Kept separate from the sweep so the rings can be stopped
  /// mid-flight while the sweep decelerates on its own timing.
  late final AnimationController _rings = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  );

  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void initState() {
    super.initState();
    if (widget.isScanning) {
      _rings.repeat();
      _sweep.repeat();
    }
  }

  @override
  void didUpdateWidget(RadarWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isScanning == oldWidget.isScanning) return;
    if (widget.isScanning) {
      _rings.repeat();
      _sweep.repeat();
    } else {
      _rings.stop();
      _sweep.stop();
    }
  }

  @override
  void dispose() {
    _rings.dispose();
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    return SizedBox(
      width: 220,
      height: 220,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: Listenable.merge([_rings, _sweep]),
            builder: (context, _) => CustomPaint(
              size: const Size(220, 220),
              painter: RadarPulsePainter(
                progress: _rings.value,
                sweep: _sweep.value,
                isScanning: widget.isScanning,
                accent: p.primary,
                deviceCount: widget.deviceCount,
              ),
            ),
          ),

          // The core. Scales and brightens on press, so it reads as a button
          // rather than as decoration.
          _RadarCore(
            isScanning: widget.isScanning,
            onTap: widget.onTap,
            accent: p.primary,
            onAccent: p.onPrimary,
          ),
        ],
      ),
    );
  }
}

class _RadarCore extends StatefulWidget {
  const _RadarCore({
    required this.isScanning,
    required this.onTap,
    required this.accent,
    required this.onAccent,
  });

  final bool isScanning;
  final VoidCallback onTap;
  final Color accent;
  final Color onAccent;

  @override
  State<_RadarCore> createState() => _RadarCoreState();
}

class _RadarCoreState extends State<_RadarCore> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down
            ? 0.92
            : widget.isScanning
                ? 1.0
                : 0.94,
        duration: AppMotion.fast,
        curve: AppMotion.standard,
        child: AnimatedContainer(
          duration: AppMotion.normal,
          curve: AppMotion.standard,
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                widget.accent,
                Color.lerp(widget.accent, Colors.black, 0.18)!,
              ],
            ),
            boxShadow: [
              BoxShadow(
                // Tied to the scanning state: the glow growing when a scan
                // starts is the confirmation that the tap registered.
                color: widget.accent
                    .withValues(alpha: widget.isScanning ? 0.42 : 0.22),
                blurRadius: widget.isScanning ? 26 : 14,
                spreadRadius: widget.isScanning ? 3 : 0,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Center(
            child: AnimatedSwitcher(
              duration: AppMotion.fast,
              child: Icon(
                widget.isScanning
                    ? Icons.radar_rounded
                    : Icons.play_arrow_rounded,
                key: ValueKey<bool>(widget.isScanning),
                size: 40,
                color: widget.onAccent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class RadarPulsePainter extends CustomPainter {
  RadarPulsePainter({
    required this.progress,
    required this.sweep,
    required this.isScanning,
    required this.accent,
    this.deviceCount = 0,
  });

  final double progress;
  final double sweep;
  final bool isScanning;
  final Color accent;
  final int deviceCount;

  static const double _coreRadius = 48.0;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    // Static guide rings, so the dial still has structure when paused.
    final guide = Paint()
      ..color = accent.withValues(alpha: 0.10)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    for (final f in const [0.62, 0.82, 1.0]) {
      canvas.drawCircle(center, _coreRadius + (maxRadius - _coreRadius) * f,
          guide);
    }

    // Expanding pulses.
    for (int i = 0; i < 3; i++) {
      final ringProgress = (progress + (i * 0.33)) % 1.0;
      final radius = _coreRadius + (maxRadius - _coreRadius) * ringProgress;
      final opacity = isScanning ? (1.0 - ringProgress) * 0.5 : 0.14;

      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = accent.withValues(alpha: opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    if (isScanning) _paintSweep(canvas, center, maxRadius);
    if (deviceCount > 0) _paintBlips(canvas, center, maxRadius);
  }

  /// A 70° wedge fading out behind the leading edge — the classic radar look,
  /// and the clearest available signal that the scan is live rather than frozen.
  void _paintSweep(Canvas canvas, Offset center, double maxRadius) {
    final angle = sweep * 2 * math.pi;
    const arc = math.pi * 0.39;

    final rect = Rect.fromCircle(center: center, radius: maxRadius);
    canvas.drawArc(
      rect,
      angle - arc,
      arc,
      true,
      Paint()
        ..shader = SweepGradient(
          startAngle: angle - arc,
          endAngle: angle,
          colors: [
            accent.withValues(alpha: 0.0),
            accent.withValues(alpha: 0.16),
          ],
          transform: GradientRotation(angle - arc),
        ).createShader(rect),
    );

    // The leading edge itself, drawn solid so the direction of travel is legible.
    canvas.drawLine(
      center + Offset(math.cos(angle), math.sin(angle)) * _coreRadius,
      center + Offset(math.cos(angle), math.sin(angle)) * maxRadius,
      Paint()
        ..color = accent.withValues(alpha: 0.34)
        ..strokeWidth = 1.5,
    );
  }

  /// One dot per discovered device, at fixed angles.
  ///
  /// Deliberately not positioned by signal strength or bearing: BLE gives no
  /// direction at all, and RSSI-to-radius would imply a precision the radio
  /// cannot support. They are a count, drawn as dots.
  void _paintBlips(Canvas canvas, Offset center, double maxRadius) {
    final paint = Paint()..color = accent.withValues(alpha: 0.75);
    final halo = Paint()..color = accent.withValues(alpha: 0.18);

    final n = deviceCount.clamp(0, 8);
    for (int i = 0; i < n; i++) {
      final angle = (i / 8) * 2 * math.pi + 0.4;
      final radius = _coreRadius + (maxRadius - _coreRadius) *
          (0.55 + 0.32 * ((i % 3) / 2));
      final at = center + Offset(math.cos(angle), math.sin(angle)) * radius;
      canvas.drawCircle(at, 7, halo);
      canvas.drawCircle(at, 3, paint);
    }
  }

  @override
  bool shouldRepaint(covariant RadarPulsePainter old) {
    return old.progress != progress ||
        old.sweep != sweep ||
        old.isScanning != isScanning ||
        old.accent != accent ||
        old.deviceCount != deviceCount;
  }
}
