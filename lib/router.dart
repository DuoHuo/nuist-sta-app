import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/app_manifest.dart';
import 'core/app_registry.dart';
import 'core/navigation/app_navigation.dart';
import 'core/navigation/app_page.dart';
import 'mini_apps/campus_map/campus_place_detail_page.dart';
import 'mini_apps/registry.dart';
import 'mini_apps/timetable/timetable_page.dart';
import 'mini_apps/timetable/timetable_schedule_event.dart';
import 'mini_apps/web/mini_web_view_page.dart';
import 'shell/home/home_page.dart';
import 'shell/profile/about/about_page.dart';
import 'shell/profile/portal_bind/portal_bind_page.dart';
import 'shell/profile/portal_bind/portal_export_page.dart';
import 'shell/profile/portal_bind/portal_import_page.dart';
import 'shell/profile/portal_bind/portal_scan_page.dart';
import 'shell/profile/portal_bind/portal_status_page.dart';
import 'shell/profile/profile_page.dart';
import 'shell/profile/settings/app_icon_page.dart';
import 'shell/profile/settings/settings_page.dart';
import 'shell/root_page.dart';
import 'shell/announcement/announcement_controller.dart';
import 'shell/announcement/announcement_overlay.dart';
import 'shell/update/update_controller.dart';
import 'shell/study/study_page.dart';

/// 系统通知和桌面小组件进入课表时直接显示内容，返回仍沿用 Material 手势。
const timetableDirectLaunch = 'timetableDirectLaunch';

/// 创建一次固定的三分支路由树；宽窄变化仅由壳改变导航器的布局。
///
/// AppNavigation 将公开详情路径放入所属分支；无来源深链进入首页分支。
/// 所有分支复用同一份详情构建逻辑，保留 [AppManifest.entry]、查询参数和 extra。
GoRouter buildRouter({
  UpdateController? updateController,
  AnnouncementController? announcementController,
  AppNavigationController? navigation,
  AppRegistry? registry,
  bool ignorePlatformInitialRoute = false,
}) {
  final panes = navigation ?? AppNavigationController();
  final apps = registry ?? appRegistry;
  List<GoRoute> details(String prefix, {bool public = false}) => _detailRoutes(
    prefix: prefix,
    public: public,
    navigation: panes,
    registry: apps,
    updateController: updateController,
  );
  final router = GoRouter(
    initialLocation: ignorePlatformInitialRoute ? '/' : null,
    overridePlatformDefaultLocation: ignorePlatformInitialRoute,
    navigatorKey: panes.rootNavigatorKey,
    observers: [panes.rootObserver],
    routes: [
      StatefulShellRoute(
        notifyRootObserver: false,
        navigatorContainerBuilder: (context, navigationShell, children) =>
            RootPage(
              navigationShell: navigationShell,
              navigation: panes,
              updates: updateController,
              announcements: announcementController,
              children: children,
            ),
        pageBuilder: (context, state, navigationShell) => AppPage<void>(
          key: state.pageKey,
          navigation: panes,
          isShellRoot: true,
          child: Builder(
            builder: (context) => AnnouncementRouteScope(
              isCurrent: ModalRoute.isCurrentOf(context) ?? true,
              child: navigationShell,
            ),
          ),
        ),
        branches: [
          StatefulShellBranch(
            navigatorKey: panes.branchNavigatorKeys[0],
            observers: [panes.branchObservers[0]],
            preload: true,
            routes: [
              GoRoute(
                path: '/',
                pageBuilder: (_, state) => AppPage<void>(
                  key: state.pageKey,
                  navigation: panes,
                  child: HomePage(
                    updates: updateController,
                    announcements: announcementController,
                    registry: apps,
                  ),
                ),
                routes: details('home/'),
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: panes.branchNavigatorKeys[1],
            observers: [panes.branchObservers[1]],
            preload: true,
            routes: [
              GoRoute(
                path: '/study',
                pageBuilder: (_, state) => AppPage<void>(
                  key: state.pageKey,
                  navigation: panes,
                  child: StudyPage(registry: apps),
                ),
                routes: details(''),
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: panes.branchNavigatorKeys[2],
            observers: [panes.branchObservers[2]],
            routes: [
              GoRoute(
                path: '/profile',
                pageBuilder: (_, state) => AppPage<void>(
                  key: state.pageKey,
                  navigation: panes,
                  child: const ProfilePage(),
                ),
                routes: details(''),
              ),
            ],
          ),
        ],
      ),
      // 保留原公开路径；深链和没有面板 scope 的入口统一落在首页栈。
      ...details('/', public: true),
    ],
  );
  panes.attach(router);
  return router;
}

List<GoRoute> _detailRoutes({
  required String prefix,
  required bool public,
  required AppNavigationController navigation,
  required AppRegistry registry,
  UpdateController? updateController,
}) {
  AppPage<void> page(GoRouterState state, Widget child) =>
      AppPage<void>(key: state.pageKey, navigation: navigation, child: child);
  String? redirect(BuildContext context, GoRouterState state) =>
      public ? AppNavigation.locationInBranch(state.uri.toString(), 0) : null;
  return [
    GoRoute(
      path: '${prefix}apps/:appId',
      redirect: redirect,
      pageBuilder: (context, state) {
        final id = state.pathParameters['appId']!;
        final manifest = registry.byId[id];
        if (manifest == null) {
          return page(state, _MiniAppNotFoundPage(appId: id));
        }
        final child = manifest.isWeb
            ? MiniWebViewPage(manifest: manifest)
            : id == 'timetable'
            ? TimetablePage(
                focusTomorrow: state.uri.queryParameters['focus'] == 'tomorrow',
                focusEvent: state.extra is ScheduleEvent
                    ? state.extra as ScheduleEvent
                    : null,
              )
            : manifest.entry!(context);
        return AppPage<void>(
          key: state.pageKey,
          navigation: navigation,
          directLaunch:
              id == 'timetable' && state.extra == timetableDirectLaunch,
          child: child,
        );
      },
    ),
    GoRoute(
      path: '${prefix}place/:placeId',
      redirect: redirect,
      pageBuilder: (_, state) => page(
        state,
        CampusPlaceDetailPage(placeId: state.pathParameters['placeId']!),
      ),
    ),
    GoRoute(
      path: '${prefix}portal-bind',
      redirect: redirect,
      pageBuilder: (_, state) => page(state, const PortalStatusPage()),
      routes: [
        GoRoute(
          path: 'register',
          pageBuilder: (_, state) => page(state, const PortalBindPage()),
        ),
        GoRoute(
          path: 'export',
          pageBuilder: (_, state) => page(state, const PortalExportPage()),
        ),
        GoRoute(
          path: 'import',
          pageBuilder: (_, state) => page(state, const PortalImportPage()),
          routes: [
            GoRoute(
              path: 'scan',
              pageBuilder: (_, state) => page(state, const PortalScanPage()),
            ),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '${prefix}about',
      redirect: redirect,
      pageBuilder: (_, state) =>
          page(state, AboutPage(updates: updateController)),
    ),
    GoRoute(
      path: '${prefix}settings',
      redirect: redirect,
      pageBuilder: (_, state) => page(state, const SettingsPage()),
      routes: [
        GoRoute(
          path: 'app-icon',
          pageBuilder: (_, state) => page(state, const AppIconPage()),
        ),
      ],
    ),
  ];
}

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
