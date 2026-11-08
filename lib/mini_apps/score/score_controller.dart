import 'package:flutter/foundation.dart';

import '../../core/auth/passkey_store.dart';
import '../../core/auth/portal_exceptions.dart';
import '../../core/refresh/silent_refresh.dart';
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

  ScoreReport? _report;
  bool _loading = false;
  bool _manualRefreshing = false;
  String? _error;
  bool _portalBound = true;
  bool _started = false;
  Future<void>? _starting;
  Future<void>? _refreshing;
  int _bindingGeneration = 0;

  ScoreReport? get report => _report;
  bool get loading => _loading;

  /// 是否正在做**用户手动**触发的刷新（页面用它显示按钮加载动画）。
  ///
  /// 首屏自动刷新一律不显示动画，避免进入页面就转圈。
  bool get manualRefreshing => _manualRefreshing;
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
  Future<void> refresh() => _runRefresh(userInitiated: true);

  Future<void> _runRefresh({
    bool checkBinding = true,
    bool userInitiated = false,
  }) => _refreshing ??=
      _refresh(
        _bindingGeneration,
        checkBinding: checkBinding,
        userInitiated: userInitiated,
      ).whenComplete(() {
        _refreshing = null;
      });

  Future<void> _refresh(
    int generation, {
    required bool checkBinding,
    bool userInitiated = false,
  }) async {
    _loading = true;
    _manualRefreshing = userInitiated;
    _error = null;
    notifyListeners();
    try {
      if (checkBinding) {
        final bound = await _bindingCheck();
        if (generation != _bindingGeneration) return;
        _portalBound = bound;
      }
      if (!_portalBound) return;
      final succeeded = await SilentRefresh.run(
        'score.controller',
        action: () async {
          final report = await _fetch();
          if (generation != _bindingGeneration) return;
          await _saveCache(report);
          if (generation != _bindingGeneration) return;
          _report = report;
        },
        userInitiated: userInitiated,
      );
      // 手动刷新失败要给用户一个可见的错误提示，但不暴露原始异常。
      if (!succeeded && userInitiated && generation == _bindingGeneration) {
        _error = '刷新失败，请稍后再试';
      }
    } on PortalCredentialError catch (e) {
      // 凭据失效必须让用户重新绑定：这条提示不能跟着其他失败一起静默掉。
      if (generation == _bindingGeneration) _error = e.message;
    } catch (_) {
      // 其余失败（网络、登录跳转、解析）已由 SilentRefresh 重试并写日志，
      // 界面上不再展示失败文案（issue #31）。
    } finally {
      if (generation == _bindingGeneration) {
        _loading = false;
        _manualRefreshing = false;
        notifyListeners();
      }
    }
  }
}
