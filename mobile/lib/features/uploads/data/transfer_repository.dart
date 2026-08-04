import '../models/picked_file.dart';
import '../models/transfer.dart';

/// The upload queue.
///
/// A stream rather than request/response: transfers change on their own
/// schedule — a chunk lands, Telegram rate-limits the bot, the queue moves —
/// and none of that is triggered by the UI asking.
abstract interface class TransferRepository {
  Stream<List<Transfer>> watch();

  /// Current snapshot, for a first frame that does not have to be empty.
  List<Transfer> get current;

  Future<void> enqueue(PickedFile file);

  Future<void> cancel(String id);

  Future<void> retry(String id);

  Future<void> pause(String id);

  Future<void> resume(String id);

  /// Drops finished rows. Failures stay — a failed upload the user has not
  /// seen is not something to tidy away.
  Future<void> clearCompleted();

  void dispose();
}
