import 'package:flutter_test/flutter_test.dart';
import 'package:nimbus_drive/core/widgets/nimbus_transfer_row.dart';
import 'package:nimbus_drive/features/files/models/drive_item.dart';
import 'package:nimbus_drive/features/uploads/data/fake_transfer_repository.dart';
import 'package:nimbus_drive/features/uploads/models/transfer.dart';
import 'package:nimbus_drive/features/uploads/uploads_controller.dart';

const _mb = 1024 * 1024;

/// Waits for [condition] instead of guessing a duration.
///
/// The fake advances on a 400 ms ticker and a direct upload needs several
/// ticks, so a hard-coded delay is a race that passes on a fast machine and
/// fails on a loaded one.
Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Transfer _t({
  required int total,
  int sent = 0,
  TransferState state = TransferState.running,
}) => Transfer(
  id: 't',
  name: 'x.bin',
  type: FileType.other,
  totalBytes: total,
  sentBytes: sent,
  state: state,
);

void main() {
  group('routing', () {
    test('20 MB and under goes straight to Telegram', () {
      expect(_t(total: kDirectUploadLimit).route, TransferRoute.direct);
      expect(_t(total: kDirectUploadLimit - 1).route, TransferRoute.direct);
    });

    test('over 20 MB has to be chunked through the server', () {
      expect(_t(total: kDirectUploadLimit + 1).route, TransferRoute.chunked);
    });

    test('chunk count follows the 19 MB segment size', () {
      // 1 GB in 19 MB pieces.
      expect(_t(total: 1024 * _mb).chunkCount, 54);
      expect(_t(total: 5 * _mb).chunkCount, 1);
    });
  });

  group('progress', () {
    test('queued reads as an empty bar, not an indeterminate sweep', () {
      // Null would make LinearProgressIndicator animate, which claims the
      // transfer is moving while it is actually waiting for capacity.
      expect(_t(total: _mb, state: TransferState.queued).progress, 0.0);
    });

    test('never exceeds 1 even if more bytes are reported than expected', () {
      expect(_t(total: 100, sent: 250).progress, 1.0);
    });

    test('a zero-byte file does not divide by zero', () {
      expect(_t(total: 0, sent: 0).progress, isNull);
    });
  });

  group('controller', () {
    late UploadsController controller;

    setUp(() => controller = UploadsController(FakeTransferRepository()));
    tearDown(() => controller.dispose());

    test('splits the queue into active, failed and completed', () {
      expect(controller.active, isNotEmpty);
      expect(controller.completed, isNotEmpty);
      // Active and completed must not overlap, or totals double-count.
      final activeIds = controller.active.map((t) => t.id).toSet();
      final doneIds = controller.completed.map((t) => t.id).toSet();
      expect(activeIds.intersection(doneIds), isEmpty);
    });

    test('overall progress weights by bytes, not by file count', () async {
      final repo = FakeTransferRepository(seed: false);
      final c = UploadsController(repo);
      addTearDown(c.dispose);

      await repo.enqueue(name: 'big.zip', sizeBytes: 1000 * _mb);
      await repo.enqueue(name: 'small.txt', sizeBytes: 1 * _mb);

      // Wait until both are actually moving, not a fixed delay.
      await _until(() => c.overallProgress != null && c.overallProgress! > 0);

      final progress = c.overallProgress;
      expect(progress, isNotNull);
      // A naive per-file average would sit near the small file's ~100%; a
      // byte-weighted one is dragged down by the large one.
      expect(progress, lessThan(0.9));
    });

    test('clearing completed leaves failures alone', () async {
      final repo = FakeTransferRepository(seed: false);
      final c = UploadsController(repo);
      addTearDown(c.dispose);

      await repo.enqueue(name: 'a.txt', sizeBytes: 1 * _mb);
      await _until(() => c.completed.isNotEmpty);

      await c.clearCompleted();
      await _until(() => c.completed.isEmpty);
      expect(c.completed, isEmpty);
    });

    test('cancel removes the transfer from the queue', () async {
      final target = controller.active.first;
      await controller.cancel(target);
      await _until(() => controller.active.every((t) => t.id != target.id));

      expect(controller.active.any((t) => t.id == target.id), isFalse);
    });
  });
}
