/// KeyGuard's design system.
///
/// Three things live here and nothing else should duplicate them:
///
///   * [AppPalette] — semantic colours, resolved per brightness. Read it with
///     `AppPalette.of(context)`. Screens should NOT branch on `isDark`
///     themselves; that is what made dark mode half-work before.
///   * [AppTypography] — Poppins, bundled as an asset. Note that most styles
///     default to a **null** colour on purpose: a `Text` whose style has no
///     colour inherits it from the enclosing `DefaultTextStyle`, which Material
///     drives from the active theme. That one detail is what makes the whole app
///     switch to dark mode without every call site being edited.
///   * [AppMotion] — durations and curves, so animations feel like one system
///     rather than a dozen independent guesses.
library;

import 'package:flutter/material.dart';

// =============================================================================
// Brand constants
// =============================================================================

/// Fixed brand colours plus the light-mode surface ramp.
///
/// These are raw values. Anything that needs to look right in both themes
/// should use [AppPalette] instead of reaching in here.
class AppColors {
  AppColors._();

  static const Color primary = Color(0xFF4234B3);
  static const Color primaryContainer = Color(0xFF5B4FCC);
  static const Color indigoLight = Color(0xFFEEEDFE);
  static const Color primaryFixedDim = Color(0xFFC5C0FF);

  static const Color background = Color(0xFFF9F9FE);
  static const Color surface = Color(0xFFF9F9FE);
  static const Color surfaceContainer = Color(0xFFEDEDF2);
  static const Color surfaceContainerLow = Color(0xFFF3F3F8);
  static const Color surfaceContainerLowest = Color(0xFFFFFFFF);
  static const Color surfaceContainerHigh = Color(0xFFE8E8ED);

  /// Mid grey chosen to stay legible on both the light and the dark surface.
  /// Secondary labels use it in either theme, so it cannot be tuned for one.
  static const Color slateMuted = Color(0xFF8B889B);

  static const Color onSurface = Color(0xFF1A1C1F);
  static const Color onSurfaceVariant = Color(0xFF474553);

  static const Color tertiary = Color(0xFF00562A);
  static const Color tertiaryFixedDim = Color(0xFF4AE183);
  static const Color successLight = Color(0xFFE1F5EE);

  static const Color errorRed = Color(0xFFE74C3C);
  static const Color errorLight = Color(0xFFFCEBEB);
  static const Color errorContainer = Color(0xFFFFDAD6);

  static const Color warning = Color(0xFF8A5300);
  static const Color warningLight = Color(0xFFFFECC7);

  static const Color borderHairline = Color(0xFFE8E8E8);
  static const Color outlineVariant = Color(0xFFC8C4D6);
  static const Color glassBg = Color(0xB3FFFFFF);
}

// =============================================================================
// Semantic palette
// =============================================================================

