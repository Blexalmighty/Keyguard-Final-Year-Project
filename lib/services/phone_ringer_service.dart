import 'dart:async';
import 'dart:io' show File;

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';

import '../models/phone_alert_tone.dart';
import 'settings_store.dart';

/// Makes the *phone* ring when the button on the keyholder is pressed.
///
/// This is the other half of the two-way alert, and until now it was the missing
/// half: the firmware already sends `FIND_PHONE|LOC:` on a short press of GPIO 7,
/// `BleService` already parsed it, logged it and pulsed the Home screen — and the
/// phone made no sound whatsoever, because there was no audio dependency in the
/// project at all. A silent "find my phone" is not a feature.
///
/// Three design decisions worth defending:
///
/// **The alarm stream, not the media stream.** A lost phone is very often a
/// silenced phone. Android's alarm stream is audible in silent mode, so the loud
/// tones go out as alarms (see [PhoneAlertTone.overridesSilentMode]) rather than
/// as media, which would be inaudible exactly when it mattered.
///
/// **The picked file is copied, not referenced.** The document picker hands back
/// a path into a cache directory that Android is free to delete, and the grant it
/// carries does not survive a reboot. Storing that path would give a ringtone
/// that works today and silently fails in a fortnight, so the bytes are copied
/// into this app's own documents directory and the copy is what gets stored.
///
/// **Fall back audibly.** If the custom file has gone missing, the phone rings
/// with [PhoneAlertTone.fallback] and says so, rather than "playing" silence.
/// Losing your ringtone choice is an annoyance; losing the alert is the whole
/// feature.
///
/// Scope, stated honestly: this rings while the app's process is alive, including
/// when it is backgrounded. It cannot ring an app the OS has killed — but neither
/// can the BLE link that delivers the button press, since `flutter_blue_plus`
/// runs no background service. The alert is therefore no more limited than the
/// connection it depends on.
class PhoneRingerService extends ChangeNotifier {
  PhoneRingerService() {
    _load();
  }

  /// The one file name a picked ringtone is ever copied to.
  ///
  /// Fixed rather than derived from the original name, so choosing a new tone
  /// replaces the old copy instead of accumulating a private library of every
  /// song the owner ever auditioned.
  static const String _copyBaseName = 'keyguard_ringtone';

  /// Hard ceiling on one ring, in case nothing ever calls [stop].
  ///
  /// Ten minutes, not the two it used to be. The ring is supposed to last until
  /// the owner silences it in the app — a phone that gives up after two minutes
  /// has stopped helping precisely when the search got hard, which is the point
  /// of the whole feature. This remains only so a crashed screen cannot leave a
  /// phone screaming in someone's bag forever.
  static const Duration _maxRingDuration = Duration(minutes: 10);

  /// How long a preview plays before stopping itself.
  ///
  /// Long enough to recognise the tone, short enough that auditioning all four
  /// is not a chore.
  static const Duration _previewDuration = Duration(milliseconds: 3200);

  /// Ring, silence, repeat. Roughly the cadence of an incoming call, which is
  /// the pattern people already read as "answer me".
  static const List<int> _vibratePattern = <int>[0, 800, 450, 800, 900];

  /// Plays the phone's own system sounds. Instance-based in v4 of the plugin, so
  /// it is held rather than called statically.
  final FlutterRingtonePlayer _systemPlayer = FlutterRingtonePlayer();

  /// Created on first use. Building an `AudioPlayer` allocates a native player,
  /// which is wasted on the many installs that never pick a custom file.
  AudioPlayer? _filePlayer;

  /// Routes a custom audio file through the alarm stream, with a wake lock so
  /// playback survives the screen locking.
  static final AudioContext _alarmContext = AudioContext(
    android: const AudioContextAndroid(
      usageType: AndroidUsageType.alarm,
      contentType: AndroidContentType.music,
      audioFocus: AndroidAudioFocus.gain,
      stayAwake: true,
    ),
  );

  SettingsStore? _settings;

  PhoneAlertTone _tone = PhoneAlertTone.fallback;
  String? _customPath;
  String? _customName;
  bool _vibrate = true;

  bool _isRinging = false;
  bool _isPreviewing = false;
  bool _isPicking = false;
  String _lastError = '';

  Timer? _capTimer;
  Timer? _previewTimer;

  // ===========================================================================
  // Getters
  // ===========================================================================

  PhoneAlertTone get tone => _tone;

