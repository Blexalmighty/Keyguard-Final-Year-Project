import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A stand-in for the map, until Google Maps is wired up.
///
/// It deliberately does **not** draw cartography. The previous version painted
/// water, parks, a highway and a bridge — a picture of San Francisco, rendered
/// underneath whatever coordinates it was given. That is worse than no map: it
/// invites the user to read streets that do not exist and were never near the
/// keyholder. What it draws now is a coordinate grid with an accuracy halo, which
/// is honest about being a diagram of a fix rather than a picture of a place.
class MapPreviewWidget extends StatefulWidget {
  const MapPreviewWidget({
    super.key,
    required this.locationName,
    required this.coordinates,
    this.height = 160,
  });

  final String locationName;
  final String coordinates;
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
                  accent: p.primary,
                ),
              ),
            ),

            // The pin sits dead centre because a single BLE-reported fix has no
            // extent to place it within — there is nothing to pan around.
            Center(
              child: Container(
                width: 15,
                height: 15,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: p.primary,
                  border: Border.all(color: p.surface, width: 2.5),
                  boxShadow: [
                    BoxShadow(
                      color: p.shadow,
                      blurRadius: 6,
                      offset: const Offset(0, 3),
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
