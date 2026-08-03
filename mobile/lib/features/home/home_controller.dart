import 'package:flutter/foundation.dart';

import '../files/data/file_repository.dart';
import '../files/models/drive_item.dart';

/// State for the Home screen.
class HomeController extends ChangeNotifier {
  HomeController(this._repository) {
    load();
  }

  final FileRepository _repository;

  DriveSummary? _summary;
  FileType? _recentFilter;
  bool _loading = true;
  String? _error;

  DriveSummary? get summary => _summary;
  bool get loading => _loading;
  String? get error => _error;

  /// Null means "All".
  FileType? get recentFilter => _recentFilter;

  /// The chip row only offers types the drive actually contains — a filter
  /// that can only ever return nothing is not worth a tap.
  List<FileType> get availableTypes {
    final types = _summary?.bytesByType.keys.toList() ?? const <FileType>[];
    return types..sort((a, b) => a.index.compareTo(b.index));
  }

  List<DriveFile> get recent {
    final all = _summary?.recent ?? const <DriveFile>[];
    if (_recentFilter == null) return all;
    return all.where((f) => f.type == _recentFilter).toList();
  }

  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      // Enough rows that filtering by type still leaves something to show.
      _summary = await _repository.summary(recentLimit: 12);
    } catch (e) {
      _error = '$e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Tapping the selected chip clears it, so "All" is always one tap away.
  void setRecentFilter(FileType? type) {
    _recentFilter = _recentFilter == type ? null : type;
    notifyListeners();
  }
}