  /// The name of the picked file, for display. Null when none has been picked.
  String? get customToneName => _customName;
  bool get hasCustomTone => _customPath != null;

  bool get vibrate => _vibrate;

  /// True while the phone is actually making a noise because the keyholder asked
  /// it to. Drives the Stop affordance on Home.
  bool get isRinging => _isRinging;

  /// True while a short preview from Settings is playing. Kept separate from
  /// [isRinging] so auditioning a tone never puts the app into "your phone is
  /// ringing, come and find it" mode.
  bool get isPreviewing => _isPreviewing;

  bool get isPickingFile => _isPicking;

  String get lastError => _lastError;

  /// What Settings should show under the tone list.
  String get toneSummary {
    if (_tone.needsFile) {
      return _customName ?? 'No file chosen yet';
    }
    return _tone.label;
  }

  // ===========================================================================
  // Persistence
  // ===========================================================================

  Future<void> _load() async {
    try {
      final store = await SettingsStore.open();
      _settings = store;
      _tone = store.phoneAlertTone;
      _customPath = store.phoneAlertTonePath;
      _customName = store.phoneAlertToneName;
      _vibrate = store.phoneAlertVibrate;
      notifyListeners();
    } catch (e) {
      debugPrint('PhoneRingerService: could not open settings store: $e');
    }
  }

  Future<void> setTone(PhoneAlertTone tone) async {
    if (_tone == tone) return;
    _tone = tone;
    _lastError = '';
    notifyListeners();
    await _settings?.setPhoneAlertTone(tone);
  }

  Future<void> setVibrate(bool value) async {
    if (_vibrate == value) return;
    _vibrate = value;
    notifyListeners();
    await _settings?.setPhoneAlertVibrate(value);
    // If the change lands mid-ring, honour it now rather than next time.
    if (_isRinging || _isPreviewing) {
      if (value) {
        await _startVibration();
      } else {
        await _stopVibration();
      }
    }
  }

  // ===========================================================================
  // Choosing a file
  // ===========================================================================

  /// Asks for read access to the phone's audio, and reports whether it was
  /// granted.
  ///
  /// Requested because the user asked for it, but deliberately **not** treated as
  /// a precondition for [pickCustomTone]: the document picker hands this app a
  /// grant for the one file the owner tapped, which works whether or not a
  /// blanket media permission was given. Asking and then proceeding either way is
  /// the honest version — a hard requirement here would block a flow that does
  /// not actually need it.
  Future<bool> requestAudioPermission() async {
    if (kIsWeb) return false;
    try {
      // `Permission.audio` maps to READ_MEDIA_AUDIO on Android 13+ and
      // `Permission.storage` to the legacy READ_EXTERNAL_STORAGE below it.
      // Requesting both and accepting either covers the split without asking the
      // caller to know the API level.
      final results =
          await [Permission.audio, Permission.storage].request();
      return results.values.any((s) => s.isGranted || s.isLimited);
    } catch (e) {
      debugPrint('PhoneRingerService: audio permission request failed: $e');
      return false;
    }
  }

  /// Opens the system picker, copies the chosen audio file into this app's own
  /// storage, and selects [PhoneAlertTone.customFile].
  ///
  /// Returns false if the owner cancelled or the copy failed; [lastError]
  /// explains which.
  Future<bool> pickCustomTone() async {
    if (!_audioSupported) {
      _lastError = 'Choosing a ringtone file only works on a phone.';
      notifyListeners();
      return false;
    }
    if (_isPicking) return false;

    _isPicking = true;
    _lastError = '';
    notifyListeners();

    try {
      await requestAudioPermission();

      final result = await FilePicker.pickFiles(type: FileType.audio);
      final picked = result?.files.firstOrNull;
      final sourcePath = picked?.path;
      if (picked == null || sourcePath == null) {
        // A cancelled picker is not an error; say nothing.
        return false;
      }

      final stored = await _copyIntoAppStorage(sourcePath, picked.name);
      if (stored == null) {
        _lastError = 'That file could not be read. Try another one.';
        return false;
      }

      _customPath = stored;
      _customName = picked.name;
      _tone = PhoneAlertTone.customFile;

      // The player caches its source, so a new file behind the same handle would
      // otherwise keep playing the old one.
      await _releaseFilePlayer();

      await _settings?.setPhoneAlertToneFile(stored, picked.name);
      await _settings?.setPhoneAlertTone(PhoneAlertTone.customFile);
      return true;
    } catch (e) {
      debugPrint('PhoneRingerService: pick failed: $e');
      _lastError = 'Could not open the file picker.';
      return false;
    } finally {
      _isPicking = false;
      notifyListeners();
    }
  }

