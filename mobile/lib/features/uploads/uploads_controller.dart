import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/widgets/nimbus_transfer_row.dart';
import 'data/transfer_repository.dart';
import 'models/transfer.dart';

/// State for the Upload screen.
class UploadsController extends ChangeNotifier {
  UploadsController(this._repository) {
    _transfers = _repository.current;
    _subscription = _repository.watch().listen((transfers) {
      _transfers = transfers;
      notifyListeners();
    });
  }

  final TransferRepository _repository;
  late final StreamSubscription<List<Transfer>> _subscription;

  List<Transfer> _transfers = const [];

  /// Where new uploads land. Null is the drive root.
  String destination = 'Nimbus';

  List<Transfer> get active =>
      _transfers.where((t) => t.isActive).toList(growable: false);

  List<Transfer> get failed => _transfers
      .where((t) => t.state == TransferState.failed)
      .toList(growable: false);

  List<Transfer> get completed => _transfers
      .where((t) => t.state == TransferState.done)
      .toList(growable: false);

  bool get isEmpty => _transfers.isEmpty;

  /// Combined progress across everything still moving, for the header summary.
  ///
  /// Weighted by bytes rather than by count: two files at 50% is not the same
  /// as a 1 GB file at 50% and a 2 MB file at 50%.
  double? get overallProgress {
    final moving = active.where((t) => t.state != TransferState.queued);
    if (moving.isEmpty) return null;

    final total = moving.fold<int>(0, (sum, t) => sum + t.totalBytes);
    if (total == 0) return null;

    final sent = moving.fold<int>(0, (sum, t) => sum + t.sentBytes);
    return sent / total;
  }

  int get activeCount => active.length;

  Future<void> cancel(Transfer t) => _repository.cancel(t.id);
  Future<void> retry(Transfer t) => _repository.retry(t.id);
  Future<void> pause(Transfer t) => _repository.pause(t.id);
  Future<void> resume(Transfer t) => _repository.resume(t.id);
  Future<void> clearCompleted() => _repository.clearCompleted();

  /// Stands in for the platform file picker, which arrives with the real
  /// upload pipeline. Sizes straddle the 20 MB line so both routes appear.
  Future<void> pickFiles() {
    const samples = [
      ('holiday-clip.mp4', 340),
      ('scan-0042.pdf', 3),
      ('album-master.wav', 210),
      ('screenshot.png', 2),
      ('project-export.zip', 780),
    ];
    final pick = samples[Random().nextInt(samples.length)];
    return _repository.enqueue(name: pick.$1, sizeBytes: pick.$2 * 1024 * 1024);
  }

  @override
  void dispose() {
    _subscription.cancel();
    _repository.dispose();
    super.dispose();
  }
}
