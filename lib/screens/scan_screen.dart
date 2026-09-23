import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/ble_device.dart';
import '../services/ble_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_logo_tile.dart';
import '../widgets/motion.dart';
import '../widgets/ownership_badge.dart';
import '../widgets/radar_painter.dart';
import '../widgets/section_label.dart';
import 'pairing_screen.dart';

/// Device discovery.
///
/// **There is deliberately no Bluetooth-vs-Wi-Fi split here, and no filter.**
/// The screen used to carry three transport chips — All / Bluetooth / Wi-Fi —
/// and a whole Wi-Fi panel, which implied the phone could reach the keyholder
/// over either radio. It cannot: the phone-to-keyholder link is always BLE.
/// Wi-Fi is something the keyholder uses by itself, to reach the cloud when the
/// phone is out of range.
///
/// Those chips were then replaced by a relevance filter — All nearby vs
/// Keyholders only — which is gone for the same underlying reason: it made the
/// list's contents depend on a mode the user had to notice and get right, and a
/// keyholder sitting behind the wrong selection looks exactly like a keyholder
/// that is not there. One unfiltered list of what the radio can see is both
/// simpler and harder to misread; keyholders are sorted to the top and given the
/// emphasised card, which is what the filter was really for.
///
/// Network setup for the keyholder lives in Settings, where it belongs — it is a
/// once-per-device configuration step, not a peer of "find my keys".
class ScanScreen extends StatelessWidget {
  const ScanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final bleService = context.watch<BleService>();
    final p = AppPalette.of(context);
    final devices = bleService.filteredScannedDevices;

