import 'package:flutter/foundation.dart';

import '../../core/auth/passkey_store.dart';
import '../../core/auth/portal_exceptions.dart';
import '../../core/logging/app_log.dart';
import '../../core/time_format.dart';
import 'score_api.dart';
import 'score_models.dart';
import 'score_store.dart';

/// 成绩查询的全局状态：学习页卡片与成绩详情页共用一份数据。
class ScoreController extends ChangeNotifier {
  ScoreController._()
    : _readCache = ScoreStore.read,
      _saveCache = ScoreStore.save,
      _fetch = ScoreApi.fetch,
      _bindingCheck = _hasPortalBinding;

  /// 测试使用独立实例，避免请求学校接口或修改真实缓存。
  @visibleForTesting
  ScoreController.forTesting({
    required this._readCache,
    required this._saveCache,
    required this._fetch,
    required this._bindingCheck,
  });

  static Future<bool> _hasPortalBinding() async =>
      await PasskeyStore.read() != null;

  final Future<ScoreReport?> Function() _readCache;
  final Future<void> Function(ScoreReport) _saveCache;
  final Future<ScoreReport> Function() _fetch;
  final Future<bool> Function() _bindingCheck;

  static final ScoreController instance = ScoreController._();
  static final _log = AppLog.logger('score.controller');

  ScoreReport? _report;
  bool _loading = false;
  String? _error;
  bool _portalBound = true;
  bool _started = false;
  Future<void>? _starting;
  Future<void>? _refreshing;
  int _bindingGeneration = 0;

  ScoreReport? get report => _report;
  bool get loading => _loading;
  String? get error => _error;
  bool get portalBound => _portalBound;

  Future<void> ensureStarted() {
    if (_started) return _starting ?? Future.value();
    _started = true;
    return _starting = _start();
  }

  Future<void> _readInitialCache(int generation) async {
    final cached = await _readCache();
    if (generation != _bindingGeneration) return;
    _report = cached;
    notifyListeners();
  }

  Future<void> _start() async {
    final generation = _bindingGeneration;
    await _readInitialCache(generation);
    if (generation != _bindingGeneration) return;
    final bound = await _bindingCheck();
    if (generation != _bindingGeneration) return;
    _portalBound = bound;
    notifyListeners();
    final cached = _report;
    if (_portalBound && (cached == null || !isFetchedToday(cached.fetchedAt))) {
      await refresh();
    }
  }

  /// 绑定或更换凭据后强制刷新；解绑仅更新状态，已有缓存保留。
  Future<void> onPortalBindingChanged(bool bound) async {
    final generation = ++_bindingGeneration;
    _portalBound = bound;
    _error = null;
    _loading = bound;
    if (!_started) {
      _started = true;
      _starting = _readInitialCache(generation);
    }
    notifyListeners();
    if (!bound) return;
    await _starting;
    if (generation != _bindingGeneration) return;
    // 旧请求及其写盘先结束，避免旧账号结果覆盖这次绑定后的数据。
    await _refreshing;
    if (generation != _bindingGeneration) return;
    await _runRefresh(checkBinding: false);
  }

  /// 手动刷新合并在途请求；绑定变化会等待旧请求后另行刷新。
  Future<void> refresh() => _runRefresh();

  Future<void> _runRefresh({bool checkBinding = true}) => _refreshing ??=
      _refresh(_bindingGeneration, checkBinding: checkBinding).whenComplete(() {
        _refreshing = null;
      });

  Future<void> _refresh(int generation, {required bool checkBinding}) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      if (checkBinding) {
        final bound = await _bindingCheck();
        if (generation != _bindingGeneration) return;
        _portalBound = bound;
      }
      if (!_portalBound) return;
      await _log.operation('refresh', () async {
        final report = await _fetch();
        if (generation != _bindingGeneration) return;
        await _saveCache(report);
        if (generation != _bindingGeneration) return;
        _report = report;
      });
    } on PortalException catch (e) {
      if (generation == _bindingGeneration) _error = e.message;
    } catch (e) {
      if (generation == _bindingGeneration) _error = '刷新失败：$e';
    } finally {
      if (generation == _bindingGeneration) {
        _loading = false;
        notifyListeners();
      }
    }
  }
}
