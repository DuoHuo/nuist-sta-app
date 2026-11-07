import 'package:flutter/foundation.dart';

import '../../core/auth/passkey_store.dart';
import '../../core/auth/portal_exceptions.dart';
import '../../core/refresh/silent_refresh.dart';
import '../../core/time_format.dart';
import 'labor_score_api.dart';
import 'labor_score_models.dart';
import 'labor_score_store.dart';

/// 劳动积分的全局状态：学习页卡片和详情页共用一份。
///
/// 生命周期与 AcademicController 一致：卡片首次挂载时 [ensureStarted]
/// （读缓存 → 缓存不是今天拉的才自动拉一次），之后在手动刷新或门户绑定变化时请求。
class LaborScoreController extends ChangeNotifier {
  LaborScoreController._()
    : _readCache = LaborScoreStore.read,
      _saveCache = LaborScoreStore.save,
      _fetch = LaborScoreApi.fetch,
      _bindingCheck = _hasPortalBinding;

  /// 测试使用独立实例，避免请求学校接口或修改真实缓存。
  @visibleForTesting
  LaborScoreController.forTesting({
    required this._readCache,
    required this._saveCache,
    required this._fetch,
    required this._bindingCheck,
  });

  static Future<bool> _hasPortalBinding() async =>
      await PasskeyStore.read() != null;

  final Future<LaborScore?> Function() _readCache;
  final Future<void> Function(LaborScore) _saveCache;
  final Future<LaborScore> Function() _fetch;
  final Future<bool> Function() _bindingCheck;

  static final LaborScoreController instance = LaborScoreController._();

  LaborScore? _score;
  bool _loading = false;
  String? _error;
  bool _portalBound = true;
  bool _started = false;
  Future<void>? _starting;
  Future<void>? _refreshing;
  int _bindingGeneration = 0;

  LaborScore? get score => _score;
  bool get loading => _loading;

  /// 最近一次刷新失败的原因，成功后清空。
  String? get error => _error;

  /// 门户未绑定时拉不到数据，卡片改成引导去绑定。
  bool get portalBound => _portalBound;

  /// 读本地缓存，缓存过了自然天才自动刷新一次；重复调用只会执行一次。
  Future<void> ensureStarted() {
    if (_started) return _starting ?? Future.value();
    _started = true;
    return _starting = _start();
  }

  Future<void> _readInitialCache(int generation) async {
    final cached = await _readCache();
    if (generation != _bindingGeneration) return;
    _score = cached;
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
    final cached = _score;
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
    _error = null;
    notifyListeners();
    try {
      if (checkBinding) {
        final bound = await _bindingCheck();
        if (generation != _bindingGeneration) return;
        _portalBound = bound;
      }
      if (!_portalBound) return;
      await SilentRefresh.run(
        'labor_score.controller',
        action: () async {
          final score = await _fetch();
          if (generation != _bindingGeneration) return;
          await _saveCache(score);
          if (generation != _bindingGeneration) return;
          _score = score;
        },
        userInitiated: userInitiated,
      );
    } on PortalCredentialError catch (e) {
      // 凭据失效必须让用户重新绑定：这条提示不能跟着其他失败一起静默掉。
      if (generation == _bindingGeneration) _error = e.message;
    } catch (_) {
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
