import 'dart:async';
import 'dart:io';
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nuist_sta_app/core/app_manifest.dart';
import 'package:nuist_sta_app/core/app_registry.dart';
import 'package:nuist_sta_app/core/app_snack_bar.dart';
import 'package:nuist_sta_app/core/layout/app_pane_layout.dart';
import 'package:nuist_sta_app/core/navigation/app_navigation.dart';
import 'package:nuist_sta_app/core/navigation/app_page.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_manifest.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/router.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_api.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_controller.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_models.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_overlay.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_sheet.dart';
import 'package:nuist_sta_app/shell/home/app_grid_item.dart';
import 'package:nuist_sta_app/shell/home/home_page.dart';
import 'package:nuist_sta_app/shell/profile/profile_page.dart';
import 'package:nuist_sta_app/shell/profile/settings/settings_page.dart';
import 'package:nuist_sta_app/shell/study/study_page.dart';

AppRegistry _registry() => AppRegistry([
  AppManifest(
    id: 'probe',
    label: '测试小程序',
    color: Colors.blue,
    entry: (_) => const _ProbePage(),
    homeCard: (_) => const _ProbeCard('首页'),
    studyCard: StudyCardContribution(
      builder: (_) => const _ProbeCard('学习'),
      order: 0,
    ),
  ),
]);

class _ProbeCard extends StatelessWidget {
  const _ProbeCard(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextField(key: ValueKey('$label输入')),
      TextButton(
        onPressed: () => AppNavigation.push(context, '/apps/probe'),
        child: Text('$label入口'),
      ),
      const SizedBox(height: 1200),
      Text('$label末尾'),
    ],
  );
}

class _ProbePage extends StatelessWidget {
  const _ProbePage();

  @override
  Widget build(BuildContext context) {
    final scope = AppNavigationScope.maybeOf(context)!;
    return Scaffold(
      appBar: AppBar(title: Text('详情${scope.branch}')),
      body: Column(
        children: [
          TextField(key: ValueKey('详情输入${scope.branch}')),
          TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              useRootNavigator: false,
              builder: (_) => const AlertDialog(content: Text('面板提示')),
            ),
            child: Text('弹窗${scope.branch}'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              AppPageRoute(
                builder: (_) => Scaffold(
                  appBar: AppBar(title: Text('内部详情${scope.branch}')),
                ),
              ),
            ),
            child: Text('内部入口${scope.branch}'),
          ),
          TextButton(
            onPressed: () => AppNavigation.pop(context, '返回结果'),
            child: const Text('返回结果'),
          ),
        ],
      ),
    );
  }
}

