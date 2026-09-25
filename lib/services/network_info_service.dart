import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// The phone's network addresses, for the last-known-location card.
///
/// Two different things are worth showing and they answer different questions.
/// The **public** address is the one the outside world sees; it is what a server
/// would log, it is roughly geolocatable to a city, and it changes when the
/// phone moves between networks — so it is a coarse corroboration of where the
/// phone was when an event was recorded. The **local** address only means
/// anything inside the current network, but it needs no internet and is
/// therefore the one that is actually available when the phone is offline, which
/// is exactly when the public lookup fails.
class NetworkInfoService {
  /// How long a public-address lookup may take.
  ///
  /// Short on purpose. This is decoration on a card, not something the app's
  /// behaviour depends on, and a captive portal will happily hold a request open
  /// far longer than anyone will wait to see an IP address.
  static const Duration _timeout = Duration(seconds: 6);

  /// How long a successful public-address lookup is trusted.
  ///
  /// The address changes when the phone changes network, and there is no signal
  /// for that here, so this is a compromise between hammering a free endpoint
  /// and showing an address from a café two hours ago.
  static const Duration _publicCacheFor = Duration(minutes: 10);

  String? _publicIp;
  DateTime? _publicIpAt;
  String? _localIp;

  Future<String?>? _inFlight;

  /// The last public address fetched, if it is still fresh.
  String? get cachedPublicIp {
    final at = _publicIpAt;
    if (_publicIp == null || at == null) return null;
    if (DateTime.now().difference(at) > _publicCacheFor) return null;
    return _publicIp;
  }

  /// The last local address read, if any.
  String? get cachedLocalIp => _localIp;

  /// The best address currently known without doing any work, public first.
  String? get cachedAddress => cachedPublicIp ?? _localIp;

  /// True when [cachedAddress] is the public address rather than the local one.
  bool get cachedAddressIsPublic => cachedPublicIp != null;

  /// Reads the phone's address on the current network.
  ///
  /// Synchronous as far as the network is concerned — it enumerates interfaces
  /// rather than asking anyone — so this works with no internet at all.
  /// Loopback is excluded, because `127.0.0.1` tells the owner nothing.
  Future<String?> refreshLocalIp() async {
    if (kIsWeb) return null;
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        // IPv4 only. A phone's IPv6 address is long enough to wrap the card and
        // is usually a temporary privacy address, which makes it worse than
        // useless as something to recognise.
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.isLoopback) continue;
          _localIp = address.address;
          return _localIp;
        }
      }
    } catch (e) {
      debugPrint('NetworkInfoService: could not read local address: $e');
    }
    return _localIp;
  }

  /// Fetches the address the internet sees this phone as.
  ///
  /// Returns null when offline or when the lookup fails. Concurrent calls share
  /// one request.
  Future<String?> refreshPublicIp() {
    final existing = _inFlight;
    if (existing != null) return existing;

    final request = _fetchPublicIp();
    _inFlight = request;
    request.whenComplete(() {
      if (identical(_inFlight, request)) _inFlight = null;
    });
    return request;
  }

  Future<String?> _fetchPublicIp() async {
    if (kIsWeb) return null;

    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      // A plain-text endpoint rather than a JSON geolocation API: this only
      // needs the address, and asking a third party to *locate* the phone would
      // send the owner's address to someone else for information the phone's own
      // GPS already provides more accurately.
      final request = await client
          .getUrl(Uri.parse('https://api.ipify.org'))
          .timeout(_timeout);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != 200) return cachedPublicIp;

      final body =
          (await response.transform(utf8.decoder).join()).trim();
      // Validated rather than trusted: this is third-party text going onto the
      // owner's screen, and an error page would otherwise be shown as if it were
      // an address.
      if (body.isEmpty || body.length > 45) return cachedPublicIp;
      if (InternetAddress.tryParse(body) == null) return cachedPublicIp;

      _publicIp = body;
      _publicIpAt = DateTime.now();
      return _publicIp;
    } catch (e) {
      debugPrint('NetworkInfoService: public address lookup failed: $e');
      return cachedPublicIp;
    } finally {
      client.close(force: true);
    }
  }

  /// Reads both addresses, preferring whichever succeeds.
  ///
  /// The local read is awaited first because it cannot fail for network reasons,
  /// so the card has something to show even if the lookup that follows times
  /// out.
  Future<void> refresh() async {
    await refreshLocalIp();
    await refreshPublicIp();
  }
}
