import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_info.dart';
import '../../core/app_manifest.dart';
import '../../core/colors.dart';
import '../../core/pull_to_refresh.dart';
import '../../core/refresh/silent_refresh.dart';
import '../../mini_apps/registry.dart';
import '../announcement/announcement_overlay.dart';
import 'app_grid_item.dart';

/// 首页：小程序信息卡片（[AppManifest.homeCard]）+ 启动宫格，数据源都是
/// 全量注册表 [appRegistry]。
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  /// 并发刷新所有提供了 [AppManifest.onHomeRefresh] 的首页卡片。
  ///
  /// 走 [SilentRefresh.runAll]：单个模块失败自动重试且只写诊断日志，不打断其他
  /// 卡片，界面上也不出现「更新中 / 更新失败」的动画与文案（issue #31）。
  static Future<void> _refreshAll() => SilentRefresh.runAll('shell.home', {
    for (final app in appRegistry.apps) app.id: ?app.onHomeRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text(kAppName),
        actions: const [AnnouncementBell()],
      ),
      body: AnnouncementOverlay(
        child: PullToRefresh(
          onRefresh: _refreshAll,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            children: [
              for (final app in appRegistry.apps)
                if (app.homeCard != null) ...[
                  Builder(builder: app.homeCard!),
                  // 设计师 10/20：首页卡片间距 12→8。
                  const SizedBox(height: 8),
                ],
              Container(
                padding: const EdgeInsets.symmetric(
                  vertical: 18,
                  horizontal: 14,
                ),
                decoration: BoxDecoration(
                  color: palette.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: GridView.count(
                  crossAxisCount: 4,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 14,
                  childAspectRatio: 0.86,
                  children: [
                    for (final app in appRegistry.homeGridApps)
                      AppGridItem(
                        app: app,
                        // 必须 push 而非 go：go 会把小程序页替换成栈底，
                        // 导致顶栏无返回按钮、系统返回键也退不回宫格。
                        onTap: () => context.push('/apps/${app.id}'),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
