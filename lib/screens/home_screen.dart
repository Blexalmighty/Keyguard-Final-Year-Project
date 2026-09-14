import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/ble_device.dart';
import '../services/ble_service.dart';
import '../theme/app_theme.dart';
import '../utils/maps_launcher.dart';
import '../widgets/app_logo_tile.dart';
import '../widgets/battery_pill.dart';
import '../widgets/map_painter.dart';
import '../widgets/motion.dart';
import '../widgets/ownership_badge.dart';
import '../widgets/section_label.dart';
import '../widgets/signal_bar.dart';

/// The screen the user actually lives on: is my keyholder near, and where was it
/// last seen.
///
/// Note what is *not* here: any mention of which radio the connection is using.
/// There is one connection state. Whether a given reading arrived over BLE or was
/// reported by the keyholder through Wi-Fi is not a decision the user can make or
/// needs to know, so surfacing it would only add a control with no action behind
/// it.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pingPulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void dispose() {
    _pingPulse.dispose();
    super.dispose();
  }

  /// Starts the pulse immediately, then hands off to the service.
  ///
  /// The animation is started before the await rather than after it, so the
  /// button visibly reacts on the first press even if the GATT write takes a
  /// moment. `pingKey` flips its state up front for the same reason, and rolls
  /// it back if the write fails — at which point `isPinging` is false and the
  /// repeat below correctly declines to start.
  void _onPingPressed(BleService bleService) {
    if (!bleService.isConnected) return;
    if (!mounted) return;

    _pingPulse.forward(from: 0.0).then((_) {
      // `mounted` because a tab switch can dispose this state while the 1.2s
      // forward run is still going, and driving a disposed controller throws.
      if (mounted && bleService.isPinging) _pingPulse.repeat(reverse: true);
    });
    bleService.pingKey();
  }

  @override
  Widget build(BuildContext context) {
    final bleService = context.watch<BleService>();
    final p = AppPalette.of(context);

    return Scaffold(
      backgroundColor: p.background,
      body: SafeArea(
        child: Column(
          children: [
            _AppBar(bleService: bleService),
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
                          _ConnectionCard(bleService: bleService),
                          _SignalCard(bleService: bleService),
                          _LocationCard(bleService: bleService),
                        ], step: AppMotion.stagger)
                            .expand((w) => [w, const SizedBox(height: 12)]),

                        const SizedBox(height: 10),

                        FadeSlideIn(
                          delay: AppMotion.stagger * 3,
                          child: _PingButton(
                            bleService: bleService,
                            pulse: _pingPulse,
                            onPressed: () => _onPingPressed(bleService),
                          ),
                        ),
                        const SizedBox(height: 12),

                        AppSwap(
                          child: bleService.isAlertActive
                              ? Padding(
                                  key: const ValueKey('stop'),
                                  padding: const EdgeInsets.only(top: 12),
                                  child:
                                      _StopAlertButton(bleService: bleService),
                                )
                              : const SizedBox(
                                  key: ValueKey('none'), height: 0),
                        ),

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
}

// =============================================================================
// App bar
// =============================================================================

class _AppBar extends StatelessWidget {
  const _AppBar({required this.bleService});

  final BleService bleService;

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
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const AppLogoTile(),
                  const SizedBox(width: 10),
                  const AppWordmark('Find X'),
                ],
              ),
              BatteryPill(
                batteryLevel: bleService.hasBatteryReading
                    ? bleService.batteryLevel
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Connection
// =============================================================================

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.bleService});

  final BleService bleService;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final connected = bleService.isConnected;
    final connecting = bleService.isConnecting;

    // Tinted by state so the card itself carries the message before any text is
    // read — the strongest signal available on a screen glanced at in a hurry.
    final accent = connected
        ? p.success
        : connecting
            ? p.primary
            : p.muted;

    return AnimatedContainer(
      duration: AppMotion.normal,
      curve: AppMotion.standard,
      padding: const EdgeInsets.fromLTRB(14, 16, 16, 16),
      // A coloured left edge rather than a coloured card. Filling the whole
      // surface with green on connect would out-shout the hero panel below it and
      // make an ordinary state look like an alarm; an edge says the same thing at
      // the right volume, and it moves with the state.
      decoration: AppDecorations.accented(p, accent),
      child: Row(
        children: [
          AnimatedContainer(
            duration: AppMotion.normal,
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: accent.withValues(alpha: 0.24)),
            ),
            child: Center(
              child: PulseDot(
                color: accent,
                active: connected || connecting,
                size: 11,
                haloSize: 30,
              ),
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppSwap(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    connected
                        ? 'Connected'
                        : connecting
                            ? 'Connecting'
                            : 'Disconnected',
                    key: ValueKey<String>('$connected$connecting'),
                    style: AppTypography.headlineMd(color: p.onSurface),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 1),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        bleService.displayName.toUpperCase(),
                        style: AppTypography.microLabel(color: p.muted),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // Rename lives here, next to the name it changes, and only
                    // while connected — a nickname is per-keyholder, and with no
                    // link there is no keyholder to name. The name is stored on
                    // the phone for the anti-stalking reason in
                    // SettingsStore.nicknameFor: a claimed keyholder
                    // deliberately advertises the generic "Find Me", so the
                    // radio must never carry the owner's label.
                    if (connected)
                      GestureDetector(
                        onTap: () => _promptRename(context, bleService),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          child: Icon(Icons.edit_outlined,
                              size: 13, color: p.muted),
                        ),
                      ),
                  ],
                ),

                // The ownership lock, on the screen the user looks at most. An
                // unauthenticated session is not a safe one.
                if (bleService.ownershipState != OwnershipState.unknown)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: OwnershipBadge(state: bleService.ownershipState),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _promptRename(
      BuildContext context, BleService bleService) async {
    final controller =
        TextEditingController(text: bleService.hasNickname ? bleService.displayName : '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Rename this keyholder'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 24,
            decoration: const InputDecoration(
              hintText: 'e.g. Keys, backpack, bike lock',
              labelText: 'Name',
            ),
            onSubmitted: (_) => Navigator.pop(dialogContext, true),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (saved == true) {
      await bleService.setNickname(controller.text.trim());
    }
    controller.dispose();
  }
}

