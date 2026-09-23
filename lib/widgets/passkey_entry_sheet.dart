import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import '../services/ble_service.dart';
import '../theme/app_theme.dart';
import 'motion.dart';

/// Walks the user through the OLED passkey step of pairing.
///
/// **Read this before changing it.** The obvious design — a six-box PIN field in
/// the app — cannot work, and building one would be a lie. No mobile platform
/// exposes an API for an app to supply a BLE passkey: on Android the Settings
/// process owns that dialog, and on iOS CoreBluetooth handles it invisibly.
/// That restriction is a *feature*. If an app could answer the passkey
/// challenge, a malicious app could pair with your keyholder without you ever
/// seeing the code on its screen — which is exactly the attack Passkey Entry
/// exists to prevent.
///
/// So this sheet's real job is to tell the user what is about to happen, trigger
/// the system prompt at a moment they expect it, and then report the outcome
/// truthfully instead of guessing.
class PasskeyEntrySheet extends StatefulWidget {
  const PasskeyEntrySheet({super.key});

  /// Returns true once the link is bonded, false if the user backed out.
  static Future<bool> show(BuildContext context) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const PasskeyEntrySheet(),
    );
    return result ?? false;
  }

  @override
  State<PasskeyEntrySheet> createState() => _PasskeyEntrySheetState();
}

class _PasskeyEntrySheetState extends State<PasskeyEntrySheet> {
  bool _waiting = false;
  String _error = '';

  Future<void> _pair() async {
    final bleService = context.read<BleService>();
    setState(() {
      _waiting = true;
      _error = '';
    });

    final bonded = await bleService.startBonding();
    if (!mounted) return;

    if (bonded) {
      Navigator.of(context).pop(true);
      return;
    }

    setState(() {
      _waiting = false;
      _error = bleService.lastError.isNotEmpty
          ? bleService.lastError
          : 'Pairing was cancelled or the code did not match. Check the number '
              'on your FindMe and try again.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final bleService = context.watch<BleService>();
    // One palette lookup replaces the `isDark ? … : …` pair that used to derive
    // the surface and text colours by hand — the reason dark mode had tones
    // nothing else in the app used.
    final p = AppPalette.of(context);

    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: p.borderStrong,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),

            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: p.primarySoft,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.password_rounded,
                      size: 18, color: p.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('Encrypt the connection',
                      style: AppTypography.headlineMd(color: p.onSurface)),
                ),
              ],
            ),
            const SizedBox(height: 14),

            const _OledMock(),
            const SizedBox(height: 16),

            Text(
              'Your FindMe is showing a six-digit code on its screen.',
              style: AppTypography.bodyLg(color: p.onSurface),
            ),
            const SizedBox(height: 8),
            Text(
              bleService.supportsBonding
                  // Naming the system dialog matters: users abandon pairing when
                  // an unexpected OS prompt appears over an app they trust.
                  ? 'Tap Pair below. Android will ask you for that code — type '
                      'it into the phone\'s own dialog, not into this app. Only '
                      'the operating system can accept a Bluetooth passkey, '
                      'which is what stops an app from pairing behind your back.'
                  : 'iOS handles Bluetooth pairing itself. When the code appears '
                      'on your FindMe, enter it in the system prompt that '
                      'iOS shows. This app cannot see or supply it.',
              style: AppTypography.bodyMd(color: p.onSurfaceVariant),
            ),

            if (bleService.bondState == BluetoothBondState.bonded) ...[
              const SizedBox(height: 14),
              _Notice(
                icon: Icons.lock_rounded,
                message: 'This phone is already paired with the keyholder. The '
                    'link is encrypted.',
                fg: p.success,
                bg: p.successSoft,
              ),
            ],

            // Animated so a failed attempt is felt, not just read — the error
            // appears where the eye already is rather than shifting the sheet.
            AppSwap(
              alignment: Alignment.topCenter,
              child: _error.isEmpty
                  ? const SizedBox(key: ValueKey('noerror'), height: 0)
                  : Padding(
                      key: const ValueKey('error'),
                      padding: const EdgeInsets.only(top: 14),
                      child: _Notice(
                        icon: Icons.error_outline_rounded,
                        message: _error,
                        fg: p.danger,
                        bg: p.dangerSoft,
                      ),
                    ),
            ),

            const SizedBox(height: 20),

            if (bleService.supportsBonding)
              SizedBox(
                height: 50,
                child: FilledButton(
                  onPressed: _waiting ? null : _pair,
                  child: AppSwap(
                    child: _waiting
                        ? SizedBox(
                            key: const ValueKey('busy'),
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: p.onPrimary),
                          )
                        : const Text('Pair', key: ValueKey('label')),
                  ),
                ),
              ),

            const SizedBox(height: 8),
            SizedBox(
              height: 44,
              child: TextButton(
                onPressed: _waiting
                    ? null
                    // `true` on iOS: there is nothing for the app to do, and
                    // blocking the claim behind a step it cannot perform would
                    // make the feature unreachable on that platform.
                    : () => Navigator.of(context)
                        .pop(!bleService.supportsBonding ? true : false),
                child: Text(
                  bleService.supportsBonding ? 'Skip for now' : 'Continue',
                  style: AppTypography.bodyMd(color: p.muted),
                ),
              ),
            ),

            if (bleService.supportsBonding)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Skipping does not skip the code — the keyholder refuses '
                  'unencrypted requests, so the phone will ask for it during '
                  'the claim instead, while you are holding the button.',
                  textAlign: TextAlign.center,
                  style: AppTypography.microLabel(color: p.muted),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A drawing of the 0.42" OLED, so the user knows what they are looking for.
///
/// The panel is 72×40 px and easy to overlook on a keyring; showing its shape is
/// faster than describing it. The dots pulse because a static mock reads as a
/// screenshot, and the point is that the user should go and look at the device.
///
/// Its colours are fixed rather than palette-driven: it is a picture of a
/// physical monochrome-blue OLED, and that object does not have a light mode.
class _OledMock extends StatefulWidget {
  const _OledMock();

  @override
  State<_OledMock> createState() => _OledMockState();
}

class _OledMockState extends State<_OledMock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: BoxDecoration(
        color: const Color(0xFF101014),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.borderStrong),
      ),
      child: Column(
        children: [
          Text('PAIR CODE',
              style: AppTypography.microLabel(color: const Color(0xFF7FE3FF))),
          const SizedBox(height: 6),
          FadeTransition(
            opacity: Tween<double>(begin: 0.45, end: 1.0).animate(
              CurvedAnimation(parent: _blink, curve: AppMotion.standard),
            ),
            child: Text(
              '● ● ● ● ● ●',
              style: AppTypography.headlineLg(color: const Color(0xFFDDF6FF))
                  .copyWith(letterSpacing: 2),
            ),
          ),
          const SizedBox(height: 6),
          Text('on your FindMe\'s screen',
              style: AppTypography.microLabel(color: const Color(0xFF6B7280))),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.message,
    required this.fg,
    required this.bg,
  });

  final IconData icon;
  final String message;
  final Color fg;
  final Color bg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: fg.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: fg),
          const SizedBox(width: 9),
          Expanded(child: Text(message, style: AppTypography.bodyMd(color: fg))),
        ],
      ),
    );
  }
}
