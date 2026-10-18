import 'dart:async';
import 'dart:io' show Platform;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'timetable_controller.dart';

/// 网络「有 / 无」的抽象（便于测试注入），只关心是否有任意连接，不区分 wifi / 移动网络。
abstract class NetworkReachability {
  /// 连接变化：true = 有任意网络，false = 无网络。
  Stream<bool> get onlineChanges;

  /// 当前是否有网络。
  Future<bool> isOnline();
}

/// 基于 connectivity_plus 的实现。
class ConnectivityPlusReachability implements NetworkReachability {
  ConnectivityPlusReachability([Connectivity? connectivity])
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  static bool _anyOnline(List<ConnectivityResult> r) =>
      r.any((e) => e != ConnectivityResult.none);

  @override
  Stream<bool> get onlineChanges =>
      _connectivity.onConnectivityChanged.map(_anyOnline);

  @override
  Future<bool> isOnline() async =>
      _anyOnline(await _connectivity.checkConnectivity());
}

/// 「无网 → 有网」边沿检测（纯逻辑）：只有从无网络变为有网络时 [update] 返回 true；
/// wifi ↔ 移动网络切换（有网 → 有网）、首次得知状态都不算恢复。
class NetworkRestoreDetector {
  bool? _online;

  bool? get online => _online;

  /// 记下初始状态（只在还不知道状态时生效，不触发恢复）。
  void seed(bool online) => _online ??= online;

  bool update(bool online) {
    final was = _online;
    _online = online;
    return was == false && online;
  }
}

/// App 层课表同步时机接线（第 7 条 AS）：
/// - 挂载时（冷启动）调用一次 [TimetableController.onAppStart]；
/// - 回到前台（[AppLifecycleState.resumed]）调用 [TimetableController.onAppResumed]；
/// - 网络从无到有时调用 [TimetableController.onNetworkRestored]（节流与「只补一次」由
///   controller 决定）。
/// 登录成功的同步（[TimetableController.onLoginSucceeded]）由门户绑定页
/// （portal_status_page）在绑定 / 导入通行密钥成功后调用，不在这里接。
class TimetableLifecycleScope extends StatefulWidget {
  const TimetableLifecycleScope({
    super.key,
    required this.child,
    this.controller,
    this.reachability,
    this.onAppStart,
    this.onAppResumed,
    this.onNetworkRestored,
  });

  final Widget child;

  /// 为空时用 [TimetableController.instance]。
  final TimetableController? controller;

  /// 测试可替换的三个触发点；为空时调用 [controller] 的同名方法。
  final Future<bool> Function()? onAppStart;
  final Future<bool> Function()? onAppResumed;
  final Future<bool> Function()? onNetworkRestored;

  /// 为空时用 [ConnectivityPlusReachability]；在 `flutter test` 里（没有平台插件）
  /// 不注入则不监听网络。
  final NetworkReachability? reachability;

  @override
  State<TimetableLifecycleScope> createState() =>
      _TimetableLifecycleScopeState();
}

class _TimetableLifecycleScopeState extends State<TimetableLifecycleScope>
    with WidgetsBindingObserver {
  final _detector = NetworkRestoreDetector();
  StreamSubscription<bool>? _sub;

  TimetableController get _ctl =>
      widget.controller ?? TimetableController.instance;

  /// 同步触发失败（如平台通道不可用）不应冒泡成未处理异常。
  static void _fire(Future<bool> Function() call) {
    try {
      unawaited(call().catchError((Object _) => false));
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fire(widget.onAppStart ?? _ctl.onAppStart);
    final reach = widget.reachability ?? _defaultReachability();
    if (reach == null) return;
    try {
      _sub = reach.onlineChanges.listen((online) {
        if (_detector.update(online)) {
          _fire(widget.onNetworkRestored ?? _ctl.onNetworkRestored);
        }
      }, onError: (Object _) {});
      unawaited(
        reach.isOnline().then(_detector.seed).catchError((Object _) {}),
      );
    } catch (_) {
      // 平台不支持连接监听：只是少了网络恢复补同步。
    }
  }

  static NetworkReachability? _defaultReachability() {
    if (!kIsWeb && Platform.environment.containsKey('FLUTTER_TEST')) {
      return null;
    }
    return ConnectivityPlusReachability();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _fire(widget.onAppResumed ?? _ctl.onAppResumed);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