  /// Forgets the chosen file and falls back to the phone's ringtone.
  Future<void> clearCustomTone() async {
    final old = _customPath;
    _customPath = null;
    _customName = null;
    if (_tone.needsFile) _tone = PhoneAlertTone.fallback;
    notifyListeners();

    await _releaseFilePlayer();
    await _settings?.clearPhoneAlertToneFile();
    await _settings?.setPhoneAlertTone(_tone);
    if (old != null) await _deleteQuietly(old);
  }

  /// Copies [sourcePath] next to the app's own data and returns the new path.
  ///
  /// The extension is carried over from [displayName] because Android's media
  /// player picks its decoder partly from the file name, and a `.ogg` renamed to
  /// nothing at all is a decode failure at the worst possible moment.
  Future<String?> _copyIntoAppStorage(
      String sourcePath, String displayName) async {
    try {
      final source = File(sourcePath);
      if (!await source.exists()) return null;

      final dir = await getApplicationDocumentsDirectory();
      final target = '${dir.path}/$_copyBaseName${_extensionOf(displayName)}';

      // Remove the previous copy first: `copy` overwrites, but an old file with a
      // different extension would otherwise be left behind forever.
      final previous = _customPath;
      if (previous != null && previous != target) await _deleteQuietly(previous);

      await source.copy(target);
      return target;
    } catch (e) {
      debugPrint('PhoneRingerService: copy failed: $e');
      return null;
    }
  }

  /// The extension of [name] including the dot, or an empty string.
  ///
  /// Hand-rolled rather than pulled from `package:path`, which is only in the
  /// dependency tree transitively — importing it directly would work today and
  /// break the day something upstream stops depending on it.
  static String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    final ext = name.substring(dot);
    // Guard against a "name" that is really a path fragment.
    if (ext.contains('/') || ext.contains(r'\')) return '';
    return ext.toLowerCase();
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('PhoneRingerService: could not delete $path: $e');
    }
  }

  // ===========================================================================
  // Ringing
  // ===========================================================================

  /// Starts ringing. Called when the keyholder's button press arrives.
  ///
  /// Safe to call again while already ringing — a second button press should not
  /// restart the sound from the top, which on a long custom file would make the
  /// phone harder to home in on rather than easier.
  Future<void> start() async {
    if (_isRinging) return;

    await _stopPreview();

    if (!_audioSupported) {
      // Still flip the flag: the Home screen's "your phone is ringing" panel and
      // its Stop button are what tell the user the press was received, and on a
      // desktop or web build that is all there is to show.
      _isRinging = true;
      _lastError = 'This build cannot play audio, so the ring is silent.';
      notifyListeners();
      return;
    }

    final tone = await _resolveTone();

    _isRinging = true;
    notifyListeners();

    await _play(tone);
    if (_vibrate) await _startVibration();

    _capTimer?.cancel();
    _capTimer = Timer(_maxRingDuration, () => unawaited(stop()));
  }

  /// Silences the phone. This is what the Stop button on Home calls.
  Future<void> stop() async {
    _capTimer?.cancel();
    _capTimer = null;

    final wasAudible = _isRinging || _isPreviewing;
    _isRinging = false;
    _isPreviewing = false;
    _previewTimer?.cancel();
    _previewTimer = null;

    if (wasAudible) {
      await _silence();
      notifyListeners();
    }
  }

  /// Plays [tone] for a few seconds so the owner can hear what they picked.
  ///
  /// Worth having for the same reason the keyholder's cadence preview is: no
  /// written description of a sound is as useful as the sound. Selecting the tone
  /// is part of the preview, because tapping a row in a list of ringtones and
  /// having it play *without* being selected is the behaviour nobody expects.
  Future<void> previewTone(PhoneAlertTone tone) async {
    await setTone(tone);

    // Never talk over a real alert to demonstrate a ringtone.
    if (_isRinging) return;

    if (!_audioSupported) {
      _lastError = 'Previewing a tone only works on a phone.';
      notifyListeners();
      return;
    }

    if (tone.needsFile && _customPath == null) {
      _lastError = 'Choose a file first.';
      notifyListeners();
      return;
    }

    await _stopPreview();

    final resolved = await _resolveTone();
    _isPreviewing = true;
    notifyListeners();

    await _play(resolved);
    if (_vibrate) await _startVibration();

    _previewTimer = Timer(_previewDuration, () => unawaited(_stopPreview()));
  }

