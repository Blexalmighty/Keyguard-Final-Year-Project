import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../build_info.dart';
import '../models/alert_pattern.dart';
import '../models/phone_alert_tone.dart';
import '../services/ble_service.dart';
import '../services/pairing_service.dart';
import '../services/phone_ringer_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_logo_tile.dart';
import '../widgets/motion.dart';
import '../widgets/section_label.dart';
import 'wifi_setup_screen.dart';

/// Settings: device info, calibration, preferences, ownership, demo mode.
///
/// This is the one screen that mentions Wi-Fi, and it does so as a *device*
/// setting rather than a connection mode. The phone always reaches the keyholder
/// over Bluetooth; giving the keyholder a network only widens how far its last
/// reported position can travel. Framing it anywhere else — as a second way to
/// connect, or as a tab beside Bluetooth — would offer a choice that does not
/// exist.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final bleService = context.watch<BleService>();
    final p = AppPalette.of(context);

    return Scaffold(
      backgroundColor: p.background,
      body: SafeArea(
        child: Column(
          children: [
            const _AppBar(),
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ...staggered([
                          _Header(),
                          _DeviceInfoCard(bleService: bleService),
                          const _SectionLabel('ALERT & PROXIMITY'),
                          _ThresholdCard(bleService: bleService),
                          _AlertPatternCard(bleService: bleService),
                          _CalibrationCard(bleService: bleService),
                          const _SectionLabel('FIND MY PHONE'),
                          const _PhoneToneCard(),
                          const _SectionLabel('BATTERY'),
                          _BatteryCard(bleService: bleService),
                          const _SectionLabel('APPEARANCE'),
                          _AppearanceCard(bleService: bleService),
                          const _SectionLabel('ALERTS & LOGGING'),
                          _PreferencesCard(bleService: bleService),
                          const _SectionLabel('KEYHOLDER NETWORK'),
                          _NetworkCard(bleService: bleService),
                          const _SectionLabel('SECURITY'),
                          _OwnershipCard(bleService: bleService),
                          _DemoModeCard(bleService: bleService),
                          _SectionLabel('DANGER ZONE', color: p.danger),
                          _DangerZone(bleService: bleService),
                        ]).expand((w) => [w, const SizedBox(height: 12)]),
                        const SizedBox(height: 20),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Chrome
// =============================================================================

class _AppBar extends StatelessWidget {
  const _AppBar();

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    return Container(
      height: 58,
      decoration: BoxDecoration(
        color: p.surface,
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Row(
            children: [
              const AppLogoTile(icon: Icons.settings_rounded, size: 30),
              const SizedBox(width: 10),
              const AppWordmark('Settings'),
              const Spacer(),
              // The build stamp is here so a screenshot answers "which APK is
              // this?" without asking. Sideloaded builds are easy to mix up, and
              // debugging a layout that was already fixed is expensive.
              Text(kBuildStamp, style: AppTypography.microLabel(color: p.muted)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Text(
        'Device information, proximity tuning, and the controls that decide who '
        'may command your keyholder.',
        style: AppTypography.bodyMd(color: p.onSurfaceVariant),
      ),
    );
  }
}

/// Thin wrapper over the shared [SectionLabel], adding this screen's spacing.
///
/// Kept as a private widget purely so the seven call sites below stay as short as
/// they were; the label itself is no longer defined here, so it cannot drift from
/// the ones on Home and History.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {this.color});

  final String text;

  /// Overrides the tick colour. Used by the danger zone, where teal would be a
  /// misleading thing to lead a destructive section with.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SectionLabel(text, color: color),
      ),
    );
  }
}

/// The one card shape every section uses, so a new section cannot invent its own.
class _Card extends StatelessWidget {
  const _Card({required this.child, this.tint, this.borderColor});

  final Widget child;
  final Color? tint;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return AnimatedContainer(
      duration: AppMotion.normal,
      curve: AppMotion.standard,
      padding: const EdgeInsets.all(16),
      decoration: AppDecorations.card(
        p,
        backgroundColor: tint,
        borderColor: borderColor,
      ),
      child: child,
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final Widget value;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(label,
              style: AppTypography.bodyMd(color: p.onSurfaceVariant)),
        ),
        const SizedBox(width: 12),
        value,
      ],
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.icon,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    return Row(
      children: [
        if (icon != null) ...[
          AnimatedContainer(
            duration: AppMotion.normal,
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: value ? p.primarySoft : p.surfaceHigh,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 17, color: value ? p.primary : p.muted),
          ),
          const SizedBox(width: 11),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppTypography.bodyLg(color: p.onSurface)),
              const SizedBox(height: 2),
              Text(subtitle, style: AppTypography.bodyMd(color: p.muted)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}

// =============================================================================
// Device info
// =============================================================================

/// The keyholder's identity plate, and this screen's one gradient panel.
///
/// Every screen gets exactly one: Home's live readout, Scan's dial, and here the
/// device itself, because that is what the rest of the page is a list of settings
/// *for*. Anything more than one and the gradient stops meaning "this is the
/// subject" and starts meaning "this app likes purple".
class _DeviceInfoCard extends StatelessWidget {
  const _DeviceInfoCard({required this.bleService});

  final BleService bleService;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    // Three states, not two. The old pill only knew "GPS Fixed" or "Searching…",
    // so a keyholder that was not even connected still claimed to be looking for
    // satellites.
    final connected = bleService.isConnected;
    final fixed = bleService.hasGpsFix;

    // On the gradient the state pill is a *solid* saturated fill with white type,
    // not the usual soft tint: a pale `successSoft` green over violet goes muddy,
    // while a solid green chip stays unmistakable. The disconnected case has no
    // hue of its own, so it becomes a translucent white chip.
    final (IconData pillIcon, Color? pillBg) = switch ((connected, fixed)) {
      (false, _) => (Icons.gps_off_rounded, null),
      (true, true) => (Icons.gps_fixed_rounded, p.success),
      (true, false) => (Icons.gps_not_fixed_rounded, p.warning),
    };
    final pillText =
        !connected ? 'No link' : (fixed ? 'GPS fixed' : 'Searching…');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppDecorations.hero(p),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
            ),
            child: const Icon(Icons.developer_board_rounded,
                size: 25, color: Colors.white),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(bleService.deviceName,
                    style: AppTypography.headlineMd(color: Colors.white),
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text('ESP32-C3  •  ${bleService.deviceId}',
                    style: AppTypography.metadataMono(
                        color: Colors.white.withValues(alpha: 0.66)),
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: 8),
          AnimatedContainer(
            duration: AppMotion.normal,
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: pillBg ?? Colors.white.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.24)),
            ),
            child: Row(
              children: [
                Icon(pillIcon, size: 12, color: Colors.white),
                const SizedBox(width: 4),
                Text(pillText,
                    style: AppTypography.microLabel(color: Colors.white)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Proximity
// =============================================================================

class _ThresholdCard extends StatelessWidget {
  const _ThresholdCard({required this.bleService});

  final BleService bleService;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Proximity Threshold',
                  style: AppTypography.bodyLg(color: p.onSurface)),
              Text('${bleService.alertDistanceThreshold.toStringAsFixed(1)} m',
                  style: AppTypography.numeric(color: p.primary, fontSize: 20)),
            ],
          ),
          Text('How far your keyholder may drift before the app warns you.',
              style: AppTypography.bodyMd(color: p.muted)),
          Slider(
            value: bleService.alertDistanceThreshold,
            min: 1.0,
            max: 10.0,
            divisions: 18,
            label: '${bleService.alertDistanceThreshold.toStringAsFixed(1)} m',
            onChanged: bleService.setAlertDistanceThreshold,
          ),
          // The halfway warning, next to the distance it halves. Off by default
          // in the sense that it is the user's first choice to make: a phone
          // that also buzzes every time the owner walks to the far side of a
          // room is a phone that gets muted, so it must be opted into, not on.
          const SizedBox(height: 6),
          _Toggle(
            icon: Icons.notifications_active_outlined,
            title: 'Warn at half distance',
            subtitle: 'Ask to send a phone notification when the keyholder '
                'reaches half the threshold above.',
            value: bleService.proximityWarningEnabled,
            onChanged: (v) => bleService.setProximityWarningEnabled(v),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Alert cadence
// =============================================================================

/// The picker that was missing: how the keyholder's buzzer should sound.
///
/// The wording throughout says *cadence* rather than *ringtone* and that is a
/// hardware fact, not pedantry. The buzzer is an active 3 V element with its own
/// oscillator, so it has one pitch and the firmware's only control is on or off.
/// A list titled "Ringtone" offering Chime, Bell and Marimba would be three names
/// for the same beep. What genuinely differs — and what actually helps you find
/// the keys — is the rhythm, so that is what this offers.
///
/// Each row can be previewed, because a written description of a rhythm is much
/// less useful than two seconds of hearing it. Preview needs the device: nothing
/// here simulates the buzzer, since a sound the phone made would tell you
/// precisely nothing about whether the keyholder works.
class _AlertPatternCard extends StatefulWidget {
  const _AlertPatternCard({required this.bleService});

  final BleService bleService;

  @override
  State<_AlertPatternCard> createState() => _AlertPatternCardState();
}

class _AlertPatternCardState extends State<_AlertPatternCard> {
  /// Which row is mid-preview, so its button can show a spinner. Held here
  /// rather than in the service because it is pure presentation.
  AlertPattern? _previewing;

  Future<void> _preview(AlertPattern pattern) async {
    setState(() => _previewing = pattern);
    await widget.bleService.previewAlertPattern(pattern);
    if (mounted) setState(() => _previewing = null);
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final selected = widget.bleService.alertPattern;
    final connected = widget.bleService.isConnected;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: p.primarySoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.graphic_eq_rounded,
                    size: 18, color: p.primary),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Alert Tone',
                        style: AppTypography.bodyLg(color: p.onSurface)),
                    const SizedBox(height: 2),
                    Text(
                      'How the keyholder beeps when you tap Ring. Its buzzer has '
                      'one fixed pitch, so what changes is the rhythm.',
                      style: AppTypography.bodyMd(color: p.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          for (final pattern in AlertPattern.values) ...[
            _PatternRow(
              pattern: pattern,
              selected: pattern == selected,
              connected: connected,
              busy: _previewing == pattern,
              onSelect: () => widget.bleService.setAlertPattern(pattern),
              onPreview: () => _preview(pattern),
            ),
            if (pattern != AlertPattern.values.last)
              const SizedBox(height: 8),
          ],
          const SizedBox(height: 12),
          // Says plainly where the setting lives. It is stored on the device, so
          // it survives reinstalling the app and applies to the low-battery
          // chirp, which sounds with no phone attached.
          Text(
            connected
                ? 'Saved on the keyholder itself, so it applies even when your '
                    'phone is not nearby.'
                : 'Saved now and sent to the keyholder the next time you '
                    'connect. Connect to hear a preview.',
            style: AppTypography.metadataMono(color: p.muted),
          ),
        ],
      ),
    );
  }
}

class _PatternRow extends StatelessWidget {
  const _PatternRow({
    required this.pattern,
    required this.selected,
    required this.connected,
    required this.busy,
    required this.onSelect,
    required this.onPreview,
  });

  final AlertPattern pattern;
  final bool selected;
  final bool connected;
  final bool busy;
  final VoidCallback onSelect;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    // Flash-only is drawn in the LED's own colour rather than the brand accent,
    // because it is the one option that makes no sound at all and that difference
    // is worth seeing before it is read.
    final tone = pattern.isSilent ? p.warning : p.primary;

    return PressableScale(
      onTap: onSelect,
      child: AnimatedContainer(
        duration: AppMotion.normal,
        curve: AppMotion.standard,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: selected ? tone.withValues(alpha: 0.10) : p.surfaceAlt,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: selected ? tone.withValues(alpha: 0.45) : p.border,
            width: selected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          children: [
            AnimatedContainer(
              duration: AppMotion.normal,
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? tone : Colors.transparent,
                border: Border.all(
                  color: selected ? tone : p.borderStrong,
                  width: 1.6,
                ),
              ),
              child: selected
                  ? Icon(Icons.check_rounded,
                      size: 13, color: p.isDark ? p.background : Colors.white)
                  : null,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        pattern.label,
                        style: AppTypography.bodyLg(
                            color: selected ? tone : p.onSurface),
                      ),
                      const SizedBox(width: 8),
                      // The rhythm, drawn. Derived from the same numbers the
                      // firmware uses, so the picture cannot drift from the sound.
                      _CadenceBars(pattern: pattern, color: tone),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(pattern.description,
                      style: AppTypography.bodyMd(color: p.muted)),
                ],
              ),
            ),
            const SizedBox(width: 6),
            // No preview button for flash-only: there is nothing to hear, and a
            // play button that produces silence looks broken.
            if (!pattern.isSilent)
              SizedBox(
                width: 34,
                height: 34,
                child: busy
                    ? Padding(
                        padding: const EdgeInsets.all(8),
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: tone),
                      )
                    : IconButton(
                        onPressed: connected ? onPreview : null,
                        padding: EdgeInsets.zero,
                        tooltip: connected
                            ? 'Ring the keyholder with this pattern'
                            : 'Connect to preview',
                        icon: Icon(
                          Icons.play_arrow_rounded,
                          size: 20,
                          color: connected ? tone : p.muted,
                        ),
                      ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A tiny picture of the cadence: filled blocks are the buzzer on, gaps are
/// silence, widths proportional to the real millisecond values.
///
/// Not decoration — it is the one part of this card that conveys the difference
/// between "three quick beeps" and "one long pip" without the user having to
/// parse a sentence. Widths come straight from [AlertPattern], so a firmware
/// retune changes the drawing too.
class _CadenceBars extends StatelessWidget {
  const _CadenceBars({required this.pattern, required this.color});

  final AlertPattern pattern;
  final Color color;

  @override
  Widget build(BuildContext context) {
    const double unitCap = 26.0;

    // Millisecond values span 60 ms to 60 s, so a linear mapping would render
    // the continuous tone as a bar wider than the screen and everything else as
    // a dot. Square root compresses the range while keeping the ordering.
    double widthFor(int ms) =>
        (sqrt(ms.clamp(1, 4000)) * 0.55).clamp(3.0, unitCap);

    final blocks = <Widget>[];
    for (var i = 0; i < pattern.burst; i++) {
      blocks.add(Container(
        width: widthFor(pattern.onMs),
        height: 9,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ));
      if (i < pattern.burst - 1) {
        blocks.add(SizedBox(width: widthFor(pattern.gapMs).clamp(3.0, 8.0)));
      }
    }
    // The pause after the burst, then a faint stub showing that the whole thing
    // repeats. Without the stub, DISCREET and CONT look like the same single bar.
    if (pattern.pauseMs > 0) {
      blocks
        ..add(SizedBox(width: widthFor(pattern.pauseMs).clamp(4.0, 14.0)))
        ..add(Container(
          width: 3,
          height: 9,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(2),
          ),
        ));
    }

    return Row(mainAxisSize: MainAxisSize.min, children: blocks);
  }
}

// =============================================================================
// Find My Phone
// =============================================================================

/// Which sound *this phone* makes when the button on the keyholder is pressed.
///
/// The mirror image of [_AlertPatternCard], and worth having as its own section
/// because it is the other direction of the alert: that card is "make my keys
/// beep", this one is "make my phone ring". Users think of the two as one
/// feature, which is exactly why they must not share one control — the keyholder
/// has a single-pitch buzzer and can only vary rhythm, while the phone has a real
/// speaker and can play anything on it. Merging them would mean offering the fob
/// a choice of songs it cannot play.
class _PhoneToneCard extends StatefulWidget {
  const _PhoneToneCard();

  @override
  State<_PhoneToneCard> createState() => _PhoneToneCardState();
}

class _PhoneToneCardState extends State<_PhoneToneCard> {
  Future<void> _select(PhoneRingerService ringer, PhoneAlertTone tone) async {
    // Picking "From my storage" with no file yet goes straight to the picker.
    // Selecting an option that cannot make a sound and saying nothing would be
    // the worst of the available behaviours.
    if (tone.needsFile && !ringer.hasCustomTone) {
      await _pick(ringer);
      return;
    }
    await ringer.setTone(tone);
  }

  Future<void> _preview(PhoneRingerService ringer, PhoneAlertTone tone) async {
    if (tone.needsFile && !ringer.hasCustomTone) {
      await _pick(ringer);
      return;
    }
    // Tapping the row that is already playing stops it, rather than restarting a
    // sound the user is currently listening to.
    if (ringer.isPreviewing && ringer.tone == tone) {
      await ringer.stop();
      return;
    }
    await ringer.previewTone(tone);
    if (!mounted) return;
    _surfaceError(ringer);
  }

  Future<void> _pick(PhoneRingerService ringer) async {
    final ok = await ringer.pickCustomTone();
    if (!mounted) return;
    if (!ok) _surfaceError(ringer);
  }

  /// Shows whatever the ringer last complained about, once, then clears it.
  ///
  /// A snackbar rather than a line in the card: every one of these is about an
  /// action the user just took — a cancelled picker, an unreadable file, a
  /// platform with no audio — and an inline message would sit there afterwards
  /// describing a moment that has passed.
  void _surfaceError(PhoneRingerService ringer) {
    if (ringer.lastError.isEmpty) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(ringer.lastError)));
    ringer.clearError();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final ringer = context.watch<PhoneRingerService>();
    final selected = ringer.tone;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: p.primarySoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.ring_volume_rounded,
                    size: 18, color: p.primary),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Ring This Phone',
                        style: AppTypography.bodyLg(color: p.onSurface)),
                    const SizedBox(height: 2),
                    Text(
                      'What this phone plays when you press the button on your '
                      'keyholder. Works the other way round to the alert above.',
                      style: AppTypography.bodyMd(color: p.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          for (final tone in PhoneAlertTone.values) ...[
            _ToneRow(
              tone: tone,
              selected: tone == selected,
              // Driven by the service, not by a local flag: `previewTone`
              // returns as soon as the sound starts and stops itself on a timer,
              // so the only thing that knows whether noise is still coming out
              // is the ringer. `tone == selected` is safe as the identity test
              // because previewing a tone selects it.
              busy: ringer.isPreviewing && tone == selected,
              // Only the custom row has a file, and only it can be missing one.
              fileName: tone.needsFile ? ringer.customToneName : null,
              picking: tone.needsFile && ringer.isPickingFile,
              onSelect: () => _select(ringer, tone),
              onPreview: () => _preview(ringer, tone),
              onPickFile: tone.needsFile ? () => _pick(ringer) : null,
              onClearFile: tone.needsFile ? ringer.clearCustomTone : null,
            ),
            if (tone != PhoneAlertTone.values.last) const SizedBox(height: 8),
          ],
          const SizedBox(height: 14),
          Divider(color: p.border, height: 1),
          const SizedBox(height: 14),
          _Toggle(
            icon: Icons.vibration_rounded,
            title: 'Vibrate as well',
            subtitle:
                'A phone under a cushion is often found by feel before it is '
                'found by ear.',
            value: ringer.vibrate,
            onChanged: ringer.setVibrate,
          ),
          const SizedBox(height: 12),
          // Two facts the user would otherwise have to discover the hard way.
          Text(
            selected.overridesSilentMode
                ? 'Plays as an alarm, so it is still heard when your phone is on '
                    'silent. Stops when you tap Stop, or after 45 seconds.'
                : 'Plays on the notification channel, so it stays quiet when '
                    'your phone is silenced. Pick another option if you want it '
                    'to override silent mode.',
            style: AppTypography.metadataMono(color: p.muted),
          ),
        ],
      ),
    );
  }
}

