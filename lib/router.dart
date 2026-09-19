import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/app_manifest.dart';
import 'mini_apps/registry.dart';
import 'mini_apps/web/mini_web_view_page.dart';
import 'shell/home/home_page.dart';
import 'shell/profile/portal_bind/portal_bind_page.dart';
import 'shell/profile/portal_bind/portal_status_page.dart';
import 'shell/profile/profile_page.dart';
import 'shell/root_page.dart';

/// 全局路由的构建工厂：由 NuistApp 在初始化时创建一次，
/// 保证每次挂载都是干净实例（widget 测试之间不互相串状态）。
///
/// 结构：
/// - StatefulShellRoute：壳（底部双页签），branch 0 = 首页 `/`，branch 1 = 我的 `/profile`
/// - `/apps/:appId`：小程序全屏入口，与壳平级 —— 进入小程序后不带底部页签，
///   系统返回键自然退回宫格。原生小程序进 [AppManifest.entry]，
///   H5 小程序进通用 WebView 承载页。
/// - `/portal-bind`：统一门户的绑定状态页（学号、凭据信息、重新绑定/解绑），
///   其子路由 `/portal-bind/register` 才是内嵌登录 + 注册 Passkey 的流程页。
///   两者都与壳平级，全屏展示。
GoRouter buildRouter() => GoRouter(
  routes: [
    StatefulShellRoute.indexedStack(
      builder:
          (context, state, navigationShell) =>
              RootPage(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/', builder: (_, _) => const HomePage()),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/profile', builder: (_, _) => const ProfilePage()),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '/apps/:appId',
      builder: (context, state) {
        final id = state.pathParameters['appId']!;
        final manifest = appRegistryById[id];
        if (manifest == null) {
          return _MiniAppNotFoundPage(appId: id);
        }
        return manifest.isWeb
            ? MiniWebViewPage(manifest: manifest)
            : manifest.entry!(context);
      },
    ),
    GoRoute(
      path: '/portal-bind',
      builder: (_, _) => const PortalStatusPage(),
      routes: [
        GoRoute(path: 'register', builder: (_, _) => const PortalBindPage()),
      ],
    ),
  ],
);

/// 访问了注册表中不存在的小程序 id 时的兜底页。
class _MiniAppNotFoundPage extends StatelessWidget {
  const _MiniAppNotFoundPage({required this.appId});

  final String appId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('小程序')),
      body: Center(child: Text('小程序「$appId」不存在或已下线')),
    );
  }
}
