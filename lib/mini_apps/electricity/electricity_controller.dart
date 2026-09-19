import 'package:flutter/foundation.dart';

import '../../core/auth/passkey_store.dart';
import '../../core/auth/portal_exceptions.dart';
import 'electricity_api.dart';
import 'electricity_models.dart';
import 'electricity_store.dart';

/// 电费的全局状态：首页卡片和详情页共用一份，刷新、换宿舍两边同步更新。
///
/// 生命周期：首页卡片首次挂载时 [ensureStarted]（读缓存 → 自动拉一次），
/// 之后只在用户手动刷新或换宿舍时再请求。
class ElectricityController extends ChangeNotifier {
  ElectricityController._();

  static final ElectricityController instance = ElectricityController._();

  static const lowKwhThreshold = 10.0;

  ElecRoom? _room;
  ElecReading? _latest;
  bool _loading = false;
  String? _error;
  bool _portalBound = true;
  bool _started = false;
  Future<void>? _starting;

  ElecRoom? get room => _room;
  ElecReading? get latest => _latest;
  bool get loading => _loading;

  /// 最近一次刷新失败的原因，成功后清空。
  String? get error => _error;

  /// 门户未绑定时电费拉不到，卡片改成引导去绑定。
  bool get portalBound => _portalBound;

  bool get isLow => (_latest?.kwh ?? double.infinity) < lowKwhThreshold;

  /// 余额为负即欠费，比 [isLow] 更严重，UI 上优先展示。
  bool get isOverdue => (_latest?.kwh ?? double.infinity) < 0;

  /// 读本地缓存并自动刷新一次；重复调用只会执行一次。
  Future<void> ensureStarted() {
    if (_started) return _starting ?? Future.value();
    _started = true;
    return _starting = _start();
  }

  Future<void> _start() async {
    _room = await ElectricityStore.readRoom();
    if (_room != null) _latest = await ElectricityStore.latest(_room!);
    _portalBound = await PasskeyStore.read() != null;
    notifyListeners();
    if (_room != null && _portalBound) await refresh();
  }

  Future<void> refresh() async {
    final room = _room;
    if (room == null || _loading) return;
    _portalBound = await PasskeyStore.read() != null;
    if (!_portalBound) {
      notifyListeners();
      return;
    }
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final kwh = await ElectricityApi.queryBalance(room);
      final reading = ElecReading(time: DateTime.now(), kwh: kwh);
      await ElectricityStore.appendReading(room, reading);
      // 拉取期间用户可能换了宿舍，那这次结果就不该盖到新宿舍头上。
      if (identical(_room, room)) _latest = reading;
    } on PortalException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = '刷新失败：$e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> bindRoom(ElecRoom room) async {
    await ElectricityStore.saveRoom(room);
    _room = room;
    _latest = await ElectricityStore.latest(room);
    _error = null;
    notifyListeners();
    await refresh();
  }

  Future<List<ElecReading>> history() {
    final room = _room;
    if (room == null) return Future.value(const []);
    return ElectricityStore.readHistory(room);
  }
}
