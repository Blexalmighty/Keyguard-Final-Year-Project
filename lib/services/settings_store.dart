import 'package:shared_preferences/shared_preferences.dart';

import 'proximity_model.dart';

/// Persistence for non-secret preferences.
///
/// Everything the Settings screen toggles used to live in plain fields on
/// `BleService`, so it all reset the moment the app was killed. This backs it
/// with `shared_preferences`.
///
/// Deliberately **not** used for the owner identifier or the shared secret —
/// those go through `owner_identity.dart` into the platform keystore. Plain
/// preferences are readable on a rooted device, which is fine for "is dark mode
/// on" and not fine for the key that unlocks the keyholder.
class SettingsStore {
  SettingsStore._(this._prefs);

  final SharedPreferences _prefs;

  static const String _kAlertSound = 'alert_sound_enabled';
  static const String _kSaveGpsOnDisconnect = 'save_gps_on_disconnect';
  static const String _kWifiCloudSync = 'wifi_cloud_sync_enabled';
  static const String _kDarkMode = 'dark_mode_enabled';
  static const String _kDemoMode = 'demo_mode_enabled';
  static const String _kAlertDistance = 'alert_distance_threshold';
  static const String _kTxPower = 'rssi_tx_power';
  static const String _kPathLoss = 'rssi_path_loss_exponent';
  static const String _kHistory = 'history_events_json';
  static const String _kLastDeviceId = 'last_device_id';
  static const String _kLastDeviceName = 'last_device_name';

  static Future<SettingsStore> open() async =>
      SettingsStore._(await SharedPreferences.getInstance());

  // --- Preferences ---

  bool get alertSoundEnabled => _prefs.getBool(_kAlertSound) ?? true;
  Future<void> setAlertSoundEnabled(bool v) => _prefs.setBool(_kAlertSound, v);

  bool get saveGpsOnDisconnect => _prefs.getBool(_kSaveGpsOnDisconnect) ?? true;
  Future<void> setSaveGpsOnDisconnect(bool v) =>
      _prefs.setBool(_kSaveGpsOnDisconnect, v);

  bool get wifiCloudSyncEnabled => _prefs.getBool(_kWifiCloudSync) ?? true;
  Future<void> setWifiCloudSyncEnabled(bool v) =>
      _prefs.setBool(_kWifiCloudSync, v);

  bool get darkModeEnabled => _prefs.getBool(_kDarkMode) ?? false;
  Future<void> setDarkModeEnabled(bool v) => _prefs.setBool(_kDarkMode, v);

  /// Demo mode is **off** unless explicitly switched on, and never defaults to
  /// true — the real hardware path must be the default so the app can never
  /// quietly present simulated state as if it were live.
  bool get demoModeEnabled => _prefs.getBool(_kDemoMode) ?? false;
  Future<void> setDemoModeEnabled(bool v) => _prefs.setBool(_kDemoMode, v);

  double get alertDistanceThreshold =>
      _prefs.getDouble(_kAlertDistance) ?? 2.0;
  Future<void> setAlertDistanceThreshold(double v) =>
      _prefs.setDouble(_kAlertDistance, v);

  // --- RSSI calibration (see ProximityModel) ---

  int get txPower => _prefs.getInt(_kTxPower) ?? ProximityModel.defaultTxPower;
  Future<void> setTxPower(int v) => _prefs.setInt(_kTxPower, v);

  double get pathLossExponent =>
      _prefs.getDouble(_kPathLoss) ?? ProximityModel.defaultPathLossExponent;
  Future<void> setPathLossExponent(double v) =>
      _prefs.setDouble(_kPathLoss, v);

  ProximityModel get proximityModel =>
      ProximityModel(txPower: txPower, pathLossExponent: pathLossExponent);

  // --- Event history ---
  //
  // Stored as a JSON array string. Fine at this scale: the log is capped at a
  // few hundred entries, and Phase 4 moves the authoritative copy to Firebase
  // with this acting as the offline cache.

  String? get historyJson => _prefs.getString(_kHistory);
  Future<void> setHistoryJson(String json) => _prefs.setString(_kHistory, json);
  Future<void> clearHistory() => _prefs.remove(_kHistory);

  // --- Last known keyholder ---
  //
  // Remembered so the app can reconnect to *this* keyholder on launch instead of
  // grabbing whichever one it happens to see first. Auto-connect is deliberately
  // narrow: on a campus where several of these units exist, connecting to a
  // stranger's keyholder would be both useless and rude.

  String? get lastDeviceId => _prefs.getString(_kLastDeviceId);
  String? get lastDeviceName => _prefs.getString(_kLastDeviceName);

  Future<void> setLastDevice(String id, String name) async {
    await _prefs.setString(_kLastDeviceId, id);
    await _prefs.setString(_kLastDeviceName, name);
  }

  Future<void> clearLastDevice() async {
    await _prefs.remove(_kLastDeviceId);
    await _prefs.remove(_kLastDeviceName);
  }
}
