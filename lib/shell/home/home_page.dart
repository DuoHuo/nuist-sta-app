import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_info.dart';
import '../../core/app_manifest.dart';
import '../../core/colors.dart';
import '../../core/pull_to_refresh.dart';
import '../../mini_apps/registry.dart';
import '../announcement/announcement_overlay.dart';
import 'app_grid_item.dart';

/// 首页：小程序信息卡片（[AppManifest.homeCard]）+ 启动宫格，数据源都是
/// 全量注册表 [appRegistry]。
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  /// 并发刷新所有提供了 [AppManifest.onHomeRefresh] 的首页卡片。
  static Future<void> _refreshAll() => Future.wait([
    for (final app in appRegistry)
      if (app.onHomeRefresh case final refresh?) refresh(),
  ]);

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
              for (final app in appRegistry)
                if (app.homeCard != null) ...[
                  Builder(builder: app.homeCard!),
                  const SizedBox(height: 12),
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
                    for (final app in appRegistry)
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
