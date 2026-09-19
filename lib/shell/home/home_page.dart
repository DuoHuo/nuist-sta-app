import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_info.dart';
import '../../mini_apps/registry.dart';
import 'app_grid_item.dart';

/// 首页：小程序启动宫格，数据源是全量注册表 [appRegistry]。
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(kAppName)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 14),
            decoration: BoxDecoration(
              color: Colors.white,
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
    );
  }
}
