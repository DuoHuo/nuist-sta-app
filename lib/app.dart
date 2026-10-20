import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/app_info.dart';
import 'core/schedule/weekly_classes.dart';
import 'core/theme.dart';
import 'core/theme_mode.dart';
import 'mini_apps/timetable/timetable_lifecycle.dart';
import 'mini_apps/timetable/timetable_week_classes.dart';
import 'router.dart';

class NuistApp extends StatefulWidget {
  const NuistApp({super.key});

  @override
  State<NuistApp> createState() => _NuistAppState();
}

class _NuistAppState extends State<NuistApp> {
  late final GoRouter _router = buildRouter();

  @override
  void initState() {
    super.initState();
    // 校园地图等通过 core 接口读本周课程，由壳把课表的实现登记进去。
    WeeklyClasses.source ??= const TimetableWeeklyClasses();
    AppThemeMode.instance.load();
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
        // 课表同步时机：冷启动 / 回前台 / 网络恢复。
        builder: (context, child) =>
            TimetableLifecycleScope(child: child ?? const SizedBox.shrink()),
      ),
    );
  }
}