/// One row of the phone-ringtone list.
///
/// Shaped deliberately like [_PatternRow] — same radio, same preview button, same
/// selected treatment — because these are two lists of the same kind of thing and
/// making them look different would suggest they behave differently.
class _ToneRow extends StatelessWidget {
  const _ToneRow({
    required this.tone,
    required this.selected,
    required this.busy,
    required this.fileName,
    required this.picking,
    required this.onSelect,
    required this.onPreview,
    this.onPickFile,
    this.onClearFile,
  });

  final PhoneAlertTone tone;
  final bool selected;
  final bool busy;

  /// The chosen file's name, for the custom row only. Null when none is chosen.
  final String? fileName;
  final bool picking;

  final VoidCallback onSelect;
  final VoidCallback onPreview;
  final VoidCallback? onPickFile;
  final VoidCallback? onClearFile;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    // Amber for the one option that will not be heard through silent mode. Same
    // reasoning as the flash-only pattern above: the caveat is worth seeing
    // before it is read.
    final hue = tone.overridesSilentMode ? p.primary : p.warning;
    final needsAFile = tone.needsFile && fileName == null;

    return PressableScale(
      onTap: onSelect,
      child: AnimatedContainer(
        duration: AppMotion.normal,
        curve: AppMotion.standard,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: selected ? hue.withValues(alpha: 0.10) : p.surfaceAlt,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: selected ? hue.withValues(alpha: 0.45) : p.border,
            width: selected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          children: [
            AnimatedContainer(
              duration: AppMotion.normal,
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? hue : Colors.transparent,
                border: Border.all(
                  color: selected ? hue : p.borderStrong,
                  width: 1.6,
                ),
              ),
              child: selected
                  ? Icon(Icons.check_rounded,
                      size: 13, color: p.isDark ? p.background : Colors.white)
                  : null,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tone.label,
                    style: AppTypography.bodyLg(
                        color: selected ? hue : p.onSurface),
                  ),
                  const SizedBox(height: 2),
                  Text(tone.description,
                      style: AppTypography.bodyMd(color: p.muted)),
                  // The file name, once there is one. Shown in the metadata face
                  // rather than as body text because it is a value the user chose,
                  // not prose this app wrote.
                  if (tone.needsFile) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(
                          needsAFile
                              ? Icons.folder_open_rounded
                              : Icons.audio_file_rounded,
                          size: 13,
                          color: needsAFile ? p.muted : p.accent,
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            picking
                                ? 'Choosing…'
                                : fileName ?? 'Tap to choose a sound',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.metadataMono(
                                color: needsAFile ? p.muted : p.accent),
                          ),
                        ),
                        if (!needsAFile && onPickFile != null)
                          TextButton(
                            onPressed: picking ? null : onPickFile,
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 0),
                              minimumSize: const Size(0, 28),
                              tapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Text('Change',
                                style: AppTypography.microLabel(
                                    color: p.primary)),
                          ),
                        // Removing the file has to be reachable, not just
                        // replacing it: an owner who picked a 40 MB podcast by
                        // mistake should be able to undo that, and "pick
                        // something else instead" is not an undo.
                        if (!needsAFile && onClearFile != null)
                          TextButton(
                            onPressed: picking ? null : onClearFile,
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 0),
                              minimumSize: const Size(0, 28),
                              tapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Text('Remove',
                                style: AppTypography.microLabel(
                                    color: p.muted)),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 34,
              height: 34,
              child: picking
                  ? Padding(
                      padding: const EdgeInsets.all(8),
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: hue),
                    )
                  : IconButton(
                      // Nothing to preview until a file exists; the row's own tap
                      // opens the picker in that case, so this stays disabled
                      // rather than silently doing something different.
                      onPressed: needsAFile ? null : onPreview,
                      padding: EdgeInsets.zero,
                      tooltip: needsAFile
                          ? 'Choose a sound first'
                          : busy
                              ? 'Stop'
                              : 'Hear this tone',
                      // A stop square while it is playing, not a spinner. The
                      // sound is the progress indicator; what the user needs from
                      // the button at that moment is a way to end it.
                      icon: Icon(
                        busy ? Icons.stop_rounded : Icons.play_arrow_rounded,
                        size: 20,
                        color: needsAFile ? p.muted : hue,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Distance calibration for the log-distance path loss model.
/// Distance is derived from RSSI as `d = 10^((txPower − RSSI) / (10·n))`. Both
/// parameters are radio- and environment-specific, so exposing them is what makes
/// the readout defensible: hold the keyholder at exactly one metre, read the live
/// dBm shown here, and set that as the reference.
class _CalibrationCard extends StatelessWidget {
  const _CalibrationCard({required this.bleService});

  final BleService bleService;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final model = bleService.proximityModel;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Distance Calibration',
                  style: AppTypography.bodyLg(color: p.onSurface)),
              AppSwap(
                child: Container(
                  key: ValueKey<int>(bleService.currentRssi),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: AppDecorations.pill(p.accent, borderRadius: 8),
                  child: Text(
                    bleService.hasRssiReading
                        ? '${bleService.currentRssi} dBm'
                        : '— dBm',
                    // Teal: this is the live radio reading, the same figure the
                    // scan list and the home readout show in the same hue.
                    style: AppTypography.metadataMono(color: p.accent),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'Hold the keyholder 1 m away, then set the reference to the live '
            'reading above.',
            style: AppTypography.bodyMd(color: p.muted),
          ),
          const SizedBox(height: 8),
          _Row(
            label: 'Reference RSSI at 1 m',
            value: Text('${model.txPower} dBm',
                style: AppTypography.metadataMono(color: p.onSurface)),
          ),
          Slider(
            value: model.txPower.toDouble(),
            min: -90,
            max: -30,
            divisions: 60,
            label: '${model.txPower} dBm',
            onChanged: (v) =>
                bleService.setProximityCalibration(txPower: v.round()),
          ),
          _Row(
            label: 'Path loss exponent (n)',
            value: Text(model.pathLossExponent.toStringAsFixed(1),
                style: AppTypography.metadataMono(color: p.onSurface)),
          ),
          Slider(
            value: model.pathLossExponent,
            min: 1.6,
            max: 4.0,
            divisions: 24,
            label: model.pathLossExponent.toStringAsFixed(1),
            onChanged: (v) => bleService.setProximityCalibration(
                pathLossExponent: double.parse(v.toStringAsFixed(1))),
          ),
          Text(
            '2.0 is free space; 2.5–3.5 suits indoors, where walls and people '
            'absorb the signal.',
            style: AppTypography.bodyMd(color: p.muted),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Battery
// =============================================================================

class _BatteryCard extends StatelessWidget {
  const _BatteryCard({required this.bleService});

  final BleService bleService;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final hasReading = bleService.hasBatteryReading;
    final level = bleService.batteryLevel;

    final barColor = !hasReading
        ? p.muted
        : level > 50
            ? p.success
            : level >= 20
                ? p.warning
                : p.danger;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Key Battery',
                  style: AppTypography.bodyLg(color: p.onSurface)),
              // A dash, not "0%": a reading the app does not have is not zero.
              Text(hasReading ? '$level%' : '—',
                  style:
                      AppTypography.numeric(color: barColor, fontSize: 20)),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            // Tweened rather than set directly, so the bar slides to its new
            // value when a BAT: frame lands instead of jumping a whole segment.
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(
                  begin: 0.0, end: hasReading ? level / 100.0 : 0.0),
              duration: AppMotion.slow,
              curve: AppMotion.standard,
              builder: (context, v, _) => LinearProgressIndicator(
                value: v,
                minHeight: 8,
                backgroundColor: p.surfaceHigh,
                valueColor: AlwaysStoppedAnimation<Color>(barColor),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            hasReading
                ? 'Read from the TP4056 pack through the ADC on GPIO 3.'
                : 'Connect to your keyholder to read its battery level.',
            style: AppTypography.bodyMd(color: p.muted),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Appearance
// =============================================================================

class _AppearanceCard extends StatelessWidget {
  const _AppearanceCard({required this.bleService});

  final BleService bleService;

  @override
  Widget build(BuildContext context) {
    final dark = bleService.darkModeEnabled;

    return _Card(
      child: _Toggle(
        icon: dark ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
        title: 'Dark Mode',
        subtitle: dark
            ? 'Dimmed surfaces, brightened accents — easier at night.'
            : 'Bright surfaces. Switch for low light.',
        value: dark,
        onChanged: bleService.setDarkModeEnabled,
      ),
    );
  }
}

// =============================================================================
// Preferences
// =============================================================================

class _PreferencesCard extends StatelessWidget {
  const _PreferencesCard({required this.bleService});

  final BleService bleService;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    return _Card(
      child: Column(
        children: [
          _Toggle(
            icon: Icons.notifications_active_rounded,
            title: 'Alert Sound',
            subtitle: 'Sound an alarm when your key drifts out of range.',
            value: bleService.alertSoundEnabled,
            onChanged: bleService.setAlertSoundEnabled,
          ),
          Divider(color: p.border, height: 24),
          _Toggle(
            icon: Icons.pin_drop_rounded,
            title: 'Save GPS on Disconnect',
            subtitle:
                'Record where you were the moment the link dropped — the last '
                'place the key was definitely with you.',
            value: bleService.saveGpsOnDisconnect,
            onChanged: bleService.setSaveGpsOnDisconnect,
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Keyholder network
// =============================================================================

/// Wi-Fi, framed correctly.
///
/// This is not a second way for the phone to reach the keyholder, and it is not
/// a transport the user selects. It is a capability given to the *device*, once,
/// so that it can report its own position when the phone is nowhere near it.
/// The app's connection state never mentions it.
class _NetworkCard extends StatelessWidget {
  const _NetworkCard({required this.bleService});

  final BleService bleService;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final syncOn = bleService.wifiCloudSyncEnabled;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Toggle(
            icon: Icons.cloud_upload_rounded,
            title: 'Cloud Reporting',
            subtitle:
                'Let the keyholder upload its position when it has a network.',
            value: syncOn,
            onChanged: bleService.setWifiCloudSyncEnabled,
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: p.surfaceAlt,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: p.border),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, size: 15, color: p.muted),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    bleService.wifiStatusMessage,
                    style: AppTypography.bodyMd(color: p.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              // Sending credentials requires a verified owner link — the
              // provisioning characteristic is encrypted and write-only, and the
              // firmware drops WIFI_SET from an unauthenticated session.
              onPressed: bleService.isConnected
                  ? () => WifiSetupScreen.open(context)
                  : null,
              icon: const Icon(Icons.wifi_rounded, size: 17),
              label: Text(
                bleService.isConnected
                    ? 'Set up the keyholder’s Wi-Fi'
                    : 'Connect to set up Wi-Fi',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Ownership
// =============================================================================

/// Which keyholders this phone holds a key for, and how to let one go.
///
/// Releasing has to be here and has to be easy. A keyholder that only its
/// original phone can ever command is useless the moment that phone is lost,
/// sold or reset — and if the app made release hard, every such case would end
/// with the user prising the case open. The honest design is to make the action
/// available and state plainly what it costs.
class _OwnershipCard extends StatelessWidget {
  const _OwnershipCard({required this.bleService});

  final BleService bleService;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final pairing = context.watch<PairingService>();
    final owned = pairing.ownedDevices;
    final canRelease = bleService.isConnected && pairing.isAuthenticated;

    return _Card(
      borderColor: owned.isEmpty ? null : p.success.withValues(alpha: 0.3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.verified_user_rounded, size: 16, color: p.primary),
              const SizedBox(width: 7),
              Text('Ownership', style: AppTypography.bodyLg(color: p.onSurface)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            owned.isEmpty
                // "does not own any keyholder yet": owning is *claimed*, not
                // merely connected. Connecting to a device does not make it yours
                // — holding its button and claiming it does, and only then does
                // the phone hold the key that proves ownership later.
                ? bleService.isConnected
                    ? 'Connected, but this phone does not own this keyholder '
                        'yet. If it has no owner, hold its button and tap Claim '
                        'on the Pair screen.'
                    : 'This phone does not own any keyholder yet. Connect to one '
                        'and claim it while holding its button.'
                : 'Only this phone can command these keyholders. Anyone else who '
                    'connects is refused and logged.',
            style: AppTypography.bodyMd(color: p.onSurfaceVariant),
          ),
          if (owned.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final device in owned)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: p.successSoft,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.vpn_key_rounded, size: 14, color: p.success),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(device.name,
                                style:
                                    AppTypography.bodyMd(color: p.success)),
                            if (device.claimedOnDisplay.isNotEmpty)
                              Text(device.claimedOnDisplay,
                                  style: AppTypography.microLabel(
                                      color: p.success)),
                            Text(device.deviceId,
                                style: AppTypography.metadataMono(
                                    color: p.onSurfaceVariant)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: owned.isEmpty
                  ? null
                  : () => _release(context, bleService, canRelease),
              style: OutlinedButton.styleFrom(
                foregroundColor: p.danger,
                side: BorderSide(color: p.danger.withValues(alpha: 0.3)),
              ),
              child: const Text('Release Ownership'),
            ),
          ),
          if (owned.isNotEmpty && !canRelease)
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Text(
                // The firmware only honours UNCLAIM from a verified owner, so
                // saying why the button is limited beats letting it fail.
                bleService.isConnected
                    ? 'Connected, but ownership has not been verified yet. Wait '
                        'for the handshake to finish.'
                    : 'Connect to the keyholder first — releasing needs the '
                        'device present so it can forget you too.',
                style: AppTypography.microLabel(color: p.muted),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _release(
      BuildContext context, BleService bleService, bool canRelease) async {
    final pairing = context.read<PairingService>();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Release ownership?'),
        content: Text(
          canRelease
              ? 'Your keyholder will forget this phone and go back to being '
                  'unclaimed. The next person to hold its button can claim it — '
                  'including a stranger, if they have the device.\n\n'
                  'Do this when you are selling or giving it away, or when you '
                  'want to pair it to a different phone.'
              // Local-only removal is a different, weaker action. Conflating the
              // two would let a user believe they had wiped a device they had
              // only stopped tracking.
              : 'This phone is not verified as the owner right now, so the '
                  'keyholder cannot be told to forget you.\n\n'
                  'You can still delete the stored key from this phone. The '
                  'device itself will stay claimed and will refuse you '
                  'afterwards — you would need to hold its button for ten '
                  'seconds to reset it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(canRelease ? 'Release' : 'Delete key from phone'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    if (canRelease) {
      final sent = await pairing.releaseOwnership();
      if (!context.mounted) return;
      _toast(
        context,
        sent
            ? 'Release sent. Waiting for the keyholder to confirm.'
            : pairing.message,
        isError: !sent,
      );
      return;
    }

    // Local-only path: drop every stored key, since without a verified link we
    // cannot know which device the user meant.
    for (final device in pairing.ownedDevices) {
      await pairing.forgetLocally(device.deviceId);
    }
    if (!context.mounted) return;
    _toast(context, 'Ownership keys deleted from this phone.');
  }

  void _toast(BuildContext context, String message, {bool isError = false}) {
    final p = AppPalette.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? p.danger : null,
      ),
    );
  }
}

// =============================================================================
// Demo mode
// =============================================================================

class _DemoModeCard extends StatelessWidget {
  const _DemoModeCard({required this.bleService});

  final BleService bleService;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final on = bleService.demoModeEnabled;

    return _Card(
      tint: on ? p.warningSoft : null,
      borderColor: on ? p.warning : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AnimatedContainer(
                duration: AppMotion.normal,
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: on
                      ? p.warning.withValues(alpha: 0.18)
                      : p.surfaceHigh,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.science_rounded,
                    size: 17, color: on ? p.warning : p.muted),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Demo Mode',
                        style: AppTypography.bodyLg(
                            color: on ? p.warning : p.onSurface)),
                    const SizedBox(height: 2),
                    Text(
                      'Fills the screens with simulated devices and signal data '
                      'for presentations, behind a permanent banner.',
                      style: AppTypography.bodyMd(color: p.muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Switch(
                value: on,
                onChanged: (val) async {
                  await bleService.setDemoModeEnabled(val);
                  if (!context.mounted) return;
                  // If the service refused — a real keyholder is connected —
                  // say so rather than silently snapping back.
                  if (val && !bleService.demoModeEnabled) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(bleService.lastError)),
                    );
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Simulated devices cannot be paired with or authenticated. Nothing '
            'in Demo Mode can hide the real state of your keyholder.',
            style: AppTypography.microLabel(color: on ? p.warning : p.muted),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Danger zone
// =============================================================================

class _DangerZone extends StatelessWidget {
  const _DangerZone({required this.bleService});

  final BleService bleService;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final connected = bleService.isConnected;

    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: bleService.toggleDeviceConnection,
            icon: Icon(
                connected
                    ? Icons.link_off_rounded
                    : Icons.bluetooth_searching_rounded,
                size: 18),
            // Uses the real device name and reflects whether there is anything
            // to reconnect to, instead of always saying "Keyholder 01".
            label: Text(connected
                ? 'Disconnect ${bleService.deviceName}'
                : bleService.hasKnownDevice
                    ? 'Reconnect ${bleService.deviceName}'
                    : 'Scan for a keyholder'),
            style: FilledButton.styleFrom(
              backgroundColor: connected ? p.surfaceHigh : p.primary,
              foregroundColor: connected ? p.onSurface : p.onPrimary,
            ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => _confirmClear(context),
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            label: const Text('Clear All History'),
            style: OutlinedButton.styleFrom(
              foregroundColor: p.danger,
              side: BorderSide(color: p.danger.withValues(alpha: 0.3)),
            ),
          ),
        ),
      ],
    );
  }

  void _confirmClear(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear all history?'),
        content: const Text(
          'Every logged connection, ping and blocked-intruder record will be '
          'deleted from this phone. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              bleService.clearAllHistory();
              Navigator.of(dialogContext).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('History cleared.')),
              );
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }
}
