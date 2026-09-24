import 'package:flutter/foundation.dart';

import '../../core/auth/passkey_store.dart';
import '../../core/auth/portal_exceptions.dart';
import '../../core/time_format.dart';
import 'score_api.dart';
import 'score_models.dart';
import 'score_store.dart';

/// 成绩查询的全局状态：学习页卡片与成绩详情页共用一份数据。
class ScoreController extends ChangeNotifier {
  ScoreController._();

  static final ScoreController instance = ScoreController._();

  ScoreReport? _report;
  bool _loading = false;
  String? _error;
  bool _portalBound = true;
  bool _started = false;
  Future<void>? _starting;

  ScoreReport? get report => _report;
  bool get loading => _loading;
  String? get error => _error;
  bool get portalBound => _portalBound;

  Future<void> ensureStarted() {
    if (_started) return _starting ?? Future.value();
    _started = true;
    return _starting = _start();
  }

  Future<void> _start() async {
    _report = await ScoreStore.read();
    _portalBound = await PasskeyStore.read() != null;
    notifyListeners();
    final cached = _report;
    if (_portalBound && (cached == null || !isFetchedToday(cached.fetchedAt))) {
      await refresh();
    }
  }

  Future<void> refresh() async {
    if (_loading) return;
    _portalBound = await PasskeyStore.read() != null;
    if (!_portalBound) {
      notifyListeners();
      return;
    }
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final report = await ScoreApi.fetch();
      await ScoreStore.save(report);
      _report = report;
    } on PortalException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = '刷新失败：$e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }
}