  Future<void> _stopPreview() async {
    _previewTimer?.cancel();
    _previewTimer = null;
    if (!_isPreviewing) return;
    _isPreviewing = false;
    await _silence();
    notifyListeners();
  }

  /// The tone that will actually be played, which is not always the tone that is
  /// selected: a custom file can be deleted from under us at any time.
  Future<PhoneAlertTone> _resolveTone() async {
    final tone = _tone;
    if (!tone.needsFile) return tone;

    final path = _customPath;
    if (path != null && await File(path).exists()) return tone;

    _lastError = 'Your chosen sound file is missing, so the phone used its '
        'normal ringtone instead.';
    return PhoneAlertTone.fallback;
  }

  Future<void> _play(PhoneAlertTone tone) async {
    try {
      switch (tone) {
        case PhoneAlertTone.systemRingtone:
          await _systemPlayer.playRingtone(
              looping: true, asAlarm: tone.overridesSilentMode);
        case PhoneAlertTone.systemAlarm:
          await _systemPlayer.playAlarm(
              looping: true, asAlarm: tone.overridesSilentMode);
        case PhoneAlertTone.systemNotification:
          // Looping a chime that was designed to be heard once is deliberate: a
          // single ping is not something anyone can walk towards.
          await _systemPlayer.playNotification(
              looping: true, asAlarm: tone.overridesSilentMode);
        case PhoneAlertTone.customFile:
          final path = _customPath;
          if (path == null) return;
          final player = _filePlayer ??= AudioPlayer();
          await player.setReleaseMode(ReleaseMode.loop);
          await player.play(DeviceFileSource(path), ctx: _alarmContext);
      }
    } catch (e) {
      debugPrint('PhoneRingerService: playback failed: $e');
      _lastError = 'The phone could not play that sound.';
      notifyListeners();
    }
  }

  /// Stops every noise-making thing, whatever was running.
  ///
  /// Both players are stopped unconditionally rather than only the one believed
  /// to be playing. Stopping an idle player is free; leaving a ringtone going
  /// because the tone was changed mid-ring is not.
  Future<void> _silence() async {
    try {
      await _systemPlayer.stop();
    } catch (e) {
      debugPrint('PhoneRingerService: system stop failed: $e');
    }
    try {
      await _filePlayer?.stop();
    } catch (e) {
      debugPrint('PhoneRingerService: file stop failed: $e');
    }
    await _stopVibration();
  }

  Future<void> _startVibration() async {
    if (!_audioSupported) return;
    try {
      if (!await Vibration.hasVibrator()) return;
      // `repeat: 0` restarts the pattern from its first entry, so this runs until
      // cancelled rather than buzzing once.
      await Vibration.vibrate(pattern: _vibratePattern, repeat: 0);
    } catch (e) {
      debugPrint('PhoneRingerService: vibrate failed: $e');
    }
  }

  Future<void> _stopVibration() async {
    if (!_audioSupported) return;
    try {
      await Vibration.cancel();
    } catch (e) {
      debugPrint('PhoneRingerService: vibrate cancel failed: $e');
    }
  }

  Future<void> _releaseFilePlayer() async {
    final player = _filePlayer;
    if (player == null) return;
    _filePlayer = null;
    try {
      await player.dispose();
    } catch (e) {
      debugPrint('PhoneRingerService: player dispose failed: $e');
    }
  }

  /// Whether this build has real audio and haptics behind it.
  ///
  /// The plugins have no web implementation, and the app is developed partly in
  /// Chrome. Guarding here means the Settings section still renders and still
  /// remembers a choice on web; it simply says so instead of throwing.
  bool get _audioSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  void clearError() {
    if (_lastError.isEmpty) return;
    _lastError = '';
    notifyListeners();
  }

  @override
  void dispose() {
    _capTimer?.cancel();
    _previewTimer?.cancel();
    // Fire-and-forget: dispose cannot await, and a phone left ringing after the
    // app is torn down is the one outcome worth risking an unawaited future for.
    unawaited(_silence());
    unawaited(_releaseFilePlayer());
    super.dispose();
  }
}
