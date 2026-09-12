/// How long this phone keeps its own record of where the keyholder has been.
///
/// The event log is a location history: every connect, disconnect and ping is
/// stamped with a position. That is useful for finding your keys and awkward
/// for everything else — a year of it describes the owner's movements, not the
/// keyholder's. So the owner picks how long it survives, and the app deletes
/// the rest without being asked.
///
/// [forever] is offered because "delete my data on a schedule" must be a choice
/// rather than something imposed; it is not the default.
enum HistoryRetention {
  week(7, 'Every week'),
  fortnight(14, 'Every 2 weeks'),
  month(30, 'Every month'),
  forever(0, 'Never');

  const HistoryRetention(this.days, this.label);

  /// How many days of history to keep. Zero means age is never a reason to
  /// delete — the 200-entry cap still applies.
  final int days;

  /// What the settings row says: it completes the sentence "Clear history…".
  final String label;

  bool get prunes => days > 0;

  /// A line describing what this choice does, for the row's subtitle.
  String get description => switch (this) {
        HistoryRetention.week =>
          'Location history older than 7 days is deleted automatically.',
        HistoryRetention.fortnight =>
          'Location history older than 14 days is deleted automatically.',
        HistoryRetention.month =>
          'Location history older than 30 days is deleted automatically.',
        HistoryRetention.forever =>
          'History is kept until you clear it yourself.',
      };

  /// The oldest timestamp worth keeping, measured from [now].
  DateTime? cutoffFrom(DateTime now) =>
      prunes ? now.subtract(Duration(days: days)) : null;

  /// Stored by name so the saved value stays readable and survives reordering
  /// of this enum — an index would silently change meaning.
  String get storageValue => name;

  static HistoryRetention fromStorage(String? value) {
    for (final r in HistoryRetention.values) {
      if (r.name == value) return r;
    }
    // The historical default: nothing was ever deleted on age, because there
    // was no such setting. Existing installs keep that behaviour until asked.
    return HistoryRetention.forever;
  }
}
