import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/ble_device.dart';
import '../models/event_model.dart';
import '../utils/coordinate_format.dart';
import 'ble_protocol.dart';
import 'proximity_model.dart';
import 'settings_store.dart';

/// How much of the scan result set the Scan screen shows.
///
/// This deliberately is **not** a transport picker. There used to be
/// `all / bluetooth / wifi` here, which implied the phone could reach the
/// keyholder over either radio and let the user choose. It cannot: the
/// phone-to-keyholder link is always BLE, and Wi-Fi is something the keyholder
/// uses to reach the cloud on its own. Presenting that as a connection mode was
/// misleading, so the only axis left is relevance — everything nearby, or just
/// keyholders.
enum ScanFilter { all, keyholders }

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

  /// Cap on the stored event log. The history screen is a timeline, not an
  /// archive, and an unbounded JSON blob in preferences would eventually hurt.
  static const int _maxHistoryEntries = 200;

  static const Duration _rssiPollInterval = Duration(seconds: 2);
  static const Duration _scanTimeout = Duration(seconds: 15);
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

  // ---------------------------------------------------------------------------
  // Scanning state
  // ---------------------------------------------------------------------------

  bool _isScanning = false;
  ScanFilter _scanFilter = ScanFilter.all;

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
  bool _alertSoundEnabled = true;
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
  ScanFilter get scanFilter => _scanFilter;
  bool get hasBluetoothPermission => _hasBluetoothPermission;
  String get permissionStatusMessage => _permissionStatusMessage;

  BluetoothAdapterState get adapterState => _adapterState;
  bool get isBluetoothOn => _adapterState == BluetoothAdapterState.on;
  bool get hasInternet => _hasInternet;
  String get lastError => _lastError;

  List<BleDevice> get scannedDevices => List.unmodifiable(_scannedDevices);
  List<EventModel> get historyEvents => List.unmodifiable(_historyEvents);

  /// The scan list the UI renders, sorted so the interesting things are on top.
  ///
  /// Keyholders first, then by signal strength. Previously ordering was
  /// whatever order the radio happened to report, which put a stranger's
  /// headphones above the user's own keyholder.
  List<BleDevice> get filteredScannedDevices {
    final list = _scanFilter == ScanFilter.keyholders
        ? _scannedDevices.where((d) => d.isKeyholder).toList()
        : List<BleDevice>.from(_scannedDevices);

    list.sort((a, b) {
      if (a.isKeyholder != b.isKeyholder) return a.isKeyholder ? -1 : 1;
      return b.rssi.compareTo(a.rssi);
    });
    return list;
  }

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
  bool get alertSoundEnabled => _alertSoundEnabled;
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
      _alertSoundEnabled = store.alertSoundEnabled;
      _saveGpsOnDisconnect = store.saveGpsOnDisconnect;
      _wifiCloudSyncEnabled = store.wifiCloudSyncEnabled;
      _darkModeEnabled = store.darkModeEnabled;
      _demoModeEnabled = store.demoModeEnabled;
      _proximity = store.proximityModel;

      _knownDeviceId = store.lastDeviceId;
      final knownName = store.lastDeviceName;
      if (knownName != null && knownName.isNotEmpty) _deviceName = knownName;
      if (_knownDeviceId != null) _deviceId = _knownDeviceId!;

      _restoreHistory(store.historyJson);

      if (_demoModeEnabled) _startDemoMode();

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
    } catch (e) {
      debugPrint('BleService: discarding unreadable history: $e');
    }
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
      notifyListeners();
    });
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

      if (scan.isGranted && connect.isGranted) {
        _hasBluetoothPermission = true;
        _permissionStatusMessage = location.isGranted
            ? ''
            : 'Location access was declined. On Android 11 and older this stops '
                'Bluetooth scanning from returning results.';
        notifyListeners();
        await startActiveHardwareScan();
      } else {
        _hasBluetoothPermission = false;
        _permissionStatusMessage = scan.isPermanentlyDenied ||
                connect.isPermanentlyDenied
            ? 'Bluetooth permissions were permanently denied. Enable them in '
                'Android Settings › Apps › KeyGuard › Permissions.'
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

  void setScanFilter(ScanFilter filter) {
    if (_scanFilter == filter) return;
    _scanFilter = filter;
    notifyListeners();
  }

  void _listenScanResults() {
    if (kIsWeb) return;
    // Subscribed once for the object's lifetime. `scanResults` is a broadcast
    // stream carrying the whole accumulated result set, so re-subscribing per
    // scan (as before) only risked leaking subscriptions.
    _scanSubscription = FlutterBluePlus.scanResults.listen(
      _onScanResults,
      onError: (Object e) {
        _lastError = 'Scan failed: $e';
        notifyListeners();
      },
    );
  }

  void _onScanResults(List<ScanResult> results) {
    BluetoothDevice? autoConnectTarget;

    for (final r in results) {
      final id = r.device.remoteId.str;
      final name = _resolveName(r);
      final isKeyholder = _looksLikeKeyholder(r, name);

      _radios[id] = r.device;
      _discovered[id] = BleDevice(
        id: id,
        name: name,
        rssi: r.rssi,
        macAddress: id,
        deviceType:
            isKeyholder ? BleDeviceType.keyholder : _guessDeviceType(name),
        isConnected: _isConnected && id == _connectedDevice?.remoteId.str,
        isPrimary: isKeyholder && id == _knownDeviceId,
        ownership: isKeyholder
            ? _advertisedOwnership(name, id)
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

  String _resolveName(ScanResult r) {
    if (r.device.platformName.isNotEmpty) return r.device.platformName;
    if (r.advertisementData.advName.isNotEmpty) {
      return r.advertisementData.advName;
    }
    final id = r.device.remoteId.str;
    return 'Unknown device (${id.substring(0, min(8, id.length))})';
  }

  /// A keyholder is identified by the service UUID in its advertisement, and
  /// only falls back to the name if that is absent.
  ///
  /// The old code matched `name.contains("BLE-Keyholder")` against every radio
  /// in the room, so anything named similarly would have been treated as the
  /// user's key fob.
  bool _looksLikeKeyholder(ScanResult r, String name) {
    if (r.advertisementData.serviceUuids.contains(Guid(BleUuids.service))) {
      return true;
    }
    return BleNames.candidates.contains(name);
  }

  /// What the advertisement alone can tell us about ownership.
  ///
  /// The firmware advertises [BleNames.unclaimed] until it has an owner and the
  /// neutral [BleNames.claimed] afterwards, so an unclaimed unit is recognisable
  /// before connecting. Anything already claimed is reported as
  /// [OwnershipState.claimedByOther] unless it is *our* device — the real answer
  /// only arrives from the challenge in Phase 2, and guessing optimistically
  /// here would show a Connect button that cannot work.
  OwnershipState _advertisedOwnership(String name, String id) {
    if (name == BleNames.unclaimed) return OwnershipState.unclaimed;
    if (id == _knownDeviceId) return OwnershipState.claimedByMe;
    return OwnershipState.claimedByOther;
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
    _scannedDevices = list;
    notifyListeners();
  }

  Future<void> startActiveHardwareScan() async {
    _lastError = '';

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
      _lastError = 'Could not start scanning: $e';
      notifyListeners();
    }
  }

  /// A narrow scan that only surfaces KeyGuard hardware, for the pairing flow.
  ///
  /// The general scan above is intentionally unfiltered so the All Devices tab
  /// can still list headphones and watches; only one BLE scan can run at a time,
  /// so the two cannot be combined.
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

  Future<void> toggleScanning() =>
      _isScanning ? stopActiveHardwareScan() : startActiveHardwareScan();

  // ===========================================================================
  // Connection
  // ===========================================================================

  Future<void> connectToDevice(BluetoothDevice device) async {
    if (_isConnecting) return;
    if (_connectedDevice?.remoteId == device.remoteId && _isConnected) return;

    _isConnecting = true;
    _lastError = '';
    notifyListeners();

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

      _knownDeviceId = _deviceId;
      await _settings?.setLastDevice(_deviceId, _deviceName);

      _rssiWindow.clear();
      _startRssiPolling(device);

      _logEvent(EventType.connected);

      // Ask for a position immediately so the map has something real to show
      // instead of a placeholder.
      await requestLocation();
    } catch (e) {
      _lastError = 'Could not connect: $e';
      await _teardownSession();
      _isConnected = false;
    } finally {
      _isConnecting = false;
      notifyListeners();
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

      // Shows the system "Pair with KeyGuard? Enter PIN" dialog. The code it
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
        'This device does not expose the KeyGuard service '
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
      throw StateError('KeyGuard service is missing its data characteristic.');
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

  Future<void> _handleDisconnected({required bool logEvent}) async {
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

    if (logEvent && wasConnected) {
      // The handout's "save GPS on disconnect" behaviour: the last known
      // position is what makes a lost item findable, so record it here.
      _logEvent(EventType.disconnected,
          includeLocation: _saveGpsOnDisconnect);
    }

    _discovered.updateAll((_, d) => d.copyWith(isConnected: false));
    _rebuildScannedDevices();
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
        }
        notifyListeners();
      } catch (e) {
        debugPrint('BleService: readRssi failed: $e');
      }
    });
  }

  // ===========================================================================
  // Incoming frames
  // ===========================================================================

  void _handleDataFrame(String data) {
    debugPrint('KeyGuard → app: $data');

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

    if (data.startsWith(BleResponses.findPhonePrefix)) {
      _applyLocation(data.substring(BleResponses.findPhonePrefix.length));
      _isPinging = true;
      _isAlertActive = true;
      _armAlertTimeout();
      _logEvent(EventType.keyPingedPhone);
      return;
    }
  }

  /// Republished for `pairing_service.dart`; the handshake itself is not this
  /// class's job, but the connection state it produces is.
  void _handleAuthFrame(String data) {
    debugPrint('KeyGuard auth → app: $data');

    if (data == BleResponses.statusUnclaimed) {
      _ownershipState = OwnershipState.unclaimed;
    } else if (data.startsWith(BleResponses.authReqPrefix)) {
      _ownershipState = OwnershipState.authenticating;
    } else if (data == BleResponses.authOk) {
      _ownershipState = OwnershipState.authenticated;
      _lastError = '';
    } else if (data == BleResponses.authFail) {
      _ownershipState = OwnershipState.authFailed;
      _lastError = 'The keyholder refused this phone.';
    } else if (data.startsWith(BleResponses.lockedPrefix)) {
      _ownershipState = OwnershipState.lockedOut;
      final secs = data.substring(BleResponses.lockedPrefix.length).trim();
      _lastError = 'Too many failed attempts. Locked for $secs s.';
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

  Future<void> pingKey() async {
    if (!_isConnected) {
      _lastError = 'Connect to your keyholder before pinging it.';
      notifyListeners();
      return;
    }

    final ok = await _write(BleCommands.findKey);
    if (!ok) return;

    _isPinging = true;
    _isAlertActive = true;
    _armAlertTimeout();
    _logEvent(EventType.phonePingedKey);
  }

  Future<void> stopAlert() async {
    await _write(BleCommands.stop);
    _alertTimer?.cancel();
    _isPinging = false;
    _isAlertActive = false;
    notifyListeners();
  }

  Future<void> requestLocation() async {
    await _write(BleCommands.getLoc);
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
    await _handleDisconnected(logEvent: true);
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
    final useLocation = includeLocation && _hasGpsFix;
    _historyEvents.insert(
      0,
      EventModel(
        id: 'ev_${DateTime.now().microsecondsSinceEpoch}',
        type: type,
        latitude: useLocation ? _lastLat : '',
        longitude: useLocation ? _lastLng : '',
        timestamp: DateTime.now(),
        bleConnected: _isConnected,
        locationName: _locationName.isEmpty ? null : _locationName,
      ),
    );
    if (_historyEvents.length > _maxHistoryEntries) {
      _historyEvents = _historyEvents.sublist(0, _maxHistoryEntries);
    }
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
    notifyListeners();
    await _settings?.setAlertDistanceThreshold(value);
  }

  Future<void> setAlertSoundEnabled(bool value) async {
    _alertSoundEnabled = value;
    notifyListeners();
    await _settings?.setAlertSoundEnabled(value);
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
      name: 'BLE-Keyholder (demo)',
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
    _scanSubscription?.cancel();
    _isScanningSubscription?.cancel();
    _adapterStateSubscription?.cancel();
    _connectivitySubscription?.cancel();
    _connectionStateSubscription?.cancel();
    _dataSubscription?.cancel();
    _authSubscription?.cancel();
    _bondSubscription?.cancel();
    _authFrames.close();
    // The scan was previously left running after disposal, draining the battery
    // for as long as the process lived.
    if (!kIsWeb && FlutterBluePlus.isScanningNow) {
      unawaited(FlutterBluePlus.stopScan());
    }
    unawaited(_connectedDevice?.disconnect() ?? Future<void>.value());
    super.dispose();
  }
}
