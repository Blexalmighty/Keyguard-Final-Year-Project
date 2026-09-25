import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/ble_device.dart';
import '../services/ble_service.dart';
import '../services/pairing_service.dart';
import '../theme/app_theme.dart';
import '../widgets/motion.dart';
import '../widgets/ownership_badge.dart';
import '../widgets/passkey_entry_sheet.dart';

/// The claim flow: an unowned keyholder becomes *yours*, and nobody else's.
///
/// Every state this screen can show maps to a real firmware response — there is
/// no optimistic UI here. If the device says `CLAIM_DENIED`, the screen says the
/// claim was denied and why, rather than spinning and hoping.
///
/// The stage card is the whole screen, really: it cross-fades between states via
/// [AppSwap] rather than swapping instantly, because a claim that flips from
/// "Claiming" to "Refused" in one frame reads as a glitch. Seeing the change
/// happen is what tells the user the app noticed something, and the colour it
/// lands on is what tells them whether it went well.
class PairingScreen extends StatelessWidget {
  const PairingScreen({super.key, required this.device});

  /// The keyholder being claimed, as it appeared in the scan list.
  final BleDevice device;

  static Future<void> open(BuildContext context, BleDevice device) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PairingScreen(device: device)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    return Scaffold(
      // The app bar takes its colours from `appBarTheme`, which is palette-driven
      // in both brightnesses — the `isDark ? … : …` pairs this screen used to
      // carry were re-deriving what the theme already knows.
      appBar: AppBar(title: const Text('Pair keyholder')),
      body: Consumer2<BleService, PairingService>(
        builder: (context, bleService, pairing, _) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...staggered([
                  _DeviceHeader(device: device, bleService: bleService),
                  _StageCard(step: _describe(bleService, pairing, p)),
                  _Actions(
                    device: device,
                    bleService: bleService,
                    pairing: pairing,
                  ),
                ], step: AppMotion.stagger)
                    .expand((w) => [w, const SizedBox(height: 20)]),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Maps live service state onto one honest sentence.
  ///
  /// The order of these checks matters: connection state is checked before
  /// pairing stage, because a stale `authenticated` stage after a dropped link
  /// would otherwise be shown as success.
  ///
  /// Colours come from the palette rather than from literals so that a refusal is
  /// the *same* red as every other refusal in the app, in both themes. The old
  /// version hardcoded `0xFF00562A` for success — a dark green that turned into
  /// near-black text on a glowing chip once dark mode existed.
  _Step _describe(BleService bleService, PairingService pairing, AppPalette p) {
    if (!bleService.isConnected) {
      if (bleService.isConnecting) {
        return _Step(
          title: 'Connecting',
          detail: 'Opening a link to the keyholder.',
          icon: Icons.bluetooth_searching_rounded,
          fg: p.primary,
          bg: p.primarySoft,
          busy: true,
        );
      }
      return _Step(
        title: 'Not connected',
        detail: 'Connect to the keyholder to find out whether it already has an '
            'owner. Keep it within a metre or so while you pair.',
        icon: Icons.bluetooth_disabled_rounded,
        fg: p.muted,
        bg: p.surfaceHigh,
      );
    }

    switch (pairing.stage) {
      case PairingStage.awaitingButtonHold:
        return _Step(
          title: 'Hold the button',
          detail: 'This keyholder has no owner yet. Press and hold the button '
              'on the device, then tap Claim while still holding it. The '
              'firmware refuses a claim from anyone who is not physically '
              'holding the device — that is what stops a stranger claiming it '
              'from across the room.',
          icon: Icons.touch_app_rounded,
          fg: p.primary,
          bg: p.primarySoft,
        );

      case PairingStage.claiming:
        return _Step(
          title: 'Claiming',
          detail: pairing.message,
          icon: Icons.hourglass_top_rounded,
          fg: p.primary,
          bg: p.primarySoft,
          busy: true,
        );

      case PairingStage.claimDenied:
        return _Step(
          title: 'Claim refused',
          detail: pairing.message,
          icon: Icons.gpp_bad_rounded,
          fg: p.danger,
          bg: p.dangerSoft,
        );

      case PairingStage.claimed:
        return _Step(
          title: 'This keyholder is yours',
          detail: pairing.message,
          icon: Icons.verified_user_rounded,
          fg: p.success,
          bg: p.successSoft,
        );

      case PairingStage.authenticating:
        return _Step(
          title: 'Proving ownership',
          detail: pairing.message,
          icon: Icons.hourglass_top_rounded,
          fg: p.primary,
          bg: p.primarySoft,
          busy: true,
        );

      case PairingStage.authenticated:
        return _Step(
          title: 'Owner verified',
          detail: pairing.message,
          icon: Icons.verified_rounded,
          fg: p.success,
          bg: p.successSoft,
        );

      case PairingStage.authFailed:
        return _Step(
          title: 'Refused by the keyholder',
          detail: pairing.message,
          icon: Icons.lock_rounded,
          fg: p.danger,
          bg: p.dangerSoft,
        );

      case PairingStage.lockedOut:
        return _Step(
          title: 'Keyholder locked',
          detail: pairing.message,
          icon: Icons.timer_off_rounded,
          fg: p.danger,
          bg: p.dangerSoft,
        );

      case PairingStage.released:
        return _Step(
          title: 'Ownership released',
          detail: pairing.message,
          icon: Icons.lock_open_rounded,
          fg: p.primary,
          bg: p.primarySoft,
        );

      case PairingStage.idle:
        return _Step(
          title: 'Connected',
          detail: 'Ready.',
          icon: Icons.link_rounded,
          fg: p.primary,
          bg: p.primarySoft,
        );
    }
  }
}

// =============================================================================
// Header
// =============================================================================

class _DeviceHeader extends StatelessWidget {
  const _DeviceHeader({required this.device, required this.bleService});

  final BleDevice device;
  final BleService bleService;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(13, 16, 16, 16),
      // The same indigo left edge the scan list uses for a keyholder, so arriving
      // here from a tap on that card feels like the card expanded rather than
      // like a different screen opened.
      decoration: AppDecorations.accented(p, p.primary),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: p.primarySoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.vpn_key_rounded, size: 22, color: p.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  // displayNameFor, not device.name: a claimed keyholder
                  // advertises the generic "FindMe", so the name on this
                  // header should be *this phone's* name for it when there is
                  // one (see SettingsStore.nicknameFor).
                  bleService.displayNameFor(device.id, advertised: device.name),
                  style: AppTypography.headlineMd(color: p.onSurface),
                ),
                const SizedBox(height: 3),
                Text(device.id,
                    style: AppTypography.metadataMono(color: p.muted)),
                const SizedBox(height: 6),
                OwnershipBadge(
                  state: bleService.isConnected
                      ? bleService.ownershipState
                      : device.ownership,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Stage card
// =============================================================================

class _StageCard extends StatelessWidget {
  const _StageCard({required this.step});

  final _Step step;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    // `AnimatedContainer` handles the tint, `AppSwap` handles the contents. Doing
    // both in the switcher would cross-fade two differently-coloured boxes over
    // each other, which flickers; tinting in place and swapping the text reads as
    // one card changing its mind.
    return AnimatedContainer(
      duration: AppMotion.normal,
      curve: AppMotion.standard,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: step.bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: step.fg.withValues(alpha: 0.3)),
      ),
      child: AppSwap(
        alignment: Alignment.topLeft,
        child: Column(
          // Keyed on the title, which is unique per stage — without a key the
          // switcher cannot tell that the stage changed.
          key: ValueKey<String>(step.title),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: step.busy
                      ? CircularProgressIndicator(
                          strokeWidth: 2, color: step.fg)
                      : Icon(step.icon, size: 18, color: step.fg),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(step.title,
                      style: AppTypography.headlineMd(color: step.fg)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(step.detail,
                style: AppTypography.bodyMd(color: p.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Actions
// =============================================================================

class _Actions extends StatelessWidget {
  const _Actions({
    required this.device,
    required this.bleService,
    required this.pairing,
  });

  final BleDevice device;
  final BleService bleService;
  final PairingService pairing;

  @override
  Widget build(BuildContext context) {
    if (!bleService.isConnected) {
      return FilledButton(
        onPressed: bleService.isConnecting
            ? null
            : () => bleService.connectDevice(device.id),
        child: Text(bleService.isConnecting ? 'Connecting…' : 'Connect'),
      );
    }

    final children = <Widget>[];

    if (pairing.canClaim) {
      children.add(FilledButton(
        onPressed: pairing.isBusy ? null : () => _claim(context),
        child: const Text('Claim this keyholder'),
      ));
    }

    if (pairing.stage == PairingStage.claimDenied) {
      children.add(FilledButton(
        onPressed: () => context.read<PairingService>().claimConnectedDevice(),
        child: const Text('Try again — hold the button first'),
      ));
    }

    if (pairing.stage == PairingStage.claimed ||
        pairing.stage == PairingStage.authenticated) {
      children.add(FilledButton(
        onPressed: () => Navigator.of(context).maybePop(),
        child: const Text('Done'),
      ));
    }

    if (children.isEmpty ||
        pairing.stage == PairingStage.authFailed ||
        pairing.stage == PairingStage.lockedOut) {
      children.add(OutlinedButton(
        onPressed: () => bleService.disconnectDevice(device.id),
        child: const Text('Disconnect'),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          children[i],
        ],
      ],
    );
  }

  Future<void> _claim(BuildContext context) async {
    // Bond first, claim second. The firmware marks every characteristic as
    // requiring an encrypted, MITM-protected link, so the claim write cannot
    // reach it unbonded — the OS would interrupt with a passkey prompt mid-claim.
    // Doing it here keeps the two steps apart.
    final ok = await PasskeyEntrySheet.show(context);
    if (!context.mounted) return;
    if (!ok) {
      final proceed = await _confirmPairLater(context);
      if (!context.mounted || !proceed) return;
    }
    await context.read<PairingService>().claimConnectedDevice();
  }

  /// Warns about the one real consequence of skipping the pairing step.
  ///
  /// It is not "claim without encryption" — the keyholder refuses unencrypted
  /// access at the Bluetooth stack level, so that is not something the app can
  /// do even deliberately. The consequence is timing: the passkey prompt will
  /// appear during the claim, while the button is still being held.
  Future<bool> _confirmPairLater(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final p = AppPalette.of(dialogContext);
        return AlertDialog(
          title: Text('Pair during the claim?',
              style: AppTypography.headlineMd(color: p.onSurface)),
          content: Text(
            'The keyholder refuses every unencrypted request, so your phone '
            'will still ask for the six-digit code — it will just ask in the '
            'middle of the claim.\n\n'
            'That means holding the button on the device with one hand while '
            'typing the code with the other, and the claim fails if you let go. '
            'Pairing first keeps the two steps apart.',
            style: AppTypography.bodyMd(color: p.onSurfaceVariant),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Pair first'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text('Continue anyway',
                  style: AppTypography.bodyLg(color: p.muted)),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }
}


/// One rendering of the pairing state: what the user is told, and how it looks.
class _Step {
  const _Step({
    required this.title,
    required this.detail,
    required this.icon,
    required this.fg,
    required this.bg,
    this.busy = false,
  });

  final String title;
  final String detail;
  final IconData icon;
  final Color fg;
  final Color bg;

  /// Shows a spinner in place of [icon] — only for states that really are
  /// waiting on the hardware.
  final bool busy;
}
