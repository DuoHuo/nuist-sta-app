import 'package:flutter/foundation.dart';

import '../../core/auth/passkey_store.dart';
import '../../core/auth/portal_exceptions.dart';
import '../../core/refresh/silent_refresh.dart';
import '../../core/time_format.dart';
import 'student_info_api.dart';
import 'student_info_models.dart';
import 'student_info_store.dart';

/// 学生卡（身份 + 学期）的全局状态：学习页头部卡片订阅它。
///
/// 生命周期与 AcademicController 一致：卡片首次挂载时 [ensureStarted]
/// （读缓存 → 缓存不是今天拉的才自动拉一次），之后在手动刷新或门户绑定变化时请求。
class StudentInfoController extends ChangeNotifier {
  StudentInfoController._()
    : _readCache = StudentInfoStore.read,
      _saveCache = StudentInfoStore.save,
      _fetch = StudentInfoApi.fetch,
      _bindingCheck = _hasPortalBinding;

  /// 测试使用独立实例，避免请求学校接口或修改真实缓存。
  @visibleForTesting
  StudentInfoController.forTesting({
    required this._readCache,
    required this._saveCache,
    required this._fetch,
    required this._bindingCheck,
  });

  static Future<bool> _hasPortalBinding() async =>
      await PasskeyStore.read() != null;

  final Future<StudentInfo?> Function() _readCache;
  final Future<void> Function(StudentInfo) _saveCache;
  final Future<StudentInfo> Function() _fetch;
  final Future<bool> Function() _bindingCheck;

  static final StudentInfoController instance = StudentInfoController._();

  StudentInfo? _info;
  bool _loading = false;
  String? _error;
  bool _portalBound = true;
  bool _started = false;
  Future<void>? _starting;
  Future<void>? _refreshing;
  int _bindingGeneration = 0;

  StudentInfo? get info => _info;
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
    _info = cached;
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
    final cached = _info;
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
        'student_info.controller',
        action: () async {
          final info = await _fetch();
          if (generation != _bindingGeneration) return;
          await _saveCache(info);
          if (generation != _bindingGeneration) return;
          _info = info;
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
