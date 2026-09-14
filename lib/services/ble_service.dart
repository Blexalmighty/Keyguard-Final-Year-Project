import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/alert_distances.dart';
import '../models/alert_pattern.dart';
import '../models/ble_device.dart';
import '../models/event_model.dart';
import '../models/history_retention.dart';
import '../utils/coordinate_format.dart';
import 'background_service.dart';
import 'ble_protocol.dart';
import 'ble_vendors.dart';
import 'network_info_service.dart';
import 'notification_service.dart';
import 'phone_location_service.dart';
import 'phone_ringer_service.dart';
import 'proximity_model.dart';
import 'scan_list_diff.dart';
import 'settings_store.dart';

/// Central BLE service: discovery, connection, and the data channel to the
/// keyholder.
///
/// Rewritten so that every value the UI shows comes from the radio. Previously
/// the connection flag started at `true`, a phantom `KG-9921` card was injected
/// into every scan result, and RSSI came from `Random()` — so the app looked
/// like it was working whether or not any hardware existed. Anything simulated
/// now lives behind [demoModeEnabled], which is off by default and cannot touch
/// a real device.
class BleService extends ChangeNotifier {
  BleService() {
    _init();
  }

  // ---------------------------------------------------------------------------
  // Configuration / persistence
  // ---------------------------------------------------------------------------

  SettingsStore? _settings;
  ProximityModel _proximity = const ProximityModel();

  /// Makes the phone itself ring when the keyholder's button is pressed.
  ///
  /// Injected rather than constructed here, and nullable, for two reasons: the
  /// Settings screen needs the same instance in order to change the tone, and a
  /// unit test that only exercises the protocol should not have to stand up an
  /// audio player. Everything below calls it through `?.`, so a service with no
  /// ringer attached behaves exactly as it did before — it just stays quiet.
  PhoneRingerService? _ringer;

  /// Wired up in `main.dart`. Idempotent, because `ChangeNotifierProxyProvider`
  /// calls its `update` on every rebuild of the provider scope.
  void attachRinger(PhoneRingerService ringer) {
    if (identical(_ringer, ringer)) return;
    _ringer = ringer;
  }

  /// The ringer, for the UI. Null until [attachRinger] has run.
  PhoneRingerService? get phoneRinger => _ringer;

  /// Posts the "your keys are getting away from you" warning. Injected and
  /// nullable for the same reasons as [_ringer]: a protocol test should not have
  /// to stand up a platform notification channel.
  NotificationService? _notifications;

  void attachNotifications(NotificationService notifications) {
    if (identical(_notifications, notifications)) return;
    _notifications = notifications;
  }

  /// Set once the app-open notification prompt has been shown, so a later
  /// permission retry does not ask a second time.
  ///
  /// The request itself is deliberately *not* made here in [attachNotifications].
  /// The constructor's [_checkPermissions] is already walking a chain of Android
  /// permission dialogs (scan, connect, location), and `permission_handler`
  /// rejects a request issued while another is in flight — so a notification
  /// request fired from here, during the same first build, would race that chain
  /// and usually be swallowed. Instead it is appended to the end of that one
  /// serialized chain, which also gives the app its "ask on opening" behaviour.
  bool _notificationPermissionRequested = false;

  /// Cap on the stored event log. The history screen is a timeline, not an
  /// archive, and an unbounded JSON blob in preferences would eventually hurt.
  static const int _maxHistoryEntries = 200;

  static const Duration _rssiPollInterval = Duration(seconds: 2);
  static const Duration _scanTimeout = Duration(seconds: 15);

  /// Pause between the end of one hunting scan and the start of the next.
  ///
  /// Four seconds keeps starts to roughly two per 30-second window, comfortably
  /// under Android's limit of five, while leaving the radio quiet long enough
  /// that continuous hunting is not a battery disaster.
  static const Duration _rescanGap = Duration(seconds: 4);
  static const Duration _connectTimeout = Duration(seconds: 20);

  /// The keyholder's own buzzer times out; if a STOP is missed, the app should
  /// not sit there claiming an alert is still sounding.
  static const Duration _alertAutoClear = Duration(seconds: 45);

  // ---------------------------------------------------------------------------
  // Device / connection state
  // ---------------------------------------------------------------------------

  /// False until a real GATT connection is established. This is the single most
  /// important line in the file: it used to be `true`.
  bool _isConnected = false;
  bool _isConnecting = false;

  String _deviceName = 'Keyholder';
  String _deviceId = '';

  int? _batteryLevel;
  int? _currentRssi;
  double? _estimatedDistance;

  /// When the last RSSI sample landed. The Home screen used to print the words
  /// "Updated Just Now" unconditionally, including while disconnected.
  DateTime? _lastRssiUpdate;

  bool _isPinging = false;
  bool _isAlertActive = false;
  Timer? _alertTimer;

  int _negotiatedMtu = 0;

  /// OS-level pairing state. Distinct from ownership: a phone can be bonded
  /// (link encrypted) and still be refused as an owner.
  BluetoothBondState? _bondState;
  StreamSubscription<BluetoothBondState>? _bondSubscription;

  OwnershipState _ownershipState = OwnershipState.unknown;

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _dataChar;
  BluetoothCharacteristic? _authChar;
  BluetoothCharacteristic? _provChar;

  StreamSubscription<List<int>>? _dataSubscription;
  StreamSubscription<List<int>>? _authSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  Timer? _rssiTimer;

  /// Auth frames are republished so `pairing_service.dart` can drive the
  /// ownership handshake without this class owning the crypto.
  final StreamController<String> _authFrames =
      StreamController<String>.broadcast();

  /// Last Wi-Fi provisioning outcome, as reported by the keyholder.
  ///
  /// Null until a WIFI_OK/WIFI_FAIL frame has arrived this session. The Wi-Fi
  /// setup screen sets a flag on the way in ([_awaitWifiResult]) and reads this
  /// when the frame lands, so it can show "joined 192.168.1.4" or "wrong
  /// password" without having to keep a subscription open itself.
  String? _wifiSetupResult;
  bool _awaitWifiResult = false;

  // ---------------------------------------------------------------------------
  // GPS state
  // ---------------------------------------------------------------------------

  bool _hasGpsFix = false;
  String _lastLat = '';
  String _lastLng = '';

  /// Only ever set from a real reverse-geocode (Phase 4). It used to be
  /// overwritten with the literal `"Mission District, CA"` on every `LOC:`
  /// frame, which meant the app confidently mislabelled every position.
  String _locationName = '';

  /// The phone's own receiver, which has replaced the keyholder's GPS module as
  /// the source of positions.
  ///
  /// The keyholder's receiver could only be read over a live BLE link, so at the
  /// one moment a position is worth having — the link dropping — there was no
  /// way to ask for it and the event was stamped with a stale reading. The phone
  /// is available then. Injected and nullable for the same reason as the ringer
  /// and the notifications: a protocol test should not have to stand up a
  /// platform location channel.
  PhoneLocationService? _phoneLocation;

  void attachPhoneLocation(PhoneLocationService location) {
    if (identical(_phoneLocation, location)) return;
    _phoneLocation = location;
    // Warms the cache at startup so the first event of the session — very often
    // an auto-connect that happens before the owner has even opened the app —
    // has a position to be stamped with.
    unawaited(_refreshPhoneFix());
  }

  /// The phone's location service, for the UI. Null until attached.
  PhoneLocationService? get phoneLocation => _phoneLocation;

  /// The phone's network addresses, shown beside the last known position.
  ///
  /// Injected and nullable like the rest. Held here rather than read directly by
  /// the Home screen so that the address survives a tab switch — a
  /// `StatefulWidget` in an `IndexedStack` would keep it too, but a rebuild from
  /// any other cause would re-run the lookup, and this is a network request.
  NetworkInfoService? _networkInfo;

  void attachNetworkInfo(NetworkInfoService info) {
    if (identical(_networkInfo, info)) return;
    _networkInfo = info;
    unawaited(refreshNetworkAddress());
  }

  /// The address to show: the public one when a lookup has succeeded, otherwise
  /// the local one. Null when neither is known yet.
  String? get networkAddress => _networkInfo?.cachedAddress;

  /// True when [networkAddress] is the public address rather than the local one,
  /// so the label can say which it is. Showing a LAN address as though it were
  /// the phone's internet address would be quietly wrong.
  bool get networkAddressIsPublic =>
      _networkInfo?.cachedAddressIsPublic ?? false;

  /// Re-reads the phone's addresses.
  ///
  /// Called on attach and whenever connectivity changes, since a public address
  /// only becomes readable once there is a route to read it over and changes
  /// when the phone moves between networks.
  Future<void> refreshNetworkAddress() async {
    final info = _networkInfo;
    if (info == null) return;
    final before = info.cachedAddress;
    await info.refresh();
    if (info.cachedAddress != before) notifyListeners();
  }

  /// Pulls a fresh position from the phone and publishes it as the last known
  /// location.
  ///
  /// Returns the fix, or null if the receiver could not produce one.
  Future<PhoneFix?> _refreshPhoneFix() async {
    final service = _phoneLocation;
    if (service == null) return null;
    final fix = await service.refresh();
    if (fix != null) _adoptPhoneFix(fix);
    return fix;
  }

  /// Publishes [fix] as the app's current position.
  ///
  /// Returns true when something actually moved, so callers can decide whether a
  /// rebuild is worth it. Split from [_adoptPhoneFix] because [_logEvent]
  /// notifies once at the end anyway and a second notification for the same
  /// frame would rebuild the History screen twice.
  bool _applyPhoneFix(PhoneFix fix) {
    final lat = fix.latitudeText;
    final lng = fix.longitudeText;
    if (lat == _lastLat && lng == _lastLng && _hasGpsFix) return false;

    // A cached place name belongs to the previous coordinates.
    if (lat != _lastLat || lng != _lastLng) _locationName = '';

    _lastLat = lat;
    _lastLng = lng;
    _hasGpsFix = true;
    return true;
  }