/// Every colour a screen actually needs, already resolved for the active theme.
///
/// Registered as a [ThemeExtension] so `AppPalette.of(context)` follows the
/// theme automatically — including the cross-fade when the user flips the Dark
/// Mode switch, because Flutter lerps registered extensions.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.brightness,
    required this.background,
    required this.surface,
    required this.surfaceAlt,
    required this.surfaceHigh,
    required this.border,
    required this.borderStrong,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.muted,
    required this.primary,
    required this.onPrimary,
    required this.primarySoft,
    required this.success,
    required this.successSoft,
    required this.danger,
    required this.dangerSoft,
    required this.warning,
    required this.warningSoft,
    required this.glass,
    required this.shadow,
  });

  final Brightness brightness;

  /// Page background, behind everything.
  final Color background;

  /// Cards and sheets sitting on [background].
  final Color surface;

  /// A second card level, for nesting without borders everywhere.
  final Color surfaceAlt;

  /// Inert fills: disabled chips, empty progress tracks, neutral status cards.
  final Color surfaceHigh;

  final Color border;
  final Color borderStrong;

  final Color onSurface;
  final Color onSurfaceVariant;

  /// Tertiary text: captions, metadata, hints.
  final Color muted;

  /// Brand indigo, lightened in dark mode so it stays readable on a dark fill.
  final Color primary;
  final Color onPrimary;

  /// Tinted brand fill for badges and selected states.
  final Color primarySoft;

  final Color success;
  final Color successSoft;
  final Color danger;
  final Color dangerSoft;
  final Color warning;
  final Color warningSoft;

  /// Translucent overlay fill, for the map scrim and floating controls.
  final Color glass;
  final Color shadow;

  bool get isDark => brightness == Brightness.dark;

  static AppPalette of(BuildContext context) =>
      Theme.of(context).extension<AppPalette>() ?? light;

  static const AppPalette light = AppPalette(
    brightness: Brightness.light,
    background: Color(0xFFF9F9FE),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFF3F3F8),
    surfaceHigh: Color(0xFFE8E8ED),
    border: Color(0xFFE8E8E8),
    borderStrong: Color(0xFFC8C4D6),
    onSurface: Color(0xFF1A1C1F),
    onSurfaceVariant: Color(0xFF474553),
    muted: Color(0xFF6F6C7E),
    primary: Color(0xFF4234B3),
    onPrimary: Color(0xFFFFFFFF),
    primarySoft: Color(0xFFEEEDFE),
    success: Color(0xFF00562A),
    successSoft: Color(0xFFE1F5EE),
    danger: Color(0xFFC5301F),
    dangerSoft: Color(0xFFFCEBEB),
    warning: Color(0xFF8A5300),
    warningSoft: Color(0xFFFFECC7),
    glass: Color(0xB3FFFFFF),
    shadow: Color(0x0A000000),
  );

  /// Dark values are indigo-tinted rather than neutral grey — a pure-grey dark
  /// theme next to an indigo brand reads as two unrelated designs.
  static const AppPalette dark = AppPalette(
    brightness: Brightness.dark,
    background: Color(0xFF0E0D14),
    surface: Color(0xFF17161F),
    surfaceAlt: Color(0xFF1E1C28),
    surfaceHigh: Color(0xFF272433),
    border: Color(0xFF2C2939),
    borderStrong: Color(0xFF3D3950),
    onSurface: Color(0xFFEDECF5),
    onSurfaceVariant: Color(0xFFB9B6C9),
    muted: Color(0xFF8E8B9E),
    // The brand indigo at 4.2:1 against #17161F would fail on small text, so
    // dark mode uses a lifted tint of the same hue instead of the raw brand.
    primary: Color(0xFFADA2FF),
    onPrimary: Color(0xFF1A1240),
    primarySoft: Color(0xFF241F3D),
    success: Color(0xFF5FE49A),
    successSoft: Color(0xFF10301F),
    danger: Color(0xFFFF9182),
    dangerSoft: Color(0xFF3A1A18),
    warning: Color(0xFFFFC760),
    warningSoft: Color(0xFF352708),
    glass: Color(0xB317161F),
    shadow: Color(0x40000000),
  );

  @override
  AppPalette copyWith({
    Brightness? brightness,
    Color? background,
    Color? surface,
    Color? surfaceAlt,
    Color? surfaceHigh,
    Color? border,
    Color? borderStrong,
    Color? onSurface,
    Color? onSurfaceVariant,
    Color? muted,
    Color? primary,
    Color? onPrimary,
    Color? primarySoft,
    Color? success,
    Color? successSoft,
    Color? danger,
    Color? dangerSoft,
    Color? warning,
    Color? warningSoft,
    Color? glass,
    Color? shadow,
  }) {
    return AppPalette(
      brightness: brightness ?? this.brightness,
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surfaceAlt: surfaceAlt ?? this.surfaceAlt,
      surfaceHigh: surfaceHigh ?? this.surfaceHigh,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      onSurface: onSurface ?? this.onSurface,
      onSurfaceVariant: onSurfaceVariant ?? this.onSurfaceVariant,
      muted: muted ?? this.muted,
      primary: primary ?? this.primary,
      onPrimary: onPrimary ?? this.onPrimary,
      primarySoft: primarySoft ?? this.primarySoft,
      success: success ?? this.success,
      successSoft: successSoft ?? this.successSoft,
      danger: danger ?? this.danger,
      dangerSoft: dangerSoft ?? this.dangerSoft,
      warning: warning ?? this.warning,
      warningSoft: warningSoft ?? this.warningSoft,
      glass: glass ?? this.glass,
      shadow: shadow ?? this.shadow,
    );
  }

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppPalette(
      // Brightness cannot be interpolated; snap at the midpoint so anything
      // keyed off `isDark` flips once rather than flickering.
      brightness: t < 0.5 ? brightness : other.brightness,
      background: mix(background, other.background),
      surface: mix(surface, other.surface),
      surfaceAlt: mix(surfaceAlt, other.surfaceAlt),
      surfaceHigh: mix(surfaceHigh, other.surfaceHigh),
      border: mix(border, other.border),
      borderStrong: mix(borderStrong, other.borderStrong),
      onSurface: mix(onSurface, other.onSurface),
      onSurfaceVariant: mix(onSurfaceVariant, other.onSurfaceVariant),
      muted: mix(muted, other.muted),
      primary: mix(primary, other.primary),
      onPrimary: mix(onPrimary, other.onPrimary),
      primarySoft: mix(primarySoft, other.primarySoft),
      success: mix(success, other.success),
      successSoft: mix(successSoft, other.successSoft),
      danger: mix(danger, other.danger),
      dangerSoft: mix(dangerSoft, other.dangerSoft),
      warning: mix(warning, other.warning),
      warningSoft: mix(warningSoft, other.warningSoft),
      glass: mix(glass, other.glass),
      shadow: mix(shadow, other.shadow),
    );
  }
}

