import 'package:shared_preferences/shared_preferences.dart';

import '../models/alert_distances.dart';
import '../models/alert_pattern.dart';
import '../models/history_retention.dart';
import '../models/phone_alert_tone.dart';
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
  static const String _kAlertPattern = 'alert_pattern';
  static const String _kPhoneTone = 'phone_alert_tone';
  static const String _kPhoneTonePath = 'phone_alert_tone_path';
  static const String _kPhoneToneName = 'phone_alert_tone_name';
  static const String _kPhoneVibrate = 'phone_alert_vibrate';
  static const String _kSaveGpsOnDisconnect = 'save_gps_on_disconnect';
  static const String _kWifiCloudSync = 'wifi_cloud_sync_enabled';
  static const String _kDarkMode = 'dark_mode_enabled';
  static const String _kDemoMode = 'demo_mode_enabled';
  static const String _kAlertDistance = 'alert_distance_threshold';
  static const String _kMaxAllowance = 'max_allowance_distance';
  static const String _kTxPower = 'rssi_tx_power';
  static const String _kPathLoss = 'rssi_path_loss_exponent';
  static const String _kHistory = 'history_events_json';
  static const String _kHistoryRetention = 'history_retention';
  static const String _kNicknamePrefix = 'device_nickname_';
  static const String _kProximityWarning = 'proximity_warning_enabled';
  static const String _kLastDeviceId = 'last_device_id';
  static const String _kLastDeviceName = 'last_device_name';

  static Future<SettingsStore> open() async =>
      SettingsStore._(await SharedPreferences.getInstance());

  // --- Preferences ---

  bool get alertSoundEnabled => _prefs.getBool(_kAlertSound) ?? true;
  Future<void> setAlertSoundEnabled(bool v) => _prefs.setBool(_kAlertSound, v);

  /// The buzzer cadence, stored as its wire token.
  ///
  /// The token rather than the enum index, deliberately: an index would silently
  /// point at a different pattern if the enum were ever reordered, and this value
  /// outlives any single build of the app.
  AlertPattern get alertPattern =>
      AlertPattern.fromWireName(_prefs.getString(_kAlertPattern));
  Future<void> setAlertPattern(AlertPattern v) =>
      _prefs.setString(_kAlertPattern, v.wireName);

  // --- Find My Phone (the keyholder's button rings this phone) ---
  //
  // Kept here, not in secure storage: a ringtone choice is not a secret, and a
  // path to a music file is not key material.

  /// Which sound the phone plays when the keyholder's button is pressed. Stored
  /// as a token for the same reason as [alertPattern].
  PhoneAlertTone get phoneAlertTone =>
      PhoneAlertTone.fromWireName(_prefs.getString(_kPhoneTone));
  Future<void> setPhoneAlertTone(PhoneAlertTone v) =>
      _prefs.setString(_kPhoneTone, v.wireName);

  /// Absolute path to the copy of the owner's chosen audio file, inside this
  /// app's own documents directory. Null until one has been picked.
  String? get phoneAlertTonePath => _prefs.getString(_kPhoneTonePath);

  /// The picked file's original name, kept only so Settings can show the owner
  /// what they chose. The stored path is an opaque copy and would read as
  /// gibberish on screen.
  String? get phoneAlertToneName => _prefs.getString(_kPhoneToneName);

  Future<void> setPhoneAlertToneFile(String path, String displayName) async {
    await _prefs.setString(_kPhoneTonePath, path);
    await _prefs.setString(_kPhoneToneName, displayName);
  }

  Future<void> clearPhoneAlertToneFile() async {
    await _prefs.remove(_kPhoneTonePath);
    await _prefs.remove(_kPhoneToneName);
  }

  /// Whether to vibrate while ringing. Defaults on: a phone down the side of a
  /// sofa is often found by feel before it is found by ear.
  bool get phoneAlertVibrate => _prefs.getBool(_kPhoneVibrate) ?? true;
  Future<void> setPhoneAlertVibrate(bool v) =>
      _prefs.setBool(_kPhoneVibrate, v);

  bool get saveGpsOnDisconnect => _prefs.getBool(_kSaveGpsOnDisconnect) ?? true;
  Future<void> setSaveGpsOnDisconnect(bool v) =>
      _prefs.setBool(_kSaveGpsOnDisconnect, v);

  bool get wifiCloudSyncEnabled => _prefs.getBool(_kWifiCloudSync) ?? true;
  Future<void> setWifiCloudSyncEnabled(bool v) =>
      _prefs.setBool(_kWifiCloudSync, v);

  HistoryRetention get historyRetention =>
      HistoryRetention.fromStorage(_prefs.getString(_kHistoryRetention));
  Future<void> setHistoryRetention(HistoryRetention v) =>
      _prefs.setString(_kHistoryRetention, v.storageValue);

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

  /// The outer boundary, beyond the alert distance.
  ///
  /// Defaults to [kDefaultMaxAllowance] rather than to the alert distance, so
  /// the escalation exists on a fresh install without the owner having to
  /// discover the setting. `BleService` clamps it to at least the alert
  /// distance, which is the invariant that keeps the three boundaries in order.
  double get maxAllowanceDistance =>
      _prefs.getDouble(_kMaxAllowance) ?? kDefaultMaxAllowance;
  Future<void> setMaxAllowanceDistance(double v) =>
      _prefs.setDouble(_kMaxAllowance, v);

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

  // --- Device nicknames ---
  //
  // A claimed keyholder advertises the generic name "KeyGuard" on purpose: a
  // per-unit name in the advertising packet lets a passer-by single out *this*
  // device, and by extension follow its owner around. That is the anti-stalking
  // property in docs/SECURITY_MODEL.md and it is not negotiable.
  //
  // The consequence is that every claimed keyholder looks identical on screen.
  // The fix is a nickname that lives *on the phone* and never goes near the
  // radio: the owner sees "Ife's keys", a stranger scanning the room still sees
  // nothing but "KeyGuard". Same approach Apple uses for AirTags.
  //
  // Keyed by BLE remote id, so a phone that owns two keyholders names them
  // independently.

  String? nicknameFor(String deviceId) =>
      _prefs.getString('$_kNicknamePrefix$deviceId');

  Future<void> setNickname(String deviceId, String nickname) async {
    final trimmed = nickname.trim();
    if (trimmed.isEmpty) {
      await _prefs.remove('$_kNicknamePrefix$deviceId');
      return;
    }
    await _prefs.setString('$_kNicknamePrefix$deviceId', trimmed);
  }

  Future<void> clearNickname(String deviceId) =>
      _prefs.remove('$_kNicknamePrefix$deviceId');

  // --- Proximity alert ---

  /// Warn once when the keyholder passes half the alert distance on its way out.
  bool get proximityWarningEnabled =>
      _prefs.getBool(_kProximityWarning) ?? true;
  Future<void> setProximityWarningEnabled(bool v) =>
      _prefs.setBool(_kProximityWarning, v);
}
