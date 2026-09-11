/// What the *phone* plays when the button on the keyholder is pressed.
///
/// Not to be confused with [AlertPattern] in `alert_pattern.dart`, which is the
/// cadence the *keyholder's* buzzer beeps in when you press Ring in the app. The
/// two directions of the alert are separate settings because they are separate
/// speakers with completely different capabilities:
///
/// | | keyholder → buzzer | phone → speaker |
/// |---|---|---|
/// | pitch | one, fixed by the oscillator | anything |
/// | source | a rhythm in firmware | a real audio file |
/// | picked in | [AlertPattern] | this enum |
///
/// So the keyholder can only vary rhythm, while the phone can play whatever the
/// owner wants — which is why this one really is a ringtone menu and that one is
/// not.
library;

/// A phone-side ringtone choice.
enum PhoneAlertTone {
  /// The phone's own default ringtone — whatever the owner set in Android's
  /// Sound settings. The obvious default: it is already a sound they recognise
  /// as "my phone", and it needs no file and no permission.
  systemRingtone(
    wireName: 'RINGTONE',
    label: 'Phone ringtone',
    description: 'Your normal incoming-call ringtone.',
    needsFile: false,
    overridesSilentMode: true,
  ),

  /// The system alarm sound. Deliberately offered separately: alarm tones are
  /// designed to be unpleasant and to cut through, which is the right choice for
  /// a phone that is genuinely lost rather than merely mislaid.
  systemAlarm(
    wireName: 'ALARM',
    label: 'Alarm sound',
    description: 'The system alarm tone. Harsher, and hardest to sleep through.',
    needsFile: false,
    overridesSilentMode: true,
  ),

  /// The short notification chime. For an owner who wants the ping to be
  /// findable but not embarrassing in a lecture hall.
  systemNotification(
    wireName: 'NOTIFICATION',
    label: 'Notification chime',
    description: 'A soft repeated chime. Stays quiet if your phone is silenced.',
    needsFile: false,
    overridesSilentMode: false,
  ),

  /// An audio file the owner picked from storage. The path is kept in settings;
  /// see `PhoneRingerService.pickCustomTone` for why the file is copied rather
  /// than referenced where it was found.
  customFile(
    wireName: 'CUSTOM',
    label: 'From my storage',
    description: 'Any song or sound on this phone.',
    needsFile: true,
    overridesSilentMode: true,
  );

  const PhoneAlertTone({
    required this.wireName,
    required this.label,
    required this.description,
    required this.needsFile,
    required this.overridesSilentMode,
  });

  /// Stored in `shared_preferences` as this token rather than as the enum index,
  /// for the same reason [AlertPattern] does: an index silently starts pointing
  /// at a different tone the first time someone reorders the enum.
  final String wireName;

  final String label;
  final String description;

  /// Whether choosing this tone requires a file to have been picked. The UI uses
  /// it to know that selecting the option must open the picker first, and the
  /// ringer uses it to fall back rather than play silence if the file is gone.
  final bool needsFile;

  /// Whether the sound is played on Android's **alarm** stream, which is audible
  /// even when the phone is on silent.
  ///
  /// This is the difference between a feature that works and one that only works
  /// when you did not need it: a phone lost down the side of a sofa is very often
  /// a phone that was silenced in a lecture. The three loud options therefore go
  /// out as alarms. The notification chime deliberately does not — an owner who
  /// picks "discreet" is asking to be discreet, and it would be dishonest for the
  /// quiet option to blare through silent mode anyway.
  final bool overridesSilentMode;

  /// Used when nothing is stored, and when a custom file has vanished.
  ///
  /// The system ringtone, not the alarm: the fallback should be the least
  /// startling of the options, because it is the one that fires when the app
  /// does not actually know what the owner wanted.
  static const PhoneAlertTone fallback = PhoneAlertTone.systemRingtone;

  static PhoneAlertTone fromWireName(String? value) {
    if (value == null) return fallback;
    for (final tone in PhoneAlertTone.values) {
      if (tone.wireName == value) return tone;
    }
    return fallback;
  }
}
