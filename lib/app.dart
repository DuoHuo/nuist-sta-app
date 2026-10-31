import 'dart:async';
import 'dart:io' show Platform;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/app_info.dart';
import 'core/logging/app_log.dart';
import 'core/network/vpn_gateway.dart';
import 'core/schedule/weekly_classes.dart';
import 'core/theme.dart';
import 'core/theme_mode.dart';
import 'mini_apps/timetable/timetable_lifecycle.dart';
import 'mini_apps/timetable/timetable_notify_bridge.dart';
import 'mini_apps/timetable/timetable_week_classes.dart';
import 'router.dart';

class NuistApp extends StatefulWidget {
  const NuistApp({super.key});

  @override
  State<NuistApp> createState() => _NuistAppState();
}

class _NuistAppState extends State<NuistApp> with WidgetsBindingObserver {
  static final _log = AppLog.logger('app.lifecycle');
  late final GoRouter _router = buildRouter();
  StreamSubscription<List<ConnectivityResult>>? _networkSubscription;
  String? _network;

  @override
  void initState() {
    super.initState();
    // 校园地图等通过 core 接口读本周课程，由壳把课表的实现登记进去。
    WeeklyClasses.source ??= const TimetableWeeklyClasses();
    AppThemeMode.instance.load();
    // 点击上课提醒 / 桌面小组件 → 打开课表（今天所在周）。
    final bridge = TimetableNotifyBridge.instance;
    bridge.setRouteHandler(_openRoute);
    bridge.takeLaunchRoute().then((r) {
      if (r != null) _openRoute(r);
    });
    WidgetsBinding.instance.addObserver(this);
    if (!kIsWeb && !Platform.environment.containsKey('FLUTTER_TEST')) {
      try {
        _networkSubscription = Connectivity().onConnectivityChanged.listen(
          (results) {
            final names = results.map((result) => result.name).toList()..sort();
            final current = names.join(',');
            final previous = _network;
            _network = current;
            if (previous != null && previous != current) {
              _log.info('network.changed', fields: {'connection_types': names});
              unawaited(VpnGateway.instance.networkChanged());
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            _log.warning(
              'network.listener_failed',
              error: error,
              stackTrace: stackTrace,
            );
          },
        );
      } catch (error, stackTrace) {
        _log.warning(
          'network.listener_unavailable',
          error: error,
          stackTrace: stackTrace,
        );
        // 平台无网络监听时，仍由请求前的健康检查恢复隧道。
      }
    }
  }

  void _openRoute(String route) {
    // 只接受站内课表路由，防止外部 Intent 注入任意跳转。
    final uri = Uri.tryParse(route);
    if (!mounted ||
        uri == null ||
        uri.hasScheme ||
        uri.hasAuthority ||
        uri.path != '/apps/timetable') {
      return;
    }
    // 重复点击复用已打开的课表页，保留首页作为返回落点。
    final matches = _router.routerDelegate.currentConfiguration.matches;
    final hasTimetable = matches.any(
      (m) =>
          m is ImperativeRouteMatch && m.matches.uri.path == '/apps/timetable',
    );
    if (hasTimetable) {
      while (_router.canPop() &&
          _router.routerDelegate.currentConfiguration.uri.path !=
              '/apps/timetable') {
        _router.pop();
      }
    }
    if (_router.routerDelegate.currentConfiguration.uri.path ==
        '/apps/timetable') {
      if (_router.routerDelegate.currentConfiguration.uri.toString() != route) {
        _router.replace(route);
      }
      return;
    }
    _router.push(route);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _log.debug('state.changed', fields: {'state': state.name});
    if (state == AppLifecycleState.resumed) {
      unawaited(VpnGateway.instance.checkHealth());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _networkSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 明暗模式由「我的 → 设置」选择，默认跟随系统。
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppThemeMode.instance,
      builder: (context, themeMode, _) => MaterialApp.router(
        title: kAppName,
        theme: appLightTheme(),
        darkTheme: appDarkTheme(),
        themeMode: themeMode,
        routerConfig: _router,
        // 课表同步时机：冷启动（远程）/ 回前台（本地）/ 网络恢复（远程）。
        builder: (context, child) =>
            TimetableLifecycleScope(child: child ?? const SizedBox.shrink()),
      ),
    );
  }
}
