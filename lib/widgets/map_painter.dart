import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'map_tiles.dart';

/// The location card's map.
///
/// Given [latitude] and [longitude] this shows real cartography, fetched from
/// OpenStreetMap — streets, buildings and their names, with the fix pinned on
/// top. That is the point of the card: "Amphitheatre, OAU" drawn on the actual
/// campus is something the owner can walk to, where a coordinate pair over a
/// grey grid is something they have to go and decode somewhere else.
///
/// Underneath the tiles is the diagram this widget used to be, and it is still
/// here on purpose. Tiles need a network; a fix does not. When the phone is
/// offline the tiles quietly fail and the grid with its accuracy rings shows
/// through, which is honest — it says "here is the fix, but not the place" —
/// instead of a grey rectangle or a broken-image icon.
///
/// What it will never do again is *invent* cartography. An older version painted
/// water, a park, a highway and a bridge — a picture of San Francisco, drawn
/// under whatever coordinates it was handed. Streets that were never near the
/// keyholder are worse than no streets at all.
class MapPreviewWidget extends StatefulWidget {
  const MapPreviewWidget({
    super.key,
    required this.locationName,
    required this.coordinates,
    this.latitude,
    this.longitude,
    this.height = 160,
  });

  final String locationName;
  final String coordinates;

  /// The fix, if it is known precisely enough to draw a map of. Null falls back
  /// to the diagram.
  final double? latitude;
  final double? longitude;

  final double height;

  @override
  State<MapPreviewWidget> createState() => _MapPreviewWidgetState();
}

class _MapPreviewWidgetState extends State<MapPreviewWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedBuilder(
              animation: _pulse,
              builder: (context, _) => CustomPaint(
                painter: _FixDiagramPainter(
                  progress: _pulse.value,
                  grid: p.border,
                  surface: p.surfaceAlt,
                  // Teal, not indigo. A fix is a measurement, and this app draws
                  // measurements in the accent — the same hue as the signal bars,
                  // the distance readout and the radar sweep.
                  accent: p.accent,
                ),
              ),
            ),

            // Over the diagram, not under it: the diagram paints an opaque
            // background, so it has to be the thing that shows when the tiles
            // do not arrive rather than the thing that covers them when they
            // do.
            if (widget.latitude != null && widget.longitude != null)
              MapTileLayer(
                latitude: widget.latitude!,
                longitude: widget.longitude!,
              ),

            // The pin sits dead centre because the tiles are laid out so that
            // the fix lands exactly there — the viewport is centred on it.
            Center(
              child: Container(
                width: 15,
                height: 15,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: p.accent,
                  border: Border.all(color: p.surface, width: 2.5),
                  boxShadow: [
                    BoxShadow(
                      color: p.accent.withValues(alpha: 0.45),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),

            Positioned(
              left: 10,
              bottom: 8,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: p.surface.withValues(alpha: 0.86),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: p.border),
                ),
                child: Text(
                  widget.coordinates,
                  style: AppTypography.metadataMono(color: p.onSurfaceVariant),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FixDiagramPainter extends CustomPainter {
  _FixDiagramPainter({
    required this.progress,
    required this.grid,
    required this.surface,
    required this.accent,
  });

  final double progress;
  final Color grid;
  final Color surface;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = surface);

    // Graticule. Fixed 24 px spacing rather than a fraction of the size, so the
    // grid keeps the same scale whether it is the 150 px card or the 200 px sheet.
    final line = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 24) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
    for (double y = 0; y < size.height; y += 24) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }

    final center = size.center(Offset.zero);

    // Crosshair through the fix.
    final cross = Paint()
      ..color = accent.withValues(alpha: 0.28)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, center.dy), Offset(size.width, center.dy), cross);
    canvas.drawLine(Offset(center.dx, 0), Offset(center.dx, size.height), cross);

    // Static accuracy rings: a reminder that a fix is a region, not a point.
    final ring = Paint()
      ..color = accent.withValues(alpha: 0.16)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final r in const [26.0, 46.0, 66.0]) {
      canvas.drawCircle(center, r, ring);
    }

    // One expanding pulse, so the diagram reads as live rather than as an image.
    final maxPulse = size.shortestSide * 0.42;
    canvas.drawCircle(
      center,
      12 + maxPulse * progress,
      Paint()
        ..color = accent.withValues(alpha: (1.0 - progress) * 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
    canvas.drawCircle(
      center,
      12 + maxPulse * progress,
      Paint()..color = accent.withValues(alpha: (1.0 - progress) * 0.07),
    );
  }

  @override
  bool shouldRepaint(covariant _FixDiagramPainter old) =>
      old.progress != progress ||
      old.grid != grid ||
      old.surface != surface ||
      old.accent != accent;
}
