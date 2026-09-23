import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/ble_service.dart';
import '../services/phone_ringer_service.dart';
import '../theme/app_theme.dart';
import 'motion.dart';

/// The strip that appears when the keyholder's button has rung this phone.
///
/// It sits above the whole navigation stack, alongside the Demo Mode banner, for
/// a simple reason: the button on the fob can be pressed while the user is
/// reading their history or halfway through Settings, and the one thing they will
/// want at that moment is to make the noise stop. Putting Stop on the Home tab
/// only would mean hunting for it while the phone screams.
///
/// Danger red rather than the app's indigo. Everything else coloured in this app
/// is reporting a measurement; this is reporting an event that is happening right
/// now and wants to be dismissed, which is the one case where a loud hue is the
/// honest choice.
class PhoneRingingBanner extends StatelessWidget {
  const PhoneRingingBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    // `select` rather than `watch`: this widget wraps every tab, and rebuilding
    // the whole navigation shell on each RSSI sample would be absurd.
    final ringing =
        context.select<PhoneRingerService, bool>((r) => r.isRinging);

    return AnimatedSize(
      duration: AppMotion.normal,
      curve: AppMotion.standard,
      alignment: Alignment.topCenter,
      child: !ringing
          ? const SizedBox(width: double.infinity, height: 0)
          : Material(
              color: p.dangerSoft,
              child: SafeArea(
                bottom: false,
                child: Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    border:
                        Border(bottom: BorderSide(color: p.danger, width: 1.5)),
                  ),
                  child: Row(
                    children: [
                      PulseDot(color: p.danger, size: 9, haloSize: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'YOUR KEYHOLDER IS RINGING THIS PHONE',
                              style: AppTypography.microLabel(color: p.danger)
                                  .copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              'You pressed the button on your FindMe.',
                              style: AppTypography.microLabel(color: p.danger)
                                  .copyWith(
                                      fontWeight: FontWeight.w400,
                                      // Softened rather than a different colour:
                                      // a second hue inside a red strip would be
                                      // one hue too many.
                                      color:
                                          p.danger.withValues(alpha: 0.78)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Deliberately a filled button and not an icon: an icon-only
                      // X in a red strip reads as "dismiss this message", and the
                      // message is not the problem.
                      PressableScale(
                        onTap: () => context.read<BleService>().silencePhoneRing(),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: p.danger,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            children: [
                              // White, not `p.surface`: danger red is saturated
                              // in both themes, so the foreground on top of it
                              // does not need to switch with the brightness.
                              const Icon(Icons.volume_off_rounded,
                                  size: 14, color: Colors.white),
                              const SizedBox(width: 5),
                              Text(
                                'STOP',
                                style:
                                    AppTypography.microLabel(color: Colors.white)
                                        .copyWith(fontWeight: FontWeight.w700),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
