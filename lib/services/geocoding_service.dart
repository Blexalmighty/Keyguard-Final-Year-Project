import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Turns a latitude/longitude into a place a person recognises.
///
/// The location card used to show either raw coordinates or, worse, the phone's
/// IP address — neither of which answers the only question being asked, which is
/// *where is it*. "6.5186, 4.5218" is not a place, and an IP address is not a
/// location at all: it is the address of whatever network equipment the phone
/// happens to be behind, which on a mobile carrier can be a different city.
///
/// **Why Nominatim and not the platform geocoder.** Android's `Geocoder` returns
/// postal address components — street, locality, admin area — so the best it can
/// ever say is "Ile-Ife, Nigeria", possibly with a road name. What is wanted is
/// the *building*: "OAU Cafeteria". OpenStreetMap's reverse endpoint, asked at
/// high zoom, names the nearest mapped feature, which in practice is the café,
/// the hall of residence, the bank. That is the difference between a label the
/// owner has to interpret and one they can walk to.
///
/// **Why no new dependency.** `dart:io`'s HttpClient does this in a dozen lines.
/// Pulling in `http` or `geocoding` for one GET would add a plugin to every
/// platform build for nothing.
///
/// **Manners.** Nominatim's usage policy allows roughly one request a second
/// from an identified client, and it is free infrastructure funded by donations.
/// So: a real User-Agent, a hard floor between calls, a cache keyed on rounded
/// coordinates, and a short timeout. A failed lookup is not an error condition —
/// the caller simply keeps showing coordinates, which is what it did before.
class GeocodingService {
  /// How close two positions must be to count as the same place.
  ///
  /// Four decimal places is about 11 metres at the equator. Below that the
  /// answer would not change, so asking again would be a wasted request — and a
  /// phone sitting still produces a slightly different fix every few seconds.
  static const int _cachePrecision = 4;

  /// Minimum gap between outbound requests, per Nominatim's usage policy.
  static const Duration _minInterval = Duration(seconds: 2);

  /// Give up rather than keep a lookup pending behind a captive portal or a
  /// stalled mobile data session.
  static const Duration _timeout = Duration(seconds: 8);

  /// Bounded so a long drive cannot grow this without limit.
  static const int _maxCacheEntries = 64;

  final Map<String, String> _cache = <String, String>{};
  DateTime _lastRequest = DateTime.fromMillisecondsSinceEpoch(0);

  /// In-flight lookups, keyed the same way as [_cache].
  ///
  /// Without this, a burst of fixes at one spot would start several identical
  /// requests before the first returned — the exact behaviour the rate limit
  /// exists to prevent.
  final Map<String, Future<String?>> _inFlight = <String, Future<String?>>{};

  /// Returns a human place name for [lat]/[lng], or null if none can be had.
  ///
  /// Null is a normal result: offline, rate-limited, or simply nothing mapped
  /// nearby. Callers must be able to carry on without it.
  Future<String?> describe(double lat, double lng) {
    final key = _keyFor(lat, lng);

    final cached = _cache[key];
    if (cached != null) return Future<String?>.value(cached);

    final pending = _inFlight[key];
    if (pending != null) return pending;

    final future = _lookup(lat, lng, key);
    _inFlight[key] = future;
    return future.whenComplete(() => _inFlight.remove(key));
  }

  /// The most recent answer for these coordinates, without touching the network.
  ///
  /// Lets a caller paint the right label immediately on a position it has
  /// already resolved once — a returning screen should not flash coordinates
  /// while a round trip it does not need completes.
  String? cachedFor(double lat, double lng) => _cache[_keyFor(lat, lng)];

  String _keyFor(double lat, double lng) =>
      '${lat.toStringAsFixed(_cachePrecision)},'
      '${lng.toStringAsFixed(_cachePrecision)}';

  Future<String?> _lookup(double lat, double lng, String key) async {
    // Space the calls out rather than dropping them. A dropped lookup means the
    // card is stuck on coordinates until the owner moves, which looks broken;
    // waiting a second or two is invisible because the coordinates are already
    // on screen in the meantime.
    final since = DateTime.now().difference(_lastRequest);
    if (since < _minInterval) {
      await Future<void>.delayed(_minInterval - since);
    }
    _lastRequest = DateTime.now();

    HttpClient? client;
    try {
      // zoom=18 is building level. Lower and the answer collapses to the
      // suburb; higher is not meaningfully different and is more likely to come
      // back with nothing named at all.
      final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
        'format': 'jsonv2',
        'lat': lat.toStringAsFixed(6),
        'lon': lng.toStringAsFixed(6),
        'zoom': '18',
        'addressdetails': '1',
      });

      client = HttpClient()..connectionTimeout = _timeout;
      final request = await client.getUrl(uri).timeout(_timeout);
      // Identifying the client is a condition of use, not decoration. Requests
      // with a default or absent User-Agent are blocked outright.
      request.headers.set(HttpHeaders.userAgentHeader,
          'FindX/1.0 (BLE proximity alert app)');
      request.headers.set(HttpHeaders.acceptLanguageHeader, 'en');

      final response = await request.close().timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) return null;

      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_timeout);
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return null;

      final label = _label(decoded);
      if (label == null) return null;

      if (_cache.length >= _maxCacheEntries) _cache.clear();
      _cache[key] = label;
      return label;
    } on Object {
      // Every failure here — no network, DNS, TLS, timeout, malformed JSON — has
      // the same consequence for the caller, which is that it keeps showing
      // coordinates. Splitting them up would only produce log lines nobody
      // reads.
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  /// Builds "OAU Cafeteria, Ile-Ife" out of the response.
  ///
  /// Two parts, deliberately: the specific thing, then enough context to place
  /// it. "Cafeteria" alone is useless in a city with twenty; "Ile-Ife" alone is
  /// the failure the owner complained about. Nominatim's own `display_name` is
  /// the opposite problem — a seven-clause postal address that does not fit on
  /// the card and buries the one word that matters.
  static String? _label(Map<String, dynamic> json) {
    final address = json['address'];
    final addr = address is Map<String, dynamic>
        ? address
        : const <String, dynamic>{};

    String? pick(List<String> keys) {
      for (final k in keys) {
        final v = k == 'name' ? json['name'] : addr[k];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
      return null;
    }

    // Most specific first. `name` is the mapped feature itself — the cafeteria,
    // the library — and is what makes this worth doing at all.
    final specific = pick([
      'name',
      'amenity',
      'shop',
      'building',
      'house_name',
      'office',
      'leisure',
      'tourism',
      'road',
    ]);

    // Then something to hang it on.
    final area = pick([
      'neighbourhood',
      'suburb',
      'village',
      'town',
      'city',
      'county',
      'state',
    ]);

    if (specific == null) return area;
    if (area == null || area == specific) return specific;
    return '$specific, $area';
  }
}
