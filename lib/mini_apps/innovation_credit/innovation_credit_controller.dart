import 'package:flutter/foundation.dart';

import '../../core/auth/passkey_store.dart';
import '../../core/auth/portal_exceptions.dart';
import '../../core/time_format.dart';
import 'innovation_credit_api.dart';
import 'innovation_credit_models.dart';
import 'innovation_credit_store.dart';

/// 双创学分的全局状态：学习页卡片和详情页共用一份。
///
/// 生命周期与 AcademicController 一致：卡片首次挂载时 [ensureStarted]
/// （读缓存 → 缓存不是今天拉的才自动拉一次），之后只在用户手动刷新时再请求。
class InnovationCreditController extends ChangeNotifier {
  InnovationCreditController._();

  static final InnovationCreditController instance =
      InnovationCreditController._();

  InnovationCredit? _credit;
  bool _loading = false;
  String? _error;
  bool _portalBound = true;
  bool _started = false;
  Future<void>? _starting;

  InnovationCredit? get credit => _credit;
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

  Future<void> _start() async {
    _credit = await InnovationCreditStore.read();
    _portalBound = await PasskeyStore.read() != null;
    notifyListeners();
    // 今天已经拉到过就只展示缓存，跨了自然天（或从没拉到过）才自动刷新。
    final cached = _credit;
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
      final credit = await InnovationCreditApi.fetch();
      await InnovationCreditStore.save(credit);
      _credit = credit;
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
