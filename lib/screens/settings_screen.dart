import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../build_info.dart';
import '../services/ble_service.dart';
import '../services/pairing_service.dart';
import '../theme/app_theme.dart';
import '../widgets/motion.dart';

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
                          _CalibrationCard(bleService: bleService),
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
                          const _SectionLabel('DANGER ZONE'),
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
              Icon(Icons.settings_rounded, size: 20, color: p.primary),
              const SizedBox(width: 9),
              Text('Settings',
                  style: AppTypography.headlineLg(color: p.onSurface)),
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

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 0),
      child: Text(text, style: AppTypography.labelCaps(color: p.muted)),
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

    final (IconData pillIcon, Color pillFg, Color pillBg) = switch ((
      connected,
      fixed,
    )) {
      (false, _) => (Icons.gps_off_rounded, p.muted, p.surfaceHigh),
      (true, true) => (Icons.gps_fixed_rounded, p.success, p.successSoft),
      (true, false) => (Icons.gps_not_fixed_rounded, p.warning, p.warningSoft),
    };
    final pillText =
        !connected ? 'No link' : (fixed ? 'GPS fixed' : 'Searching…');

    return _Card(
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: p.primarySoft,
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(Icons.developer_board_rounded,
                size: 25, color: p.primary),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(bleService.deviceName,
                    style: AppTypography.headlineMd(color: p.onSurface),
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text('ESP32-C3  •  ${bleService.deviceId}',
                    style: AppTypography.metadataMono(color: p.muted),
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: 8),
          AnimatedContainer(
            duration: AppMotion.normal,
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: pillBg,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              children: [
                Icon(pillIcon, size: 12, color: pillFg),
                const SizedBox(width: 4),
                Text(pillText, style: AppTypography.microLabel(color: pillFg)),
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
        ],
      ),
    );
  }
}

/// Distance calibration for the log-distance path loss model.
///
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
                  decoration: BoxDecoration(
                    color: p.primarySoft,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    bleService.hasRssiReading
                        ? '${bleService.currentRssi} dBm'
                        : '— dBm',
                    style: AppTypography.metadataMono(color: p.primary),
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
                  ? () => _showNotYetWired(context)
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

  void _showNotYetWired(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Wi-Fi provisioning is next up — the firmware already accepts '
          'WIFI_SET, the app screen is not built yet.',
        ),
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
                ? 'This phone does not own any keyholder yet. Pair one from the '
                    'Scan tab.'
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
