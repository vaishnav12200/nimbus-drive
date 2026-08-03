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
}