    return Scaffold(
      backgroundColor: p.background,
      body: SafeArea(
        child: Column(
          children: [
            _ScanAppBar(bleService: bleService),
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
                        // Only ever one banner, and only when it is actionable.
                        // A screen that stacks three notices teaches the user to
                        // ignore all of them.
                        AppSwap(
                          alignment: Alignment.topCenter,
                          child: _banner(context, bleService, p),
                        ),

                        const SizedBox(height: 8),
                        FadeSlideIn(
                          child: Center(
                            child: RadarWidget(
                              isScanning: bleService.isScanning,
                              deviceCount: devices.length,
                              onTap: bleService.toggleScanning,
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),

                        FadeSlideIn(
                          delay: AppMotion.stagger,
                          child: _statusText(bleService, p),
                        ),
                        const SizedBox(height: 20),

                        FadeSlideIn(
                          delay: AppMotion.stagger * 2,
                          child: _resultsHeader(bleService, devices.length, p),
                        ),
                        const SizedBox(height: 12),

                        if (devices.isEmpty)
                          FadeSlideIn(
                            delay: AppMotion.stagger * 3,
                            child: _EmptyResults(bleService: bleService),
                          )
                        else
                          // Keyed by device id so a card that appears mid-scan
                          // animates in on its own rather than the whole list
                          // re-running its entrance. The key is propagated by
                          // staggered() to the FadeSlideIn wrapper, so Flutter
                          // preserves the animation state across scan rebuilds.
                          ...staggered([
                            for (final device in devices)
                              Padding(
                                key: ValueKey<String>(device.id),
                                padding: const EdgeInsets.only(bottom: 12),
                                child: _DeviceCard(
                                  device: device,
                                  bleService: bleService,
                                ),
                              ),
                          ]),

                        const SizedBox(height: 24),
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

  Widget _statusText(BleService bleService, AppPalette p) {
    return Column(
      children: [
        AppSwap(
          child: Text(
            bleService.isScanning
                ? 'Looking for your keyholder…'
                : 'Scanning paused',
            key: ValueKey<bool>(bleService.isScanning),
            style: AppTypography.headlineMd(color: p.onSurface),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Tap the dial to ${bleService.isScanning ? 'stop' : 'start'}',
          style: AppTypography.bodyMd(color: p.muted),
        ),
      ],
    );
  }

  Widget _resultsHeader(BleService bleService, int shown, AppPalette p) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // The tick goes teal only while the radio is actually sweeping. Accent is
        // this app's colour for live measurement, so the heading itself reports
        // whether the list below it is still growing.
        SectionLabel(
          'NEARBY DEVICES',
          color: bleService.isScanning ? p.accent : p.muted,
          textColor: p.onSurfaceVariant,
        ),
        AnimatedContainer(
          duration: AppMotion.normal,
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: AppDecorations.pill(
            bleService.isScanning ? p.accent : p.muted,
            borderRadius: 12,
          ),
          child: Text('FOUND: $shown',
              style: AppTypography.metadataMono(
                  color: bleService.isScanning ? p.accent : p.muted)),
        ),
      ],
    );
  }

  /// The single most useful notice, or nothing.
  Widget _banner(BuildContext context, BleService bleService, AppPalette p) {
    if (!bleService.hasBluetoothPermission) {
      return Padding(
        key: const ValueKey('permission'),
        padding: const EdgeInsets.only(bottom: 16),
        child: _PermissionBanner(bleService: bleService),
      );
    }
    if (!bleService.isBluetoothOn) {
      return Padding(
        key: const ValueKey('adapter'),
        padding: const EdgeInsets.only(bottom: 16),
        child: _InfoBanner(
          icon: Icons.bluetooth_disabled,
          message: 'Bluetooth is off. Turn it on to find your keyholder.',
          fg: p.danger,
          bg: p.dangerSoft,
        ),
      );
    }
    if (bleService.lastError.isNotEmpty) {
      return Padding(
        key: const ValueKey('error'),
        padding: const EdgeInsets.only(bottom: 16),
        child: _InfoBanner(
          icon: Icons.error_outline,
          message: bleService.lastError,
          fg: p.danger,
          bg: p.dangerSoft,
          onDismiss: bleService.clearError,
        ),
      );
    }
    if (bleService.permissionStatusMessage.isNotEmpty) {
      return Padding(
        key: const ValueKey('hint'),
        padding: const EdgeInsets.only(bottom: 16),
        child: _InfoBanner(
          icon: Icons.info_outline,
          message: bleService.permissionStatusMessage,
          fg: p.warning,
          bg: p.warningSoft,
        ),
      );
    }
    return const SizedBox.shrink(key: ValueKey('none'));
  }
}

// =============================================================================
// App bar
// =============================================================================

class _ScanAppBar extends StatelessWidget {
  const _ScanAppBar({required this.bleService});

  final BleService bleService;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final connected = bleService.isConnected;

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
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const AppLogoTile(),
                  const SizedBox(width: 10),
                  const AppWordmark('FindX'),
                ],
              ),

              // One state, one word. Notably absent: which radio it arrived on.
              AnimatedContainer(
                duration: AppMotion.normal,
                curve: AppMotion.standard,
                padding: const EdgeInsets.only(left: 6, right: 11, top: 5,
                    bottom: 5),
                decoration: BoxDecoration(
                  color: connected ? p.successSoft : p.surfaceHigh,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: connected
                        ? p.success.withValues(alpha: 0.3)
                        : p.border,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PulseDot(
                      color: connected ? p.success : p.muted,
                      active: connected,
                      size: 7,
                      haloSize: 18,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      connected ? 'Connected' : 'Disconnected',
                      style: AppTypography.microLabel(
                        color: connected ? p.success : p.muted,
                      ).copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Banners
// =============================================================================

class _PermissionBanner extends StatelessWidget {
  const _PermissionBanner({required this.bleService});

  final BleService bleService;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.dangerSoft,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.danger.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: p.danger, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              // Location is not named here: the manifest declares BLUETOOTH_SCAN
              // with neverForLocation, so on Android 12+ this app asks for no
              // location permission at all.
              'Bluetooth permission is required to scan for your keyholder.',
              style: AppTypography.bodyMd(color: p.danger),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: bleService.requestPermissions,
            style: FilledButton.styleFrom(
              backgroundColor: p.danger,
              foregroundColor: p.isDark ? const Color(0xFF3A0B06) : Colors.white,
              minimumSize: const Size(0, 38),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Grant'),
          ),
        ],
      ),
    );
  }
}

/// A single-line notice strip. Used for Bluetooth being off, for a scan or
/// connection error the service has recorded, and for the permission hint.
class _InfoBanner extends StatelessWidget {
  const _InfoBanner({
    required this.icon,
    required this.message,
    required this.fg,
    required this.bg,
    this.onDismiss,
  });

  final IconData icon;
  final String message;
  final Color fg;
  final Color bg;

  /// Shows a close button when non-null.
  ///
  /// Only the error banner passes one. "Bluetooth is off" and the permission
  /// hint describe a condition that is still true — dismissing those would hide
  /// a fact, not an old message — so they stay until the condition changes.
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(12, 12, onDismiss == null ? 12 : 4, 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: fg.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: fg, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: AppTypography.bodyMd(color: fg)),
          ),
          if (onDismiss != null)
            IconButton(
              onPressed: onDismiss,
              icon: Icon(Icons.close_rounded, color: fg, size: 18),
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              padding: EdgeInsets.zero,
            ),
        ],
      ),
    );
  }
}

// =============================================================================
// Empty state
// =============================================================================

