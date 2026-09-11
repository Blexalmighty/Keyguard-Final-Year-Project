import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The keyholder's battery level, or a dash when it has not reported one.
///
/// [batteryLevel] is deliberately nullable. The ESP32 sends `BAT:<percent>`
/// every 30 s, so before the first frame arrives — and any time the app is
/// disconnected — there is no reading. Rendering that as a confident green "0%"
/// would be a false statement about the hardware.
class BatteryPill extends StatelessWidget {
  const BatteryPill({
    super.key,
    required this.batteryLevel,
    this.isCharging = false,
  });

  final int? batteryLevel;

  /// Whether the pack is on charge. The current firmware has no way to detect
  /// this (the TP4056 status pads are not wired to a GPIO), so it defaults to
  /// false rather than showing a charging bolt that means nothing.
  final bool isCharging;

  IconData get _icon {
    final level = batteryLevel;
    if (level == null) return Icons.battery_unknown_rounded;
    if (isCharging) return Icons.battery_charging_full_rounded;
    if (level > 80) return Icons.battery_full_rounded;
    if (level > 50) return Icons.battery_5_bar_rounded;
    if (level > 20) return Icons.battery_3_bar_rounded;
    return Icons.battery_1_bar_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final level = batteryLevel;

    // Semantic roles rather than literal colours, so the same pill reads
    // correctly on a white card and on the dark theme's near-black surface.
    final (Color fg, Color bg) = switch (level) {
      null => (p.muted, p.surfaceHigh),
      final l when l > 50 => (p.success, p.successSoft),
      final l when l >= 20 => (p.warning, p.warningSoft),
      _ => (p.danger, p.dangerSoft),
    };

    return AnimatedContainer(
      duration: AppMotion.normal,
      curve: AppMotion.standard,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        // A hairline in the same hue, matching OwnershipBadge. Without it the
        // pill reads as a flat blob of colour on a card; with it, it reads as a
        // deliberate chip.
        border: Border.all(color: fg.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_icon, size: 15, color: fg),
          const SizedBox(width: 4),
          Text(
            level != null ? '$level%' : '--',
            style: AppTypography.metadataMono(color: fg)
                .copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
