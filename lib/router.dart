import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/app_manifest.dart';
import 'mini_apps/campus_map/campus_place_detail_page.dart';
import 'mini_apps/innovation_credit/innovation_credit_page.dart';
import 'mini_apps/labor_score/labor_score_page.dart';
import 'mini_apps/registry.dart';
import 'mini_apps/score/score_page.dart';
import 'mini_apps/web/mini_web_view_page.dart';
import 'shell/home/home_page.dart';
import 'shell/profile/portal_bind/portal_bind_page.dart';
import 'shell/profile/portal_bind/portal_export_page.dart';
import 'shell/profile/portal_bind/portal_import_page.dart';
import 'shell/profile/portal_bind/portal_scan_page.dart';
import 'shell/profile/portal_bind/portal_status_page.dart';
import 'shell/profile/profile_page.dart';
import 'shell/root_page.dart';
import 'shell/study/study_page.dart';

/// 全局路由的构建工厂：由 NuistApp 在初始化时创建一次，
/// 保证每次挂载都是干净实例（widget 测试之间不互相串状态）。
///
/// 结构：
/// - StatefulShellRoute：壳（底部三页签），branch 0 = 首页 `/`，
///   branch 1 = 学习 `/study`，branch 2 = 我的 `/profile`
/// - `/apps/:appId`：小程序全屏入口，与壳平级 —— 进入小程序后不带底部页签，
///   系统返回键自然退回宫格。原生小程序进 [AppManifest.entry]，
///   H5 小程序进通用 WebView 承载页。
/// - `/portal-bind`：统一门户的绑定状态页（学号、凭据信息、重新绑定/解绑），
///   其子路由 `/portal-bind/register` 才是内嵌登录 + 注册 Passkey 的流程页；
///   `export` / `import`（及 `import/scan` 扫码）是通行密钥在设备间搬运的页面。
///   都与壳平级，全屏展示。
/// - `/innovation-credit`、`/labor-score`：学习页两张卡片的详情页，同样与壳
///   平级全屏展示，返回键退回学习页。
/// - `/place/:placeId`：校园地图的地物详情页（建筑 / POI / 通用地物共用）。
///   与壳平级，可深链与分享；页面按编号自行取数，不依赖地图页是否打开。
GoRouter buildRouter() => GoRouter(
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          RootPage(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [GoRoute(path: '/', builder: (_, _) => const HomePage())],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/study', builder: (_, _) => const StudyPage()),
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
      path: '/place/:placeId',
      builder: (context, state) =>
          CampusPlaceDetailPage(placeId: state.pathParameters['placeId']!),
    ),
    GoRoute(
      path: '/portal-bind',
      builder: (_, _) => const PortalStatusPage(),
      routes: [
        GoRoute(path: 'register', builder: (_, _) => const PortalBindPage()),
        GoRoute(path: 'export', builder: (_, _) => const PortalExportPage()),
        GoRoute(
          path: 'import',
          builder: (_, _) => const PortalImportPage(),
          routes: [
            GoRoute(path: 'scan', builder: (_, _) => const PortalScanPage()),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '/innovation-credit',
      builder: (_, _) => const InnovationCreditPage(),
    ),
    GoRoute(path: '/labor-score', builder: (_, _) => const LaborScorePage()),
    GoRoute(path: '/scores', builder: (_, _) => const ScorePage()),
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
