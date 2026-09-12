import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/event_model.dart';
import '../services/ble_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_logo_tile.dart';
import '../widgets/map_modal.dart';
import '../widgets/motion.dart';
import '../widgets/section_label.dart';

/// The activity log: connections, pings, and — the ones that matter — blocked
/// pairing attempts.
///
/// Security events get a coloured edge and a filter of their own, because a
/// blocked intruder is the single most important thing this app can tell the
/// user and it must not read as just another grey row.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  bool _securityOnly = false;

  @override
  Widget build(BuildContext context) {
    // Selected rather than watched. This screen reads exactly one value, but it
    // lives in an IndexedStack alongside the other three and so stays mounted
    // whichever tab is showing — watching the whole service meant every RSSI
    // sample and every scan result re-grouped up to 200 events by day while the
    // user was looking at a different screen entirely.
    //
    // `historyEvents` hands back a fresh unmodifiable view each call, so the
    // default identity check would always report a change; Selector's built-in
    // collection comparison walks the elements instead, which for an unchanged
    // log is 200 identity checks and no rebuild.
    final all = context.select<BleService, List<EventModel>>(
      (service) => service.historyEvents,
    );
    final p = AppPalette.of(context);

    final securityCount = all.where((e) => e.isSecurityEvent).length;
    final events =
        _securityOnly ? all.where((e) => e.isSecurityEvent).toList() : all;
    final groups = _groupByDay(events);

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
                        FadeSlideIn(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 4, bottom: 14),
                            child: Text(
                              all.isEmpty
                                  ? 'Connections, pings and blocked pairing '
                                      'attempts appear here.'
                                  : '${all.length} event'
                                      '${all.length == 1 ? '' : 's'} logged on '
                                      'this phone.',
                              style: AppTypography.bodyMd(
                                  color: p.onSurfaceVariant),
                            ),
                          ),
                        ),

                        if (all.isNotEmpty)
                          FadeSlideIn(
                            delay: AppMotion.stagger,
                            child: _Filters(
                              securityOnly: _securityOnly,
                              securityCount: securityCount,
                              totalCount: all.length,
                              onChanged: (v) =>
                                  setState(() => _securityOnly = v),
                            ),
                          ),
                        const SizedBox(height: 16),

                        AppSwap(
                          alignment: Alignment.topCenter,
                          child: groups.isEmpty
                              ? _EmptyState(
                                  key: ValueKey('empty$_securityOnly'),
                                  securityOnly: _securityOnly,
                                )
                              : Column(
                                  key: ValueKey(
                                      'list$_securityOnly${events.length}'),
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  // Grouped by the events' own timestamps. The
                                  // previous version always drew a "TODAY"
                                  // heading plus a hardcoded "4 events synced
                                  // from Firebase yesterday" card, shown whether
                                  // or not anything had ever been synced.
                                  children: [
                                    ...staggered(
                                      groups
                                          .expand((g) => <Widget>[
                                                _DayHeader(
                                                    label: g.label,
                                                    count: g.events.length),
                                                ...g.events
                                                    .asMap()
                                                    .entries
                                                    .map((entry) =>
                                                        _TimelineItem(
                                                          event: entry.value,
                                                          isLast: entry.key ==
                                                              g.events.length -
                                                                  1,
                                                        )),
                                              ])
                                          .toList(),
                                      step: AppMotion.stagger,
                                    ),
                                  ],
                                ),
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

  /// Splits the (newest-first) log into day buckets, preserving order.
  List<_DayGroup> _groupByDay(List<EventModel> events) {
    final now = DateTime.now();
    final groups = <_DayGroup>[];

    for (final event in events) {
      final label = _dayLabel(event.timestamp, now);
      if (groups.isNotEmpty && groups.last.label == label) {
        groups.last.events.add(event);
      } else {
        groups.add(_DayGroup(label, [event]));
      }
    }
    return groups;
  }

  static const List<String> _months = [
    'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', //
    'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC',
  ];

  String _dayLabel(DateTime timestamp, DateTime now) {
    final day = DateTime(timestamp.year, timestamp.month, timestamp.day);
    final today = DateTime(now.year, now.month, now.day);
    final difference = today.difference(day).inDays;

    if (difference == 0) return 'TODAY';
    if (difference == 1) return 'YESTERDAY';
    return '${day.day} ${_months[day.month - 1]} ${day.year}';
  }
}

class _DayGroup {
  _DayGroup(this.label, this.events);

