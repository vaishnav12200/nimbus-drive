import 'package:flutter_test/flutter_test.dart';
import 'package:nimbus_drive/core/utils/formatters.dart';

void main() {
  group('formatBytes', () {
    test('keeps raw bytes below a kilobyte', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(999), '999 B');
    });

    test('steps up units at 1024', () {
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(1024 * 1024 * 1024), '1.0 GB');
    });

    test('drops the decimal at three digits, where it is only noise', () {
      expect(formatBytes(432013312), '412 MB');
      expect(formatBytes(5033164), '4.8 MB');
    });

    test('saturates at the largest unit rather than overflowing the table', () {
      expect(formatBytes(1024 * 1024 * 1024 * 1024 * 5), '5.0 TB');
    });
  });

  group('formatWhen', () {
    final now = DateTime(2026, 8, 3, 14, 30);

    test('shows the time for today', () {
      expect(formatWhen(DateTime(2026, 8, 3, 9, 5), now: now), '09:05');
    });

    test('names yesterday rather than dating it', () {
      expect(formatWhen(DateTime(2026, 8, 2, 23, 59), now: now), 'Yesterday');
    });

    test('omits the year while it matches', () {
      expect(formatWhen(DateTime(2026, 7, 30), now: now), 'Jul 30');
    });

    test('adds the year once it differs', () {
      expect(formatWhen(DateTime(2025, 7, 30), now: now), 'Jul 30, 2025');
    });

    test('compares calendar days, not elapsed hours', () {
      // 20 hours earlier, but a different date — "Yesterday", not a time.
      expect(formatWhen(DateTime(2026, 8, 2, 18), now: now), 'Yesterday');
    });
  });

  group('formatRetryAfter', () {
    test('stays in seconds under a minute', () {
      expect(formatRetryAfter(1), '1 second');
      expect(formatRetryAfter(45), '45 seconds');
    });

    test('rounds minutes up, so the stated wait is never short', () {
      // 1013s is what the server actually returned when registration was
      // rate limited: 16.9 minutes, reported as 17.
      expect(formatRetryAfter(1013), '17 minutes');
      expect(formatRetryAfter(61), '2 minutes');
    });

    test('rolls over to hours', () {
      expect(formatRetryAfter(3600), '1 hour');
      expect(formatRetryAfter(7000), '2 hours');
    });
  });

  group('isProbablyEmail', () {
    test('accepts ordinary addresses', () {
      expect(isProbablyEmail('you@example.com'), isTrue);
      expect(isProbablyEmail('  a.b+tag@sub.example.co.uk '), isTrue);
    });

    test('rejects a domain with no dot', () {
      // The shape that produced a 422 from the server: the client should have
      // caught it without spending a registration attempt.
      expect(isProbablyEmail('vaishnav@gmail'), isFalse);
    });

    test('rejects malformed shapes', () {
      for (final bad in [
        '',
        'nope',
        '@example.com',
        'a@',
        'a@.com',
        'a@b.',
        'a@b@c.com',
        'a b@c.com',
      ]) {
        expect(isProbablyEmail(bad), isFalse, reason: bad);
      }
    });
  });
}
