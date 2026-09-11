import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The rounded gradient square that sits at the left of every app bar.
///
/// A gradient tile rather than a flat tinted square, and it is deliberately the
/// *only* piece of chrome that is coloured for its own sake: the tile can never
/// be mistaken for a status, because it never changes. Everything else that is
/// coloured in this app is reporting something.
///
/// Shared rather than copied into each screen because four slightly different
/// logo marks — three sizes, two corner radii — is what makes an app look
/// assembled instead of designed.
class AppLogoTile extends StatelessWidget {
  const AppLogoTile({
    super.key,
    this.icon = Icons.vpn_key_rounded,
    this.size = 32,
  });

  /// Per-screen mark. Home and Scan use the key; History uses a clock, Settings
  /// a cog — so the tile also answers "which tab am I on" at a glance.
  final IconData icon;

  final double size;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [p.gradientFrom, p.gradientTo],
        ),
        borderRadius: BorderRadius.circular(size * 0.3125),
        boxShadow: [
          BoxShadow(
            color: p.gradientFrom.withValues(alpha: 0.35),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      // White, not `onPrimary`: the two gradient stops are fixed across both
      // themes, so the foreground on top of them can be fixed too.
      child: Icon(icon, size: size * 0.53, color: Colors.white),
    );
  }
}

/// The 'KeyGuard' wordmark, or a screen title set in the same face.
///
/// The tight negative tracking is the whole trick — it is what separates a
/// wordmark from a heading, and it has to be identical on all four tabs.
class AppWordmark extends StatelessWidget {
  const AppWordmark(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    return Text(
      text,
      style: AppTypography.headlineLg(color: p.onSurface)
          .copyWith(letterSpacing: -0.6),
    );
  }
}
