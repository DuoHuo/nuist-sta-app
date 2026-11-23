import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// 为首页、学习和我的保留固定导航器，并协调窗口内的返回目标。
class AppNavigationController extends ChangeNotifier {
  AppNavigationController() {
    _rootObserver = _PaneObserver(this);
    _branchObservers = List.generate(3, (_) => _PaneObserver(this));
  }

  /// 全局提示使用的导航器。
  final rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'app-root');

  /// 三个分支的导航器键在窗口尺寸变化时保持不变。
  final branchNavigatorKeys = List.generate(
    3,
    (index) => GlobalKey<NavigatorState>(debugLabel: 'app-pane-$index'),
  );

  late final _PaneObserver _rootObserver;
  late final List<_PaneObserver> _branchObservers;

  /// 全局导航栈观察器。
  NavigatorObserver get rootObserver => _rootObserver;

  /// 三个分支分别使用独立的观察器。
  List<NavigatorObserver> get branchObservers => _branchObservers;
  final _locations = <int, RouteMatchList>{};
  GoRouter? _router;
  int _activeIndex = 0;
  int _focusedIndex = 0;
  bool? _wide;
  bool _returnHomeAfterDetail = false;
  List<int> _visible = [0];
  NavigatorState? _gestureNavigator;
  Completer<void>? _gestureEnd;
  int? _pendingIndex;
  bool _notificationScheduled = false;
  bool _disposed = false;

  /// 当前路由所属的分支。
  int get activeIndex => _activeIndex;

  /// 手势及其恢复动画期间冻结返回目标和导航操作。
  bool get gestureInProgress => _gestureNavigator != null;

  /// 新导航等待当前手势取消或完成，避免插入正在返回的栈。
  Future<void> get gestureFinished =>
      _gestureEnd?.future ?? Future<void>.value();

  /// 固定路由树创建后连接路由器，不随布局重新创建。
  void attach(GoRouter router) {
    _router = router;
    router.routerDelegate.addListener(_rememberLocation);
  }

  int? _branchOf(RouteMatchList location) {
    int? index;
    void visit(List<RouteMatchBase> matches) {
      for (final match in matches) {
        if (match is ShellRouteMatch) {
          final candidate = branchNavigatorKeys.indexOf(match.navigatorKey);
          if (candidate >= 0) {
            index = candidate;
            return;
          }
          visit(match.matches);
        }
      }
    }

    visit(location.matches);
    return index;
  }

  void _rememberLocation() {
    final location = _router!.routerDelegate.currentConfiguration;
    final index = _branchOf(location);
    if (index != null) {
      _locations[index] = location;
      if (_activeIndex != index) _focusedIndex = index;
      _activeIndex = index;
    }
    _notifyLater();
  }

  /// 同步所属分支后再跳转，避免另一栏的导航栈被 push 或 pop 修改。
  void activate(int index) {
    if (_gestureNavigator != null &&
        _gestureNavigator != branchNavigatorKeys[index].currentState) {
      return;
    }
    _pendingIndex = null;
    _focusedIndex = index;
    final router = _router;
    if (router == null || _activeIndex == index) return;
    _rememberLocation();
    // 本应用没有异步 redirect/onExit，restore 经 SynchronousFuture 同步更新
    // delegate。保存完整 match list，连同 extra 和 push 的返回 Future 一起恢复。
    final location =
        _locations[index] ??
        router.configuration.findMatch(
          Uri.parse(['/', '/study', '/profile'][index]),
        );
    router.restore(location);
    _rememberLocation();
  }

  /// 底部入口切换；返回组合入口时恢复两个分支的原状态。
  void showBranch(int index) {
    if (_gestureNavigator != null) return;
    _returnHomeAfterDetail = false;
    activate(index);
    _notifyLater();
  }

  /// 点击或聚焦面板时记录最近操作栏。
  void interact(int index) {
    if (!_visible.contains(index)) return;
    activate(index);
  }

  /// 分支中是否存在详情页（普通对话框不改变底栏布局）。
  bool hasDetails(int index) => _branchObservers[index].hasDetails;

  /// 可见分支或全局弹层需要处理返回时，由 Flutter 接管 Android 系统返回。
  bool get canHandleBack =>
      _rootObserver.hasRouteAboveRoot || _backBranch != null;

  /// 分支是否实际可见，用于首页公告等编排。
  bool isVisible(int index) => _visible.contains(index);

  /// 更新布局，返回窄屏需要显示的分支；只变矩形，不替换导航器。
  int updateLayout({required bool wide}) {
    var index = _activeIndex;
    if (_gestureNavigator != null) {
      final target = branchNavigatorKeys.indexWhere(
        (key) => key.currentState == _gestureNavigator,
      );
      if (target >= 0) index = target;
      // 手势中可以调整矩形，但保留开始前的宽窄状态。
      // 结束后再应用收窄落点，避免学习详情退出后停留在学习根页。
      _visible = wide && index != 2 ? [0, 1] : [index];
      return index;
    } else if (_wide == true && !wide && index != 2) {
      final detail = [
        _focusedIndex,
        _activeIndex,
        0,
        1,
      ].where((i) => i != 2 && hasDetails(i)).firstOrNull;
      index = detail ?? 0;
      _returnHomeAfterDetail = detail != null;
      _activateAfterFrame(index);
    } else if (!wide &&
        _returnHomeAfterDetail &&
        index != 2 &&
        !hasDetails(index)) {
      index = 0;
      _returnHomeAfterDetail = false;
      _activateAfterFrame(0);
    }
    if (wide) _returnHomeAfterDetail = false;
    _wide = wide;
    _visible = wide && index != 2 ? [0, 1] : [index];
    return index;
  }

  void _activateAfterFrame(int index) {
    if (index == _activeIndex) return;
    _pendingIndex = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || _pendingIndex != index) return;
      activate(index);
    });
  }

  int? get _backBranch {
    final order = <int>{_focusedIndex, _activeIndex, ..._visible};
    for (final index in order) {
      if (_visible.contains(index) && _branchObservers[index].canHandleBack) {
        return index;
      }
    }
    return null;
  }

  /// 仅返回目标栏允许启动页面手势；隐藏栏和被全局弹层遮挡的栏不抢手势。
  bool isBackTarget(NavigatorState navigator) {
    if (_gestureNavigator != null) return _gestureNavigator == navigator;
    if (_rootObserver.hasRouteAboveRoot) {
      return rootNavigatorKey.currentState == navigator;
    }
    final index = _backBranch;
    return index != null &&
        branchNavigatorKeys[index].currentState == navigator;
  }

  /// 手势开始时同步路由并冻结目标，直到取消或完成的动画结束。
  void beginGesture(NavigatorState navigator) {
    if (_gestureNavigator != null) return;
    final index = branchNavigatorKeys.indexWhere(
      (key) => key.currentState == navigator,
    );
    if (index >= 0) activate(index);
    _gestureNavigator = navigator;
    _gestureEnd = Completer<void>();
  }

  void _endGesture(NavigatorState? navigator) {
    if (_gestureNavigator == navigator) {
      _gestureNavigator = null;
      final completion = _gestureEnd;
      _gestureEnd = null;
      completion?.complete();
      _notifyLater();
    }
  }

  /// 系统返回依次交给全局弹层、最近操作栏和另一可见栏。
  /// maybePop 保留 PopScope、网页历史和地图内部返回的处理顺序。
  Future<bool> handleBack() async {
    if (_rootObserver.hasRouteAboveRoot) {
      return rootNavigatorKey.currentState?.maybePop() ?? false;
    }
    final index = _backBranch;
    if (index == null) return false;
    activate(index);
    return branchNavigatorKeys[index].currentState?.maybePop() ?? false;
  }

  void _notifyLater() {
    if (_disposed || _notificationScheduled) return;
    _notificationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notificationScheduled = false;
      if (!_disposed) notifyListeners();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  void dispose() {
    _disposed = true;
    _gestureEnd?.complete();
    _gestureEnd = null;
    _router?.routerDelegate.removeListener(_rememberLocation);
    super.dispose();
  }
}

