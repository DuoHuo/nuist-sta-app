import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/app_info.dart';
import 'core/theme.dart';
import 'mini_apps/timetable/timetable_lifecycle.dart';
import 'router.dart';

class NuistApp extends StatefulWidget {
  const NuistApp({super.key});

  @override
  State<NuistApp> createState() => _NuistAppState();
}

class _NuistAppState extends State<NuistApp> {
  late final GoRouter _router = buildRouter();

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: kAppName,
      theme: appLightTheme(),
      darkTheme: appDarkTheme(),
      // 跟随系统明暗，App 内不提供手动开关。
      themeMode: ThemeMode.system,
      routerConfig: _router,
      // 课表同步时机：冷启动 / 回前台 / 网络恢复。
      builder: (context, child) =>
          TimetableLifecycleScope(child: child ?? const SizedBox.shrink()),
    );
  }
}
