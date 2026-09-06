import 'package:flutter/material.dart';

import '../models/ble_device.dart';
import '../theme/app_theme.dart';

/// A small pill stating who owns a keyholder.
///
/// This is the ownership lock made visible. The requirement is that once a
/// keyholder is paired, nobody else can pair with it until the owner releases
/// it — the firmware enforces that, and this badge is how the app explains it
/// instead of offering a Connect button that will simply be refused.
///
/// The label strings are asserted by `test/widget_test.dart` ('YOUR DEVICE',
/// 'OWNER VERIFIED'), which checks a fresh install shows neither. Changing the
/// wording means changing those tests.
class OwnershipBadge extends StatelessWidget {
  const OwnershipBadge({
    super.key,
    required this.state,
    this.isDemo = false,
  });

  final OwnershipState state;
  final bool isDemo;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    if (isDemo) {
      return _pill('SIMULATED', Icons.science_outlined, p.warning,
          p.warningSoft);
    }

    switch (state) {
      case OwnershipState.unknown:
        return const SizedBox.shrink();

      case OwnershipState.unclaimed:
        return _pill('UNCLAIMED', Icons.lock_open, p.primary, p.primarySoft);

      case OwnershipState.claimedByMe:
        return _pill('YOUR DEVICE', Icons.verified_user, p.success,
            p.successSoft);

      case OwnershipState.claimedByOther:
        return _pill('LOCKED TO ANOTHER OWNER', Icons.lock, p.muted,
            p.surfaceHigh);

      case OwnershipState.authenticating:
        return _pill('VERIFYING…', Icons.hourglass_top, p.primary,
            p.primarySoft);

      case OwnershipState.authenticated:
        return _pill('OWNER VERIFIED', Icons.verified, p.success,
            p.successSoft);

      case OwnershipState.authFailed:
        return _pill('REFUSED', Icons.gpp_bad, p.danger, p.dangerSoft);

      case OwnershipState.lockedOut:
        return _pill('LOCKED OUT', Icons.timer_off, p.danger, p.dangerSoft);
    }
  }

  Widget _pill(String label, IconData icon, Color fg, Color bg) {
    // Animated so a keyholder moving through unclaimed → verifying → verified
    // reads as one thing changing state rather than three different badges.
    return AnimatedContainer(
      duration: AppMotion.normal,
      curve: AppMotion.standard,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: fg.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: fg),
          const SizedBox(width: 5),
          Text(
            label,
            style: AppTypography.microLabel(color: fg)
                .copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.5),
          ),
        ],
      ),
    );
  }
}