  /// Publishes [fix] as the app's current position and rebuilds.
  void _adoptPhoneFix(PhoneFix fix) {
    if (_applyPhoneFix(fix)) notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Scanning state
  // ---------------------------------------------------------------------------

  bool _isScanning = false;

  /// False until the runtime permissions are actually granted.
  bool _hasBluetoothPermission = false;
  String _permissionStatusMessage = '';

  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  bool _hasInternet = false;
  String _lastError = '';

  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<bool>? _isScanningSubscription;
  StreamSubscription<BluetoothAdapterState>? _adapterStateSubscription;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  /// Discovered entries, keyed by remote id.
  final Map<String, BleDevice> _discovered = {};

  /// The underlying radio handles, so a tap on a card can connect for real
  /// rather than just flipping a boolean.
  final Map<String, BluetoothDevice> _radios = {};

  List<BleDevice> _scannedDevices = [];

  /// The keyholder this phone is paired with, remembered across launches.
  String? _knownDeviceId;

  /// Set once per launch so a repeatedly-firing `scanResults` cannot stack up
  /// overlapping `connect()` calls — the old auto-connect sat inside the scan
  /// callback with no such guard.
  bool _autoConnectDone = false;

  /// Consecutive failed auto-connect attempts.
  ///
  /// A failed connect re-arms the hunt (see [connectToDevice]), which is right
  /// for the ordinary case — the keyholder was at the edge of range and the
  /// link did not come up. But a unit that refuses every time would then be
  /// retried forever, holding the radio on for the rest of the day. After
  /// [_maxAutoConnectAttempts] the app stops trying by itself and waits for the
  /// owner to press scan, which resets this.
  int _autoConnectFailures = 0;
  static const int _maxAutoConnectAttempts = 3;

  /// True while the app should keep re-arming the scan until it finds the
  /// keyholder. See [beginContinuousScan].
  bool _keepHunting = false;
  Timer? _rescanTimer;

  /// Whether the scan currently running was started by the hunt loop rather
  /// than by the owner.
  ///
  /// Read by the `scanResults` error handler, which is subscribed once for the
  /// object's lifetime and so has no other way to tell an automatic scan from
  /// one the owner asked for.
  bool _scanIsBackground = false;

  /// True once the keyholder has crossed half the alert distance on its way out,
  /// so the warning fires once per departure rather than on every RSSI sample.
  bool _proximityWarned = false;

  /// The same latch for the configured alert distance itself. Separate from
  /// [_proximityWarned] because the two boundaries are crossed at different
  /// moments and each notice has to fire exactly once per departure.
  bool _outOfRangeWarned = false;

  /// And the same again for the maximum allowance, the outermost boundary.
  bool _maxAllowanceWarned = false;

  bool _proximityWarningEnabled = true;

  /// Whether the app holds its own process open once the owner leaves it.
  ///
  /// See services/background_service.dart for what that actually means. Mirrored
  /// here rather than read from the store on demand so the Settings switch has
  /// something synchronous to render.
  bool _backgroundRunningEnabled = true;

  // ---------------------------------------------------------------------------
  // Signal
  // ---------------------------------------------------------------------------

  final RssiWindow _rssiWindow = RssiWindow();

  // ---------------------------------------------------------------------------
  // History
  // ---------------------------------------------------------------------------

  List<EventModel> _historyEvents = [];

  // ---------------------------------------------------------------------------
  // Settings (mirrored from SettingsStore so getters stay synchronous)
  // ---------------------------------------------------------------------------

  double _alertDistanceThreshold = 2.0;

  /// The outer boundary: how far the keyholder may get before the app treats it
  /// as gone rather than merely wandering.
  ///
  /// Always at or above [_alertDistanceThreshold] — see [maxAllowanceDistance],
  /// which enforces that on read so a stored pair that has fallen out of order
  /// (an old install where the alert distance was raised past the allowance)
  /// cannot produce a boundary that fires before the one inside it.
  double _maxAllowanceDistance = kDefaultMaxAllowance;

  bool _alertSoundEnabled = true;

  /// The buzzer cadence. See [AlertPattern] for why this is a rhythm rather than
  /// a tone: the keyholder's buzzer is an active element with exactly one pitch.
  AlertPattern _alertPattern = AlertPattern.fallback;

  bool _saveGpsOnDisconnect = true;
  bool _wifiCloudSyncEnabled = true;
  bool _darkModeEnabled = false;
  bool _demoModeEnabled = false;

  Timer? _demoTimer;

  // ===========================================================================
  // Getters
  // ===========================================================================

  bool get isConnected => _isConnected;
  bool get isConnecting => _isConnecting;
  String get deviceName => _deviceName;
  String get deviceId => _deviceId.isEmpty ? '—' : _deviceId;

  /// The name to put in front of the owner for [deviceId].
  ///
  /// Prefers the nickname they chose, because a claimed keyholder advertises the
  /// deliberately generic "Find Me" — see SettingsStore.nicknameFor. Falls back
  /// to whatever the radio broadcast, then to a last resort so no card is ever
  /// blank.
  String displayNameFor(String id, {String? advertised}) {
    final nick = _settings?.nicknameFor(id);
    if (nick != null && nick.isNotEmpty) return nick;
    if (advertised != null && advertised.isNotEmpty) return advertised;
    return 'Keyholder';
  }

  /// The connected (or last known) keyholder's display name.
  String get displayName => displayNameFor(_deviceId, advertised: _deviceName);

  /// True when the owner has given this keyholder a name of their own.
  bool get hasNickname {
    final n = _settings?.nicknameFor(_deviceId);
    return n != null && n.isNotEmpty;
  }

  /// Rename the connected keyholder. Local to this phone; nothing is written to
  /// the device, so the advertised name stays generic.
  Future<void> setNickname(String nickname) async {
    if (_deviceId.isEmpty) return;
    await _settings?.setNickname(_deviceId, nickname);
    _rebuildScannedDevices();
    notifyListeners();
  }

  /// True once a keyholder has been connected to at least once on this phone.
  bool get hasKnownDevice => _knownDeviceId != null;

  int get batteryLevel => _batteryLevel ?? 0;
  bool get hasBatteryReading => _batteryLevel != null;

  int get currentRssi => _currentRssi ?? 0;
  bool get hasRssiReading => _currentRssi != null;

  /// Human-readable age of the most recent RSSI sample.
  String get rssiFreshness {
    final at = _lastRssiUpdate;
    if (at == null) return 'No readings yet';
    final seconds = DateTime.now().difference(at).inSeconds;
    if (seconds <= 3) return 'Updated just now';
    if (seconds < 60) return 'Updated ${seconds}s ago';
    final minutes = seconds ~/ 60;
    return 'Updated ${minutes}m ago';
  }

  double get estimatedDistance => _estimatedDistance ?? 0.0;
  bool get hasDistanceEstimate => _estimatedDistance != null;

  /// True when the keyholder is further away than the configured threshold.
  bool get isOutOfRange =>
      _isConnected &&
      _estimatedDistance != null &&
      _estimatedDistance! > _alertDistanceThreshold;

  bool get isPinging => _isPinging;
  bool get isAlertActive => _isAlertActive;

  int get negotiatedMtu => _negotiatedMtu;
  OwnershipState get ownershipState => _ownershipState;

  bool get hasGpsFix => _hasGpsFix;
  String get lastLat => _lastLat;
  String get lastLng => _lastLng;

  String get locationName {
    if (_locationName.isNotEmpty) return _locationName;
    if (_hasGpsFix) return coordinatesFormatted;
    return 'Location unknown';
  }

  String get coordinatesFormatted {
    if (!isPlausibleFix(_lastLat, _lastLng)) return 'No GPS fix';
    return formatCoordinateStrings(_lastLat, _lastLng);
  }

  List<double> get rssiBars => List.unmodifiable(_rssiWindow.barHeights);

  bool get isScanning => _isScanning;
  bool get hasBluetoothPermission => _hasBluetoothPermission;
  String get permissionStatusMessage => _permissionStatusMessage;

  BluetoothAdapterState get adapterState => _adapterState;
  bool get isBluetoothOn => _adapterState == BluetoothAdapterState.on;
  bool get hasInternet => _hasInternet;
  String get lastError => _lastError;

  /// Dismiss whatever is in [lastError].
  ///
  /// The banner that shows this used to have no way off the screen: nothing
  /// cleared `_lastError` except the *start* of the next scan or connect, so a
  /// message like "could not connect after 3 tries" sat there in red long after
  /// the keyholder had been found and was sitting in the list. An error the user
  /// has read and acted on is no longer news, and they need to be able to say so.
  void clearError() {
    if (_lastError.isEmpty) return;
    _lastError = '';
    notifyListeners();
  }

  List<BleDevice> get scannedDevices => List.unmodifiable(_scannedDevices);
  List<EventModel> get historyEvents => List.unmodifiable(_historyEvents);

  /// The scan list the UI renders, sorted so the interesting things are on top.
  ///
  /// Everything the radio can see, unfiltered. There used to be a relevance
  /// filter in front of this — all nearby, or keyholders only — and it was
  /// removed because a keyholder hidden behind the wrong selection is
  /// indistinguishable from a keyholder that is not there. Ordering does the
  /// filter's real job: keyholders first, then by signal strength, so the thing
  /// the owner is looking for is never buried under a neighbour's television.
  ///
  /// That ordering is applied once in [_rebuildScannedDevices], where the list is
  /// built, rather than again here. This getter is read during build, and with
  /// `continuousUpdates` the scan callback fires several times a second, so a
  /// copy-and-re-sort per frame was paying twice for an order the service had
  /// already established.
  List<BleDevice> get filteredScannedDevices =>
      List.unmodifiable(_scannedDevices);

  /// How many keyholders the current scan can see, for the Scan screen counter.
  int get keyholderCount => _scannedDevices.where((d) => d.isKeyholder).length;

  /// Explains what the keyholder's Wi-Fi is for, on the Settings screen.
  ///
  /// It reads as a range feature to users — "Wi-Fi gives it better range" — and
  /// that is half true, but not in the way people assume. It does not extend the
  /// phone-to-keyholder radio link; it lets the keyholder report its position to
  /// the cloud so the phone can read it from anywhere. Saying so plainly here is
  /// cheaper than letting the user discover it when it matters.
  String get wifiStatusMessage =>
      'Giving your keyholder a Wi-Fi network lets it report its position to the '
      'cloud on its own, so you can still see where it is when it is out of '
      'Bluetooth range. The phone always talks to the keyholder over Bluetooth; '
      'this only widens where its last position can reach you.';

  double get alertDistanceThreshold => _alertDistanceThreshold;

  /// The maximum allowance, never reported as closer than the alert distance.
  ///
  /// Clamped here rather than only on write, because the alert distance can be
  /// raised after the allowance was set. Without this an owner who moved the
  /// alert distance to 8 m while the allowance sat at 4 m would have an outer
  /// boundary *inside* the inner one, and the "gone too far" notice would fire
  /// before the "out of range" notice it is supposed to escalate from.
  double get maxAllowanceDistance =>
      _maxAllowanceDistance < _alertDistanceThreshold
          ? _alertDistanceThreshold
          : _maxAllowanceDistance;

  /// True when the allowance is far enough beyond the alert distance to be a
  /// separate event worth notifying about.
  ///
  /// At or very near the alert distance the two boundaries would be crossed in
  /// the same RSSI sample and the owner would get two notifications for one
  /// departure. Half a metre of separation is the point at which the escalation
  /// means something.
  bool get maxAllowanceActive =>
      maxAllowanceDistance >= _alertDistanceThreshold + 0.5;

  bool get alertSoundEnabled => _alertSoundEnabled;
  AlertPattern get alertPattern => _alertPattern;
  bool get saveGpsOnDisconnect => _saveGpsOnDisconnect;
  bool get wifiCloudSyncEnabled => _wifiCloudSyncEnabled;
  bool get darkModeEnabled => _darkModeEnabled;
  bool get demoModeEnabled => _demoModeEnabled;

  ProximityModel get proximityModel => _proximity;

  String get signalQuality {
    final rssi = _currentRssi;
    if (rssi == null) return 'No signal';
    return ProximityModel.qualityFor(rssi);
  }

  /// Auth-characteristic traffic, for the pairing service.
  Stream<String> get authFrames => _authFrames.stream;
  BluetoothCharacteristic? get authCharacteristic => _authChar;
  BluetoothCharacteristic? get provisioningCharacteristic => _provChar;
  BluetoothDevice? get connectedDevice => _connectedDevice;

  // ===========================================================================
  // Initialisation
  // ===========================================================================

  Future<void> _init() async {
    await _loadSettings();
    _listenAdapterState();
    _listenScanResults();
    _listenScanningFlag();
    _listenConnectivity();
    await _checkPermissions();
  }

  Future<void> _loadSettings() async {
    try {
      final store = await SettingsStore.open();
      _settings = store;

      _alertDistanceThreshold = store.alertDistanceThreshold;
      _maxAllowanceDistance = store.maxAllowanceDistance;
      _alertSoundEnabled = store.alertSoundEnabled;
      _alertPattern = store.alertPattern;
      _saveGpsOnDisconnect = store.saveGpsOnDisconnect;
      _wifiCloudSyncEnabled = store.wifiCloudSyncEnabled;
      _darkModeEnabled = store.darkModeEnabled;
      _demoModeEnabled = store.demoModeEnabled;
      _proximity = store.proximityModel;

      _knownDeviceId = store.lastDeviceId;
      final knownName = store.lastDeviceName;
      if (knownName != null && knownName.isNotEmpty) _deviceName = knownName;
      if (_knownDeviceId != null) _deviceId = _knownDeviceId!;
      _proximityWarningEnabled = store.proximityWarningEnabled;
      _backgroundRunningEnabled = store.backgroundRunningEnabled;

      // Read before the history it governs, so the restore below can drop
      // anything already past its date rather than briefly showing it.
      _historyRetention = store.historyRetention;

      _restoreHistory(store.historyJson);

      if (_demoModeEnabled) _startDemoMode();

      // After the stored preference is known, and not awaited: starting a
      // foreground service crosses a platform channel, and first paint should
      // not wait on it.
      unawaited(_syncBackgroundService());

      notifyListeners();
    } catch (e) {
      debugPrint('BleService: could not open settings store: $e');
    }
  }

  void _restoreHistory(String? json) {
    if (json == null || json.isEmpty) return;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return;
      _historyEvents = decoded
          .whereType<Map<String, dynamic>>()
          .map(EventModel.fromJson)
          .toList();
      // Enforced on the way in as well as on the way out. The app may have been
      // closed for longer than the retention window, in which case the rows are
      // already expired by the time they are read back and must not be shown.
      if (_pruneHistory()) unawaited(_persistHistory());
    } catch (e) {
      debugPrint('BleService: discarding unreadable history: $e');
    }
  }

