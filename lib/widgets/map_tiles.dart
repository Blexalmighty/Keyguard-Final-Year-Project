import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Which cartography the card draws.
enum MapTileStyle {
  /// Aerial imagery over the street map. What "show me where it actually is"
  /// means to most people: roofs, car parks, footpaths — the things you
  /// recognise when you arrive.
  satellite,

  /// Street cartography alone. Lighter on requests and legible at any zoom,
  /// kept for callers that want a diagram rather than a photograph.
  streets,
}

/// A real map, drawn from raster tiles — satellite imagery over OpenStreetMap.
///
/// **Why tiles and not `google_maps_flutter`.** The Maps SDK needs a Google
/// Cloud API key with a billing account attached, and without one it renders a
/// blank grey square — on this card, indistinguishable from "no fix yet". That
/// is not a detail that can be worked around: hitting Google's own tile
/// endpoints directly, without the SDK, is a breach of their terms of service,
/// so there is no keyless path to Google's imagery at all. Tiles from open
/// providers are plain images over HTTPS: no key, no billing, no native SDK, no
/// extra APK weight, and nothing to configure before the app works on somebody
/// else's phone.
///
/// What people actually mean by "like Google Maps" is mostly **aerial imagery at
/// high zoom** — seeing the roof of the building rather than a coloured polygon
/// with a road name. That is what [MapTileStyle.satellite] provides, from Esri's
/// World Imagery service, and it is why this card no longer looks like a street
/// diagram. The remaining difference is interactivity, which is fine: tapping
/// hands the point to the phone's real maps app, where panning and directions
/// belong.
///
/// **Two layers, not one.** The satellite tiles are drawn *over* the street
/// tiles. Aerial coverage at building zoom is not universal, and where it is
/// missing the imagery request simply fails — at which point the street map
/// underneath shows through instead of a hole. Two sources cost a few more
/// requests per card and remove the one failure mode that would make the card
/// useless.
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
    this.zoom = 18,
    this.style = MapTileStyle.satellite,
  });

  final double latitude;
  final double longitude;

  /// 18 is building level, and it is 18 rather than 17 on purpose: it is the
  /// same zoom `GeocodingService` asks Nominatim for, so the picture and the
  /// label underneath it describe the same scale. A card that says "OAU
  /// Cafeteria" over a view of half the campus is two answers to one question.
  final int zoom;

  final MapTileStyle style;

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

        final streets = _tilesFor(
          left: left,
          top: top,
          width: w,
          height: h,
          url: _streetUrl,
        );
        final imagery = style == MapTileStyle.satellite
            ? _tilesFor(
                left: left,
                top: top,
                width: w,
                height: h,
                url: _satelliteUrl,
              )
            : const <Widget>[];

        return Stack(
          fit: StackFit.expand,
          children: [
            ...streets,

            // Over the streets: where imagery exists this is the map, and where
            // it does not the request fails and the streets below are what the
            // owner sees.
            ...imagery,

            // OSM's cartography is drawn for a white page. In dark mode it is a
            // bright rectangle in an otherwise dark app, so it is taken down a
            // little — not inverted, which turns roads into black scratches and
            // makes water look like land. Aerial imagery is already dark enough
            // not to need it, so this only applies to the street style.
            if (isDark && style == MapTileStyle.streets)
              IgnorePointer(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.28),
                ),
              ),

            // Attribution. Not decoration: both sources require credit as a
            // condition of use — OSM's tiles are ODbL, and Esri's World Imagery
            // terms name the providers behind the pixels.
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
                  style == MapTileStyle.satellite
                      ? '© Esri, Maxar · OpenStreetMap'
                      : '© OpenStreetMap',
                  style: TextStyle(fontSize: 8.5, color: p.muted),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Lays out one source's tiles across the viewport.
  List<Widget> _tilesFor({
    required double left,
    required double top,
    required double width,
    required double height,
    required String Function(int x, int y) url,
  }) {
    final firstX = (left / _tileSize).floor();
    final lastX = ((left + width) / _tileSize).floor();
    final firstY = (top / _tileSize).floor();
    final lastY = ((top + height) / _tileSize).floor();

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
            url(normalisedX, ty),
            // Required by the tile usage policy; requests without one are
            // refused outright.
            headers: const {
              'User-Agent': 'FindX/1.0 (BLE proximity alert app)',
            },
            fit: BoxFit.cover,
            // No error icon and no placeholder box. A tile that cannot be
            // fetched should leave the card looking deliberate, not broken —
            // and for the imagery layer this is the mechanism that reveals the
            // street map underneath where there is no aerial coverage.
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
    return tiles;
  }

  String _streetUrl(int x, int y) =>
      'https://tile.openstreetmap.org/$zoom/$x/$y.png';

  /// Esri's World Imagery, free to use with attribution.
  ///
  /// Note the path order — `/tile/{z}/{y}/{x}` — which is row before column,
  /// the opposite of the OSM convention. Swapping them silently returns a tile
  /// from somewhere else on Earth rather than an error, which is the kind of bug
  /// that survives review.
  String _satelliteUrl(int x, int y) =>
      'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/'
      'MapServer/tile/$zoom/$y/$x';

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
