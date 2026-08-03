import 'package:flutter_test/flutter_test.dart';
import 'package:nimbus_drive/features/files/models/drive_item.dart';
import 'package:nimbus_drive/features/shared/data/share_repository.dart';
import 'package:nimbus_drive/features/shared/models/share_link.dart';
import 'package:nimbus_drive/features/shared/shares_controller.dart';

ShareLink _link({
  String id = 'l',
  Duration? expiresIn,
  int? maxDownloads,
  int downloads = 0,
}) => ShareLink(
  id: id,
  token: 'abcd1234',
  fileName: 'file.pdf',
  fileType: FileType.document,
  fileSize: 1024,
  createdAt: DateTime.now(),
  expiresAt: expiresIn == null ? null : DateTime.now().add(expiresIn),
  maxDownloads: maxDownloads,
  downloadCount: downloads,
);

Future<SharesController> _controller() async {
  final c = SharesController(InMemoryShareRepository(latency: Duration.zero));
  await Future<void>.delayed(Duration.zero);
  return c;
}

void main() {
  group('link state', () {
    test('no expiry and no cap stays alive', () {
      expect(_link().isDead, isFalse);
    });

    test('a past expiry is dead', () {
      expect(_link(expiresIn: const Duration(days: -1)).isDead, isTrue);
    });

    test('hitting the download cap is dead too', () {
      // The server answers SHARE_EXPIRED for both, so the UI treats them alike.
      final link = _link(maxDownloads: 5, downloads: 5);
      expect(link.isExhausted, isTrue);
      expect(link.isDead, isTrue);
    });

    test('under the cap and in date is alive', () {
      final link = _link(
        expiresIn: const Duration(days: 3),
        maxDownloads: 10,
        downloads: 9,
      );
      expect(link.isDead, isFalse);
    });

    test('url is built from the token', () {
      expect(_link().url, endsWith('/s/abcd1234'));
    });
  });

  group('controller', () {
    test('no filter shows everything', () async {
      final c = await _controller();
      expect(c.filter, isNull);
      expect(c.links.length, greaterThan(1));
    });

    test('filters split into live and dead, covering every link', () async {
      final c = await _controller();
      final total = c.links.length;

      expect(
        c.countFor(ShareFilter.active) + c.countFor(ShareFilter.expired),
        total,
      );
    });

    test('the active filter hides dead links', () async {
      final c = await _controller();
      c.setFilter(ShareFilter.active);
      expect(c.links.every((l) => !l.isDead), isTrue);
    });

    test('tapping the selected filter again clears it', () async {
      final c = await _controller();

      c.setFilter(ShareFilter.expired);
      expect(c.filter, ShareFilter.expired);

      c.setFilter(ShareFilter.expired);
      expect(c.filter, isNull, reason: 'there must be a way back to all');
    });

    test('revoking removes the link', () async {
      final c = await _controller();
      final target = c.links.first;

      await c.revoke(target);
      expect(c.links.any((l) => l.id == target.id), isFalse);
    });
  });
}