// =============================================================================
// Motion
// =============================================================================

/// Shared timings. Animations that share a curve read as one interface; a screen
/// where every transition picked its own duration reads as an accident.
class AppMotion {
  AppMotion._();

  /// Taps, ripples, colour changes on press.
  static const Duration fast = Duration(milliseconds: 150);

  /// The default: cards appearing, values changing, expansion.
  static const Duration normal = Duration(milliseconds: 260);

  /// Route transitions and anything crossing the whole screen.
  static const Duration slow = Duration(milliseconds: 420);

  /// Breathing/pulsing loops, e.g. the scanning radar.
  static const Duration pulse = Duration(milliseconds: 1800);

  /// Decelerating — for things entering or settling. The default choice.
  static const Curve enter = Curves.easeOutCubic;

  /// Accelerating — for things leaving.
  static const Curve exit = Curves.easeInCubic;

  /// Slight overshoot, for state changes worth noticing (connected, verified).
  static const Curve emphasized = Curves.easeOutBack;

  static const Curve standard = Curves.easeInOutCubic;

  /// Per-item delay in a staggered list reveal. Kept small deliberately: a long
  /// stagger looks elegant once and feels slow on every subsequent launch.
  static const Duration stagger = Duration(milliseconds: 45);
}

// =============================================================================
// Typography
// =============================================================================

/// Poppins, bundled from `assets/fonts/`.
///
/// Previously these came from `google_fonts`, which downloads at first run — so
/// the app looked wrong until it had internet, which is a poor property for a
/// demo. The files ship with the APK now and `google_fonts` is gone.
///
/// **Most defaults are `null` on purpose.** A `Text` style with a null colour
/// inherits from the surrounding `DefaultTextStyle`, which Material derives from
/// the theme — so `AppTypography.bodyMd()` is automatically light-on-dark in
/// dark mode. Pass an explicit colour only when the colour carries meaning
/// (success green, danger red, brand indigo).
class AppTypography {
  AppTypography._();

  static const String family = 'Poppins';

  static TextStyle headlineLg({Color? color}) => TextStyle(
        fontFamily: family,
        fontSize: 22,
        height: 28 / 22,
        letterSpacing: -0.44,
        fontWeight: FontWeight.w600,
        color: color,
      );

  static TextStyle headlineMd({Color? color}) => TextStyle(
        fontFamily: family,
        fontSize: 17,
        height: 22 / 17,
        letterSpacing: -0.2,
        fontWeight: FontWeight.w600,
        color: color,
      );

  static TextStyle bodyLg({Color? color}) => TextStyle(
        fontFamily: family,
        fontSize: 15,
        height: 20 / 15,
        fontWeight: FontWeight.w500,
        color: color,
      );

  static TextStyle bodyMd({Color? color}) => TextStyle(
        fontFamily: family,
        fontSize: 13,
        height: 18 / 13,
        fontWeight: FontWeight.w400,
        color: color,
      );

  static TextStyle labelCaps({Color color = AppColors.slateMuted}) => TextStyle(
        fontFamily: family,
        fontSize: 11,
        height: 14 / 11,
        letterSpacing: 0.8,
        fontWeight: FontWeight.w600,
        color: color,
      );

  static TextStyle microLabel({Color color = AppColors.slateMuted}) => TextStyle(
        fontFamily: family,
        fontSize: 10,
        height: 12 / 10,
        fontWeight: FontWeight.w500,
        color: color,
      );

