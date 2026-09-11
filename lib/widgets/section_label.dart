import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A small caps heading with a coloured tick in front of it.
///
/// Four screens had grown their own version of "uppercase grey label", each a
/// slightly different size and colour. Pulling them into one widget is what makes
/// the sections read as one system, and the tick is where a little colour buys
/// structure: the eye finds the coloured marks and gets the shape of the page
/// before reading a word of it.
///
/// The tick defaults to the teal accent. Pass a hue when the section is about
/// something with a colour of its own — a danger zone, a verified state.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.color, this.textColor});

  final String text;

  /// The tick's colour. Defaults to [AppPalette.accent].
  final Color? color;

  /// The label's colour. Defaults to [AppPalette.muted] — a section heading is
  /// structure, not content, and should not compete with the cards under it.
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 3,
          height: 12,
          decoration: BoxDecoration(
            color: color ?? p.accent,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 7),
        Text(
          text,
          style: AppTypography.labelCaps(color: textColor ?? p.muted),
        ),
      ],
    );
  }
}
