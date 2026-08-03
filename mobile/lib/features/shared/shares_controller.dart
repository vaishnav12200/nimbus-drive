import 'package:flutter/foundation.dart';

import 'data/share_repository.dart';
import 'models/share_link.dart';

enum ShareFilter {
  active('Active'),
  expired('Expired');

  const ShareFilter(this.label);

  final String label;
}

class SharesController extends ChangeNotifier {
  SharesController(this._repository) {
    load();
  }

  final ShareRepository _repository;

  List<ShareLink> _all = const [];
  ShareFilter? _filter;
  bool _loading = true;
  String? _error;

  bool get loading => _loading;
  String? get error => _error;
  ShareFilter? get filter => _filter;

  /// Null filter means everything.
  List<ShareLink> get links => switch (_filter) {
    null => _all,
    ShareFilter.active => _all.where((l) => !l.isDead).toList(),
    ShareFilter.expired => _all.where((l) => l.isDead).toList(),
  };

  int countFor(ShareFilter filter) => switch (filter) {
    ShareFilter.active => _all.where((l) => !l.isDead).length,
    ShareFilter.expired => _all.where((l) => l.isDead).length,
  };

  bool get hasAny => _all.isNotEmpty;

  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      _all = await _repository.list();
    } catch (e) {
      _error = '$e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void setFilter(ShareFilter filter) {
    // Tapping the active filter again clears it, so there is always a way back
    // to everything without a third chip.
    _filter = _filter == filter ? null : filter;
    notifyListeners();
  }

  Future<void> revoke(ShareLink link) async {
    await _repository.revoke(link.id);
    await load();
  }
}