  /// For MAC addresses, coordinates and other fixed-width-ish data.
  ///
  /// Poppins is not monospaced, so this leans on tabular figures — digits of
  /// equal width — plus wider tracking. That keeps columns of coordinates from
  /// jittering as they update without shipping a second font family.
  static TextStyle metadataMono({Color color = AppColors.slateMuted}) =>
      TextStyle(
        fontFamily: family,
        fontSize: 10,
        height: 14 / 10,
        letterSpacing: 0.4,
        fontWeight: FontWeight.w500,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: color,
      );

  /// Large numerals — distance, battery percentage. Tabular so the layout does
  /// not shift as the value changes.
  static TextStyle numeric({Color? color, double fontSize = 34}) => TextStyle(
        fontFamily: family,
        fontSize: fontSize,
        height: 1.1,
        letterSpacing: -1.0,
        fontWeight: FontWeight.w600,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: color,
      );
}

// =============================================================================
// Decorations
// =============================================================================

class AppDecorations {
  AppDecorations._();

  /// Theme-aware card surface. Prefer this over the colour-argument form.
  static BoxDecoration card(
    AppPalette palette, {
    double borderRadius = 16.0,
    Color? borderColor,
    Color? backgroundColor,
    bool elevated = true,
  }) {
    return BoxDecoration(
      color: backgroundColor ?? palette.surface,
      borderRadius: BorderRadius.circular(borderRadius),
      border: Border.all(color: borderColor ?? palette.border, width: 1.0),
      boxShadow: elevated
          ? [
              BoxShadow(
                color: palette.shadow,
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ]
          : null,
    );
  }

  /// A soft tinted fill — status cards, badges, callouts.
  static BoxDecoration tinted(
    Color tint, {
    double borderRadius = 14.0,
    double borderOpacity = 0.28,
  }) {
    return BoxDecoration(
      color: tint,
      borderRadius: BorderRadius.circular(borderRadius),
    ).copyWith(
      border: Border.all(color: tint.withValues(alpha: borderOpacity)),
    );
  }

  /// Retained so existing call sites keep compiling. New code should use [card].
  static BoxDecoration cardDecoration({
    Color backgroundColor = AppColors.surfaceContainerLowest,
    Color borderColor = AppColors.borderHairline,
    double borderRadius = 16.0,
  }) {
    return BoxDecoration(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(borderRadius),
      border: Border.all(color: borderColor, width: 1.0),
      boxShadow: const [
        BoxShadow(color: Color(0x0A000000), blurRadius: 12, offset: Offset(0, 3)),
      ],
    );
  }

  static BoxDecoration glassDecoration({
    double borderRadius = 16.0,
    Color borderColor = AppColors.borderHairline,
    Color? backgroundColor,
  }) {
    return BoxDecoration(
      color: backgroundColor ?? AppColors.glassBg,
      borderRadius: BorderRadius.circular(borderRadius),
      border: Border.all(color: borderColor, width: 1.0),
      boxShadow: const [
        BoxShadow(color: Color(0x08000000), blurRadius: 12, offset: Offset(0, 3)),
      ],
    );
  }
}

// =============================================================================
// ThemeData
// =============================================================================

/// Builds the two `ThemeData`s. Everything Material draws for us — app bars,
/// switches, dialogs, snack bars, the nav bar — is configured here so screens do
/// not have to restyle each one by hand.
class AppTheme {
  AppTheme._();

  static ThemeData light() => _build(AppPalette.light);
  static ThemeData dark() => _build(AppPalette.dark);