// =============================================================================
// Signal
// =============================================================================

/// The proximity readout, and the app's one large piece of colour.
///
/// This is the card that got the gradient rather than the connection card above
/// it, and the reason is that this one is *always* the same kind of thing. A
/// coloured panel that sometimes means "good" and sometimes means "offline"
/// teaches the user nothing; a coloured panel that always means "here is the live
/// measurement" is legible on the second glance.
///
/// Everything on it is drawn in white or a white alpha rather than in palette
/// colours, because the gradient is fixed in both themes — so the same code is
/// correct in light and dark mode with no branching.
class _SignalCard extends StatelessWidget {
  const _SignalCard({required this.bleService});

  final BleService bleService;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    // Named once, used throughout: the point of a hero panel is that it looks
    // like one surface, which means one set of tints.
    const onHero = Colors.white;
    final onHeroDim = Colors.white.withValues(alpha: 0.62);
    final onHeroFaint = Colors.white.withValues(alpha: 0.16);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: AppDecorations.hero(p),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('SIGNAL STRENGTH',
                        style: AppTypography.labelCaps(color: onHeroDim)),
                    const SizedBox(height: 5),
                    AppSwap(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        bleService.signalQuality,
                        key: ValueKey<String>(bleService.signalQuality),
                        style: AppTypography.headlineLg(color: onHero),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('EST. DISTANCE',
                      style: AppTypography.labelCaps(color: onHeroDim)),
                  const SizedBox(height: 5),
                  // Tabular figures via AppTypography.numeric, so the number does
                  // not shift the row's width as it counts up and down.
                  if (bleService.hasDistanceEstimate)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          bleService.estimatedDistance.toStringAsFixed(1),
                          style: AppTypography.numeric(
                              color: onHero, fontSize: 30),
                        ),
                        const SizedBox(width: 3),
                        Text('m',
                            style: AppTypography.bodyMd(color: onHeroDim)),
                      ],
                    )
                  else
                    Text('--',
                        style: AppTypography.numeric(
                            color: onHeroDim, fontSize: 30)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 18),

          // White rather than the teal accent: on violet, teal reads as a muddy
          // blue and stops being distinguishable from the panel behind it.
          SignalBarWidget(barHeights: bleService.rssiBars, color: onHero),
          const SizedBox(height: 16),

          Container(height: 1, color: onHeroFaint),
          const SizedBox(height: 12),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                bleService.hasRssiReading
                    ? '${bleService.currentRssi} dBm'
                    : '-- dBm',
                style: AppTypography.metadataMono(color: onHeroDim),
              ),
              Text(
                // Was the hardcoded string 'Updated Just Now', which the app
                // displayed even with no keyholder connected at all.
                bleService.rssiFreshness,
                style: AppTypography.metadataMono(color: onHeroDim),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Location
// =============================================================================

class _LocationCard extends StatelessWidget {
  const _LocationCard({required this.bleService});

  final BleService bleService;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: AppDecorations.card(p),
        child: Column(
          children: [
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const SectionLabel('LAST KNOWN LOCATION'),
                  AnimatedRotation(
                    turns: bleService.hasGpsFix ? 0 : 0.5,
                    duration: AppMotion.slow,
                    child: Icon(
                      bleService.hasGpsFix
                          ? Icons.location_on_rounded
                          : Icons.gps_not_fixed_rounded,
                      size: 18,
                      // Teal, not indigo: a satellite fix is a live measurement,
                      // which is what the accent hue is reserved for.
                      color: bleService.hasGpsFix ? p.accent : p.muted,
                    ),
                  ),
                ],
              ),
            ),

            AppSwap(
              child: bleService.hasGpsFix
                  // Tappable, because what is below is a diagram and not a
                  // street map. The tap hands the coordinates to Google Maps,
                  // where the owner gets the real map, directions and a share
                  // button — none of which an in-app thumbnail could offer.
                  ? InkWell(
                      key: const ValueKey('map'),
                      onTap: () => _openInMaps(context, bleService),
                      child: MapPreviewWidget(
                        locationName: bleService.locationName,
                        coordinates: bleService.coordinatesFormatted,
                        height: 150,
                      ),
                    )
                  : Container(
                      key: const ValueKey('nofix'),
                      height: 150,
                      color: p.surfaceAlt,
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.satellite_alt_rounded,
                                size: 30, color: p.muted),
                            const SizedBox(height: 8),
                            Text('Waiting for GPS fix',
                                style:
                                    AppTypography.bodyMd(color: p.muted)),
                          ],
                        ),
                      ),
                    ),
            ),

            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              color: p.surfaceAlt,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          bleService.hasGpsFix
                              ? bleService.locationName
                              : 'Waiting for GPS fix…',
                          style: AppTypography.bodyMd(color: p.onSurface),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        bleService.hasGpsFix
                            ? bleService.coordinatesFormatted
                            : '--',
                        // The coordinate pair is measured data, so it takes the
                        // accent — matching the pin and the crosshair in the
                        // diagram above it.
                        style: AppTypography.metadataMono(
                            color: bleService.hasGpsFix ? p.accent : p.muted),
                      ),
                    ],
                  ),

                  // The phone's network address, under the position it was
                  // recorded at. It corroborates the fix: the address is what a
                  // server sees, so it places the phone on a network at roughly
                  // the same moment the coordinates place it on the ground.
                  // Hidden entirely until one is known rather than shown as a
                  // dash — an empty labelled row here would look like a bug.
                  if (bleService.networkAddress != null) ...[
                    const SizedBox(height: 7),
                    Divider(color: p.border, height: 1),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        Icon(
                          bleService.networkAddressIsPublic
                              ? Icons.public_rounded
                              : Icons.router_rounded,
                          size: 14,
                          color: p.muted,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          // Labelled, because the two are not interchangeable: a
                          // 192.168.x.x address says nothing about where the
                          // phone is, and presenting it as the phone's address on
                          // the internet would be quietly false.
                          bleService.networkAddressIsPublic
                              ? 'Public IP'
                              : 'Local IP',
                          style: AppTypography.microLabel(color: p.muted),
                        ),
                        const Spacer(),
                        Text(
                          bleService.networkAddress!,
                          style: AppTypography.metadataMono(color: p.muted),
                        ),
                      ],
                    ),
                  ],

                  if (bleService.hasGpsFix) ...[
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        Icon(Icons.open_in_new_rounded,
                            size: 13, color: p.primary),
                        const SizedBox(width: 6),
                        Text('Tap the map to open in Google Maps',
                            style: AppTypography.microLabel(color: p.primary)),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Hands the last known position to the phone's maps app.
  ///
  /// The failure is reported rather than swallowed. A tap that does nothing is
  /// indistinguishable from a broken card, and on a phone with neither a maps
  /// app nor a browser this genuinely cannot succeed.
  Future<void> _openInMaps(BuildContext context, BleService service) async {
    final lat = double.tryParse(service.lastLat);
    final lng = double.tryParse(service.lastLng);
    if (lat == null || lng == null) return;

    final messenger = ScaffoldMessenger.of(context);
    final opened = await openInMaps(
      latitude: lat,
      longitude: lng,
      label: service.displayName,
    );
    if (opened) return;

    messenger.showSnackBar(
      const SnackBar(content: Text('No app on this phone can open a map.')),
    );
  }
}