/// Honest empty state. The old build never showed one, because the service
/// injected a phantom keyholder card whenever the scan found nothing.
class _EmptyResults extends StatelessWidget {
  const _EmptyResults({required this.bleService});

  final BleService bleService;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    final String message;
    if (!bleService.hasBluetoothPermission) {
      message = 'Grant the Bluetooth permission above to start scanning.';
    } else if (!bleService.isBluetoothOn) {
      message = 'Bluetooth is off, so nothing can be found.';
    } else if (bleService.isScanning) {
      message = 'Scanning… nothing in range yet. Keep the keyholder within a '
          'few metres of the phone.';
    } else {
      message = 'Tap the dial to scan for nearby devices.';
    }

    return Container(
      padding: const EdgeInsets.all(26),
      decoration: AppDecorations.card(p),
      child: Column(
        children: [
          // Rotates gently while scanning: an empty state that is visibly
          // working is not the same message as an empty state that has given up.
          _SpinWhile(
            active: bleService.isScanning,
            child: Icon(
              bleService.isScanning
                  ? Icons.radar_rounded
                  : Icons.bluetooth_searching_rounded,
              size: 32,
              color: p.muted,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: AppTypography.bodyMd(color: p.muted),
          ),
        ],
      ),
    );
  }
}

class _SpinWhile extends StatefulWidget {
  const _SpinWhile({required this.child, required this.active});

  final Widget child;
  final bool active;

  @override
  State<_SpinWhile> createState() => _SpinWhileState();
}

class _SpinWhileState extends State<_SpinWhile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _c.repeat();
  }

  @override
  void didUpdateWidget(_SpinWhile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active) return;
    widget.active ? _c.repeat() : _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      RotationTransition(turns: _c, child: widget.child);
}

