import 'package:flutter/material.dart';

import 'app_navigation.dart';

/// 普通 Material 页面，保留主题转场并只让返回目标栏接受页面手势。
class AppPage<T> extends MaterialPage<T> {
  const AppPage({
    required super.child,
    super.key,
    super.name,
    super.arguments,
    super.restorationId,
    super.maintainState,
    super.fullscreenDialog,
    super.allowSnapshotting,
    super.canPop,
    super.onPopInvoked,
    this.navigation,
    this.isShellRoot = false,
    this.directLaunch = false,
  });

  final AppNavigationController? navigation;

  /// 壳根页的嵌套返回由协调器处理，隐藏分支不能阻止系统退出。
  final bool isShellRoot;

  /// 系统入口直接展示内容，同时保留退出转场与所属栏的预测性返回。
  final bool directLaunch;

  @override
  Route<T> createRoute(BuildContext context) => _AppPageBasedRoute<T>(this);
}

/// 直接 Navigator.push 的页面也沿用同一返回协调，独立宿主不受影响。
class AppPageRoute<T> extends MaterialPageRoute<T> with _CoordinatedBack<T> {
  AppPageRoute({
    required super.builder,
    super.settings,
    super.requestFocus,
    super.maintainState,
    super.fullscreenDialog,
    super.allowSnapshotting,
    super.barrierDismissible,
  });

  @override
  AppNavigationController? get navigation =>
      AppNavigationScope.readOf(navigator!.context)?.navigation;
}

class _AppPageBasedRoute<T> extends PageRoute<T>
    with MaterialRouteTransitionMixin<T>, _CoordinatedBack<T> {
  _AppPageBasedRoute(AppPage<T> page)
    : super(settings: page, allowSnapshotting: page.allowSnapshotting);

  AppPage<T> get _page => settings as AppPage<T>;

  @override
  AppNavigationController? get navigation =>
      _page.navigation ??
      AppNavigationScope.readOf(navigator!.context)?.navigation;

  @override
  Widget buildContent(BuildContext context) => _page.child;

  @override
  bool get maintainState => _page.maintainState;

  @override
  bool get fullscreenDialog => _page.fullscreenDialog;

  @override
  Duration get transitionDuration =>
      _page.directLaunch ? Duration.zero : super.transitionDuration;

  @override
  Duration get reverseTransitionDuration => _page.directLaunch
      ? const Duration(milliseconds: 300)
      : super.reverseTransitionDuration;

  @override
  RoutePopDisposition get popDisposition {
    // go_router 为所有常驻分支登记 PopScope，包括隐藏的详情栈。
    // 壳根页没有上一级；先由 BackButtonListener 处理可见栏，耗尽后交给系统。
    // 业务表单和全局弹层仍使用各自路由的 PopScope，不经过此例外。
    if (_page.isShellRoot && isFirst) return RoutePopDisposition.bubble;
    return super.popDisposition;
  }
}

mixin _CoordinatedBack<T> on PageRoute<T> {
  AppNavigationController? get navigation;

  @override
  bool get popGestureEnabled =>
      super.popGestureEnabled && (navigation?.isBackTarget(navigator!) ?? true);

  @override
  void handleStartBackGesture({double progress = 0.0}) {
    navigation?.beginGesture(navigator!);
    super.handleStartBackGesture(progress: progress);
  }
}
