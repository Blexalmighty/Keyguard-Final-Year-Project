/// The alert cadences the keyholder can sound.
///
/// **Why these are patterns and not ringtones.** The buzzer on the keyholder is
/// an *active* 3 V element: it contains its own oscillator, so it has exactly one
/// pitch and the only thing the firmware controls is whether current is flowing.
/// `digitalWrite(HIGH)` and `digitalWrite(LOW)` are the entire instrument.
/// `tone()` drives a *passive* buzzer by generating a square wave and does
/// nothing useful here — which is already written down in the hardware notes as a
/// mistake that cost debugging time once.
///
/// So a menu offering "Chime / Bell / Marimba" would be a menu of names for one
/// sound. What genuinely differs is rhythm, and rhythm is what makes a beep
/// findable: a long continuous tone is easy to localise in an open room, a fast
/// triple-beep cuts through conversation, and a slow single pip is what you want
/// when the keys are in a bag in a lecture hall and you would rather not
/// announce it.
///
/// Each pattern is defined by three numbers the firmware can act on directly.
/// The app sends the *name*, not the numbers, so that a future firmware revision
/// can retune a pattern without the app needing to agree about milliseconds.
enum AlertPattern {
  /// Unbroken tone. Loudest and easiest to walk towards.
  continuous(
    wireName: 'CONT',
    label: 'Continuous',
    description: 'One unbroken tone. Easiest to walk towards in an open room.',
    onMs: 60000,
    gapMs: 0,
    burst: 1,
    pauseMs: 0,
  ),

  /// The default. A quarter second on, a quarter off — audible without being
  /// frantic.
  steady(
    wireName: 'STEADY',
    label: 'Steady beep',
    description: 'A short beep twice a second. The default.',
    onMs: 250,
    gapMs: 0,
    burst: 1,
    pauseMs: 250,
  ),

  /// Three quick beeps, then a gap. Cuts through background noise because the
  /// ear notices the rhythm rather than the tone.
  triple(
    wireName: 'TRIPLE',
    label: 'Triple pulse',
    description: 'Three quick beeps, then a pause. Carries through noise.',
    onMs: 90,
    gapMs: 80,
    burst: 3,
    pauseMs: 700,
  ),

  /// Rapid chirping. Highest urgency; also the fastest to drain the cell.
  urgent(
    wireName: 'URGENT',
    label: 'Urgent chirp',
    description: 'Rapid chirping. Most attention-getting, hardest on battery.',
    onMs: 60,
    gapMs: 0,
    burst: 1,
    pauseMs: 60,
  ),

  /// One short pip every two seconds. For finding keys without telling the room
  /// you have lost them.
  discreet(
    wireName: 'DISCREET',
    label: 'Discreet pip',
    description: 'One short pip every two seconds. Quiet places, lecture halls.',
    onMs: 70,
    gapMs: 0,
    burst: 1,
    pauseMs: 2000,
  ),

  /// LED only. The buzzer stays silent.
  ///
  /// Not the same thing as switching the alert off: the red LED on GPIO 4 still
  /// flashes, so the keyholder is findable in a dark bag or a quiet room where a
  /// buzzer would be rude.
  silent(
    wireName: 'SILENT',
    label: 'Flash only',
    description: 'LED flashes, buzzer stays silent. Still findable in the dark.',
    onMs: 400,
    gapMs: 0,
    burst: 1,
    pauseMs: 400,
  );

  const AlertPattern({
    required this.wireName,
    required this.label,
    required this.description,
    required this.onMs,
    required this.gapMs,
    required this.burst,
    required this.pauseMs,
  });

  /// The token sent over BLE as `ALERT_SET:<wireName>`. Short on purpose — the
  /// frame has to fit comfortably even if MTU negotiation lands low.
  final String wireName;

  final String label;
  final String description;

  /// Milliseconds the buzzer is driven high per beep.
  final int onMs;

  /// Milliseconds of silence *between* the beeps of a burst. Zero when [burst]
  /// is 1, since there is nothing to sit between.
  final int gapMs;

  /// Beeps per burst. `1` for a plain on/off cycle.
  final int burst;

  /// Milliseconds of silence *after* a completed burst, before it repeats.
  ///
  /// Separate from [gapMs] because the two are what distinguish a rhythm from a
  /// stream of evenly spaced beeps: [triple] is three fast beeps and a rest, not
  /// six beeps at one spacing.
  final int pauseMs;

  bool get isSilent => this == AlertPattern.silent;

  /// A one-line summary of the rhythm, for the settings row.
  ///
  /// Derived from the numbers rather than written out by hand so the caption can
  /// never disagree with what the firmware will actually do.
  String get cadence {
    if (this == AlertPattern.continuous) return 'unbroken';
    final beeps = burst == 1 ? '${onMs}ms' : '$burst × ${onMs}ms';
    return '$beeps, ${pauseMs}ms gap';
  }

  static const AlertPattern fallback = AlertPattern.steady;

  /// Parse a stored or received token. Unknown values fall back to [fallback]
  /// rather than throwing: a preference written by a newer build of the app, or a
  /// pattern a future firmware drops, must not stop the alert working.
  static AlertPattern fromWireName(String? value) {
    if (value == null) return fallback;
    for (final p in AlertPattern.values) {
      if (p.wireName == value) return p;
    }
    return fallback;
  }
}