// =============================================================================
// Device card
// =============================================================================

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.device, required this.bleService});

  final BleDevice device;
  final BleService bleService;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final action = _actionFor(context, bleService, device);
    final isKeyholder = device.isKeyholder;

    final (IconData iconData, Color iconBg, Color iconFg) = switch (
        device.deviceType) {
      BleDeviceType.keyholder => (Icons.vpn_key_rounded, p.primarySoft,
          p.primary),
      BleDeviceType.headphones => (Icons.headphones_rounded, p.primarySoft,
          p.primary),
      BleDeviceType.watch => (Icons.watch_rounded, p.surfaceHigh, p.muted),
      BleDeviceType.bluetooth => (Icons.bluetooth_rounded, p.surfaceHigh,
          p.muted),
      BleDeviceType.generic => (Icons.devices_other_rounded, p.surfaceHigh,
          p.muted),
    };

    // Keyholders get the emphasised treatment. Previously this branch was driven
    // by `isPrimary`, which the service set on an injected phantom card — so the
    // highlight had nothing to do with real hardware.
    //
    // The emphasis is a coloured left edge rather than a coloured border all the
    // way round, matching the connection card on Home: an edge carries the state
    // at a glance without turning the whole row into a warning label. The hue
    // *is* the state — green connected, grey locked out, indigo available.
    final edge = device.isLockedToAnotherOwner
        ? p.muted
        : device.isConnected
            ? p.success
            : p.primary;
    final decoration = isKeyholder
        ? AppDecorations.accented(p, edge)
        : AppDecorations.card(p, elevated: false);

    final shortId = device.macAddress.length > 12
        ? device.macAddress.substring(0, 12)
        : device.macAddress;

    return PressableScale(
      // The whole card opens the pairing screen for a keyholder, so the button is
      // a shortcut rather than the only route. Non-keyholders have nothing to
      // show, so tapping them does nothing.
      onTap: isKeyholder && !device.isDemo && !device.isLockedToAnotherOwner
          ? () => PairingScreen.open(context, device)
          : null,
      child: AnimatedContainer(
        duration: AppMotion.normal,
        curve: AppMotion.standard,
        padding: EdgeInsets.fromLTRB(isKeyholder ? 13 : 16, 16, 16, 16),
        decoration: decoration,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Stack(
                  children: [
                    Container(
                      width: isKeyholder ? 48 : 44,
                      height: isKeyholder ? 48 : 44,
                      decoration: BoxDecoration(
                        color: iconBg,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(iconData,
                          color: iconFg, size: isKeyholder ? 26 : 22),
                    ),
                    if (device.isConnected)
                      Positioned(
                        bottom: -2,
                        right: -2,
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: p.surface,
                          ),
                          child: PulseDot(
                              color: p.success, size: 8, haloSize: 14),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // A device that broadcast no name is shown in italic muted
                      // type rather than being given an invented one. The name
                      // is the one thing on this card the user might act on, so
                      // it has to be visibly a placeholder when it is one.
                      Text(
                        device.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: isKeyholder
                            ? AppTypography.headlineMd(color: p.primary)
                            : AppTypography.bodyLg(
                                color: device.hasAdvertisedName
                                    ? p.onSurface
                                    : p.muted,
                              ).copyWith(
                                fontStyle: device.hasAdvertisedName
                                    ? FontStyle.normal
                                    : FontStyle.italic,
                              ),
                      ),
                      // What the advertisement implied, when it gave no name.
                      // Separate line, separate weight: this is evidence about
                      // the device, not its identity.
                      if (device.hint != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          device.hint!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.bodyMd(color: p.onSurfaceVariant),
                        ),
                      ],
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          // The dBm figure is a live measurement, so it takes the
                          // accent; the MAC beside it is an identifier and stays
                          // muted. Same rule as the home screen's readout.
                          Icon(Icons.signal_cellular_alt_rounded,
                              size: 12, color: p.accent),
                          const SizedBox(width: 4),
                          Text('${device.rssi} dBm',
                              style: AppTypography.metadataMono(
                                  color: p.accent)),
                          Expanded(
                            child: Text('  •  $shortId',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTypography.metadataMono(
                                    color: p.muted)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _ActionButton(action: action, prominent: isKeyholder),
              ],
            ),

            // The ownership lock, stated rather than implied.
            if (device.isDemo || device.ownership != OwnershipState.unknown) ...[
              const SizedBox(height: 12),
              OwnershipBadge(state: device.ownership, isDemo: device.isDemo),
            ],
            if (action.reason != null) ...[
              const SizedBox(height: 7),
              Text(
                action.reason!,
                style: AppTypography.metadataMono(color: p.muted),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// What a device card's button should say, and whether it should do anything.
  ///
  /// The lock itself is enforced by the firmware — the app cannot stop anyone
  /// connecting to a BLE peripheral. But offering a Connect button that the
  /// keyholder will silently refuse is worse than not offering one, so a locked
  /// or simulated device gets a dead button and a stated reason.
  _CardAction _actionFor(
      BuildContext context, BleService bleService, BleDevice device) {
    if (device.isDemo) {
      return const _CardAction(
        label: 'Demo',
        isSecondary: true,
        reason: 'Simulated entry — it cannot be paired with or authenticated.',
      );
    }
    if (device.isLockedToAnotherOwner) {
      return const _CardAction(
        label: 'Locked',
        isSecondary: true,
        reason: 'Owned by another user. Its owner must release it before you '
            'can pair.',
      );
    }
    if (device.isConnected) {
      return _CardAction(
        label: 'Disconnect',
        isSecondary: true,
        onPressed: () => bleService.disconnectDevice(device.id),
      );
    }
    if (bleService.isConnecting) {
      return const _CardAction(label: 'Connecting', isSecondary: true,
          busy: true);
    }

    // A keyholder goes to the pairing screen, which connects and then explains
    // whatever the firmware says about ownership. Anything else — headphones, a
    // watch — just connects, because there is nothing to claim.
    if (device.isKeyholder) {
      return _CardAction(
        label: device.ownership == OwnershipState.claimedByMe ||
                device.ownership == OwnershipState.authenticated
            ? 'Connect'
            : 'Pair',
        onPressed: () => PairingScreen.open(context, device),
      );
    }

    return _CardAction(
      label: 'Connect',
      onPressed: () => bleService.connectDevice(device.id),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.action, required this.prominent});

  final _CardAction action;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    return FilledButton(
      onPressed: action.onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: action.isSecondary ? p.surfaceHigh : p.primary,
        foregroundColor: action.isSecondary ? p.onSurface : p.onPrimary,
        disabledBackgroundColor: p.surfaceHigh,
        disabledForegroundColor: p.muted,
        elevation: 0,
        minimumSize: Size(0, prominent ? 40 : 36),
        padding: EdgeInsets.symmetric(horizontal: prominent ? 16 : 12),
        textStyle: AppTypography.headlineMd()
            .copyWith(fontSize: prominent ? 13 : 12),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: AppSwap(
        child: action.busy
            ? SizedBox(
                key: const ValueKey('busy'),
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: p.muted),
              )
            : Text(action.label, key: ValueKey<String>(action.label)),
      ),
    );
  }
}

class _CardAction {
  const _CardAction({
    required this.label,
    this.onPressed,
    this.isSecondary = false,
    this.reason,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool isSecondary;

  /// Why the button is dead, shown under the card. Null when it is live.
  final String? reason;

  /// Shows a spinner instead of the label.
  final bool busy;
}
