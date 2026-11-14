import 'package:flutter/foundation.dart';

import '../../core/auth/passkey_store.dart';
import '../../core/auth/portal_exceptions.dart';
import '../../core/logging/app_log.dart';
import '../../core/refresh/silent_refresh.dart';
import 'electricity_api.dart';
import 'electricity_models.dart';
import 'electricity_store.dart';

/// 电费的全局状态：首页卡片和详情页共用一份，刷新、换宿舍两边同步更新。
///
/// 生命周期：首页卡片首次挂载时 [ensureStarted]（读缓存 → 自动拉一次），
/// 之后在用户手动刷新、换宿舍或绑定门户后再请求。
class ElectricityController extends ChangeNotifier {
  ElectricityController._({
    Future<bool> Function()? bindingCheck,
    Future<ElecRoom?> Function()? readRoom,
    Future<ElecReading?> Function(ElecRoom room)? readLatest,
    Future<double> Function(ElecRoom room)? queryBalance,
    Future<void> Function(ElecRoom room, ElecReading reading)? appendReading,
  }) : _bindingCheck = bindingCheck ?? _readPortalBound,
       _readRoom = readRoom ?? ElectricityStore.readRoom,
       _readLatest = readLatest ?? ElectricityStore.latest,
       _queryBalance = queryBalance ?? ElectricityApi.queryBalance,
       _appendReading = appendReading ?? ElectricityStore.appendReading;

  /// 注入绑定状态、余额请求与本地缓存，用合成数据验证生命周期。
  @visibleForTesting
  factory ElectricityController.forTesting({
    required Future<bool> Function() bindingCheck,
    required Future<ElecRoom?> Function() readRoom,
    required Future<ElecReading?> Function(ElecRoom room) readLatest,
    required Future<double> Function(ElecRoom room) queryBalance,
    required Future<void> Function(ElecRoom room, ElecReading reading)
    appendReading,
  }) => ElectricityController._(
    bindingCheck: bindingCheck,
    readRoom: readRoom,
    readLatest: readLatest,
    queryBalance: queryBalance,
    appendReading: appendReading,
  );

  static final ElectricityController instance = ElectricityController._();
  static final _log = AppLog.logger('electricity.controller');

  static const lowKwhThreshold = 10.0;

  static Future<bool> _readPortalBound() async =>
      await PasskeyStore.read() != null;

  final Future<bool> Function() _bindingCheck;
  final Future<ElecRoom?> Function() _readRoom;
  final Future<ElecReading?> Function(ElecRoom room) _readLatest;
  final Future<double> Function(ElecRoom room) _queryBalance;
  final Future<void> Function(ElecRoom room, ElecReading reading)
  _appendReading;

  ElecRoom? _room;
  ElecReading? _latest;
  bool _loading = false;
  bool _manualRefreshing = false;
  String? _error;
  bool _portalBound = true;
  Future<void>? _starting;
  Future<void>? _loadingLocal;
  Future<void>? _refreshing;
  int _bindingRevision = 0;

  ElecRoom? get room => _room;
  ElecReading? get latest => _latest;
  bool get loading => _loading;

  /// 是否正在做**用户手动**触发的刷新（页面用它显示按钮加载动画）。
  bool get manualRefreshing => _manualRefreshing;

  /// 最近一次刷新失败的原因，成功后清空。
  String? get error => _error;

  /// 门户未绑定时电费拉不到，卡片改成引导去绑定。
  bool get portalBound => _portalBound;

  bool get isLow => (_latest?.kwh ?? double.infinity) < lowKwhThreshold;

  /// 余额为负即欠费，比 [isLow] 更严重，UI 上优先展示。
  bool get isOverdue => (_latest?.kwh ?? double.infinity) < 0;

  /// 读本地缓存并自动刷新一次；重复调用只会执行一次。
  Future<void> ensureStarted() => _starting ??= _start();

  Future<void> _start() async {
    await _ensureLocalLoaded();
    // 绑定事件自己负责刷新，首次挂载不再重复请求。
    if (_bindingRevision == 0) {
      await _refresh(userInitiated: true, trigger: 'startup');
    }
  }

  Future<void> _ensureLocalLoaded() => _loadingLocal ??= _loadLocal();

  Future<void> _loadLocal() async {
    _room = await _readRoom();
    if (_room != null) _latest = await _readLatest(_room!);
    notifyListeners();
  }

