import 'package:flutter_test/flutter_test.dart';
import 'package:nimbus_drive/features/files/data/in_memory_file_repository.dart';
import 'package:nimbus_drive/features/files/files_controller.dart';
import 'package:nimbus_drive/features/files/models/drive_item.dart';
import 'package:nimbus_drive/features/home/home_controller.dart';

InMemoryFileRepository _repo() =>
    InMemoryFileRepository(latency: Duration.zero);

Future<HomeController> _controller() async {
  final c = HomeController(_repo());
  await Future<void>.delayed(Duration.zero);
  return c;
}

void main() {
  group('summary', () {
    test('storage used is the sum of every file, at any depth', () async {
      final repo = _repo();
      final summary = await repo.summary();

      expect(summary.storageUsed, greaterThan(0));
      expect(
        summary.storageUsed,
        summary.bytesByType.values.fold<int>(0, (a, b) => a + b),
        reason: 'the breakdown must account for every stored byte',
      );
    });

    test('omits categories with nothing in them', () async {
      final summary = await _repo().summary();
      expect(summary.bytesByType.values.every((v) => v > 0), isTrue);
    });

    test('recent is newest-first and respects the limit', () async {
      final summary = await _repo().summary(recentLimit: 3);

      expect(summary.recent, hasLength(3));
      for (var i = 1; i < summary.recent.length; i++) {
        expect(
          summary.recent[i - 1].updatedAt.isBefore(summary.recent[i].updatedAt),
          isFalse,
        );
      }
    });

    test('used fraction stays within 0..1', () async {
      final summary = await _repo().summary();
      expect(summary.usedFraction, inInclusiveRange(0, 1));
    });
  });

  group('controller', () {
    test('offers only categories the drive actually contains', () async {
      final c = await _controller();

      expect(c.availableTypes, isNotEmpty);
      expect(
        c.availableTypes.every((t) => c.summary!.bytesByType.containsKey(t)),
        isTrue,
        reason: 'a filter that can only return nothing is not worth a tap',
      );
    });

    test('filtering recent narrows to one category', () async {
      final c = await _controller();
      final type = c.recent.first.type;

      c.setRecentFilter(type);
      expect(c.recent, isNotEmpty);
      expect(c.recent.every((f) => f.type == type), isTrue);
    });

    test('tapping the selected chip clears back to all', () async {
      final c = await _controller();
      final all = c.recent.length;

      c.setRecentFilter(FileType.image);
      c.setRecentFilter(FileType.image);

      expect(c.recentFilter, isNull);
      expect(c.recent, hasLength(all));
    });
  });

  group('cross-tab navigation', () {
    test('showOnly resets to the root with a single type filter', () async {
      final files = FilesController(_repo());
      await Future<void>.delayed(Duration.zero);

      // Walk into a folder first, so the reset is doing real work.
      files.open(files.items.whereType<DriveFolder>().first);
      await Future<void>.delayed(Duration.zero);
      expect(files.isRoot, isFalse);

      files.showOnly(FileType.image);
      await Future<void>.delayed(Duration.zero);

      expect(files.isRoot, isTrue, reason: 'a category spans the whole drive');
      expect(files.query.types, {FileType.image});
      expect(
        files.items.whereType<DriveFile>().every(
          (f) => f.type == FileType.image,
        ),
        isTrue,
      );
    });

    test('showOnly(null) clears the filter', () async {
      final files = FilesController(_repo());
      await Future<void>.delayed(Duration.zero);

      files.showOnly(FileType.video);
      await Future<void>.delayed(Duration.zero);
      expect(files.query.types, isNotEmpty);

      files.showOnly(null);
      await Future<void>.delayed(Duration.zero);
      expect(files.query.types, isEmpty);
    });
  });
}
