/// Opens a position in Google Maps.
///
/// Deliberately a hand-off rather than an embedded map. `google_maps_flutter`
/// needs a Maps SDK API key compiled into `AndroidManifest.xml`, and a build
/// without one does not fail loudly — it renders a blank grey rectangle, which
/// on this screen would be indistinguishable from "no fix yet". Handing the
/// coordinates to the Maps app needs no key, no billing account and no network
/// permission of its own, and it lands the owner somewhere strictly more useful
/// than an in-app thumbnail: the real Maps app, with directions, satellite view
/// and a Share button.
library;

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens [latitude],[longitude] in whatever handles maps on this device.
///
/// Returns false if nothing could be opened, so the caller can say so rather
/// than leaving a tap looking ignored.
Future<bool> openInMaps({
  required double latitude,
  required double longitude,
  String? label,
}) async {
  if (kIsWeb) return false;

  final lat = latitude.toStringAsFixed(6);
  final lng = longitude.toStringAsFixed(6);
  final marker = label == null || label.trim().isEmpty
      ? '$lat,$lng'
      : Uri.encodeComponent(label.trim());

  // Tried in order of how well each one places a *pin* rather than a search
  // result.
  //
  // `geo:` with a `q` is the Android intent for "show me this point", and it is
  // the only one that does not need a browser. The universal https URL is the
  // fallback, which Android hands to the Maps app anyway when it is installed
  // and to the browser when it is not — so a phone with no Maps app still shows
  // the position rather than failing.
  final candidates = <Uri>[
    Uri.parse('geo:$lat,$lng?q=$lat,$lng($marker)'),
    Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=$lat%2C$lng',
    ),
  ];

  for (final uri in candidates) {
    try {
      if (await canLaunchUrl(uri)) {
        if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          return true;
        }
      }
    } catch (e) {
      debugPrint('openInMaps: $uri failed: $e');
    }
  }
  return false;
}