  final String label;
  final List<EventModel> events;
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
              const AppLogoTile(icon: Icons.history_rounded, size: 30),
              const SizedBox(width: 10),
              const AppWordmark('Activity'),
            ],
          ),
        ),
      ),
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({
    required this.securityOnly,
    required this.securityCount,
    required this.totalCount,
    required this.onChanged,
  });

  final bool securityOnly;
  final int securityCount;
  final int totalCount;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _Chip(
            label: 'Everything',
            count: totalCount,
            selected: !securityOnly,
            onTap: () => onChanged(false),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _Chip(
            label: 'Security',
            count: securityCount,
            selected: securityOnly,
            danger: true,
            onTap: () => onChanged(true),
          ),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
    this.danger = false,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final accent = danger ? p.danger : p.primary;

    return PressableScale(
      onTap: onTap,
      borderRadius: 12,
      child: AnimatedContainer(
        duration: AppMotion.normal,
        curve: AppMotion.standard,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? (danger ? p.dangerSoft : p.primarySoft)
              : p.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? accent.withValues(alpha: 0.45) : p.border,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(label,
                style: AppTypography.bodyMd(
                    color: selected ? accent : p.onSurfaceVariant)),
            const SizedBox(width: 6),
            AnimatedContainer(
              duration: AppMotion.normal,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: (selected ? accent : p.muted).withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Text('$count',
                  style: AppTypography.microLabel(
                      color: selected ? accent : p.muted)),
            ),
          ],
        ),
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          SectionLabel(label),
          const SizedBox(width: 8),
          Text('$count', style: AppTypography.microLabel(color: p.muted)),
          const SizedBox(width: 8),
          Expanded(child: Divider(color: p.border)),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({super.key, required this.securityOnly});

  final bool securityOnly;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(28),
      decoration: AppDecorations.card(p),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: securityOnly ? p.successSoft : p.surfaceHigh,
              shape: BoxShape.circle,
            ),
            child: Icon(
              securityOnly
                  ? Icons.shield_rounded
                  : Icons.history_toggle_off_rounded,
              size: 25,
              color: securityOnly ? p.success : p.muted,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            securityOnly ? 'Nothing to report' : 'No events yet',
            style: AppTypography.bodyLg(color: p.onSurface),
          ),
          const SizedBox(height: 6),
          Text(
            securityOnly
                // Framed as reassurance, because an empty security log is the
                // good outcome — not a missing feature.
                ? 'No one has tried to claim or command your keyholder. Blocked '
                    'attempts would be listed here.'
                : 'Pair with your keyholder to start logging activity.',
            textAlign: TextAlign.center,
            style: AppTypography.bodyMd(color: p.muted),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Timeline row
// =============================================================================

class _TimelineItem extends StatelessWidget {
  const _TimelineItem({required this.event, this.isLast = false});

  final EventModel event;

  /// Whether this is the last row of its day group. Suppresses the connector
  /// line, so each day reads as a closed run rather than one continuous thread
  /// that appears to pass straight through the next heading.
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final accent = event.accent(p);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: PressableScale(
        // Only offer the map when the event actually carries a fix — tapping
        // through to a map of "No GPS fix" was never useful.
        onTap: event.hasLocation
            ? () => MapModalSheet.show(
                  context,
                  locationTitle: event.displayLocation,
                  coordinates: event.coordinatesFormatted,
                )
            : null,
        // Intrinsic height so the connector in the gutter can stretch to whatever
        // height the card next to it turns out to be. A fixed-length stub would
        // leave a gap under any row that wrapped to two lines.
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 34,
                child: Column(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: event.fill(p),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: accent.withValues(alpha: 0.35), width: 1.5),
                      ),
                      child: Icon(event.icon, size: 16, color: accent),
                    ),
                    if (!isLast)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          // The thread runs in the event's own hue and fades out
                          // downwards, which is what makes the column read as one
                          // timeline instead of a stack of unrelated cards.
                          child: Container(
                            width: 2,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(1),
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  accent.withValues(alpha: 0.32),
                                  accent.withValues(alpha: 0.04),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  padding: EdgeInsets.fromLTRB(
                      event.isSecurityEvent ? 11 : 14, 14, 14, 14),
                  // A security event gets a solid coloured left edge and a faint
                  // wash of the same hue, the same treatment the connection card
                  // and keyholder cards use. A blocked pairing attempt should not
                  // be just another grey row in the timeline.
                  decoration: event.isSecurityEvent
                      ? AppDecorations.accented(p, accent)
                      : AppDecorations.card(p),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              event.displayTitle,
                              style: AppTypography.bodyLg(color: accent),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(event.formattedTime,
                              style:
                                  AppTypography.metadataMono(color: p.muted)),
                        ],
                      ),
                      // Which keyholder. Without this the log reads "Connected /
                      // Disconnected / Connected" with nothing to say what it was
                      // connected *to* — useless the moment a phone has met more
                      // than one device, and vague even when it has not.
                      if (event.hasDeviceName) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Icon(Icons.vpn_key_rounded,
                                size: 12, color: p.muted),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                event.displaySubject,
                                style: AppTypography.microLabel(color: p.muted),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          // Coordinates are a measurement, so they take the teal
                          // accent rather than the event's own hue — the same
                          // colour the live readout on Home uses for a position.
                          Icon(
                            event.hasLocation
                                ? Icons.location_on_rounded
                                : Icons.location_off_rounded,
                            size: 12,
                            color: event.hasLocation ? p.accent : p.muted,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              event.coordinatesFormatted,
                              style: AppTypography.metadataMono(
                                  color:
                                      event.hasLocation ? p.accent : p.muted),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (event.hasLocation) ...[
                            const SizedBox(width: 8),
                            Icon(Icons.map_rounded, size: 16, color: p.muted),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