  /// 更新门户绑定状态；解绑保留本地宿舍和历史，重新绑定后立即刷新余额。
  Future<void> onPortalBindingChanged(bool bound) async {
    final revision = ++_bindingRevision;
    _portalBound = bound;
    _error = null;
    notifyListeners();
    await _ensureLocalLoaded();
    if (!bound || revision != _bindingRevision) return;
    // 旧凭据的请求可能仍在返回；等它结束后补一次新请求，不能因 loading 丢掉。
    if (_refreshing case final refreshing?) await refreshing;
    if (revision != _bindingRevision) return;
    await _refresh(knownBinding: bound, trigger: 'binding_changed');
  }

  /// 重读绑定状态并刷新余额；并发调用共用同一次请求。
  Future<void> refresh() => _refresh(userInitiated: true);

  Future<void> _refresh({
    bool? knownBinding,
    bool userInitiated = false,
    String? trigger,
  }) {
    if (_refreshing case final refreshing?) {
      return SilentRefresh.join(refreshing);
    }
    late final Future<void> future;
    future = SilentRefresh.track(
      () =>
          _refreshCurrent(
            knownBinding: knownBinding,
            userInitiated: userInitiated,
            trigger: trigger,
          ).whenComplete(() {
            if (identical(_refreshing, future)) _refreshing = null;
          }),
    );
    _refreshing = future;
    return SilentRefresh.join(future);
  }

  Future<void> _refreshCurrent({
    bool? knownBinding,
    bool userInitiated = false,
    String? trigger,
  }) async {
    final revision = _bindingRevision;
    await _ensureLocalLoaded();
    if (revision != _bindingRevision) {
      SilentRefresh.skipCurrent(reason: 'binding_changed');
      return;
    }
    final bound = knownBinding ?? await _bindingCheck();
    if (revision != _bindingRevision) {
      SilentRefresh.skipCurrent(reason: 'binding_changed');
      return;
    }
    _portalBound = bound;
    final room = _room;
    if (!bound || room == null) {
      SilentRefresh.skipCurrent(
        reason: !bound ? 'not_bound' : 'room_not_selected',
      );
      notifyListeners();
      return;
    }
    _loading = true;
    _manualRefreshing = userInitiated;
    _error = null;
    notifyListeners();
    try {
      final succeeded = await SilentRefresh.run(
        'electricity.controller',
        action: () async {
          final kwh = await _queryBalance(room);
          if (revision != _bindingRevision) {
            SilentRefresh.skipCurrent(reason: 'binding_changed');
            return;
          }
          final reading = ElecReading(time: DateTime.now(), kwh: kwh);
          await _appendReading(room, reading);
          // 拉取期间用户可能换了宿舍，那这次结果就不该盖到新宿舍头上。
          if (revision == _bindingRevision && identical(_room, room)) {
            _latest = reading;
          } else {
            SilentRefresh.skipCurrent(reason: 'selection_changed');
          }
        },
        userInitiated: userInitiated,
        trigger: trigger,
        fields: {'has_cache': _latest != null},
      );
      // 手动刷新失败要给用户一个可见的错误提示，但不暴露原始异常。
      if (!succeeded && userInitiated && revision == _bindingRevision) {
        _error = '刷新失败，请稍后再试';
      }
    } on PortalCredentialError catch (e) {
      SilentRefresh.failCurrent();
      // 凭据失效必须让用户重新绑定：这条提示不能跟着其他失败一起静默掉。
      if (revision == _bindingRevision) _error = e.message;
    } catch (_) {
      SilentRefresh.failCurrent();
      // 其余失败（网络、登录跳转、解析）已由 SilentRefresh 重试并写日志。
    } finally {
      _loading = false;
      _manualRefreshing = false;
      notifyListeners();
    }
  }

  Future<void> bindRoom(ElecRoom room) async {
    await _ensureLocalLoaded();
    await _log.operation('room.bind', () async {
      await ElectricityStore.saveRoom(room);
      _room = room;
      _latest = await _readLatest(room);
      _error = null;
      notifyListeners();
      await refresh();
    });
  }

  Future<List<ElecReading>> history() {
    final room = _room;
    if (room == null) return Future.value(const []);
    return ElectricityStore.readHistory(room);
  }
}