Future<(GoRouter, AppNavigationController)> _pump(
  WidgetTester tester, {
  double width = 800,
  bool dark = false,
  AppRegistry? registry,
  AnnouncementController? announcements,
  MediaQueryData Function(MediaQueryData)? media,
  List<bool>? frameworkBack,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (frameworkBack != null) {
    final messenger = tester.binding.defaultBinaryMessenger;
    final previousLifecycle = tester.binding.lifecycleState;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
        frameworkBack.add(call.arguments as bool);
      }
      return null;
    });
    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(
        previousLifecycle ?? AppLifecycleState.detached,
      );
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
  }
  final navigation = AppNavigationController();
  final notices =
      announcements ??
      AnnouncementController.test(
        fetch: ({etag, lastModified}) async =>
            const AnnouncementFetchResult(notModified: false, items: []),
      );
  final router = buildRouter(
    navigation: navigation,
    registry: registry ?? _registry(),
    announcementController: notices,
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    navigation.dispose();
    router.dispose();
    notices.dispose();
  });
  await tester.pumpWidget(
    MaterialApp.router(
      theme: dark ? appDarkTheme() : appLightTheme(),
      routerConfig: router,
      builder: (context, child) => MediaQuery(
        data: media?.call(MediaQuery.of(context)) ?? MediaQuery.of(context),
        child: child!,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (router, navigation);
}

Future<bool?> _gesture(
  WidgetTester tester,
  String method, {
  double progress = 0,
}) async {
  ByteData? response;
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    const StandardMethodCodec().encodeMethodCall(
      MethodCall(method, {
        'touchOffset': [5.0, 300.0],
        'progress': progress,
        'swipeEdge': 0,
      }),
    ),
    (data) => response = data,
  );
  await tester.pumpAndSettle();
  return const StandardMethodCodec().decodeEnvelope(response!) as bool?;
}

void main() {
  test('阈值扣除安全区，竖向铰链填满两侧，横向铰链使用最大安全区域', () {
    AppPaneLayout layout(
      double width, {
      EdgeInsets padding = EdgeInsets.zero,
      List<DisplayFeature> features = const [],
    }) => AppPaneLayout.resolve(
      MediaQueryData(
        size: Size(width, 900),
        padding: padding,
        displayFeatures: features,
      ),
    );
    expect(layout(655).wide, isFalse);
    expect(layout(656).home!.width, 320);
    expect(
      layout(
        696,
        padding: const EdgeInsets.symmetric(horizontal: 20),
      ).home!.width,
      320,
    );
    expect(
      layout(695, padding: const EdgeInsets.symmetric(horizontal: 20)).wide,
      isFalse,
    );
    final hinge = layout(
      740,
      features: const [
        DisplayFeature(
          bounds: Rect.fromLTWH(320, 0, 40, 900),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.unknown,
        ),
      ],
    );
    expect(hinge.home!.width, 320);
    expect(hinge.study!.width, 380);
    expect(hinge.study!.left, 360);
    final small = layout(
      650,
      features: const [
        DisplayFeature(
          bounds: Rect.fromLTWH(290, 0, 40, 900),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.unknown,
        ),
      ],
    );
    expect(small.wide, isFalse);
    expect(small.region, const Rect.fromLTWH(330, 0, 320, 900));
    final horizontal = layout(
      700,
      features: const [
        DisplayFeature(
          bounds: Rect.fromLTWH(0, 350, 700, 30),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.unknown,
        ),
      ],
    );
    expect(horizontal.region, const Rect.fromLTWH(0, 380, 700, 520));
  });

  testWidgets('预加载不改变活动栏，输入框聚焦记录最近操作栏', (tester) async {
    final (_, navigation) = await _pump(tester);
    expect(navigation.activeIndex, 0);
    await tester.showKeyboard(find.byKey(const ValueKey('学习输入')));
    await tester.pumpAndSettle();
    expect(navigation.activeIndex, 1);
    await tester.showKeyboard(find.byKey(const ValueKey('首页输入')));
    await tester.pumpAndSettle();
    expect(navigation.activeIndex, 0);
    expect(tester.takeException(), isNull);
  });

  test('折叠屏展开或状态未知的折痕不裁剪连续屏幕', () {
    for (final state in [
      DisplayFeatureState.postureFlat,
      DisplayFeatureState.unknown,
    ]) {
      for (final bounds in [
        const Rect.fromLTWH(400, 0, 0, 900),
        const Rect.fromLTWH(0, 450, 800, 0),
      ]) {
        final layout = AppPaneLayout.resolve(
          MediaQueryData(
            size: const Size(800, 900),
            padding: const EdgeInsets.only(top: 24, bottom: 20),
            displayFeatures: [
              DisplayFeature(
                bounds: bounds,
                type: DisplayFeatureType.fold,
                state: state,
              ),
            ],
          ),
        );
        expect(layout.region, const Rect.fromLTWH(0, 24, 800, 856));
        expect(layout.home, const Rect.fromLTWH(0, 24, 392, 856));
        expect(layout.study, const Rect.fromLTWH(408, 24, 392, 856));
        expect(layout.separatedByHinge, isFalse);
      }
    }
  });

  test('半开折叠屏仍避开分隔折痕，展平后恢复完整高度', () {
    MediaQueryData media(DisplayFeatureState state) => MediaQueryData(
      size: const Size(800, 900),
      displayFeatures: [
        DisplayFeature(
          bounds: const Rect.fromLTWH(0, 450, 800, 0),
          type: DisplayFeatureType.fold,
          state: state,
        ),
      ],
    );
    expect(
      AppPaneLayout.resolve(media(DisplayFeatureState.postureHalfOpened))
          .region,
      const Rect.fromLTWH(0, 0, 800, 450),
    );
    expect(
      AppPaneLayout.resolve(media(DisplayFeatureState.postureFlat)).region,
      const Rect.fromLTWH(0, 0, 800, 900),
    );
  });

  for (final dark in [false, true]) {
    testWidgets('${dark ? '深色' : '浅色'} Android 返回登记跟随可见栈，隐藏栏通知不影响系统退出', (
      tester,
    ) async {
      final frameworkBack = <bool>[];
      final (_, navigation) = await _pump(
        tester,
        dark: dark,
        frameworkBack: frameworkBack,
      );
      expect(frameworkBack.last, isFalse);
      await tester.tap(find.text('学习入口'));
      await tester.pumpAndSettle();
      expect(frameworkBack.last, isTrue);
      // 另一可见栏的空栈通知不能取消学习详情的返回登记。
      const NavigationNotification(canHandlePop: false)
          .dispatch(tester.element(find.byType(HomePage)));
      await tester.pump();
      expect(frameworkBack.last, isTrue);
      final studyContext = tester.element(find.text('详情1'));

      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();
      expect(frameworkBack.last, isFalse);
      expect(await navigation.handleBack(), isFalse);
      const NavigationNotification(canHandlePop: true).dispatch(studyContext);
      await tester.pump();
      expect(frameworkBack.last, isFalse, reason: '隐藏详情不能阻止我的根页退出');

      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(frameworkBack.last, isTrue);
      final settingsContext = tester.element(find.byType(SettingsPage));
      tester.view.physicalSize = const Size(390, 900);
      await tester.pumpAndSettle();
      expect(frameworkBack.last, isTrue);
      tester.view.physicalSize = const Size(800, 900);
      await tester.pumpAndSettle();
      await tester.tap(find.text('首页+学习'));
      await tester.pumpAndSettle();
      expect(frameworkBack.last, isTrue);
      const NavigationNotification(canHandlePop: false)
          .dispatch(settingsContext);
      await tester.pump();
      expect(frameworkBack.last, isTrue, reason: '隐藏设置页不能取消学习详情的返回登记');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('详情1'), findsNothing);
      expect(frameworkBack.last, isFalse);

      unawaited(
        showDialog<void>(
          context: navigation.rootNavigatorKey.currentContext!,
          useRootNavigator: true,
          builder: (_) => const AlertDialog(content: Text('全局返回登记')),
        ),
      );
      await tester.pumpAndSettle();
      expect(frameworkBack.last, isTrue);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('全局返回登记'), findsNothing);
      expect(frameworkBack.last, isFalse);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('${dark ? '深色' : '浅色'}宽屏通知位于右上角，收窄后同一状态回到首页', (tester) async {
      final notices = AnnouncementController.test(
        fetch: ({etag, lastModified}) async => const AnnouncementFetchResult(
          notModified: false,
          items: [
            Announcement(
              id: 'wide-badge',
              title: '右上角公告',
              remind: AnnouncementRemind.badge,
            ),
          ],
        ),
      );
      final (_, navigation) = await _pump(
        tester,
        dark: dark,
        announcements: notices,
        media: (media) => media.copyWith(
          displayFeatures: [
            DisplayFeature(
              bounds: Rect.fromLTWH(
                media.size.width / 2,
                0,
                0,
                media.size.height,
              ),
              type: DisplayFeatureType.fold,
              state: DisplayFeatureState.postureFlat,
            ),
          ],
        ),
      );
      expect(notices.hasUnread, isTrue);
      expect(find.byType(AnnouncementBell), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(StudyPage),
          matching: find.byType(AnnouncementBell),
        ),
        findsNothing,
      );
      final bell = tester.getRect(find.byTooltip('公告'));
      expect(bell.right, greaterThanOrEqualTo(784));
      expect(bell.right, lessThanOrEqualTo(800));
      expect(bell.top, lessThan(56));
      expect(
        tester
            .widget<AnnouncementBell>(find.byType(AnnouncementBell))
            .controller,
        same(notices),
      );
      await tester.tap(find.byTooltip('公告'));
      await tester.pumpAndSettle();
      expect(notices.hasUnread, isFalse);
      expect(
        tester
            .widget<AnnouncementDialog>(find.byType(AnnouncementDialog))
            .items
            .single
            .id,
        'wide-badge',
      );
      expect(tester.getSize(find.byType(ModalBarrier).last).width, 800);
      expect(navigation.rootNavigatorKey.currentState!.canPop(), isTrue);
      expect(navigation.activeIndex, 0);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AnnouncementDialog), findsNothing);
      tester.view.physicalSize = const Size(390, 900);
      await tester.pumpAndSettle();
      expect(find.byType(AnnouncementBell), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(HomePage),
          matching: find.byType(AnnouncementBell),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<AnnouncementBell>(find.byType(AnnouncementBell))
            .controller,
        same(notices),
      );
      expect(notices.hasUnread, isFalse);
      await tester.tap(find.byTooltip('公告'));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(ModalBarrier).last).width, 390);
      expect(
        find.descendant(
          of: find.byType(AnnouncementDialog),
          matching: find.text('右上角公告'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    for (final posture in [
      DisplayFeatureState.postureFlat,
      DisplayFeatureState.unknown,
    ]) {
      testWidgets('${dark ? '深色' : '浅色'}折叠屏平铺折痕旋转保持全高与两栏状态 ${posture.name}', (
        tester,
      ) async {
        final (_, navigation) = await _pump(
          tester,
          dark: dark,
          media: (media) => media.copyWith(
            padding: const EdgeInsets.only(top: 24, bottom: 20),
            viewPadding: const EdgeInsets.only(top: 24, bottom: 20),
            displayFeatures: [
              DisplayFeature(
                bounds: media.size.width > media.size.height
                    ? Rect.fromLTWH(
                        0,
                        media.size.height / 2,
                        media.size.width,
                        0,
                      )
                    : Rect.fromLTWH(
                        media.size.width / 2,
                        0,
                        0,
                        media.size.height,
                      ),
                type: DisplayFeatureType.fold,
                state: posture,
              ),
            ],
          ),
        );
        final homeNavigator = navigation.branchNavigatorKeys[0].currentState;
        final studyNavigator = navigation.branchNavigatorKeys[1].currentState;
        await tester.enterText(find.byKey(const ValueKey('学习输入')), '旋转前的输入');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        final scroll = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byType(StudyPage),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        scroll.position.jumpTo(70);
        await tester.pump();
        for (final size in [
          const Size(900, 800),
          const Size(1100, 740),
          const Size(740, 1100),
          const Size(800, 900),
        ]) {
          tester.view.physicalSize = size;
          await tester.pumpAndSettle();
          expect(find.byType(HomePage), findsOneWidget);
          expect(find.byType(StudyPage), findsOneWidget);
          for (final index in [0, 1]) {
            final rect = tester.getRect(
              find.byKey(ValueKey('app-pane-$index')),
            );
            expect(rect.top, 24);
            expect(rect.height, size.height - 100);
            expect(rect.width, (size.width - 16) / 2);
            expect(rect.bottom, size.height - 76);
          }
          final tab = find
              .ancestor(of: find.text('首页+学习'), matching: find.byType(InkWell))
              .last;
          expect(tester.getRect(tab).bottom, size.height - 20);
          expect(
            navigation.branchNavigatorKeys[0].currentState,
            same(homeNavigator),
          );
          expect(
            navigation.branchNavigatorKeys[1].currentState,
            same(studyNavigator),
          );
          expect(find.text('旋转前的输入'), findsOneWidget);
          expect(scroll.position.pixels, 70);
          expect(tester.takeException(), isNull);
        }
      });
    }

    for (final posture in [
      DisplayFeatureState.postureFlat,
      DisplayFeatureState.unknown,
      DisplayFeatureState.postureHalfOpened,
    ]) {
      testWidgets('${dark ? '深色' : '浅色'}折叠屏我的与设置始终铺满窗口 ${posture.name}', (
        tester,
      ) async {
        final (router, navigation) = await _pump(
          tester,
          dark: dark,
          media: (media) => media.copyWith(
            padding: const EdgeInsets.only(top: 24, bottom: 20),
            viewPadding: const EdgeInsets.only(top: 24, bottom: 20),
            displayFeatures: [
              DisplayFeature(
                bounds: media.size.width > media.size.height
                    ? Rect.fromLTWH(
                        0,
                        media.size.height / 2,
                        media.size.width,
                        0,
                      )
                    : Rect.fromLTWH(
                        media.size.width / 2,
                        0,
                        0,
                        media.size.height,
                      ),
                type: DisplayFeatureType.fold,
                state: posture,
              ),
            ],
          ),
        );
        await tester.tap(find.text('我的'));
        await tester.pumpAndSettle();
        final profile = tester.state(find.byType(ProfilePage));
        final profileNavigator = navigation.branchNavigatorKeys[2].currentState;
        expect(
          MediaQuery.sizeOf(tester.element(find.byType(ProfilePage))),
          const Size(800, 800),
        );
        await tester.tap(find.text('设置'));
        await tester.pumpAndSettle();
        final route =
            ModalRoute.of(tester.element(find.byType(SettingsPage)))!
                as PageRoute;
        for (final size in [const Size(900, 800), const Size(800, 900)]) {
          tester.view.physicalSize = size;
          await tester.pumpAndSettle();
          expect(
            MediaQuery.sizeOf(tester.element(find.byType(SettingsPage))),
            Size(size.width, size.height - 100),
          );
          expect(
            navigation.branchNavigatorKeys[2].currentState,
            same(profileNavigator),
          );
          expect(
            ModalRoute.of(tester.element(find.byType(SettingsPage))),
            same(route),
          );
          expect(router.state.uri.path, '/profile/settings');
          expect(navigation.activeIndex, 2);
          expect(
            tester.getRect(find.byKey(const ValueKey('app-pane-2'))).bottom,
            size.height - 76,
          );
          expect(tester.takeException(), isNull);
        }
        expect(await _gesture(tester, 'startBackGesture'), isTrue);
        await _gesture(tester, 'updateBackGestureProgress', progress: .4);
        expect(route.animation!.value, closeTo(.6, .001));
        await _gesture(tester, 'cancelBackGesture');
        expect(
          ModalRoute.of(tester.element(find.byType(SettingsPage))),
          same(route),
        );
        await _gesture(tester, 'startBackGesture');
        await _gesture(tester, 'commitBackGesture');
        expect(tester.state(find.byType(ProfilePage)), same(profile));
        expect(
          MediaQuery.sizeOf(tester.element(find.byType(ProfilePage))),
          const Size(800, 800),
        );
        await tester.tap(find.text('首页+学习'));
        await tester.pumpAndSettle();
        expect(find.byType(HomePage), findsOneWidget);
        expect(find.byType(StudyPage), findsOneWidget);
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant.only(TargetPlatform.android));
    }
  }

  testWidgets('656 dp 双栏，连续收窄恢复首页，导航器、输入与独立滚动保留', (tester) async {
    final (_, navigation) = await _pump(tester, width: 656);
    expect(find.byType(HomePage), findsOneWidget);
    expect(find.byType(StudyPage), findsOneWidget);
    expect(find.text('首页+学习'), findsOneWidget);
    expect(
      MediaQuery.sizeOf(tester.element(find.byType(StudyPage))).width,
      320,
    );
    final homeNavigator = navigation.branchNavigatorKeys[0].currentState;
    final studyNavigator = navigation.branchNavigatorKeys[1].currentState;
    await tester.enterText(find.byKey(const ValueKey('学习输入')), '保留输入');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final studyScroll = find.descendant(
      of: find.byType(StudyPage),
      matching: find.byType(Scrollable),
    );
    final state = tester.state<ScrollableState>(studyScroll.first);
    state.position.jumpTo(70);
    await tester.pump();
    for (final width in [655.0, 900.0, 390.0, 700.0]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpAndSettle();
      expect(
        navigation.branchNavigatorKeys[0].currentState,
        same(homeNavigator),
      );
      expect(
        navigation.branchNavigatorKeys[1].currentState,
        same(studyNavigator),
      );
      if (width < 656) expect(find.byType(StudyPage), findsNothing);
    }
    expect(find.text('保留输入'), findsOneWidget);
    expect(state.position.pixels, 70);
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(find.byType(HomePage), findsNothing);
    await tester.tap(find.text('首页+学习'));
    await tester.pumpAndSettle();
    expect(find.text('保留输入'), findsOneWidget);
    expect(state.position.pixels, 70);
  });

  testWidgets('大字体宫格自动减少列数，完整入口文案在 320 dp 栏内可见', (tester) async {
    await _pump(
      tester,
      width: 656,
      registry: AppRegistry([
        AppManifest(
          id: 'large-label',
          label: '完整测试入口',
          color: Colors.blue,
          icon: Icons.apps,
          entry: (_) => const _ProbePage(),
        ),
      ]),
      media: (media) => media.copyWith(textScaler: const TextScaler.linear(2)),
    );
    final label = find.text('完整测试入口');
    expect(label.hitTestable(), findsOneWidget);
    expect(
      tester.renderObject<RenderParagraph>(label).didExceedMaxLines,
      isFalse,
    );
    await tester.tap(label);
    await tester.pumpAndSettle();
    expect(find.text('详情0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('两栏分别扣除安全区与键盘，避免重复缩小窗口', (tester) async {
    final (_, navigation) = await _pump(
      tester,
      width: 700,
      media: (media) => media.copyWith(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        viewPadding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      ),
    );
    addTearDown(tester.view.resetViewInsets);
    expect(
      tester.getRect(find.byKey(const ValueKey('app-pane-0'))),
      const Rect.fromLTWH(20, 24, 322, 800),
    );
    await tester.tap(find.byKey(const ValueKey('学习输入')));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    final media = MediaQuery.of(tester.element(find.byType(StudyPage)));
    expect(media.size, const Size(322, 800));
    expect(media.padding, EdgeInsets.zero);
    expect(media.viewPadding, EdgeInsets.zero);
    expect(media.viewInsets.bottom, 224);
    expect(navigation.activeIndex, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('全局提示条只显示一次，位置避开底部入口', (tester) async {
    final (_, navigation) = await _pump(tester);
    ScaffoldMessenger.of(navigation.rootNavigatorKey.currentContext!)
        .showSnackBar(AppSnackBar(content: const Text('全局提示')));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
    final rootScaffold = tester.widget<Scaffold>(
      find.byWidgetPredicate(
        (widget) => widget is Scaffold && widget.bottomNavigationBar != null,
      ),
    );
    final bar = find.byWidget(rootScaffold.bottomNavigationBar!);
    expect(
      tester.getBottomLeft(find.byType(SnackBar)).dy,
      lessThanOrEqualTo(tester.getTopLeft(bar).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('竖向铰链两侧不等宽时，面板和底部按钮分别避开铰链', (tester) async {
    await _pump(
      tester,
      width: 1100,
      media: (media) => media.copyWith(
        displayFeatures: const [
          DisplayFeature(
            bounds: Rect.fromLTWH(320, 0, 40, 900),
            type: DisplayFeatureType.hinge,
            state: DisplayFeatureState.unknown,
          ),
        ],
      ),
    );
    expect(MediaQuery.sizeOf(tester.element(find.byType(HomePage))).width, 320);
    expect(
      MediaQuery.sizeOf(tester.element(find.byType(StudyPage))).width,
      740,
    );
    expect(tester.getCenter(find.text('首页+学习')).dx, 160);
    expect(tester.getCenter(find.text('我的')).dx, 730);
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(
      MediaQuery.sizeOf(tester.element(find.byType(ProfilePage))).width,
      1100,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('两栏详情与弹窗各自打开，系统返回先退最近操作栏再退另一栏', (tester) async {
    final (router, navigation) = await _pump(tester);
    await tester.tap(find.text('学习入口'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/study/apps/probe');
    await tester.tap(find.text('首页入口'));
    await tester.pumpAndSettle();
    expect(find.text('详情0'), findsOneWidget);
    expect(find.text('详情1'), findsOneWidget);
    await tester.tap(find.text('弹窗0'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(ModalBarrier).last).width, 392);
    expect(navigation.rootNavigatorKey.currentState!.canPop(), isFalse);
    await tester.tap(find.byKey(const ValueKey('详情输入1')));
    await tester.enterText(find.byKey(const ValueKey('详情输入1')), '另一栏可操作');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('详情1'), findsNothing);
    expect(find.text('面板提示'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('面板提示'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('详情0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('学习详情收窄后铺满并保留，返回根页后显示首页', (tester) async {
    final (_, navigation) = await _pump(tester);
    await tester.tap(find.text('学习入口'));
    await tester.pumpAndSettle();
    final route = ModalRoute.of(tester.element(find.text('详情1')));
    await tester.enterText(find.byKey(const ValueKey('详情输入1')), '详情输入');
    tester.view.physicalSize = const Size(390, 900);
    await tester.pumpAndSettle();
    expect(find.text('详情1'), findsOneWidget);
    expect(find.text('详情输入'), findsOneWidget);
    expect(MediaQuery.sizeOf(tester.element(find.text('详情1'))).width, 390);
    expect(ModalRoute.of(tester.element(find.text('详情1'))), same(route));
    expect(find.text('我的'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(navigation.activeIndex, 0);
    expect(find.byType(HomePage), findsOneWidget);
    expect(find.byType(StudyPage), findsNothing);
    expect(find.text('我的'), findsOneWidget);
  });

  testWidgets('隐藏栏的详情和弹层不阻止我的根页交给系统返回', (tester) async {
    final (router, navigation) = await _pump(tester);
    await tester.tap(find.text('首页入口'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学习入口'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('弹窗1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(await navigation.handleBack(), isFalse);
    expect(await router.routerDelegate.popRoute(), isFalse);
    await tester.tap(find.text('首页+学习'));
    await tester.pumpAndSettle();
    expect(find.text('详情0'), findsOneWidget);
    expect(find.text('详情1'), findsOneWidget);
    expect(find.text('面板提示'), findsOneWidget);
  });

  testWidgets('查询参数、extra 与泛型返回 Future 跨宽窄及分支切换保留', (tester) async {
    final (router, _) = await _pump(tester);
    final extra = Object();
    final result = AppNavigation.push<String>(
      tester.element(find.byType(StudyPage)),
      '/apps/probe?focus=tomorrow',
      extra: extra,
    );
    await tester.pumpAndSettle();
    expect(router.state.extra, same(extra));
    expect(router.state.uri.queryParameters['focus'], 'tomorrow');
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('首页+学习'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(390, 900);
    await tester.pumpAndSettle();
    await tester.tap(find.text('返回结果'));
    await tester.pumpAndSettle();
    expect(await result, '返回结果');
  });

  testWidgets('返回所属栏时保留全局弹层与另一栏详情', (tester) async {
    final (_, navigation) = await _pump(tester);
    final result = AppNavigation.push<String>(
      tester.element(find.byType(HomePage)),
      '/apps/probe',
    );
    await tester.pumpAndSettle();
    final homeContext = tester.element(find.text('详情0'));
    await tester.tap(find.text('学习入口'));
    await tester.pumpAndSettle();
    unawaited(
      showDialog<void>(
        context: navigation.rootNavigatorKey.currentContext!,
        useRootNavigator: true,
        builder: (_) => const AlertDialog(content: Text('全局提示')),
      ),
    );
    await tester.pumpAndSettle();
    AppNavigation.pop(homeContext, '返回结果');
    await tester.pumpAndSettle();
    expect(find.text('全局提示'), findsOneWidget);
    expect(find.text('详情0'), findsNothing);
    expect(find.text('详情1'), findsOneWidget);
    expect(navigation.activeIndex, 1);
    expect(await result, '返回结果');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('全局提示'), findsNothing);
    expect(find.text('详情1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('隐藏栏异步返回保留我的页面，重新打开组合时不恢复已退出详情', (tester) async {
    final (_, navigation) = await _pump(tester);
    final result = AppNavigation.push<String>(
      tester.element(find.byType(HomePage)),
      '/apps/probe',
    );
    await tester.pumpAndSettle();
    final homeContext = tester.element(find.text('详情0'));
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    AppNavigation.pop(homeContext, '隐藏栏结果');
    await tester.pumpAndSettle();
    expect(await result, '隐藏栏结果');
    expect(navigation.activeIndex, 2);
    expect(find.byType(ProfilePage), findsOneWidget);
    await tester.tap(find.text('首页+学习'));
    await tester.pumpAndSettle();
    expect(find.byType(HomePage), findsOneWidget);
    expect(find.text('详情0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手势期间另一栏的导航等待取消，之后保留参数和返回结果', (tester) async {
    final (router, navigation) = await _pump(tester);
    final studyContext = tester.element(find.byType(StudyPage));
    await tester.tap(find.text('首页入口'));
    await tester.pumpAndSettle();
    expect(await _gesture(tester, 'startBackGesture'), isTrue);
    final extra = Object();
    final result = AppNavigation.push<String>(
      studyContext,
      '/apps/probe?focus=tomorrow',
      extra: extra,
    );
    await tester.pump();
    expect(navigation.activeIndex, 0);
    expect(find.text('详情1'), findsNothing);
    await _gesture(tester, 'cancelBackGesture');
    expect(find.text('详情0'), findsOneWidget);
    expect(find.text('详情1'), findsOneWidget);
    expect(router.state.extra, same(extra));
    expect(router.state.uri.queryParameters['focus'], 'tomorrow');
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('app-pane-1')),
        matching: find.text('返回结果'),
      ),
    );
    await tester.pumpAndSettle();
    expect(await result, '返回结果');
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  for (final cancel in [false, true]) {
    testWidgets('手势${cancel ? '取消' : '完成'}时异步返回只退出所属详情一次', (tester) async {
      final (_, navigation) = await _pump(tester);
      final result = AppNavigation.push<String>(
        tester.element(find.byType(HomePage)),
        '/apps/probe',
      );
      await tester.pumpAndSettle();
      final homeContext = tester.element(find.text('详情0'));
      await tester.tap(find.text('学习入口'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('详情输入0')));
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(await _gesture(tester, 'startBackGesture'), isTrue);
      AppNavigation.pop(homeContext, '保存结果');
      await _gesture(
        tester,
        cancel ? 'cancelBackGesture' : 'commitBackGesture',
      );
      expect(await result, cancel ? '保存结果' : null);
      expect(find.text('详情0'), findsNothing);
      expect(find.byType(HomePage), findsOneWidget);
      expect(find.text('详情1'), findsOneWidget);
      expect(navigation.hasDetails(0), isFalse);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('学习详情在返回手势中收窄，${cancel ? '取消保留详情再返回' : '完成'}后显示首页', (
      tester,
    ) async {
      final (_, navigation) = await _pump(tester);
      await tester.tap(find.text('学习入口'));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('详情输入1'));
      await tester.enterText(input, '收窄前的内容');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final route = ModalRoute.of(tester.element(input))! as PageRoute;
      await _gesture(tester, 'startBackGesture');
      await _gesture(tester, 'updateBackGestureProgress', progress: .4);
      tester.view.physicalSize = const Size(390, 900);
      await tester.pumpAndSettle();
      expect(navigation.activeIndex, 1);
      expect(ModalRoute.of(tester.element(input)), same(route));
      expect(MediaQuery.sizeOf(tester.element(input)).width, 390);
      if (cancel) {
        await _gesture(tester, 'cancelBackGesture');
        expect(find.text('收窄前的内容'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      } else {
        await _gesture(tester, 'commitBackGesture');
      }
      expect(find.byType(HomePage), findsOneWidget);
      expect(find.byType(StudyPage), findsNothing);
      expect(navigation.activeIndex, 0);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  for (final dark in [false, true]) {
    testWidgets('${dark ? '深色' : '浅色'}真实课表表单保留局部保护、键盘避让与跨尺寸返回', (tester) async {
      final controller = TimetableController.instance;
      final originalClock = TimetableController.clock;
      final originalBinding = TimetableController.bindingCheck;
      final directory = Directory.systemTemp.createTempSync(
        'wide-course-form-',
      );
      TimetableStore.debugDirectory = directory;
      TimetableController.clock = () => DateTime(2026, 11, 16, 8);
      TimetableController.bindingCheck = () async => false;
      controller.debugReset();
      controller.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(termStartDate: DateTime(2026, 11, 2)),
        ),
      );
      addTearDown(() {
        TimetableStore.debugDirectory = null;
        TimetableController.clock = originalClock;
        TimetableController.bindingCheck = originalBinding;
        controller.debugReset();
        directory.deleteSync(recursive: true);
      });
      final (router, navigation) = await _pump(
        tester,
        width: 656,
        dark: dark,
        registry: AppRegistry([
          timetableManifest,
          AppManifest(
            id: 'probe',
            label: '学习测试',
            color: Colors.blue,
            showInHomeGrid: false,
            entry: (_) => const _ProbePage(),
            studyCard: StudyCardContribution(
              builder: (_) => const _ProbeCard('学习'),
              order: 0,
            ),
          ),
        ]),
      );
      final studyInput = find.byKey(const ValueKey('学习输入'));
      await tester.tap(studyInput);
      await tester.enterText(studyInput, '右栏保留内容');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.tap(find.widgetWithText(AppGridItem, '课表'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/home/apps/timetable');
      await tester.tap(find.byTooltip('添加'));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(ModalBarrier).last).width, 320);
      await tester.tap(find.byKey(const Key('add_entry_course')));
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('manual_course_name'));
      final route = ModalRoute.of(tester.element(field))! as PageRoute;
      final input = tester.widget<TextFormField>(field).controller!;
      expect(route.popGestureEnabled, isTrue);
      await tester.enterText(field, '保留的测试课程');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(route.popGestureEnabled, isFalse);
      expect(await _gesture(tester, 'startBackGesture'), isFalse);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget);
      expect(tester.getSize(find.byType(ModalBarrier).last).width, 320);
      expect(navigation.rootNavigatorKey.currentState!.canPop(), isFalse);
      await tester.tap(find.byKey(const Key('course_form_discard_cancel')));
      await tester.pumpAndSettle();
      expect(input.text, '保留的测试课程');

      final note = find.byKey(const Key('manual_course_note'));
      await tester.ensureVisible(note);
      await tester.showKeyboard(note);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.getBottomLeft(note).dy, lessThanOrEqualTo(620));
      tester.view.resetViewInsets();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.text('学习入口'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('详情1'), findsNothing);
      expect(input.text, '保留的测试课程');
      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();
      expect(await navigation.handleBack(), isFalse);
      expect(await router.routerDelegate.popRoute(), isFalse);
      await tester.tap(find.text('首页+学习'));
      await tester.pumpAndSettle();
      expect(input.text, '保留的测试课程');
      tester.view.physicalSize = const Size(390, 900);
      await tester.pumpAndSettle();
      expect(find.byType(StudyPage), findsNothing);
      expect(ModalRoute.of(tester.element(field)), same(route));
      expect(MediaQuery.sizeOf(tester.element(field)).width, 390);
      await tester.ensureVisible(field);
      await tester.enterText(field, '');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(route.popGestureEnabled, isTrue);
      expect(await _gesture(tester, 'startBackGesture'), isTrue);
      await _gesture(tester, 'updateBackGestureProgress', progress: .4);
      expect(route.animation!.value, closeTo(.6, .001));
      await _gesture(tester, 'cancelBackGesture');
      expect(input.text, '');
      expect(ModalRoute.of(tester.element(field)), same(route));
      await _gesture(tester, 'startBackGesture');
      await _gesture(tester, 'updateBackGestureProgress', progress: .4);
      await _gesture(tester, 'commitBackGesture');
      expect(find.byKey(const Key('manual_course_name')), findsNothing);
      expect(find.byType(TimetablePage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(HomePage), findsOneWidget);
      tester.view.physicalSize = const Size(656, 900);
      await tester.pumpAndSettle();
      expect(find.text('右栏保留内容'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('${dark ? '深色' : '浅色'}学习操作时普通首页公告仍在本栏显示', (tester) async {
      final pending = Completer<AnnouncementFetchResult>();
      final announcements = AnnouncementController.test(
        fetch: ({etag, lastModified}) => pending.future,
      );
      final (_, navigation) = await _pump(
        tester,
        dark: dark,
        announcements: announcements,
      );
      await tester.tap(find.text('学习入口'));
      await tester.pumpAndSettle();
      pending.complete(
        const AnnouncementFetchResult(
          notModified: false,
          items: [
            Announcement(
              id: 'local-popup',
              title: '普通首页公告',
              remind: AnnouncementRemind.popup,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('普通首页公告'), findsOneWidget);
      expect(tester.getSize(find.byType(ModalBarrier).last).width, 392);
      expect(navigation.rootNavigatorKey.currentState!.canPop(), isFalse);
      expect(find.text('详情1'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('详情1'), findsNothing);
      expect(find.text('普通首页公告'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('普通首页公告'), findsNothing);
    });

    testWidgets('${dark ? '深色' : '浅色'}阻断公告覆盖整个窗口，过期后恢复详情返回', (tester) async {
      var now = DateTime(2026, 11, 20);
      final pending = Completer<AnnouncementFetchResult>();
      final announcements = AnnouncementController.test(
        now: () => now,
        fetch: ({etag, lastModified}) => pending.future,
      );
      final (_, navigation) = await _pump(
        tester,
        dark: dark,
        announcements: announcements,
      );
      await tester.tap(find.text('学习入口'));
      await tester.pumpAndSettle();
      final route =
          ModalRoute.of(tester.element(find.text('详情1')))! as PageRoute;
      pending.complete(
        AnnouncementFetchResult(
          notModified: false,
          items: [
            Announcement(
              id: 'global-blocking',
              title: '全局阻断公告',
              dismissible: false,
              expiresAt: now.add(const Duration(seconds: 1)),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(ModalBarrier).last).width, 800);
      expect(navigation.rootNavigatorKey.currentState!.canPop(), isTrue);
      expect(route.popGestureEnabled, isFalse);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('全局阻断公告'), findsOneWidget);
      tester.view.physicalSize = const Size(390, 900);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(ModalBarrier).last).width, 390);
      now = now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('全局阻断公告'), findsNothing);
      expect(ModalRoute.of(tester.element(find.text('详情1'))), same(route));
      expect(route.popGestureEnabled, isTrue);
      await _gesture(tester, 'startBackGesture');
      await _gesture(tester, 'commitBackGesture');
      expect(find.byType(HomePage), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('${dark ? '深色' : '浅色'}两栏只让目标页面跟随预测性返回，取消保留状态', (tester) async {
      final (_, navigation) = await _pump(tester, dark: dark);
      await tester.tap(find.text('学习入口'));
      await tester.pumpAndSettle();
      final studyRoute =
          ModalRoute.of(tester.element(find.text('详情1')))! as PageRoute;
      await tester.tap(find.text('首页入口'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('内部入口0'));
      await tester.pumpAndSettle();
      final homeRoute =
          ModalRoute.of(tester.element(find.text('内部详情0')))! as PageRoute;
      expect(studyRoute.popGestureEnabled, isFalse);
      expect(homeRoute.popGestureEnabled, isTrue);
      expect(await _gesture(tester, 'startBackGesture'), isTrue);
      navigation.interact(1);
      await _gesture(tester, 'updateBackGestureProgress', progress: 0.4);
      expect(homeRoute.animation!.value, closeTo(0.6, 0.001));
      expect(studyRoute.animation!.value, 1);
      expect(navigation.activeIndex, 0);
      await _gesture(tester, 'cancelBackGesture');
      expect(find.text('内部详情0'), findsOneWidget);
      await _gesture(tester, 'startBackGesture');
      await _gesture(tester, 'updateBackGestureProgress', progress: 0.4);
      await _gesture(tester, 'commitBackGesture');
      expect(find.text('内部详情0'), findsNothing);
      expect(find.text('详情1'), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
}
