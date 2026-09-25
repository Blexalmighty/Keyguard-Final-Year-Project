import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../utils/maps_launcher.dart';
import 'map_painter.dart';
import 'section_label.dart';

/// Bottom sheet showing where a logged event happened.
class MapModalSheet extends StatelessWidget {
  const MapModalSheet({
    super.key,
    required this.locationTitle,
    required this.coordinates,
    this.latitude,
    this.longitude,
  });

  final String locationTitle;
  final String coordinates;

  /// The fix as numbers, for handing off to the Maps app.
  ///
  /// Nullable rather than required because [coordinates] is already a formatted
  /// string and an event logged before the phone had a fix has nothing to hand
  /// off. When either is null the sheet simply shows the diagram without the
  /// "open in Maps" affordance, instead of offering a button that cannot work.
  final double? latitude;
  final double? longitude;

  bool get _canOpenMaps => latitude != null && longitude != null;

  static void show(
    BuildContext context, {
    required String locationTitle,
    required String coordinates,
    double? latitude,
    double? longitude,
  }) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      // Transparent so the sheet's own rounded container is what the user sees;
      // the shape and colour come from `bottomSheetTheme`.
      backgroundColor: Colors.transparent,
      builder: (context) => MapModalSheet(
        locationTitle: locationTitle,
        coordinates: coordinates,
        latitude: latitude,
        longitude: longitude,
      ),
    );
  }

  Future<void> _openInMaps(BuildContext context) async {
    final lat = latitude;
    final lng = longitude;
    if (lat == null || lng == null) return;

    // Captured before the await: this sheet can be dismissed while the platform
    // is still deciding whether anything handles the intent, and reaching for
    // `ScaffoldMessenger.of(context)` afterwards would be a use of a defunct
    // element.
    final messenger = ScaffoldMessenger.of(context);
    final opened =
        await openInMaps(latitude: lat, longitude: lng, label: locationTitle);
    if (opened) return;

    messenger.showSnackBar(
      const SnackBar(content: Text('No app on this phone can open a map.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        boxShadow: [
          BoxShadow(color: p.shadow, blurRadius: 22, offset: const Offset(0, -4)),
        ],
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 12,
        bottom: MediaQuery.of(context).padding.bottom + 20,
      ),
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
          const SizedBox(height: 16),

          Row(
            children: [
              Icon(Icons.pin_drop_rounded, size: 18, color: p.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(locationTitle,
                    style: AppTypography.headlineMd(color: p.onSurface),
                    overflow: TextOverflow.ellipsis),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: Icon(Icons.close_rounded, size: 20, color: p.muted),
                style: IconButton.styleFrom(backgroundColor: p.surfaceHigh),
              ),
            ],
          ),
          const SizedBox(height: 14),

          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            // The diagram doubles as the button, matching the Home card: the
            // thing that looks like a map is the thing you tap to get the real
            // one. Wrapped only when there is a fix to hand off, so a fixless
            // event does not offer a dead ripple.
            child: _canOpenMaps
                ? InkWell(
                    onTap: () => _openInMaps(context),
                    child: MapPreviewWidget(
                      locationName: locationTitle,
                      coordinates: coordinates,
                      latitude: latitude,
                      longitude: longitude,
                      height: 200,
                    ),
                  )
                : MapPreviewWidget(
                    locationName: locationTitle,
                    coordinates: coordinates,
                    latitude: latitude,
                    longitude: longitude,
                    height: 200,
                  ),
          ),
          const SizedBox(height: 14),

          Container(
            padding: const EdgeInsets.all(14),
            // Teal, matching the pin and crosshair in the diagram directly above
            // and every other coordinate readout in the app.
            decoration: AppDecorations.pill(p.accent, borderRadius: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionLabel('COORDINATES', textColor: p.accent),
                const SizedBox(height: 4),
                Text(
                  coordinates,
                  style: AppTypography.metadataMono(color: p.accent)
                      .copyWith(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            // Says plainly where the fix came from and what the diagram is, so
            // nobody mistakes the grid for a street map or the ring for a
            // measured accuracy figure. It used to credit "the keyholder's GPS
            // module", which stopped being true when positions moved to this
            // phone's own receiver.
            _canOpenMaps
                ? 'Recorded by this phone’s GPS when the event happened. The '
                    'grid is a diagram of the fix, not a street map — tap it to '
                    'open the position in Google Maps.'
                : 'Recorded by this phone’s GPS when the event happened. The '
                    'grid is a diagram of the fix, not a street map.',
            style: AppTypography.microLabel(color: p.muted),
          ),
        ],
      ),
    );
  }
}