class _PaneObserver extends NavigatorObserver {
  _PaneObserver(this.owner);

  final AppNavigationController owner;
  final _routes = <Route<dynamic>>[];

  bool get hasDetails => _routes.skip(1).any((route) => route is PageRoute);

  // go_router 在壳路由上注册的 PopScope 用于保护嵌套栈，并不是全局弹层。
  bool get hasRouteAboveRoot => _routes.length > 1;

  bool get canHandleBack {
    final top = _routes.lastOrNull;
    return _routes.length > 1 ||
        (top?.willHandlePopInternally ?? false) ||
        top?.popDisposition == RoutePopDisposition.doNotPop;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    owner._notifyLater();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    owner._notifyLater();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    owner._notifyLater();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final position = _routes.indexOf(oldRoute!);
    if (position >= 0) {
      if (newRoute == null) {
        _routes.removeAt(position);
      } else {
        _routes[position] = newRoute;
      }
    }
    owner._notifyLater();
  }

  @override
  void didStartUserGesture(
    Route<dynamic> route,
    Route<dynamic>? previousRoute,
  ) {
    owner.beginGesture(navigator!);
  }

  @override
  void didStopUserGesture() => owner._endGesture(navigator);
}

/// 面板尺寸之外的导航上下文：小程序仅依赖 core，无需感知壳。
class AppNavigationScope extends InheritedWidget {
  const AppNavigationScope({
    super.key,
    required this.navigation,
    required this.branch,
    required this.visible,
    required this.wide,
    required super.child,
  });

