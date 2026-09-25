import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A real map, drawn from OpenStreetMap's raster tiles.
///
/// **Why tiles and not `google_maps_flutter`.** The Maps SDK needs an API key
/// and a billing account, and without one it renders a blank grey square — on
/// this card, indistinguishable from "no fix yet". Tiles are plain PNGs over
/// HTTPS: no key, no native SDK, no extra APK weight, and nothing to configure
/// before the app works on someone else's phone. The trade-off is that this is a
/// picture rather than an interactive map, which is fine because tapping it
/// hands the point to the phone's real maps app, where panning and directions
/// belong.
///
/// **How it is positioned.** Web Mercator, the same projection every slippy map
/// uses. The point is converted to a pixel in the world at zoom [zoom], the
/// viewport is centred on it, and the tiles covering that rectangle are laid out
/// at their own world positions. That is what puts the pin exactly over the
/// place instead of merely near it — a single centred tile would be off by up to
/// half a tile, which at building zoom is the wrong side of the street.
///
/// **Offline.** Every tile fails independently and silently; the caller's own
/// background shows through. Nothing here throws, and nothing shows a broken
/// image icon.
class MapTileLayer extends StatelessWidget {
  const MapTileLayer({
    super.key,
    required this.latitude,
    required this.longitude,
    this.zoom = 17,
  });

  final double latitude;
  final double longitude;

  /// 17 is building level — close enough to recognise the block you are on,
  /// wide enough to see which way the road runs.
  final int zoom;

  static const double _tileSize = 256;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        if (!w.isFinite || !h.isFinite || w <= 0 || h <= 0) {
          return const SizedBox.shrink();
        }

        final scale = _tileSize * (1 << zoom);
        final worldX = _projectX(longitude) * scale;
        final worldY = _projectY(latitude) * scale;

        // Top-left of the viewport, in world pixels.
        final left = worldX - w / 2;
        final top = worldY - h / 2;

        final firstX = (left / _tileSize).floor();
        final lastX = ((left + w) / _tileSize).floor();
        final firstY = (top / _tileSize).floor();
        final lastY = ((top + h) / _tileSize).floor();

        final maxIndex = (1 << zoom) - 1;
        final tiles = <Widget>[];

        for (var ty = firstY; ty <= lastY; ty++) {
          // Above the pole or below it there is no tile. Wrapping y would show
          // the other hemisphere, so it is simply left blank.
          if (ty < 0 || ty > maxIndex) continue;
          for (var tx = firstX; tx <= lastX; tx++) {
            // x *does* wrap: the world is a cylinder, and a viewport straddling
            // the antimeridian needs the tiles from the far side.
            final wrappedX = tx % (maxIndex + 1);
            final normalisedX = wrappedX < 0 ? wrappedX + maxIndex + 1 : wrappedX;

            tiles.add(Positioned(
              left: tx * _tileSize - left,
              top: ty * _tileSize - top,
              width: _tileSize,
              height: _tileSize,
              child: Image.network(
                'https://tile.openstreetmap.org/$zoom/$normalisedX/$ty.png',
                // Required by the tile usage policy; requests without one are
                // refused outright.
                headers: const {
                  'User-Agent': 'FindX/1.0 (BLE proximity alert app)',
                },
                fit: BoxFit.cover,
                // No error icon and no placeholder box. A tile that cannot be
                // fetched should leave the card looking deliberate, not broken.
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
                // Fades in as each tile lands, so a slow connection looks like a
                // map loading rather than the card flickering.
                frameBuilder: (_, child, frame, wasSync) {
                  if (wasSync || frame != null) {
                    return AnimatedOpacity(
                      opacity: 1,
                      duration: const Duration(milliseconds: 220),
                      child: child,
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
            ));
          }
        }

        return Stack(
          fit: StackFit.expand,
          children: [
            ...tiles,

            // OSM's cartography is drawn for a white page. In dark mode it is a
            // bright rectangle in an otherwise dark app, so it is taken down a
            // little — not inverted, which turns roads into black scratches and
            // makes water look like land.
            if (isDark)
              IgnorePointer(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.28),
                ),
              ),

            // Attribution. Not decoration: the tiles are ODbL-licensed and
            // crediting the project is a condition of using them.
            Positioned(
              right: 6,
              bottom: 6,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: p.surface.withValues(alpha: 0.78),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  '© OpenStreetMap',
                  style: TextStyle(fontSize: 8.5, color: p.muted),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Longitude to a 0–1 fraction across the world.
  static double _projectX(double lng) => (lng + 180.0) / 360.0;

  /// Latitude to a 0–1 fraction down the world, Mercator.
  static double _projectY(double lat) {
    // Clamped to the Mercator limit: the projection sends the poles to
    // infinity, and an unclamped value produces a NaN offset that Flutter
    // asserts on rather than a blank map.
    final clamped = lat.clamp(-85.05112878, 85.05112878);
    final s = math.sin(clamped * math.pi / 180.0);
    return 0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi);
  }
}
