import 'package:hermes_android/core/l10n/l10n.dart';
import 'package:intl/intl.dart';

/// Compact relative time shared by conversation rows and activity lists.
///
/// The Gateway timestamps are seconds since the epoch; `now` is injectable
/// so window boundaries stay deterministic in widget tests.
///
/// With [l10n] the result is in the person's language ("5 мин", "2 ч", "3 д",
/// "12 окт"). Without it the original English short form is kept, for callers
/// that have no localizations at hand.
String formatRelativeTime(
  DateTime now,
  double lastActiveSeconds, {
  AppLocalizations? l10n,
}) {
  final activity = DateTime.fromMillisecondsSinceEpoch(
    (lastActiveSeconds * 1000).round(),
  );
  final elapsed = now.difference(activity);
  if (elapsed.inMinutes < 1) return l10n?.time_short_now ?? 'now';
  if (elapsed.inHours < 1) {
    return l10n?.time_short_minutes(elapsed.inMinutes) ??
        '${elapsed.inMinutes}m';
  }
  if (elapsed.inDays < 1) {
    return l10n?.time_short_hours(elapsed.inHours) ?? '${elapsed.inHours}h';
  }
  if (elapsed.inDays < 7) {
    return l10n?.time_short_days(elapsed.inDays) ?? '${elapsed.inDays}d';
  }
  if (l10n != null) {
    try {
      return DateFormat.MMMd(l10n.localeName).format(activity);
    } catch (_) {
      // No date symbols for this locale: fall through to the numeric form.
    }
  }
  return '${activity.day}/${activity.month}';
}