  final AppNavigationController navigation;
  final int branch;
  final bool visible;
  final bool wide;

  /// 订阅面板可见性。
  static AppNavigationScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppNavigationScope>();

  /// 路由在判断手势时只读取，不登记构建依赖。
  static AppNavigationScope? readOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppNavigationScope>();

  @override
  bool updateShouldNotify(AppNavigationScope oldWidget) =>
      navigation != oldWidget.navigation ||
      branch != oldWidget.branch ||
      visible != oldWidget.visible ||
      wide != oldWidget.wide;
}

/// 保留查询参数、extra 和泛型返回结果的面板导航入口。
abstract final class AppNavigation {
  /// 当前上下文所在面板与路由是否对用户可见，并订阅可见性变化。
  ///
  /// 结合 [AppNavigationScope.visible] 与 [TickerMode]：在后台预加载的页签或被
  /// 上层路由遮挡时返回 `false`，独立宿主（无 [AppNavigationScope]）则仅看
  /// [TickerMode]。适合在 `didChangeDependencies` 中决定是否触发远端刷新。
  static bool isVisibleOf(BuildContext context) {
    final scope = AppNavigationScope.maybeOf(context);
    final tickerEnabled = TickerMode.valuesOf(context).enabled;
    return (scope?.visible ?? true) && tickerEnabled;
  }

  /// 将公开详情路径放入所属分支，独立小程序宿主继续使用原有路径。
  static Future<T?> push<T extends Object?>(
    BuildContext context,
    String location, {
    Object? extra,
  }) {
    final scope = AppNavigationScope.readOf(context);
    if (scope == null) return context.push<T>(location, extra: extra);
    if (scope.navigation.gestureInProgress) {
      return _pushAfterGesture<T>(context, scope, location, extra);
    }
    scope.navigation.activate(scope.branch);
    return context.push<T>(
      locationInBranch(location, scope.branch),
      extra: extra,
    );
  }

  static Future<T?> _pushAfterGesture<T extends Object?>(
    BuildContext context,
    AppNavigationScope scope,
    String location,
    Object? extra,
  ) async {
    final route = ModalRoute.of(context);
    await scope.navigation.gestureFinished;
    if (!context.mounted || (route != null && !route.isCurrent)) return null;
    return push<T>(context, location, extra: extra);
  }

  /// 返回前同步所属分支，直接退出本栏，避免异步结果关闭全局弹层或另一栏。
  static void pop<T extends Object?>(BuildContext context, [T? result]) {
    final scope = AppNavigationScope.readOf(context);
    if (scope != null && scope.navigation.gestureInProgress) {
      unawaited(_popAfterGesture(context, scope, result));
      return;
    }
    if (scope == null) {
      context.pop<T>(result);
      return;
    }
    final previousBranch = scope.navigation.activeIndex;
    scope.navigation.activate(scope.branch);
    try {
      Navigator.of(context).pop<T>(result);
    } finally {
      // 异步保存可能在用户操作另一栏或切到我的之后完成。
      // 本栏栈已同步更新，恢复此前活动分支，不抢走当前页面与返回焦点。
      if (previousBranch != scope.branch) {
        scope.navigation.activate(previousBranch);
      }
    }
  }

  static Future<void> _popAfterGesture<T extends Object?>(
    BuildContext context,
    AppNavigationScope scope,
    T? result,
  ) async {
    final route = ModalRoute.of(context);
    await scope.navigation.gestureFinished;
    if (context.mounted && (route == null || route.isCurrent)) {
      pop<T>(context, result);
    }
  }

  /// 公开路径与内部面板路径间的转换，URI 的其他部分原样保留。
  static String locationInBranch(String location, int branch) {
    final uri = Uri.parse(location);
    if (uri.hasScheme || uri.hasAuthority) return location;
    var path = uri.path;
    for (final prefix in ['/home', '/study', '/profile']) {
      if (path.startsWith('$prefix/')) path = path.substring(prefix.length);
    }
    if (![
      '/apps/',
      '/place/',
      '/portal-bind',
      '/settings',
      '/about',
    ].any((prefix) => path.startsWith(prefix))) {
      return location;
    }
    return uri
        .replace(path: '${['/home', '/study', '/profile'][branch]}$path')
        .toString();
  }
}