  /// The owner's retention choice. Defaults to [HistoryRetention.forever] until
  /// settings load, so nothing is ever deleted on the strength of a default.
  HistoryRetention _historyRetention = HistoryRetention.forever;

  HistoryRetention get historyRetention => _historyRetention;

  /// Change how long location history is kept, applying it immediately.
  ///
  /// Applied at once rather than at the next event, because a setting that
  /// promises to delete something should have done so by the time the owner has
  /// finished reading the row they just tapped.
  Future<void> setHistoryRetention(HistoryRetention value) async {
    if (_historyRetention == value) return;
    _historyRetention = value;
    await _settings?.setHistoryRetention(value);
    if (_pruneHistory()) await _persistHistory();
    notifyListeners();
  }

  /// Drop events older than the retention window. Returns true if any were
  /// removed, so callers know whether a re-save is needed.
  bool _pruneHistory() {
    final cutoff = _historyRetention.cutoffFrom(DateTime.now());
    if (cutoff == null || _historyEvents.isEmpty) return false;
    final before = _historyEvents.length;
    _historyEvents =
        _historyEvents.where((e) => e.timestamp.isAfter(cutoff)).toList();
    return _historyEvents.length != before;
  }

  Future<void> _persistHistory() async {
    final store = _settings;
    if (store == null) return;
    try {
      await store.setHistoryJson(
        jsonEncode(_historyEvents.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('BleService: could not persist history: $e');
    }
  }

  void _listenAdapterState() {
    if (kIsWeb) return;
    _adapterStateSubscription =
        FlutterBluePlus.adapterState.listen((state) async {
      _adapterState = state;
      if (state != BluetoothAdapterState.on) {
        // Bluetooth was switched off — nothing below this layer will tell us the
        // link is gone, so tear the session down ourselves.
        _lastError = 'Bluetooth is turned off.';
        if (_isConnected) await _handleDisconnected(logEvent: true);
        _isScanning = false;
      } else if (_lastError == 'Bluetooth is turned off.') {
        _lastError = '';
        // Turning the adapter back on is the user saying "look again". The
        // hunt's timer cannot have survived the radio being off, so re-arm it.
        if (!_isConnected && _hasBluetoothPermission) beginContinuousScan();
      }
      notifyListeners();
    }, onError: (Object e) => debugPrint('adapterState error: $e'));
  }

  void _listenScanningFlag() {
    if (kIsWeb) return;
    // Drives the radar animation from the platform's own view of whether a scan
    // is running, so a scan that ends on timeout stops the spinner.
    _isScanningSubscription = FlutterBluePlus.isScanning.listen((scanning) {
      if (_isScanning == scanning) return;
      _isScanning = scanning;

      // A scan that just ended while there is still nothing to talk to is not a
      // finished job, it is a keyholder the phone has not found *yet*. Android
      // caps a single startScan at a fixed window and then stops the radio, so
      // "keep looking" has to be re-armed each time rather than requested once.
      if (!scanning && _keepHunting && !_isConnected && !_isConnecting) {
        _armRescan();
      }
      notifyListeners();
    });
  }

  /// Restart the scan shortly after one ends, for as long as we are hunting.
  ///
  /// The gap is deliberate. Back-to-back scanning with no pause is what Android
  /// 7+ penalises with `SCAN_FAILED_SCANNING_TOO_FREQUENTLY` — five starts in a
  /// 30-second window and the app is blocked from scanning for the next half
  /// minute, which would turn "always looking" into "never looking".
  void _armRescan() {
    _rescanTimer?.cancel();
    _rescanTimer = Timer(_rescanGap, () {
      if (!_keepHunting || _isConnected || _isConnecting) return;
      unawaited(startActiveHardwareScan(background: true));
    });
  }

  /// Look for the keyholder continuously until it is found.
  ///
  /// Called on launch, on an explicit scan, and — the case that matters most —
  /// the instant a connection drops, because that is exactly when the owner has
  /// walked away from their keys and the app has one job.
  void beginContinuousScan() {
    if (kIsWeb) return;
    _keepHunting = true;
    if (!_isConnected && !_isConnecting && !FlutterBluePlus.isScanningNow) {
      unawaited(startActiveHardwareScan(background: true));
    }
  }

  /// Stop the hunt. Called on connect, and when the user stops a scan by hand.
  void endContinuousScan() {
    _keepHunting = false;
    _rescanTimer?.cancel();
    _rescanTimer = null;
  }

  void _listenConnectivity() {
    try {
      _connectivitySubscription =
          Connectivity().onConnectivityChanged.listen((results) {
        // Scoped to what connectivity_plus can actually answer: does *this
        // phone* have a route to the internet. It cannot enumerate access
        // points, so it is no longer used to fabricate a Wi-Fi scan result.
        _hasInternet = results.any((r) =>
            r == ConnectivityResult.wifi ||
            r == ConnectivityResult.mobile ||
            r == ConnectivityResult.ethernet);
        notifyListeners();

        // The phone's public address depends on which network it is on, so a
        // connectivity change is exactly when it needs re-reading. Also the only
        // chance to read it at all if the app started with no route: the lookup
        // on attach would have failed and there is nothing else to retry it.
        if (_hasInternet) unawaited(refreshNetworkAddress());
      });
    } catch (e) {
      debugPrint('BleService: connectivity listener error: $e');
    }
  }

  // ===========================================================================
  // Permissions
  // ===========================================================================

  Future<void> _checkPermissions() async {
    if (kIsWeb) {
      _hasBluetoothPermission = false;
      _permissionStatusMessage =
          'Bluetooth scanning is not available in a browser. Run the app on an '
          'Android device.';
      notifyListeners();
      return;
    }

    try {
      final scan = await Permission.bluetoothScan.request();
      final connect = await Permission.bluetoothConnect.request();

      // Location is requested but *not* required. On Android 12+ the manifest
      // declares BLUETOOTH_SCAN with `neverForLocation`, so scanning needs no
      // location grant — and this app has no business deriving your position
      // from nearby radios. Android 11 and below still gate BLE scanning behind
      // it, hence the best-effort request.
      final location = await Permission.locationWhenInUse.request();

      // The notification prompt rides on the tail of the Bluetooth chain rather
      // than racing it — see [_notificationPermissionRequested]. Asked once per
      // app open, after the requests above have all resolved, so the owner sees
      // one orderly sequence of dialogs rather than two that collide. Awaited so
      // it stays part of that sequence; a denial is a real answer and the
      // posting methods already fall silent without the grant.
      if (!_notificationPermissionRequested) {
        _notificationPermissionRequested = true;
        await _notifications?.requestPermission();
      }

      if (scan.isGranted && connect.isGranted) {
        _hasBluetoothPermission = true;
        _permissionStatusMessage = location.isGranted
            ? ''
            : 'Location access was declined. On Android 11 and older this stops '
                'Bluetooth scanning from returning results.';
        notifyListeners();
        // Not a single `startActiveHardwareScan()`: Android stops the radio at
        // the end of every scan window, so one call means the app looks for a
        // few seconds after launch and then quietly gives up. This arms the
        // repeating hunt instead, which stops itself the moment it connects.
        beginContinuousScan();
      } else {
        _hasBluetoothPermission = false;
        _permissionStatusMessage = scan.isPermanentlyDenied ||
                connect.isPermanentlyDenied
            ? 'Bluetooth permissions were permanently denied. Enable them in '
                'Android Settings › Apps › Find X › Permissions.'
            : 'Nearby-devices permission is required to find your keyholder.';
        notifyListeners();
      }
    } catch (e) {
      _hasBluetoothPermission = false;
      _permissionStatusMessage = 'Could not check Bluetooth permissions: $e';
      notifyListeners();
    }
  }

  Future<void> requestPermissions() => _checkPermissions();

  // ===========================================================================
  // Scanning
  // ===========================================================================

  void _listenScanResults() {
    if (kIsWeb) return;
    // Subscribed once for the object's lifetime. `scanResults` is a broadcast
    // stream carrying the whole accumulated result set, so re-subscribing per
    // scan (as before) only risked leaking subscriptions.
    _scanSubscription = FlutterBluePlus.scanResults.listen(
      _onScanResults,
      onError: (Object e) {
        if (_scanIsBackground) {
          debugPrint('BleService: background scan stream error: $e');
          return;
        }
        _lastError = 'Scan failed: $e';
        notifyListeners();
      },
    );
  }

  void _onScanResults(List<ScanResult> results) {
    BluetoothDevice? autoConnectTarget;

    for (final r in results) {
      final id = r.device.remoteId.str;
      final advertised = _advertisedName(r);
      final isKeyholder = _looksLikeKeyholder(r, advertised);

      if (isKeyholder) {
        debugPrint('BleService: keyholder discovered — '
            'id=$id, advName=${advertised ?? '(none)'}, '
            'displayName=${displayNameFor(id, advertised: advertised)}');
      }

      _radios[id] = r.device;
      _discovered[id] = BleDevice(
        // A keyholder gets the owner's nickname if there is one; everything else
        // is shown exactly as it advertised itself.
        name: isKeyholder
            ? displayNameFor(id, advertised: advertised)
            : (advertised ?? 'Unnamed device'),
        id: id,
        hasAdvertisedName: advertised != null,
        // Only computed when there is no name — a named device needs no guess.
        hint: advertised != null
            ? null
            : describeUnnamed(
                manufacturerData: r.advertisementData.manufacturerData,
                serviceUuids: r.advertisementData.serviceUuids
                    .map((g) => g.str)
                    .toList(),
              ),
        rssi: r.rssi,
        macAddress: id,
        deviceType: isKeyholder
            ? BleDeviceType.keyholder
            : _guessDeviceType(advertised ?? ''),
        isConnected: _isConnected && id == _connectedDevice?.remoteId.str,
        isPrimary: isKeyholder && id == _knownDeviceId,
        ownership: isKeyholder
            ? _advertisedOwnership(r, id)
            : OwnershipState.unknown,
      );

      // Auto-connect only to the keyholder this phone already knows. Grabbing
      // whichever unit advertises first would be wrong on a campus where more
      // than one of these exists.
      if (isKeyholder &&
          id == _knownDeviceId &&
          !_autoConnectDone &&
          !_isConnected &&
          !_isConnecting) {
        autoConnectTarget = r.device;
      }
    }

    _rebuildScannedDevices();

    // Deliberately outside the loop, behind a once-per-launch guard: this
    // callback fires many times per scan, and the previous code called
    // `connect()` from inside it on every single hit.
    if (autoConnectTarget != null) {
      _autoConnectDone = true;
      unawaited(connectToDevice(autoConnectTarget));
    }
  }

  /// The name the radio actually broadcast, or null if it broadcast none.
  ///
  /// `advertisementData.advName` is checked **first**, and that ordering is the
  /// fix for the empty-looking scan list. `device.platformName` comes from the
  /// Android Bluetooth cache, which is only populated for devices the phone has
  /// bonded with — so for everything else it is an empty string, and preferring
  /// it meant the live name sitting right there in the scan response was never
  /// read. A freshly-flashed keyholder has never been bonded, so its own name was
  /// among the ones being dropped.
  ///
  /// Returning null rather than a manufactured `Unknown device (A4:C1:38…)`
  /// leaves the decision about how to present a nameless radio to the UI, where
  /// it can be styled as a placeholder instead of masquerading as a name.
  String? _advertisedName(ScanResult r) {
    final adv = r.advertisementData.advName.trim();
    if (adv.isNotEmpty) return adv;

    final cached = r.device.platformName.trim();
    if (cached.isNotEmpty) return cached;

    return null;
  }

  /// A keyholder is identified by the service UUID in its advertisement, and
  /// only falls back to the name if that is absent.
  ///
  /// The old code matched `name.contains("BLE-Keyholder")` against every radio
  /// in the room, so anything named similarly would have been treated as the
  /// user's key fob.
  bool _looksLikeKeyholder(ScanResult r, String? name) {
    if (r.advertisementData.serviceUuids.contains(Guid(BleUuids.service))) {
      return true;
    }
    return name != null && BleNames.candidates.contains(name);
  }

  /// What the advertisement alone can tell us about ownership.
  ///
  /// The keyholder advertises its claim state as one byte of service data under
  /// [BleUuids.service] — see [BleAdvState]. It used to be inferred from the
  /// advertised name instead, but the name is now the same in both states
  /// ([BleNames.keyholder]), because a name long enough to distinguish them did
  /// not fit in the advertising packet beside the service UUID.
  ///
  /// A claimed keyholder is reported as [OwnershipState.claimedByOther] unless
  /// it is *our* device: the real answer only arrives from the challenge in
  /// Phase 2, and guessing optimistically here would show a Connect button that
  /// cannot work.
  ///
  /// When the advertisement carries no state byte at all the answer is
  /// [OwnershipState.unknown], which leaves the device pairable. That is not
  /// laxity — it is the honest reading. Firmware predating the state byte (and
  /// the simplified sketch, which has no notion of ownership) says nothing about
  /// ownership, and treating silence as "claimed by somebody else" would lock
  /// the user out of their own hardware with a Locked badge that nothing can
  /// clear. The firmware still refuses an unauthorised session; this only
  /// decides whether the app is willing to try.
  OwnershipState _advertisedOwnership(ScanResult r, String id) {
    final state = r.advertisementData.serviceData[Guid(BleUuids.service)];
    if (state != null && state.isNotEmpty) {
      if (state.first == BleAdvState.unclaimed) return OwnershipState.unclaimed;
      return id == _knownDeviceId
          ? OwnershipState.claimedByMe
          : OwnershipState.claimedByOther;
    }

    // Legacy firmware: the name was the signal.
    if (_advertisedName(r) == BleNames.legacyUnclaimed) {
      return OwnershipState.unclaimed;
    }
    if (id == _knownDeviceId) return OwnershipState.claimedByMe;
    return OwnershipState.unknown;
  }

  BleDeviceType _guessDeviceType(String name) {
    final lower = name.toLowerCase();
    const headphoneHints = [
      'headphone', 'headset', 'earbud', 'buds', 'airpod', 'wh-', 'wf-',
      'bose', 'sony', 'jbl', 'beats', 'shokz', 'soundcore', 'audio', 'tune',
    ];
    if (headphoneHints.any(lower.contains)) return BleDeviceType.headphones;
    if (lower.contains('watch') ||
        lower.contains('band') ||
        lower.contains('fit')) {
      return BleDeviceType.watch;
    }
    return BleDeviceType.bluetooth;
  }

  void _rebuildScannedDevices() {
    final list = _discovered.values.toList()
      // Keyholders first, then by signal strength — the thing you are looking
      // for should never be buried under a neighbour's television.
      ..sort((a, b) {
        if (a.isKeyholder != b.isKeyholder) return a.isKeyholder ? -1 : 1;
        return b.rssi.compareTo(a.rssi);
      });

    // Only notify when the list the user can see actually changed.
    //
    // `continuousUpdates` means this runs several times a second for the whole
    // length of a scan, and most of those passes differ only by a dBm or two on
    // a device nobody is looking at. Rebuilding the scan list for that is work
    // with no visible result, and it was happening while the radar animation was
    // trying to hold 60fps.
    //
    // Small RSSI movement is deliberately ignored: the bars and the distance
    // estimate are already smoothed, so a 1 dBm flicker cannot change what is
    // drawn.
    //
    // When nothing material changed the *displayed* list is deliberately left
    // in place rather than quietly replaced. Comparing each sample against what
    // is on screen makes this a deadband: a slow one-dBm-at-a-time drift
    // accumulates against the displayed value and does eventually cross the
    // threshold. Adopting the new list each time would reset the comparison on
    // every sample, and a device sliding steadily out of range would never
    // trigger a repaint at all. `_discovered` holds the fresh data either way,
    // so nothing is lost.
    if (!scanListChanged(_scannedDevices, list)) return;

    _scannedDevices = list;
    notifyListeners();
  }

  /// Starts a general scan.
  ///
  /// [background] marks a start the owner did not ask for — the automatic
  /// re-arm in [_armRescan]. Those failures are logged, not shown. The hunt loop
  /// retries every [_rescanGap] on its own, so surfacing a transient failure
  /// from one of its attempts put a red banner on screen describing something
  /// the app was already in the middle of fixing, and left it there. A scan the
  /// owner started by tapping still reports honestly.
  Future<void> startActiveHardwareScan({bool background = false}) async {
    if (!background) _lastError = '';
    _scanIsBackground = background;

    if (kIsWeb) {
      _permissionStatusMessage =
          'Bluetooth scanning is not available in a browser.';
      notifyListeners();
      return;
    }
    if (!_hasBluetoothPermission) {
      await _checkPermissions();
      return;
    }
    if (!isBluetoothOn) {
      _lastError = 'Turn Bluetooth on to scan for your keyholder.';
      notifyListeners();
      return;
    }
    if (FlutterBluePlus.isScanningNow) return;

    // Stale entries are dropped rather than left on screen implying the device
    // is still nearby.
    _discovered.removeWhere((id, _) => id != _connectedDevice?.remoteId.str);
    _rebuildScannedDevices();

    try {
      await FlutterBluePlus.startScan(
        timeout: _scanTimeout,
        // The manifest declares BLUETOOTH_SCAN with `neverForLocation`; asking
        // flutter_blue_plus to assert fine location here would contradict it.
        androidUsesFineLocation: false,
        // Refresh RSSI for devices already in the list, and prune ones that
        // stopped advertising, so the card list reflects the room right now.
        continuousUpdates: true,
        continuousDivisor: 2,
        removeIfGone: const Duration(seconds: 10),
      );
    } catch (e) {
      if (background) {
        // The hunt loop will try again in [_rescanGap]. Saying so in red would
        // describe a problem the app is already recovering from.
        debugPrint('BleService: background rescan failed to start: $e');
        return;
      }
      _lastError = 'Could not start scanning: $e';
      notifyListeners();
    }
  }

  /// A narrow scan that only surfaces Find Me hardware, for the pairing flow.
  ///
  /// The general scan above is intentionally unfiltered so the Scan tab can list
  /// everything in the room; only one BLE scan can run at a time, so the two
  /// cannot be combined.
  Future<void> startKeyholderOnlyScan() async {
    if (kIsWeb || !_hasBluetoothPermission || !isBluetoothOn) return;
    try {
      if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();
      await FlutterBluePlus.startScan(
        timeout: _scanTimeout,
        withServices: [Guid(BleUuids.service)],
        androidUsesFineLocation: false,
      );
    } catch (e) {
      _lastError = 'Could not start scanning: $e';
      notifyListeners();
    }
  }

  Future<void> stopActiveHardwareScan() async {
    if (kIsWeb) return;
    try {
      if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();
    } catch (e) {
      debugPrint('BleService: stopScan error: $e');
    }
    _isScanning = false;
    notifyListeners();
  }

  Future<void> toggleScanning() {
    if (_isScanning) {
      // Stopping by hand means "leave it alone", which is the opposite of the
      // automatic hunt. `stopActiveHardwareScan` is shared with the connect
      // flow, where stopping is only a pause, so the hunt is ended *here*.
      endContinuousScan();
      return stopActiveHardwareScan();
    }
    // Choosing to scan is also choosing to keep looking until it connects — and
    // it clears any automatic give-up, because pressing scan is the owner saying
    // "try again" after the run of failures that stopped the hunt.
    _autoConnectFailures = 0;
    _autoConnectDone = false;
    // Started *before* `beginContinuousScan`, which also starts one. If the
    // hunt loop got there first this call would hit the "already scanning"
    // guard and return without clearing [lastError] — leaving the owner tapping
    // Scan at a red banner that never goes away.
    final started = startActiveHardwareScan();
    beginContinuousScan();
    return started;
  }

  // ===========================================================================
  // Connection
  // ===========================================================================

  Future<void> connectToDevice(BluetoothDevice device) async {
    if (_isConnecting) return;
    if (_connectedDevice?.remoteId == device.remoteId && _isConnected) return;

    _isConnecting = true;
    _lastError = '';
    notifyListeners();

    // Read in `finally`, where the retry decision is made. A local rather than a
    // field because it describes this one attempt, not the service.
    bool connectFailed = false;

    try {
      await stopActiveHardwareScan();

      // Attached before connecting so a link that drops during service
      // discovery is still reported. The old code never watched this stream at
      // all, so the UI stayed on "Connected" until the app was restarted.
      _watchConnectionState(device);

      await device.connect(
        timeout: _connectTimeout,
        mtu: BleAuthParams.desiredMtu,
      );

      _connectedDevice = device;
      _negotiatedMtu = device.mtuNow;
      _watchBondState(device);

      // `CLAIM_OK:` plus a 64-character hex key is 73 bytes. At the default
      // 23-byte ATT MTU only 20 bytes of payload survive, so the owner key would
      // arrive silently truncated and look like a crypto bug.
      if (_negotiatedMtu < BleAuthParams.minimumUsableMtu) {
        try {
          await device.requestMtu(BleAuthParams.desiredMtu);
          _negotiatedMtu = device.mtuNow;
        } catch (e) {
          debugPrint('BleService: MTU request failed: $e');
        }
      }

      await _discoverCharacteristics(device);

      _isConnected = true;
      _deviceId = device.remoteId.str;
      if (device.platformName.isNotEmpty) _deviceName = device.platformName;

      // Found it — stop re-arming the scan and give the radio back.
      endContinuousScan();
      _proximityWarned = false;
      _outOfRangeWarned = false;
      _maxAllowanceWarned = false;

      _knownDeviceId = _deviceId;
      await _settings?.setLastDevice(_deviceId, _deviceName);

      _rssiWindow.clear();
      _startRssiPolling(device);

      // Connected, so the run of failures is over.
      _autoConnectFailures = 0;
      // ...and so is anything the failures put on screen. `_lastError` is
      // cleared at the top of this method too, but a give-up message written by
      // an *earlier* attempt's `finally` block survives that, because it is set
      // after the clear. Without this line the owner sat looking at "could not
      // connect after 3 tries" while the dial read Connected.
      _lastError = '';

      _logEvent(EventType.connected);

      // Posted after the event is logged so the shade and History agree. This is
      // the moment the owner's keys became findable again, and they are very
      // often not looking at the app when it happens — an auto-reconnect fires
      // while the phone is in a pocket.
      unawaited(
        _notifications?.showLinkState(
              deviceName: displayName,
              connected: true,
            ) ??
            Future.value(),
      );
      unawaited(_notifications?.cancelOutOfRange() ?? Future.value());

      // The ongoing background notice is a status line, so it changes with the
      // status. Left alone it would still read "looking for your keyholder"
      // while the keyholder was sitting connected.
      _refreshBackgroundNotification();

      // Ask for a position immediately so the map has something real to show
      // instead of a placeholder.
      await requestLocation();
    } catch (e) {
      _lastError = 'Could not connect: $e';
      await _teardownSession();
      _isConnected = false;
      connectFailed = true;
    } finally {
      _isConnecting = false;
      notifyListeners();

      // A failed connect used to be a dead end for auto-connect. `_autoConnectDone`
      // stayed set, so the keyholder was never tried again; and the scan had been
      // stopped up at the top of this method while `_isConnecting` was still true,
      // which is exactly the condition that suppresses the automatic re-arm in
      // [_listenScanningFlag]. The result was an app that silently stopped looking
      // and needed the owner to press scan — the one thing auto-connect exists to
      // avoid.
      //
      // Re-armed here, in `finally`, because `beginContinuousScan` checks
      // `_isConnecting` and would do nothing if called before the line above.
      if (connectFailed && !kIsWeb) {
        _autoConnectFailures++;
        if (_autoConnectFailures < _maxAutoConnectAttempts) {
          _autoConnectDone = false;
          beginContinuousScan();
        } else {
          // Out of automatic attempts. Say so, rather than leaving the owner
          // looking at a screen that claims nothing is wrong — and name the
          // usual cause, because "found it but could not connect" almost always
          // means the keyholder is still holding a session open with another
          // phone, or was carried out of range between the scan hit and the
          // connect. Neither is obvious from a bare failure count.
          _lastError =
              'Found your keyholder but could not connect after $_autoConnectFailures '
              'tries. It may still be connected to another phone, or have moved '
              'out of range. Tap the dial to try again.';
          notifyListeners();
        }
      }
    }
  }

  // ===========================================================================
  // Link-layer bonding (the OLED passkey)
  // ===========================================================================

  /// Whether this platform lets the app drive BLE bonding at all.
  ///
  /// Android exposes `createBond()`; iOS does not — CoreBluetooth bonds
  /// implicitly the first time an encrypted characteristic is accessed, and no
  /// public API can start or observe it. So the passkey step is presented as
  /// guidance on iOS rather than a button that would do nothing.
  bool get supportsBonding => !kIsWeb && Platform.isAndroid;

  /// Current bond state of the connected device, or null when unknown.
  BluetoothBondState? get bondState => _bondState;

  bool get isBonded => _bondState == BluetoothBondState.bonded;

  /// Starts OS-level pairing so the 6-digit code on the keyholder's OLED can be
  /// entered.
  ///
  /// **The passkey is typed into the system dialog, not into this app.** No
  /// mobile platform lets an application supply a BLE passkey programmatically —
  /// Android's Settings process owns that prompt, which is precisely what makes
  /// it trustworthy: a malicious app cannot answer the challenge on the user's
  /// behalf. All this method can do is trigger the prompt and report the result
  /// honestly.
  ///
  /// Bonding gives the link encryption with MITM protection. It is a different
  /// guarantee from the ownership lock: bonding protects the *traffic*, the
  /// challenge-response protects *who may command the device*. Both are needed —
  /// encryption without owner binding lets any bonded phone take over, and owner
  /// binding without encryption lets a sniffer read the GPS history in the clear.
  Future<bool> startBonding() async {
    final device = _connectedDevice;
    if (device == null) {
      _lastError = 'Connect to the keyholder before pairing.';
      notifyListeners();
      return false;
    }
    if (!supportsBonding) {
      _lastError = '';
      notifyListeners();
      return false;
    }

    try {
      // `bondState` is a stream, not a snapshot; its first value is the current
      // state. Reading it avoids showing a pairing prompt to someone who paired
      // this keyholder weeks ago.
      final current = await device.bondState.first;
      if (current == BluetoothBondState.bonded) {
        _bondState = BluetoothBondState.bonded;
        notifyListeners();
        return true;
      }

      // Shows the system "Pair with Find Me? Enter PIN" dialog. The code it
      // asks for is the one the firmware is rendering on the OLED.
      //
      // `createBond` waits for the outcome itself and throws if the bond does
      // not complete, so reaching the next line means it succeeded.
      await device.createBond();
      _bondState = BluetoothBondState.bonded;
      notifyListeners();
      return true;
    } catch (e) {
      _lastError = 'Pairing was not completed: $e';
      notifyListeners();
      return false;
    }
  }

  /// Removes the OS bond, so the next connection asks for the passkey again.
  ///
  /// Needed alongside releasing ownership: the firmware clears its side with
  /// `esp_ble_remove_bond_device()`, and if the phone kept a stale bond the two
  /// would disagree and every reconnect would fail with an encryption error
  /// rather than an honest "not paired".
  Future<void> removeBond(BluetoothDevice device) async {
    if (!supportsBonding) return;
    try {
      await device.removeBond();
      _bondState = BluetoothBondState.none;
      notifyListeners();
    } catch (e) {
      debugPrint('BleService: removeBond failed: $e');
    }
  }

  void _watchBondState(BluetoothDevice device) {
    if (!supportsBonding) return;
    _bondSubscription?.cancel();
    _bondSubscription = device.bondState.listen(
      (state) {
        _bondState = state;
        notifyListeners();
      },
      onError: (Object e) => debugPrint('BleService: bond state: $e'),
    );
  }

  // ===========================================================================

  Future<void> _discoverCharacteristics(BluetoothDevice device) async {
    final services = await device.discoverServices();

    BluetoothService? target;
    for (final s in services) {
      if (s.uuid == Guid(BleUuids.service)) {
        target = s;
        break;
      }
    }
    if (target == null) {
      throw StateError(
        'This device does not expose the Find Me service '
        '(${BleUuids.service}). It is not a keyholder.',
      );
    }

    // Looked up by UUID. The previous implementation walked every service and
    // kept the *last* writable characteristic it saw, which on most stacks is
    // something in Generic Attribute rather than the data channel.
    _dataChar = _findChar(target, BleUuids.dataChar);
    _authChar = _findChar(target, BleUuids.authChar);
    _provChar = _findChar(target, BleUuids.provChar);

    if (_dataChar == null) {
      throw StateError('Find Me service is missing its data characteristic.');
    }

    _dataSubscription =
        await _subscribe(device, _dataChar!, _handleDataFrame);
    if (_authChar != null) {
      _authSubscription = await _subscribe(device, _authChar!, _handleAuthFrame);
    }
  }

  BluetoothCharacteristic? _findChar(BluetoothService service, String uuid) {
    final want = Guid(uuid);
    for (final c in service.characteristics) {
      if (c.uuid == want) return c;
    }
    return null;
  }

  Future<StreamSubscription<List<int>>?> _subscribe(
    BluetoothDevice device,
    BluetoothCharacteristic c,
    void Function(String frame) onFrame,
  ) async {
    // Gated on `notify` alone. The old condition was `notify || read`, so
    // `setNotifyValue(true)` was called on read-only characteristics, where it
    // throws — aborting the whole discovery loop partway through.
    if (!c.properties.notify && !c.properties.indicate) return null;

    final sub = c.lastValueStream.listen((value) {
      if (value.isEmpty) return;
      onFrame(utf8.decode(value, allowMalformed: true).trim());
    });
    // Cleaned up by the plugin when the link drops, so a stale subscription
    // cannot outlive its device.
    device.cancelWhenDisconnected(sub);

    await c.setNotifyValue(true);
    return sub;
  }

  void _watchConnectionState(BluetoothDevice device) {
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = device.connectionState.listen((state) async {
      if (state == BluetoothConnectionState.disconnected) {
        if (_isConnected || _isConnecting) {
          await _handleDisconnected(logEvent: _isConnected);
        }
      }
    }, onError: (Object e) => debugPrint('connectionState error: $e'));
  }

  /// [resumeHunting] is false only when the owner pressed Disconnect themselves.
  /// Re-arming the scan then would reconnect within seconds and make the button
  /// look broken; every *involuntary* drop resumes the hunt.
  Future<void> _handleDisconnected({
    required bool logEvent,
    bool resumeHunting = true,
  }) async {
    final wasConnected = _isConnected;
    _isConnected = false;
    _ownershipState = OwnershipState.unknown;
    _currentRssi = null;
    _estimatedDistance = null;
    _lastRssiUpdate = null;
    _rssiWindow.clear();
    _isPinging = false;
    _isAlertActive = false;
    _alertTimer?.cancel();
    _rssiTimer?.cancel();
    _negotiatedMtu = 0;

    // A dropped link is not a reason to keep screaming. The keyholder's own
    // buzzer times out by itself; the phone's ring has to be stopped here,
    // because the STOP command that normally does it can no longer be delivered.
    await _ringer?.stop();

    if (logEvent && wasConnected) {
      // The handout's "save GPS on disconnect" behaviour: the last known
      // position is what makes a lost item findable, so record it here.
      _logEvent(EventType.disconnected,
          includeLocation: _saveGpsOnDisconnect);
    }

    // Told to the owner, not just written to the log. A disconnect while the app
    // is in the background is the single event they most need to hear about: it
    // is what "I left my keys behind" looks like from the phone's side.
    //
    // Posted on every involuntary drop, including one the owner caused by
    // pressing Disconnect — `logEvent` is false only in paths that are not a
    // real session ending, and suppressing the notice for a deliberate
    // disconnect would mean the button silently does two different things.
    if (wasConnected) {
      unawaited(
        _notifications?.showLinkState(
              deviceName: displayName,
              connected: false,
            ) ??
            Future.value(),
      );
    }

    _refreshBackgroundNotification();

    _discovered.updateAll((_, d) => d.copyWith(isConnected: false));
    _rebuildScannedDevices();

    // The proximity warnings are armed again for the next departure. Any banner
    // still in the shade is pulled: it quotes a distance, and with the link gone
    // that number is a guess about where the keys were, not where they are.
    _proximityWarned = false;
    _outOfRangeWarned = false;
    _maxAllowanceWarned = false;
    unawaited(_notifications?.cancelProximityWarning() ?? Future.value());
    unawaited(_notifications?.cancelOutOfRange() ?? Future.value());
    unawaited(_notifications?.cancelMaxAllowanceExceeded() ?? Future.value());

    // Start hunting immediately. A disconnect while the app is open almost
    // always means the owner has walked out of range of their keys, so this is
    // the single most important moment to be looking — and _autoConnectDone is
    // cleared so the reconnect can actually fire when the keyholder reappears.
    if (wasConnected && !kIsWeb && resumeHunting) {
      _autoConnectDone = false;
      beginContinuousScan();
    }

    notifyListeners();
  }

  Future<void> _teardownSession() async {
    await _dataSubscription?.cancel();
    await _authSubscription?.cancel();
    await _bondSubscription?.cancel();
    _dataSubscription = null;
    _authSubscription = null;
    _bondSubscription = null;
    _bondState = null;
    _dataChar = null;
    _authChar = null;
    _provChar = null;
    _rssiTimer?.cancel();
    _rssiTimer = null;
  }

  // ===========================================================================
  // Signal strength
  // ===========================================================================

  void _startRssiPolling(BluetoothDevice device) {
    _rssiTimer?.cancel();
    _rssiTimer = Timer.periodic(_rssiPollInterval, (_) async {
      if (!_isConnected) return;
      try {
        // Real dBm from the radio. This replaces `_startRssiSimulation()`,
        // which drove the whole signal display from `Random()`.
        final rssi = await device.readRssi();
        _rssiWindow.add(rssi);

        final smoothed = _rssiWindow.median;
        if (smoothed != null) {
          _currentRssi = smoothed;
          _estimatedDistance = _proximity.distanceFor(smoothed);
          _lastRssiUpdate = DateTime.now();
          _evaluateProximityWarning();
        }
        notifyListeners();
      } catch (e) {
        debugPrint('BleService: readRssi failed: $e');
      }
    });
  }

  /// Warn once when the keyholder crosses **half** the alert distance, and again
  /// when it crosses the distance itself.
  ///
  /// Half, not only the threshold, because a warning that arrives at the moment
  /// you are already out of range arrives too late to be useful. The point is to
  /// catch the owner while turning away from the desk, not to announce a loss
  /// after the fact — so the halfway notice is silent advice and the threshold
  /// notice, which is the one they actually configured, is allowed to make a
  /// sound.
  ///
  /// Each fires once per departure. Without the latches this would notify on
  /// every two-second RSSI sample for as long as the owner stood near a
  /// boundary — and RSSI is noisy enough that they would not even have to move.
  ///
  /// A third boundary, the owner's maximum allowance, is handled at the end by
  /// [_evaluateMaxAllowance]. It sits behind the same enable flag as the other
  /// two: it is an escalation of this warning, not a separate feature.
  void _evaluateProximityWarning() {
    if (!_proximityWarningEnabled) return;
    final d = _estimatedDistance;
    if (d == null) return;

    final halfway = _alertDistanceThreshold / 2;

    // Re-arm once safely back inside, with a 25% margin so that noise around the
    // boundary cannot rattle the latch on and off.
    if (_proximityWarned) {
      if (d < halfway * 0.75) _proximityWarned = false;
    } else if (d >= halfway) {
      _proximityWarned = true;
      unawaited(
        _notifications?.showProximityWarning(
              deviceName: displayName,
              distanceMetres: d,
              thresholdMetres: _alertDistanceThreshold,
            ) ??
            Future.value(),
      );
    }

    // The threshold itself, latched independently. Same 25% margin, applied to
    // the full distance: walking back to the desk clears the notice and re-arms
    // it for the next time the owner leaves.
    if (_outOfRangeWarned) {
      if (d < _alertDistanceThreshold * 0.75) {
        _outOfRangeWarned = false;
        unawaited(_notifications?.cancelOutOfRange() ?? Future.value());
      }
    } else if (d >= _alertDistanceThreshold) {
      _outOfRangeWarned = true;
      unawaited(
        _notifications?.showOutOfRange(
              deviceName: displayName,
              distanceMetres: d,
              thresholdMetres: _alertDistanceThreshold,
            ) ??
            Future.value(),
      );
    }

    // The maximum allowance, the last of the three. Evaluated after the
    // out-of-range check rather than instead of it — this used to `return` once
    // the threshold latch was handled, which would have made the allowance
    // unreachable — so a keyholder that goes straight past both boundaries in
    // one sample produces both notices, in the right order.
    _evaluateMaxAllowance(d);
  }

  /// The outermost boundary: the keyholder is further away than the owner said
  /// it should ever be.
  ///
  /// Does one thing the inner boundaries do not — it records the crossing in
  /// History, with the phone's position. This is the moment that answers "where
  /// was it when I lost it", and unlike a disconnect it happens while the link
  /// is still up, so the distance on that row is measured rather than inferred
  /// from the last reading before the link died.
  void _evaluateMaxAllowance(double d) {
    if (!maxAllowanceActive) return;
    final limit = maxAllowanceDistance;

    if (_maxAllowanceWarned) {
      if (d < limit * 0.75) {
        _maxAllowanceWarned = false;
        unawaited(
          _notifications?.cancelMaxAllowanceExceeded() ?? Future.value(),
        );
      }
      return;
    }
    if (d < limit) return;

    _maxAllowanceWarned = true;
    unawaited(
      _notifications?.showMaxAllowanceExceeded(
            deviceName: displayName,
            distanceMetres: d,
            allowanceMetres: limit,
          ) ??
          Future.value(),
    );
    // Logged as a security event so it lands in both History and the Security
    // tab. `_logEvent` stamps it with the phone's position and then refines it,
    // which is the whole point of recording it here rather than waiting for the
    // disconnect that may follow minutes later and streets away.
    _logEvent(EventType.maxAllowanceExceeded);
  }

  bool get proximityWarningEnabled => _proximityWarningEnabled;

  Future<void> setProximityWarningEnabled(bool value) async {
    _proximityWarningEnabled = value;
    if (!value) {
      _proximityWarned = false;
      _outOfRangeWarned = false;
      _maxAllowanceWarned = false;
      unawaited(_notifications?.cancelProximityWarning() ?? Future.value());
      unawaited(_notifications?.cancelOutOfRange() ?? Future.value());
      unawaited(_notifications?.cancelMaxAllowanceExceeded() ?? Future.value());
    }
    await _settings?.setProximityWarningEnabled(value);
    // The warning is a system notification. Android 13+ asks before an app may
    // post one, so turning the toggle on is the right moment to ask: the owner
    // has just asked for this feature, and a denial is a real answer rather
    // than something the app should silently paper over.
    if (value && !kIsWeb) await _notifications?.requestPermission();
    notifyListeners();
  }

  bool get backgroundRunningEnabled => _backgroundRunningEnabled;

  /// True on a platform where [backgroundRunningEnabled] can do anything.
  ///
  /// Android only. Exposed so the Settings screen can hide the switch rather
  /// than offer one that silently does nothing.
  bool get backgroundRunningSupported => BackgroundService.isSupported;

  /// Turns background monitoring on or off.
  ///
  /// Switching it on asks for notification permission first, and treats a
  /// refusal as a refusal: Android 13+ will technically start a foreground
  /// service without it, but the service then runs with no visible
  /// notification, which the system treats as a candidate for removal. Claiming
  /// the feature is on in that state would be a lie the owner only discovers
  /// when their keys are already gone.
  Future<void> setBackgroundRunningEnabled(bool value) async {
    if (!BackgroundService.isSupported) return;

    if (value) {
      BackgroundService.configure();
      if (!await BackgroundService.hasNotificationPermission) {
        await _settings?.setBackgroundPermissionAsked(true);
        final granted = await BackgroundService.requestNotificationPermission();
        if (!granted) {
          _backgroundRunningEnabled = false;
          _lastError =
              'Find X needs permission to show a notification before it can '
              'keep watching in the background.';
          notifyListeners();
          return;
        }
      }
      final started = await BackgroundService.start(
        connected: _isConnected,
        deviceName: displayName,
      );
      _backgroundRunningEnabled = started;
      if (!started) {
        _lastError = 'This phone would not let Find X run in the background.';
      }
    } else {
      await BackgroundService.stop();
      _backgroundRunningEnabled = false;
    }

    await _settings?.setBackgroundRunningEnabled(_backgroundRunningEnabled);
    notifyListeners();
  }

  /// Starts the background service if the owner has it switched on.
  ///
  /// Called once the settings have loaded, because on a cold start the stored
  /// preference is not known until then.
  Future<void> _syncBackgroundService() async {
    if (!BackgroundService.isSupported) return;

    // Registered whether or not the feature is on, because the service can
    // outlive the app that started it: `stopWithTask` is false, so a swipe out
    // of Recents leaves it running, and the owner may well press Stop on a
    // relaunched app whose `_backgroundRunningEnabled` was loaded before this.
    BackgroundService.listenForStopRequest(_onBackgroundStopRequested);

    if (!_backgroundRunningEnabled) return;
    BackgroundService.configure();

    if (!await BackgroundService.hasNotificationPermission) {
      // Asked exactly once, on the first launch that finds the feature on.
      //
      // It has to be asked *somewhere*: the feature is on by default, Android
      // 13+ will run a foreground service with no visible notification but
      // treats one as a candidate for removal, and a switch that reads "on"
      // while nothing is watching is the failure this whole feature exists to
      // prevent. Asking again on later launches would be nagging for something
      // already declined — the Settings switch is where they can change their
      // mind.
      if (_settings?.backgroundPermissionAsked ?? true) return;
      await _settings?.setBackgroundPermissionAsked(true);
      if (!await BackgroundService.requestNotificationPermission()) return;
    }

    await BackgroundService.start(
      connected: _isConnected,
      deviceName: displayName,
    );
  }

  /// The owner pressed Stop on the ongoing notification.
  ///
  /// The service isolate has already stopped the service; what is left is to
  /// make that stick. Without persisting it here the app would start monitoring
  /// again on next launch, and "stop" would have meant "until you next open the
  /// app" — not what the button says.
  void _onBackgroundStopRequested() {
    if (!_backgroundRunningEnabled) return;
    _backgroundRunningEnabled = false;
    unawaited(_settings?.setBackgroundRunningEnabled(false) ?? Future.value());
    notifyListeners();
  }

  /// Keeps the ongoing notification's text honest as the link comes and goes.
  void _refreshBackgroundNotification() {
    if (!_backgroundRunningEnabled) return;
    unawaited(BackgroundService.updateLinkState(
      connected: _isConnected,
      deviceName: displayName,
    ));
  }

  // ===========================================================================
  // Incoming frames
  // ===========================================================================

  void _handleDataFrame(String data) {
    debugPrint('Find Me → app: $data');

    if (data == BleResponses.ready) {
      _lastError = '';
      notifyListeners();
      return;
    }

    if (data == BleResponses.notAuthed) {
      _ownershipState = OwnershipState.authFailed;
      _lastError =
          'The keyholder rejected that command — this phone is not its owner.';
      notifyListeners();
      return;
    }

    if (data.startsWith(BleResponses.locPrefix)) {
      _applyLocation(data.substring(BleResponses.locPrefix.length));
      notifyListeners();
      return;
    }

    if (data.startsWith(BleResponses.batPrefix)) {
      final val =
          int.tryParse(data.substring(BleResponses.batPrefix.length).trim());
      if (val != null) {
        _batteryLevel = val.clamp(0, 100);
        notifyListeners();
      }
      return;
    }

    // The device reporting which cadence it is actually set to. Treated as
    // authoritative over the local preference: the keyholder keeps the pattern in
    // NVS, so after a reinstall — or on a second phone that has been given
    // ownership — the app's stored value is a guess and this is the fact.
    if (data.startsWith(BleResponses.alertPrefix)) {
      final token = data.substring(BleResponses.alertPrefix.length).trim();
      final reported = AlertPattern.fromWireName(token);
      if (reported != _alertPattern) {
        _alertPattern = reported;
        unawaited(_settings?.setAlertPattern(reported) ?? Future.value());
        notifyListeners();
      }
      return;
    }

    if (data.startsWith(BleResponses.findPhonePrefix)) {
      _applyLocation(data.substring(BleResponses.findPhonePrefix.length));
      _isPinging = true;
      _isAlertActive = true;
      _armAlertTimeout();
      _logEvent(EventType.keyPingedPhone);
      // The point of the whole frame. Everything above this line was already
      // here — the location was parsed, the event was logged, the Home screen
      // pulsed — and the phone still made no sound, which meant the button on the
      // keyholder did nothing a user in another room could detect.
      unawaited(_ringer?.start() ?? Future<void>.value());
      return;
    }
  }

  /// Republished for `pairing_service.dart`; the handshake itself is not this
  /// class's job, but the connection state it produces is.
  void _handleAuthFrame(String data) {
    debugPrint('Find Me auth → app: $data');

    if (data == BleResponses.statusUnclaimed) {
      _ownershipState = OwnershipState.unclaimed;
    } else if (data.startsWith(BleResponses.authReqPrefix)) {
      _ownershipState = OwnershipState.authenticating;
    } else if (data == BleResponses.authOk) {
      _ownershipState = OwnershipState.authenticated;
      _lastError = '';
      // First moment the device will accept a command. The cadence is pushed
      // here rather than at connect time because on a claimed device every
      // command before AUTH_OK is refused outright.
      unawaited(pushAlertPattern());
    } else if (data == BleResponses.authFail) {
      _ownershipState = OwnershipState.authFailed;
      _lastError = 'The keyholder refused this phone.';
    } else if (data.startsWith(BleResponses.lockedPrefix)) {
      _ownershipState = OwnershipState.lockedOut;
      final secs = data.substring(BleResponses.lockedPrefix.length).trim();
      _lastError = 'Too many failed attempts. Locked for $secs s.';
    } else if (data.startsWith(BleResponses.wifiOkPrefix)) {
      // WIFI_OK:<ip>. The IP is what the owner actually needs — it is the only
      // thing that confirms the device reached the network rather than merely
      // accepting the credentials.
      if (_awaitWifiResult) {
        _wifiSetupResult =
            'Joined ${data.substring(BleResponses.wifiOkPrefix.length).trim()}';
      }
      // A successful provisioning is a security-relevant decision (who may give
      // the device a network is who may steer where it reports), so it leaves a
      // trail in History.
      logSecurityEvent(EventType.wifiProvisioned);
    } else if (data.startsWith(BleResponses.wifiFailPrefix)) {
      if (_awaitWifiResult) {
        final reason = data.substring(BleResponses.wifiFailPrefix.length);
        _wifiSetupResult = _describeWifiFailure(reason);
      }
    }

    if (!_authFrames.isClosed) _authFrames.add(data);
    notifyListeners();
  }

  void _applyLocation(String payload) {
    final parts = payload.split(',');
    if (parts.length < 2) return;
    final lat = parts[0].trim();
    final lng = parts[1].trim();

    // A NEO-6M with no satellites reports 0,0. Accepting it would pin the
    // keyholder into the Atlantic and claim a fix that does not exist.
    if (!isPlausibleFix(lat, lng)) {
      _hasGpsFix = false;
      return;
    }

    // A cached place name belongs to the *previous* position. Keeping it after
    // the keyholder moves would relabel the new coordinates with the old
    // neighbourhood, which is the mistake the old hardcoded
    // `"Mission District, CA"` made permanent. Phase 4 refills it from a real
    // reverse-geocode.
    if (lat != _lastLat || lng != _lastLng) _locationName = '';

    _lastLat = lat;
    _lastLng = lng;
    _hasGpsFix = true;
  }

  void _armAlertTimeout() {
    _alertTimer?.cancel();
    _alertTimer = Timer(_alertAutoClear, () {
      if (!_isAlertActive && !_isPinging) return;
      _isAlertActive = false;
      _isPinging = false;
      // Whichever direction the alert was going in, it is over. A ring that
      // outlives the state flag driving the Stop button would be unstoppable
      // from the UI.
      unawaited(_ringer?.stop() ?? Future<void>.value());
      notifyListeners();
    });
  }

  // ===========================================================================
  // Outgoing commands
  // ===========================================================================

  Future<bool> _write(String command) async {
    final c = _dataChar;
    if (c == null || !_isConnected) {
      _lastError = 'Not connected to a keyholder.';
      notifyListeners();
      return false;
    }
    try {
      await c.write(
        utf8.encode(command),
        withoutResponse: !c.properties.write &&
            c.properties.writeWithoutResponse,
      );
      return true;
    } catch (e) {
      _lastError = 'Could not send "$command": $e';
      notifyListeners();
      return false;
    }
  }

  /// Writes to the auth characteristic on behalf of `PairingService`.
  ///
  /// Kept here rather than letting the pairing service touch the characteristic
  /// directly, so that all GATT traffic goes through one place with one error
  /// path. The crypto stays in `PairingService`; the radio stays in this class.
  Future<bool> writeAuthFrame(String frame) async {
    final c = _authChar;
    if (c == null || !_isConnected) {
      _lastError = 'Not connected to a keyholder.';
      notifyListeners();
      return false;
    }
    try {
      await c.write(
        utf8.encode(frame),
        withoutResponse:
            !c.properties.write && c.properties.writeWithoutResponse,
      );
      return true;
    } catch (e) {
      // Never log `frame` itself: on the claim path it is followed by the owner
      // key, and secrets must not reach the debug console.
      _lastError = 'Could not send the ownership handshake: $e';
      notifyListeners();
      return false;
    }
  }

  /// Lets `PairingService` publish the ownership state it has determined.
  ///
  /// The service owns this field because the whole UI reads it, but only the
  /// pairing handshake actually knows the answer.
  void setOwnershipState(OwnershipState state) {
    if (_ownershipState == state) return;
    _ownershipState = state;
    _markKnownDeviceOwnership(state);
    notifyListeners();
  }

  /// Reflects the live ownership state onto the connected device's scan entry,
  /// so the card in the Scan tab and the badge on Home never disagree.
  void _markKnownDeviceOwnership(OwnershipState state) {
    final id = _connectedDevice?.remoteId.str;
    if (id == null) return;
    final entry = _discovered[id];
    if (entry == null || !entry.isKeyholder) return;
    _discovered[id] = entry.copyWith(ownership: state);
    _rebuildScannedDevices();
  }

  /// Rings the keyholder's buzzer.
  ///
  /// The state flips *before* the write, not after. A GATT write is a round trip
  /// over the radio and can take a noticeable fraction of a second — longer on a
  /// congested 2.4 GHz band — and while it was awaited the button had no way to
  /// show it had been pressed: `isPinging` was still false, so the ring animation
  /// had nothing to run on and the Stop Alert button, which only exists while
  /// `isAlertActive`, had not appeared yet. The press looked ignored, and the
  /// owner pressed again.
  ///
  /// If the write fails the state is rolled back, so an optimistic flip cannot
  /// leave the UI claiming a buzzer is sounding on a device that never got the
  /// command. `_write` has already set `_lastError` in that case.
  Future<void> pingKey() async {
    if (!_isConnected) {
      _lastError = 'Connect to your keyholder before pinging it.';
      notifyListeners();
      return;
    }

    // Already ringing: the owner pressing Ping again means "I still cannot find
    // it", not "start a second alert". Re-arm the timeout so the buzzer is not
    // cut short by a countdown that started with the first press.
    if (_isAlertActive) {
      _armAlertTimeout();
      unawaited(_write(BleCommands.findKey));
      return;
    }

    _isPinging = true;
    _isAlertActive = true;
    _armAlertTimeout();
    notifyListeners();

    final ok = await _write(BleCommands.findKey);
    if (!ok) {
      _alertTimer?.cancel();
      _isPinging = false;
      _isAlertActive = false;
      notifyListeners();
      return;
    }

    _logEvent(EventType.phonePingedKey);
  }

  /// Silences both ends of the alert.
  ///
  /// Sends STOP to the keyholder *and* stops the phone ringing, because from the
  /// user's point of view there is one noise to make go away and they should not
  /// have to know which device is producing it.
  ///
  /// The local state is cleared first and the write is not awaited before the
  /// UI is told. The reason is the same as in [pingKey], and here it matters
  /// more: the one thing this button must do is make the noise stop, and making
  /// the owner watch a spinner while a write times out on a link that has
  /// already gone is the worst possible moment to be unresponsive. A STOP that
  /// fails to reach a keyholder is covered anyway — its buzzer times out on its
  /// own, which is what [_alertAutoClear] mirrors.
  Future<void> stopAlert() async {
    _alertTimer?.cancel();
    _isPinging = false;
    _isAlertActive = false;
    notifyListeners();

    // The phone's own ringer first: it is the noise coming out of the device in
    // the owner's hand, so it is the one they expect to stop instantly.
    await _ringer?.stop();
    await _write(BleCommands.stop);
  }

  /// Refreshes the last known position.
  ///
  /// This used to be `_write(BleCommands.getLoc)` — a request to the
  /// keyholder's own GPS module. That only worked while there was a link to ask
  /// over, which made it useless at the moment it mattered most, and it made the
  /// map depend on satellites reaching a device that is typically in a pocket or
  /// a bag. It now reads the phone's receiver instead.
  ///
  /// The keyholder is still asked as well when there is a link, so a unit that
  /// does have a module keeps contributing — [_applyLocation] accepts whatever
  /// comes back. Its answer is not waited for.
  Future<void> requestLocation() async {
    if (_isConnected) unawaited(_write(BleCommands.getLoc));
    await _refreshPhoneFix();
  }

  /// Silences the phone after the keyholder's button rang it.
  ///
  /// Separate from [stopAlert] because the two are not the same action. This one
  /// is reached from the "your phone is ringing" banner, which is very often still
  /// on screen after the link has dropped — and [stopAlert] would try a BLE write
  /// first and post "Not connected to a keyholder." for its trouble, reporting a
  /// failure for something that succeeded. The STOP is still sent when there is a
  /// link to send it on, because the same press also lit the keyholder's LED.
  Future<void> silencePhoneRing() async {
    _alertTimer?.cancel();
    _isPinging = false;
    _isAlertActive = false;
    await _ringer?.stop();
    notifyListeners();
    if (_isConnected) await _write(BleCommands.stop);
  }
  // ===========================================================================
  // Connect / disconnect by id (called from the device cards)
  // ===========================================================================

  Future<void> connectDevice(String id) async {
    final entry = _discovered[id];
    if (entry != null && entry.isDemo) {
      _lastError =
          'This is a Demo Mode entry, not real hardware. Turn Demo Mode off in '
          'Settings to connect to your keyholder.';
      notifyListeners();
      return;
    }
    if (entry != null && entry.isLockedToAnotherOwner) {
      _lastError =
          'This keyholder belongs to someone else. Its owner must release it '
          'before you can pair.';
      notifyListeners();
      return;
    }

    final radio = _radios[id];
    if (radio == null) {
      _lastError = 'That device is no longer in range. Scan again.';
      notifyListeners();
      return;
    }
    await connectToDevice(radio);
  }

  Future<void> disconnectDevice(String id) async {
    // An explicit Disconnect also ends the hunt, or the app would reconnect a
    // few seconds later and the button would appear not to work.
    endContinuousScan();

    final device = _connectedDevice;
    if (device == null || device.remoteId.str != id) {
      final entry = _discovered[id];
      if (entry != null) {
        _discovered[id] = entry.copyWith(isConnected: false);
        _rebuildScannedDevices();
      }
      return;
    }

    try {
      // Awaited, unlike before — the fire-and-forget call meant the UI could
      // repaint as "disconnected" while the link was still up.
      await device.disconnect();
    } catch (e) {
      debugPrint('BleService: disconnect error: $e');
    }
    await _teardownSession();
    _connectedDevice = null;
    // The connectionState listener normally handles this; call it directly too
    // so state is correct even if that event is missed.
    await _handleDisconnected(logEvent: true, resumeHunting: false);
  }

  Future<void> toggleDeviceConnection() async {
    if (_isConnected) {
      final id = _connectedDevice?.remoteId.str;
      if (id != null) await disconnectDevice(id);
      return;
    }

    final known = _knownDeviceId;
    if (known != null && _radios.containsKey(known)) {
      await connectDevice(known);
    } else {
      // Not in the current result set — go and look for it.
      _autoConnectDone = false;
      await startActiveHardwareScan();
    }
  }

  // ===========================================================================
  // History
  // ===========================================================================

  void _logEvent(EventType type, {bool includeLocation = true}) {
    // The phone's cache first, then whatever the keyholder last reported. The
    // phone is the primary source now, but a cached reading can be up to two
    // minutes old, and if the keyholder does have a module its `LOC:` frame may
    // well be newer.
    final cached = includeLocation ? _phoneLocation?.usableCachedFix : null;
    if (cached != null) _applyPhoneFix(cached);

    final useLocation = includeLocation && _hasGpsFix;
    final id = 'ev_${DateTime.now().microsecondsSinceEpoch}';
    _historyEvents.insert(
      0,
      EventModel(
        id: id,
        type: type,
        latitude: useLocation ? _lastLat : '',
        longitude: useLocation ? _lastLng : '',
        timestamp: DateTime.now(),
        bleConnected: _isConnected,
        locationName: _locationName.isEmpty ? null : _locationName,
        // Resolved now, not at read time, so a rename later leaves the old rows
        // saying what the device was called when it happened. Null when the app
        // has never met a keyholder, so a first-run log is not full of
        // "Keyholder".
        deviceName: _deviceId.isEmpty ? null : displayName,
      ),
    );
    if (_historyEvents.length > _maxHistoryEntries) {
      _historyEvents = _historyEvents.sublist(0, _maxHistoryEntries);
    }
    // The retention window is checked here too, so a phone left running for
    // weeks expires old rows as it goes instead of only at the next launch.
    _pruneHistory();
    unawaited(_persistHistory());
    notifyListeners();

    // The row is already in the list; now go and get a better position for it.
    // Deliberately after the insert and not awaited: a fresh high-accuracy fix
    // takes seconds, and a disconnect logged seconds late is a disconnect the
    // owner has already walked away from. Worse, the app is often being pushed
    // into the background at that exact moment, so an event that waits for
    // satellites is an event that may never be written at all.
    if (includeLocation) unawaited(_refinePosition(id));
  }

  /// Replaces the coordinates on an already-logged event with an accurate fix.
  ///
  /// Matched by id rather than by index, because anything may have been inserted
  /// above the row in the seconds this takes. A row that has since been pruned
  /// or pushed off the end of the log is simply left alone.
  Future<void> _refinePosition(String eventId) async {
    final service = _phoneLocation;
    if (service == null) return;

    final fix = await service.refresh();
    if (fix == null) return;

    final moved = _applyPhoneFix(fix);

    final index = _historyEvents.indexWhere((e) => e.id == eventId);
    if (index < 0) {
      if (moved) notifyListeners();
      return;
    }

    final event = _historyEvents[index];
    if (event.latitude == fix.latitudeText &&
        event.longitude == fix.longitudeText) {
      if (moved) notifyListeners();
      return;
    }

    _historyEvents[index] = event.copyWith(
      latitude: fix.latitudeText,
      longitude: fix.longitudeText,
      // The name, if there ever was one, described the coordinates being
      // replaced.
      clearLocationName: true,
    );
    unawaited(_persistHistory());
    notifyListeners();
  }

  /// Records a security decision in the log. Called by the pairing service.
  void logSecurityEvent(EventType type) => _logEvent(type);

  Future<void> clearAllHistory() async {
    _historyEvents.clear();
    await _settings?.clearHistory();
    notifyListeners();
  }

  // ===========================================================================
  // Settings
  // ===========================================================================

  Future<void> setAlertDistanceThreshold(double value) async {
    _alertDistanceThreshold = value;
    // Moving the inner boundary can invalidate an already-fired outer one. If
    // the owner raises the alert distance past where the keyholder currently is,
    // the allowance latch should not stay stuck on from the previous departure.
    if (value > maxAllowanceDistance) _maxAllowanceWarned = false;
    notifyListeners();
    await _settings?.setAlertDistanceThreshold(value);
  }

  /// Sets the outer boundary — how far the keyholder may get before the app
  /// treats it as gone rather than wandering.
  ///
  /// Not clamped on the way in. The stored value is kept exactly as the owner
  /// set it and [maxAllowanceDistance] applies the floor on read, so lowering
  /// the alert distance again restores the allowance the owner originally chose
  /// rather than leaving it permanently flattened to whatever the alert distance
  /// happened to be at the time.
  Future<void> setMaxAllowanceDistance(double value) async {
    if (_maxAllowanceDistance == value) return;
    _maxAllowanceDistance = value;
    // Re-armed, so raising the limit does not leave a notice latched from a
    // boundary that is now further away than the keyholder is.
    _maxAllowanceWarned = false;
    unawaited(_notifications?.cancelMaxAllowanceExceeded() ?? Future.value());
    notifyListeners();
    await _settings?.setMaxAllowanceDistance(value);
  }

  Future<void> setAlertSoundEnabled(bool value) async {
    _alertSoundEnabled = value;
    notifyListeners();
    await _settings?.setAlertSoundEnabled(value);
  }

  /// Chooses the cadence the keyholder's buzzer uses.
  ///
  /// Saved locally *and* pushed to the device, because the device is the thing
  /// that has to make the noise and it may have to do so with no phone attached —
  /// the low-battery warning fires whether or not anyone is connected. The
  /// keyholder stores it in NVS and echoes it back as [BleResponses.alertPrefix],
  /// which is what actually confirms the change landed.
  ///
  /// When nothing is connected this only writes the preference. That is not a
  /// failure: it is applied on the next connection, and [pushAlertPattern] is
  /// called from the post-authentication path for exactly that reason.
  Future<void> setAlertPattern(AlertPattern pattern) async {
    if (_alertPattern == pattern) return;
    _alertPattern = pattern;
    notifyListeners();
    await _settings?.setAlertPattern(pattern);
    await pushAlertPattern();
  }

  /// Sends the stored cadence to the keyholder. Safe to call when disconnected.
  Future<bool> pushAlertPattern() async {
    if (!_isConnected) return false;
    return _write('${BleCommands.alertSetPrefix}${_alertPattern.wireName}');
  }

  /// Rings the keyholder for a couple of seconds so the chosen cadence can be
  /// heard, then stops it.
  ///
  /// A preview is worth having because the difference between these patterns is
  /// rhythm, and no written description of a rhythm is as useful as hearing it.
  /// The stop is scheduled rather than left to [_alertAutoClear] so that trying
  /// four patterns in a row does not leave the device buzzing for 45 seconds.
  Future<void> previewAlertPattern(AlertPattern pattern) async {
    await setAlertPattern(pattern);

    if (!_isConnected) {
      _lastError = 'Connect to your keyholder to hear the alert.';
      notifyListeners();
      return;
    }

    if (!await _write(BleCommands.findKey)) return;
    _isAlertActive = true;
    notifyListeners();

    // Long enough to hear a full cycle of the slowest pattern (a discreet pip is
    // 70 ms on, 2 s off), short enough not to be annoying.
    await Future.delayed(const Duration(milliseconds: 2600));
    await stopAlert();
  }

  Future<void> setSaveGpsOnDisconnect(bool value) async {
    _saveGpsOnDisconnect = value;
    notifyListeners();
    await _settings?.setSaveGpsOnDisconnect(value);
  }

  Future<void> setWifiCloudSyncEnabled(bool value) async {
    _wifiCloudSyncEnabled = value;
    notifyListeners();
    await _settings?.setWifiCloudSyncEnabled(value);
  }

  /// Send Wi-Fi credentials to the connected keyholder.
  ///
  /// Builds `WIFI_SET:<ssid b64>:<password b64>` and writes it to the *prov*
  /// characteristic, not the data channel — the firmware refuses WIFI_SET on the
  /// data characteristic and only accepts it from an authenticated session, so
  /// this also fails cleanly when the ownership handshake has not happened.
  /// Both fields are base64-encoded, per the firmware parser, so that a colon or
  /// non-ASCII character in either cannot split the frame wrong.
  ///
  /// Returns true only once the write completed; the device's own
  /// `WIFI_OK:<ip>`/`WIFI_FAIL:<reason>` arrives later on the auth stream, which
  /// the Wi-Fi setup screen reads back through [wifiSetupResult].
  Future<bool> setupWifi({required String ssid, required String password}) async {
    if (ssid.trim().isEmpty) return false;
    final frame = '${BleCommands.wifiSetPrefix}'
        '${base64Encode(utf8.encode(ssid))}:'
        '${base64Encode(utf8.encode(password))}';
    return _writeProv(frame);
  }

  /// Writes to the provisioning characteristic, with the same error path as
  /// [_write] but against a different channel. Kept separate so a prov write can
  /// never accidentally go to the data characteristic (or vice versa).
  Future<bool> _writeProv(String frame) async {
    final c = _provChar;
    if (c == null || !_isConnected) {
      _lastError = 'Not connected to a keyholder.';
      notifyListeners();
      return false;
    }
    try {
      await c.write(
        utf8.encode(frame),
        withoutResponse: !c.properties.write && c.properties.writeWithoutResponse,
      );
      return true;
    } catch (e) {
      _lastError = 'Could not send Wi-Fi credentials: $e';
      notifyListeners();
      return false;
    }
  }

  /// The outcome of the most recent Wi-Fi provisioning attempt, once the
  /// keyholder has had a chance to answer. Null while nothing has been attempted
  /// or while the device is still connecting.
  String? get wifiSetupResult => _wifiSetupResult;

  /// Called by the Wi-Fi setup screen before it writes credentials, so the
  /// handler in [_handleAuthFrame] knows to record the reply for reading back.
  void armWifiResultCapture() {
    _awaitWifiResult = true;
    _wifiSetupResult = null;
  }

  /// Maps the firmware's terse failure reasons to something an owner reads
  /// naturally. The firmware sends bare tokens; the phone is the one with a
  /// screen.
  String _describeWifiFailure(String reason) {
    switch (reason.trim()) {
      case 'NO_CONNECT':
        return 'The keyholder could not reach that network. Check the name, '
            'confirm the password, and try again.';
      case 'BAD_FORMAT':
        return 'The network details were not recognised. Try again.';
      case 'BAD_SSID':
        return 'The network name was empty. Enter it and try again.';
      default:
        return reason.trim().isEmpty
            ? 'The keyholder did not join the network.'
            : 'The keyholder did not join the network ($reason).';
    }
  }

  Future<void> setDarkModeEnabled(bool value) async {
    _darkModeEnabled = value;
    notifyListeners();
    await _settings?.setDarkModeEnabled(value);
  }

  Future<void> setDeviceName(String name) async {
    _deviceName = name;
    notifyListeners();
    if (_deviceId.isNotEmpty) {
      await _settings?.setLastDevice(_deviceId, name);
    }
  }

  /// Recalibrates the distance model. Hold the keyholder at exactly one metre,
  /// read the raw dBm, and set that as [txPower].
  Future<void> setProximityCalibration({
    int? txPower,
    double? pathLossExponent,
  }) async {
    _proximity = ProximityModel(
      txPower: txPower ?? _proximity.txPower,
      pathLossExponent: pathLossExponent ?? _proximity.pathLossExponent,
    );
    final smoothed = _rssiWindow.median;
    if (smoothed != null) _estimatedDistance = _proximity.distanceFor(smoothed);
    notifyListeners();
    if (txPower != null) await _settings?.setTxPower(txPower);
    if (pathLossExponent != null) {
      await _settings?.setPathLossExponent(pathLossExponent);
    }
  }

  // ===========================================================================
  // Demo Mode
  // ===========================================================================

  /// Turns simulated data on or off.
  ///
  /// Off by default and never enabled implicitly. Everything it produces is
  /// flagged [BleDevice.isDemo], which [connectDevice] refuses, so a simulated
  /// entry can never be claimed, authenticated, or mistaken for a real
  /// keyholder — the point being that Demo Mode must not be able to hide a real
  /// security state.
  Future<void> setDemoModeEnabled(bool value) async {
    if (_demoModeEnabled == value) return;
    _demoModeEnabled = value;
    await _settings?.setDemoModeEnabled(value);

    if (value) {
      _startDemoMode();
    } else {
      _stopDemoMode();
    }
    notifyListeners();
  }

  void _startDemoMode() {
    if (_isConnected) {
      // Real hardware wins. Demo data must never overlay a live session.
      _demoModeEnabled = false;
      _lastError =
          'Disconnect from your keyholder before turning on Demo Mode.';
      return;
    }

    final rand = Random(7); // Fixed seed: reproducible for screenshots.
    _discovered['DEMO-KEYHOLDER'] = BleDevice(
      id: 'DEMO-KEYHOLDER',
      name: 'Find Me (demo)',
      rssi: -48,
      macAddress: 'DE:M0:00:01',
      deviceType: BleDeviceType.keyholder,
      ownership: OwnershipState.unclaimed,
      isDemo: true,
    );
    _discovered['DEMO-HEADPHONES'] = BleDevice(
      id: 'DEMO-HEADPHONES',
      name: 'Wireless Headphones (demo)',
      rssi: -63,
      macAddress: 'DE:M0:00:02',
      deviceType: BleDeviceType.headphones,
      isDemo: true,
    );
    _rebuildScannedDevices();

    _demoTimer?.cancel();
    _demoTimer = Timer.periodic(const Duration(milliseconds: 900), (_) {
      if (!_demoModeEnabled || _isConnected) return;
      final rssi = -45 - rand.nextInt(30);
      _rssiWindow.add(rssi);
      _currentRssi = _rssiWindow.median;
      _estimatedDistance = _proximity.distanceFor(_currentRssi!);
      _lastRssiUpdate = DateTime.now();
      notifyListeners();
    });
  }

  void _stopDemoMode() {
    _demoTimer?.cancel();
    _demoTimer = null;
    _discovered.removeWhere((_, d) => d.isDemo);
    if (!_isConnected) {
      _rssiWindow.clear();
      _currentRssi = null;
      _estimatedDistance = null;
      _batteryLevel = null;
      _lastRssiUpdate = null;
    }
    _rebuildScannedDevices();
  }

  // ===========================================================================

  @override
  void dispose() {
    _rssiTimer?.cancel();
    _alertTimer?.cancel();
    _demoTimer?.cancel();
    _rescanTimer?.cancel();
    _scanSubscription?.cancel();
    _isScanningSubscription?.cancel();
    _adapterStateSubscription?.cancel();
    _connectivitySubscription?.cancel();
    _connectionStateSubscription?.cancel();
    _dataSubscription?.cancel();
    _authSubscription?.cancel();
    _bondSubscription?.cancel();
    _authFrames.close();
    // Unregistered but the service is deliberately NOT stopped: it exists
    // precisely to outlive this object. Leaving the callback attached would aim
    // a Stop press at a disposed ChangeNotifier.
    BackgroundService.stopListeningForStopRequest();
    // The scan was previously left running after disposal, draining the battery
    // for as long as the process lived.
    if (!kIsWeb && FlutterBluePlus.isScanningNow) {
      unawaited(FlutterBluePlus.stopScan());
    }
    _keepHunting = false;
    unawaited(_connectedDevice?.disconnect() ?? Future<void>.value());
    super.dispose();
  }
}
