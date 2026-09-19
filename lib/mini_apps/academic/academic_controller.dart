import 'package:flutter/foundation.dart';

import '../../core/auth/passkey_store.dart';
import '../../core/auth/portal_exceptions.dart';
import 'academic_api.dart';
import 'academic_models.dart';
import 'academic_store.dart';

/// 学业概览的全局状态：学习页卡片订阅它。
///
/// 生命周期：卡片首次挂载时 [ensureStarted]（读缓存 → 自动拉一次），
/// 之后只在用户手动刷新时再请求。
class AcademicController extends ChangeNotifier {
  AcademicController._();

  static final AcademicController instance = AcademicController._();

  AcademicSummary? _summary;
  bool _loading = false;
  String? _error;
  bool _portalBound = true;
  bool _started = false;
  Future<void>? _starting;

  AcademicSummary? get summary => _summary;
  bool get loading => _loading;

  /// 最近一次刷新失败的原因，成功后清空。
  String? get error => _error;

  /// 门户未绑定时拉不到数据，卡片改成引导去绑定。
  bool get portalBound => _portalBound;

  /// 读本地缓存并自动刷新一次；重复调用只会执行一次。
  Future<void> ensureStarted() {
    if (_started) return _starting ?? Future.value();
    _started = true;
    return _starting = _start();
  }

  Future<void> _start() async {
    _summary = await AcademicStore.read();
    _portalBound = await PasskeyStore.read() != null;
    notifyListeners();
    if (_portalBound) await refresh();
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
      final summary = await AcademicApi.fetchSummary();
      await AcademicStore.save(summary);
      _summary = summary;
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