// =============================================================================
// Ping
// =============================================================================

class _PingButton extends StatefulWidget {
  const _PingButton({
    required this.bleService,
    required this.pulse,
    required this.onPressed,
  });

  final BleService bleService;
  final AnimationController pulse;
  final VoidCallback onPressed;

  @override
  State<_PingButton> createState() => _PingButtonState();
}

class _PingButtonState extends State<_PingButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final enabled = widget.bleService.isConnected;
    final pinging = widget.bleService.isPinging;

    return Center(
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapUp: enabled ? (_) => setState(() => _down = false) : null,
        onTapCancel: enabled ? () => setState(() => _down = false) : null,
        onTap: widget.onPressed,
        child: AnimatedBuilder(
          animation: widget.pulse,
          builder: (context, _) {
            final pulseScale = pinging ? 1.0 + widget.pulse.value * 0.06 : 1.0;
            return Transform.scale(
              scale: pulseScale * (_down ? 0.95 : 1.0),
              child: AnimatedContainer(
                duration: AppMotion.normal,
                curve: AppMotion.standard,
                width: 152,
                height: 152,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  // The same two stops as the hero panel, so the primary action
                  // and the primary readout are visibly the same brand rather
                  // than two indigos that happen to be near each other.
                  gradient: enabled
                      ? LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [p.gradientFrom, p.gradientTo],
                        )
                      : null,
                  color: enabled ? null : p.surfaceHigh,
                  border: Border.all(
                    color: enabled ? p.sheen : p.border,
                    width: 1.5,
                  ),
                  boxShadow: enabled
                      ? [
                          // Two shadows: a tight one that seats the button on the
                          // page, and a wide coloured bloom that grows while the
                          // buzzer is sounding. The bloom is the animation — a
                          // ring that only glows when something is actually
                          // happening on the hardware.
                          BoxShadow(
                            color: p.shadow,
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                          BoxShadow(
                            color: p.gradientTo
                                .withValues(alpha: pinging ? 0.55 : 0.34),
                            blurRadius: pinging ? 38 : 24,
                            spreadRadius: pinging ? 9 : 2,
                            offset: const Offset(0, 8),
                          ),
                        ]
                      : null,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(13),
                      decoration: BoxDecoration(
                        color: (enabled ? Colors.white : p.muted)
                            .withValues(alpha: 0.18),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: (enabled ? Colors.white : p.muted)
                              .withValues(alpha: 0.22),
                        ),
                      ),
                      child: Icon(
                        pinging
                            ? Icons.graphic_eq_rounded
                            : Icons.volume_up_rounded,
                        size: 32,
                        color: enabled ? Colors.white : p.muted,
                      ),
                    ),
                    const SizedBox(height: 9),
                    Text(
                      pinging ? 'Ringing…' : 'Ping Key',
                      style: AppTypography.headlineMd(
                          color: enabled ? Colors.white : p.muted),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _StopAlertButton extends StatelessWidget {
  const _StopAlertButton({required this.bleService});

  final BleService bleService;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: bleService.stopAlert,
        icon: const Icon(Icons.volume_off_rounded, size: 18),
        label: const Text('Stop Alert'),
        style: FilledButton.styleFrom(
          backgroundColor: p.dangerSoft,
          foregroundColor: p.danger,
          elevation: 0,
          minimumSize: const Size.fromHeight(50),
          textStyle: AppTypography.headlineMd(),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: p.danger.withValues(alpha: 0.25)),
          ),
        ),
      ),
    );
  }
}
