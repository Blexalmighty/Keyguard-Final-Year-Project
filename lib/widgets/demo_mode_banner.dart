import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/ble_service.dart';
import '../theme/app_theme.dart';
import 'motion.dart';

/// A persistent, unmissable strip shown whenever Demo Mode is on.
///
/// The reason it lives above the whole navigation stack rather than on one
/// screen is that simulated data is only safe if the user can never forget it is
/// simulated. A security tool that quietly shows fabricated "Connected" state is
/// worse than one that shows nothing, so the warning follows you everywhere and
/// cannot be dismissed — only switched off in Settings.
///
/// It is also the one element that does *not* soften in dark mode: the amber
/// comes from the palette's warning pair, which stays high-contrast in both
/// brightnesses precisely so this cannot fade into the background.
class DemoModeBanner extends StatelessWidget {
  const DemoModeBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final isOn = context.select<BleService, bool>((s) => s.demoModeEnabled);

    // Animated in rather than swapped instantly, so turning Demo Mode on is
    // visibly an event. `AnimatedSize` collapses the strip to zero height when
    // off, which keeps it out of the layout entirely.
    return AnimatedSize(
      duration: AppMotion.normal,
      curve: AppMotion.standard,
      alignment: Alignment.topCenter,
      child: !isOn
          ? const SizedBox(width: double.infinity, height: 0)
          : Material(
              color: p.warningSoft,
              child: SafeArea(
                bottom: false,
                child: Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    border:
                        Border(bottom: BorderSide(color: p.warning, width: 1.5)),
                  ),
                  child: Row(
                    children: [
                      PulseDot(color: p.warning, size: 8, haloSize: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'DEMO MODE — data on screen is simulated, not from '
                          'hardware',
                          style: AppTypography.microLabel(color: p.warning)
                              .copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
