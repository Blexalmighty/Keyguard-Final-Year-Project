import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Eight bars showing the recent RSSI window, oldest on the left.
///
/// The bars are drawn from real readings taken by `BleService`'s periodic
/// `readRssi()` — not from a random walk — so a bar that drops is the radio
/// telling you something. The fading opacity ramp is what makes the direction of
/// time legible without a label.
class SignalBarWidget extends StatelessWidget {
  const SignalBarWidget({
    super.key,
    required this.barHeights,
    this.height = 70,
    this.color,
  });

  /// Percentages (0–100), one per bar.
  final List<double> barHeights;

  final double height;

  /// Bar colour. Defaults to the teal accent, which is this app's colour for
  /// live measured values — the same hue the distance readout and the radar use,
  /// so a glance at any of the three reads as the same kind of information.
  ///
  /// Pass white when drawing on the gradient hero panel, where the accent would
  /// vanish into the violet.
  final Color? color;

  static const List<double> opacities = [
    0.22, 0.34, 0.46, 0.60, 0.76, 1.0, 0.72, 0.40, //
  ];

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final hue = color ?? p.accent;

    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(8, (index) {
          final percent =
              index < barHeights.length ? barHeights[index] : 40.0;
          final opacity = opacities[index % opacities.length];

          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2.5),
              child: Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  // A faint full-height track, so a weak reading looks like a
                  // low bar rather than a missing one.
                  Container(
                    height: height,
                    decoration: BoxDecoration(
                      color: hue.withValues(alpha: 0.10),
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(3)),
                    ),
                  ),
                  AnimatedContainer(
                    duration: AppMotion.normal,
                    curve: AppMotion.standard,
                    height: (height * (percent / 100)).clamp(6.0, height),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          hue.withValues(alpha: opacity),
                          hue.withValues(alpha: opacity * 0.55),
                        ],
                      ),
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(3)),
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}