  static ThemeData _build(AppPalette p) {
    final isDark = p.isDark;

    final colorScheme = ColorScheme(
      brightness: p.brightness,
      primary: p.primary,
      onPrimary: p.onPrimary,
      primaryContainer: p.primarySoft,
      onPrimaryContainer: isDark ? p.onSurface : AppColors.primary,
      secondary: p.primary,
      onSecondary: p.onPrimary,
      tertiary: p.success,
      onTertiary: isDark ? const Color(0xFF06301A) : Colors.white,
      error: p.danger,
      onError: isDark ? const Color(0xFF3A0B06) : Colors.white,
      errorContainer: p.dangerSoft,
      onErrorContainer: p.danger,
      surface: p.background,
      onSurface: p.onSurface,
      surfaceContainerLowest: p.surface,
      surfaceContainerLow: p.surfaceAlt,
      surfaceContainer: p.surfaceAlt,
      surfaceContainerHigh: p.surfaceHigh,
      surfaceContainerHighest: p.surfaceHigh,
      onSurfaceVariant: p.onSurfaceVariant,
      outline: p.borderStrong,
      outlineVariant: p.border,
      shadow: Colors.black,
      scrim: Colors.black54,
      inverseSurface: isDark ? p.onSurface : const Color(0xFF17161F),
      onInverseSurface: isDark ? p.background : Colors.white,
      inversePrimary: isDark ? AppColors.primary : p.primarySoft,
    );

    // Driving the text theme from the palette is what lets null-coloured styles
    // inherit the right colour. See the AppTypography doc comment.
    final textTheme = TextTheme(
      headlineLarge: AppTypography.headlineLg(color: p.onSurface),
      headlineMedium: AppTypography.headlineMd(color: p.onSurface),
      titleMedium: AppTypography.headlineMd(color: p.onSurface),
      bodyLarge: AppTypography.bodyLg(color: p.onSurface),
      bodyMedium: AppTypography.bodyMd(color: p.onSurface),
      bodySmall: AppTypography.bodyMd(color: p.onSurfaceVariant),
      labelLarge: AppTypography.bodyLg(color: p.onSurface),
      labelMedium: AppTypography.labelCaps(color: p.muted),
      labelSmall: AppTypography.microLabel(color: p.muted),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: p.brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: p.background,
      canvasColor: p.background,
      fontFamily: AppTypography.family,
      textTheme: textTheme,
      extensions: <ThemeExtension<dynamic>>[p],

      // Ripples are cheap polish: the default Material splash on a card grid
      // looks dated, and a subtle highlight reads as more considered.
      splashFactory: InkSparkle.splashFactory,
      highlightColor: p.primary.withValues(alpha: 0.06),

      appBarTheme: AppBarTheme(
        backgroundColor: p.surface,
        foregroundColor: p.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        titleTextStyle: AppTypography.headlineMd(color: p.onSurface),
        iconTheme: IconThemeData(color: p.onSurface, size: 22),
      ),

      cardTheme: CardThemeData(
        color: p.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: p.border),
        ),
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: p.primarySoft,
        elevation: 0,
        height: 64,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 22,
            color: selected ? p.primary : p.muted,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return AppTypography.microLabel(
            color: selected ? p.primary : p.muted,
          ).copyWith(
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            fontSize: 11,
          );
        }),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.primary,
          foregroundColor: p.onPrimary,
          disabledBackgroundColor: p.surfaceHigh,
          disabledForegroundColor: p.muted,
          minimumSize: const Size.fromHeight(50),
          textStyle: AppTypography.bodyLg(),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.primary,
          side: BorderSide(color: p.borderStrong),
          minimumSize: const Size.fromHeight(50),
          textStyle: AppTypography.bodyLg(),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: p.primary,
          textStyle: AppTypography.bodyLg(),
        ),
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? p.onPrimary : p.muted),
        trackColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? p.primary
                : p.surfaceHigh),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? Colors.transparent
                : p.borderStrong),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: p.border),
        ),
        titleTextStyle: AppTypography.headlineMd(color: p.onSurface),
        contentTextStyle: AppTypography.bodyMd(color: p.onSurfaceVariant),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalBarrierColor: Colors.black.withValues(alpha: isDark ? 0.62 : 0.4),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: isDark ? p.surfaceHigh : const Color(0xFF23212E),
        contentTextStyle: AppTypography.bodyMd(color: Colors.white),
        actionTextColor: p.primary,
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),

      dividerTheme: DividerThemeData(color: p.border, thickness: 1, space: 1),

      listTileTheme: ListTileThemeData(
        iconColor: p.onSurfaceVariant,
        textColor: p.onSurface,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),

      iconTheme: IconThemeData(color: p.onSurfaceVariant, size: 22),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: p.primary,
        linearTrackColor: p.surfaceHigh,
        circularTrackColor: p.surfaceHigh,
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surfaceAlt,
        hintStyle: AppTypography.bodyMd(color: p.muted),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: p.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: p.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: p.primary, width: 1.6),
        ),
      ),

      // Fade-through rather than a horizontal slide: this app's tabs are
      // siblings, not a drill-down, so a slide implies a hierarchy that is not
      // there. Platforms not listed keep their own default.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        },
      ),
    );
  }
}
