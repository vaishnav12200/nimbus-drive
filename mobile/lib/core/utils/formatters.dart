/// Display formatting for sizes and dates.
///
/// Deliberately dependency-free. `intl` would give correct localisation, but
/// it is a real decision (message catalogues, locale negotiation, a build step)
/// and the app is English-only today. These are the two formats a file list
/// needs; swapping in `intl` later means rewriting this file and nothing else.
library;

const _units = ['B', 'KB', 'MB', 'GB', 'TB'];

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Bytes as "2.4 MB".
///
/// Binary steps (1024) with decimal labels, which is what file managers show
/// and therefore what a user comparing this to their desktop expects. One
/// decimal place below 100, none above — "412 MB" reads better than
/// "412.3 MB", and the extra digit is noise at that magnitude.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';

  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < _units.length - 1) {
    value /= 1024;
    unit++;
  }

  final digits = value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${_units[unit]}';
}

/// A wait, as an error message should state it: "45 seconds", "17 minutes".
///
/// `RATE_LIMITED` and `FLOOD_WAIT` both carry `details.retry_after`. Showing
/// "slow down" without the number leaves the only sensible next action —
/// waiting — indistinguishable from the app being broken, so people keep
/// tapping and extend the very window they are stuck in.
String formatRetryAfter(int seconds) {
  if (seconds < 60) return '$seconds second${seconds == 1 ? '' : 's'}';

  // Rounded up: telling someone 17 minutes when it is 17.5 invites one more
  // rejected attempt.
  final minutes = (seconds / 60).ceil();
  if (minutes < 60) return '$minutes minute${minutes == 1 ? '' : 's'}';

  final hours = (minutes / 60).ceil();
  return '$hours hour${hours == 1 ? '' : 's'}';
}

/// Whether [value] is plausibly an email address.
///
/// Deliberately loose — the server's validator is the authority and rejects
/// far more than this. It exists to catch the shapes that are obviously wrong
/// ("me@gmail", no dot after the @) *before* a round trip, because on
/// `/auth/register` a wasted attempt also spends part of a 5-per-hour budget.
bool isProbablyEmail(String value) {
  final trimmed = value.trim();
  final at = trimmed.indexOf('@');
  if (at <= 0 || at != trimmed.lastIndexOf('@')) return false;

  final domain = trimmed.substring(at + 1);
  final dot = domain.indexOf('.');
  // A dot that is neither first nor last: "a@b.c" passes, "a@.com" and
  // "a@b." do not.
  return dot > 0 && dot < domain.length - 1 && !trimmed.contains(' ');
}

/// A timestamp as a file list shows it: "14:32" today, "Yesterday", "Jul 30",
/// "Jul 30, 2025" once the year differs.
///
/// The resolution drops as the date recedes because that is the order in which
/// the information stops mattering — the minute a file changed is interesting
/// today and noise next month.
String formatWhen(DateTime when, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final date = DateTime(when.year, when.month, when.day);
  final reference = DateTime(today.year, today.month, today.day);
  final daysAgo = reference.difference(date).inDays;

  if (daysAgo == 0) {
    final h = when.hour.toString().padLeft(2, '0');
    final m = when.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
  if (daysAgo == 1) return 'Yesterday';

  final month = _months[when.month - 1];
  if (when.year == today.year) return '$month ${when.day}';
  return '$month ${when.day}, ${when.year}';
}
