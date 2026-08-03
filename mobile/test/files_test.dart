import 'package:flutter_test/flutter_test.dart';
import 'package:nimbus_drive/features/files/data/file_repository.dart';
import 'package:nimbus_drive/features/files/data/in_memory_file_repository.dart';
import 'package:nimbus_drive/features/files/files_controller.dart';
import 'package:nimbus_drive/features/files/models/drive_item.dart';
import 'package:nimbus_drive/features/files/models/file_query.dart';

/// No artificial latency: these assert behaviour, not timing.
InMemoryFileRepository _repo() =>
    InMemoryFileRepository(latency: Duration.zero);

/// Settles the load the constructor kicks off.
Future<FilesController> _controller() async {
  final controller = FilesController(_repo());
  await Future<void>.delayed(Duration.zero);
  return controller;
}

void main() {
  group('listing', () {
    test('folders lead the list in both sort directions', () async {
      final repo = _repo();

      for (final order in SortOrder.values) {
        final listing = await repo.list(
          query: FileQuery(sort: FileSort.name, order: order),
        );
        final firstFile = listing.items.indexWhere((i) => i is DriveFile);
        final lastFolder = listing.items.lastIndexWhere(
          (i) => i is DriveFolder,
        );

        expect(
          lastFolder,
          lessThan(firstFile),
          reason: 'reversing $order must not bury folders below files',
        );
      }
    });

    test('sorting by size largest-first actually orders by size', () async {
      final listing = await _repo().list(
        query: const FileQuery(
          sort: FileSort.size,
          order: SortOrder.descending,
        ),
      );

      final sizes = listing.items.whereType<DriveFile>().map((f) => f.size);
      expect(
        sizes.toList(),
        orderedEquals(sizes.toList()..sort((a, b) => b - a)),
      );
    });

    test(
      'a type filter hides other files but keeps folders reachable',
      () async {
        final listing = await _repo().list(
          query: const FileQuery(types: {FileType.image}),
        );

        expect(listing.items.whereType<DriveFolder>(), isNotEmpty);
        expect(
          listing.items.whereType<DriveFile>().every(
            (f) => f.type == FileType.image,
          ),
          isTrue,
        );
      },
    );

    test('search is case-insensitive on the name', () async {
      final listing = await _repo().list(
        query: const FileQuery(search: 'ARCHITECTURE'),
      );

      expect(listing.items, hasLength(1));
      expect(listing.items.single.name, contains('architecture'));
    });

    test('breadcrumbs run root-first to the current folder', () async {
      final repo = _repo();
      final listing = await repo.list(
        folderId: 'f-design-old',
        query: const FileQuery(),
      );

      expect(listing.breadcrumbs.map((f) => f.name), [
        'Design assets',
        'Archive 2025',
      ]);
    });

    test('the root listing has no breadcrumbs', () async {
      final listing = await _repo().list(query: const FileQuery());
      expect(listing.breadcrumbs, isEmpty);
      expect(listing.folder, isNull);
    });
  });

  group('mutations', () {
    test('renaming onto a sibling name is refused', () async {
      final repo = _repo();
      await expectLater(
        repo.rename('a2', 'Q3 architecture review.pdf'),
        throwsA(isA<DuplicateName>()),
      );
    });

    test('the same name in a different folder is fine', () async {
      final repo = _repo();
      await repo.rename('d1', 'roadmap.xlsx'); // exists at the root, not here
      final listing = await repo.list(
        folderId: 'f-design',
        query: const FileQuery(),
      );
      expect(listing.items.any((i) => i.name == 'roadmap.xlsx'), isTrue);
    });

    test('sharing an encrypted file is refused', () async {
      await expectLater(
        _repo().createShareLink('a1'),
        throwsA(isA<ShareNotAllowed>()),
      );
    });

    test('deleting a folder takes its contents with it', () async {
      final repo = _repo();
      await repo.delete('f-design');

      final children = await repo.list(
        folderId: 'f-design',
        query: const FileQuery(),
      );
      expect(children.items, isEmpty);
    });
  });

  group('controller', () {
    test('opening a folder clears filters carried from the parent', () async {
      final controller = await _controller();

      // Captured before searching: the search narrows folders too, so after it
      // runs there is no folder left in the list to open.
      final folder = controller.items.whereType<DriveFolder>().first;

      controller.search('sunset');
      await Future<void>.delayed(Duration.zero);
      expect(controller.query.search, 'sunset');

      controller.open(folder);
      await Future<void>.delayed(Duration.zero);

      // A search term carried into a new folder hides its contents and looks
      // like an empty folder.
      expect(controller.query.search, isEmpty);
      expect(controller.currentFolderId, folder.id);
    });

    test('re-picking the current sort field flips the direction', () async {
      final controller = await _controller();

      controller.setSort(FileSort.size);
      await Future<void>.delayed(Duration.zero);
      expect(controller.query.order, SortOrder.descending); // largest first

      controller.setSort(FileSort.size);
      await Future<void>.delayed(Duration.zero);
      expect(controller.query.order, SortOrder.ascending);
    });

    test('a superseded load cannot overwrite a newer one', () async {
      // Latency makes the first request finish last, which is exactly the race
      // that leaves stale results on screen.
      final controller = FilesController(
        InMemoryFileRepository(latency: const Duration(milliseconds: 40)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));

      controller.search('sunset');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      controller.search('roadmap');

      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(controller.query.search, 'roadmap');
      expect(controller.items.single.name, 'roadmap.xlsx');
    });

    test('goUp reports false at the root so back can pop the route', () async {
      final controller = await _controller();
      expect(controller.goUp(), isFalse);

      controller.open(controller.items.whereType<DriveFolder>().first);
      await Future<void>.delayed(Duration.zero);
      expect(controller.goUp(), isTrue);
    });

    test(
      'distinguishes an empty folder from one filtered to nothing',
      () async {
        final controller = await _controller();

        controller.search('no-such-file-anywhere');
        await Future<void>.delayed(Duration.zero);

        expect(controller.items, isEmpty);
        expect(controller.isFilteredEmpty, isTrue);
      },
    );
  });
}
