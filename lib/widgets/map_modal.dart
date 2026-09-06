import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'map_painter.dart';

/// Bottom sheet showing where a logged event happened.
class MapModalSheet extends StatelessWidget {
  const MapModalSheet({
    super.key,
    required this.locationTitle,
    required this.coordinates,
  });

  final String locationTitle;
  final String coordinates;

  static void show(
    BuildContext context, {
    required String locationTitle,
    required String coordinates,
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
      ),
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
              Icon(Icons.pin_drop_rounded, size: 18, color: p.primary),
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
            child: MapPreviewWidget(
              locationName: locationTitle,
              coordinates: coordinates,
              height: 200,
            ),
          ),
          const SizedBox(height: 14),

          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: p.primarySoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('COORDINATES',
                    style: AppTypography.labelCaps(color: p.primary)),
                const SizedBox(height: 4),
                Text(
                  coordinates,
                  style: AppTypography.metadataMono(color: p.primary)
                      .copyWith(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            // Says plainly what the diagram is, so nobody mistakes the grid for
            // a street map or the ring for a measured accuracy figure.
            'Reported by the keyholder’s GPS module. The grid is a diagram of the '
            'fix, not a street map.',
            style: AppTypography.microLabel(color: p.muted),
          ),
        ],
      ),
    );
  }
}
