import 'package:flutter/foundation.dart';

import '../../core/auth/passkey_store.dart';
import '../../core/auth/portal_exceptions.dart';
import '../../core/refresh/silent_refresh.dart';
import '../../core/time_format.dart';
import 'academic_api.dart';
import 'academic_models.dart';
import 'academic_store.dart';

/// 学业概览的全局状态：学习页卡片订阅它。
///
/// 生命周期：后台预加载时可先 [ensureCacheLoaded] 仅读本地缓存，进入可见态
/// 时再 [ensureStarted]（缓存不是今天拉的才自动拉一次），之后在用户手动刷新
/// 或门户绑定变化时请求。
class AcademicController extends ChangeNotifier {
  AcademicController._()
    : _readCache = AcademicStore.read,
      _saveCache = AcademicStore.save,
      _fetch = AcademicApi.fetchSummary,
      _bindingCheck = _hasPortalBinding;

  /// 测试使用独立实例，避免请求学校接口或修改真实缓存。
  @visibleForTesting
  AcademicController.forTesting({
    required this._readCache,
    required this._saveCache,
    required this._fetch,
    required this._bindingCheck,
  });

  static Future<bool> _hasPortalBinding() async =>
      await PasskeyStore.read() != null;

  final Future<AcademicSummary?> Function() _readCache;
  final Future<void> Function(AcademicSummary) _saveCache;
  final Future<AcademicSummary> Function() _fetch;
  final Future<bool> Function() _bindingCheck;

  static final AcademicController instance = AcademicController._();

  AcademicSummary? _summary;
  bool _loading = false;
  String? _error;
  bool _portalBound = true;
  bool _cacheLoaded = false;
  Future<void>? _loadingCache;
  bool _started = false;
  Future<void>? _starting;
  Future<void>? _refreshing;
  int _bindingGeneration = 0;

  AcademicSummary? get summary => _summary;
  bool get loading => _loading;

  /// 最近一次刷新失败的原因，成功后清空。
  String? get error => _error;

  /// 门户未绑定时拉不到数据，卡片改成引导去绑定。
  bool get portalBound => _portalBound;

  /// 仅读取本地缓存并检查门户绑定状态，不发起远端网络请求；重复调用只会执行一次。
  Future<void> ensureCacheLoaded() {
    if (_cacheLoaded) return _loadingCache ?? Future.value();
    _cacheLoaded = true;
    return _loadingCache = _loadCacheAndBinding();
  }

  /// 读本地缓存，缓存过了自然天才自动刷新一次；重复调用只会执行一次。
  Future<void> ensureStarted() {
    if (_started) return _starting ?? Future.value();
    _started = true;
    return _starting = _start();
  }

  /// 测试用：重置控制器状态并使在途异步操作失效，避免测试间状态泄漏。
  @visibleForTesting
  void debugReset() {
    _bindingGeneration++;
    _summary = null;
    _loading = false;
    _error = null;
    _portalBound = true;
    _cacheLoaded = false;
    _loadingCache = null;
    _started = false;
    _starting = null;
    _refreshing = null;
  }

  Future<void> _readInitialCache(int generation) async {
    final cached = await _readCache();
    if (generation != _bindingGeneration) return;
    _summary = cached;
    notifyListeners();
  }

  Future<void> _loadCacheAndBinding() async {
    final generation = _bindingGeneration;
    await _readInitialCache(generation);
    if (generation != _bindingGeneration) return;
    final bound = await _bindingCheck();
    if (generation != _bindingGeneration) return;
    _portalBound = bound;
    notifyListeners();
  }

  Future<void> _start() async {
    final generation = _bindingGeneration;
    await ensureCacheLoaded();
    if (generation != _bindingGeneration) return;
    final cached = _summary;
    if (_portalBound && (cached == null || !isFetchedToday(cached.fetchedAt))) {
      await _runRefresh();
    }
  }

  /// 绑定或更换凭据后强制刷新；解绑仅更新状态，已有缓存保留。
  Future<void> onPortalBindingChanged(bool bound) async {
    final generation = ++_bindingGeneration;
    _portalBound = bound;
    _error = null;
    _loading = bound;
    if (!_cacheLoaded) {
      _cacheLoaded = true;
      _loadingCache = _readInitialCache(generation);
    }
    if (!_started) {
      _started = true;
      _starting = _loadingCache;
    }
    notifyListeners();
    if (!bound) return;
    await _loadingCache;
    if (generation != _bindingGeneration) return;
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
  }) {
    if (_refreshing case final current?) return SilentRefresh.join(current);
    final generation = _bindingGeneration;
    late final Future<void> task;
    task = SilentRefresh.track(
      () =>
          _refresh(
            generation,
            checkBinding: checkBinding,
            userInitiated: userInitiated,
          ).whenComplete(() {
            if (identical(_refreshing, task)) _refreshing = null;
          }),
    );
    _refreshing = task;
    return SilentRefresh.join(task);
  }

  Future<void> _refresh(
    int generation, {
    required bool checkBinding,
    bool userInitiated = false,
  }) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      if (checkBinding) {
        final bound = await _bindingCheck();
        if (generation != _bindingGeneration) {
          SilentRefresh.skipCurrent();
          return;
        }
        _portalBound = bound;
      }
      if (!_portalBound) {
        SilentRefresh.skipCurrent(reason: 'not_bound');
        return;
      }
      await SilentRefresh.run(
        'academic.controller',
        action: () async {
          final summary = await _fetch();
          if (generation != _bindingGeneration) {
            SilentRefresh.skipCurrent();
            return;
          }
          await _saveCache(summary);
          if (generation != _bindingGeneration) {
            SilentRefresh.skipCurrent();
            return;
          }
          _summary = summary;
        },
        userInitiated: userInitiated,
        fields: {'has_cache': _summary != null},
      );
    } on PortalCredentialError catch (e) {
      SilentRefresh.failCurrent();
      // 凭据失效必须让用户重新绑定：这条提示不能跟着其他失败一起静默掉。
      if (generation == _bindingGeneration) _error = e.message;
    } catch (_) {
      SilentRefresh.failCurrent();
      // 其余失败（网络、登录跳转、解析）已由 SilentRefresh 重试并写日志，
      // 界面上不再展示失败文案（issue #31）。
    } finally {
      if (generation == _bindingGeneration) {
        _loading = false;
        notifyListeners();
      }
    }
  }
}
