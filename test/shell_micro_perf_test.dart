import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/app_manifest.dart';
import 'package:nuist_sta_app/core/app_registry.dart';
import 'package:nuist_sta_app/core/navigation/app_navigation.dart';
import 'package:nuist_sta_app/core/pull_to_refresh.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/main.dart' show preloadBeforeFirstFrame;
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_api.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_controller.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_home_card.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_models.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_store.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_api.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_controller.dart';
import 'package:nuist_sta_app/shell/home/app_grid_item.dart';
import 'package:nuist_sta_app/shell/home/home_page.dart';
import 'package:nuist_sta_app/shell/profile/about/about_page.dart';
import 'package:nuist_sta_app/shell/profile/settings/app_icon_bridge.dart';
import 'package:nuist_sta_app/shell/profile/settings/app_icon_controller.dart';
import 'package:nuist_sta_app/shell/profile/settings/app_icon_models.dart';
import 'package:nuist_sta_app/shell/profile/settings/app_icon_page.dart';
import 'package:nuist_sta_app/shell/profile/settings/settings_page.dart';

class _CountingScrollChild extends StatelessWidget {
  const _CountingScrollChild({required this.onBuild});

  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild();
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: const [
        SizedBox(height: 120, child: Center(child: Text('列表顶部'))),
        SizedBox(height: 800),
      ],
    );
  }
}

class _FakeAppIconBridge implements AppIconBridge {
  static const _state = AppIconState(
    supported: true,
    builtinId: AppIconIds.defaultIcon,
    canPin: true,
    customPinned: false,
    pending: false,
  );

  @override
  Future<AppIconState> getState() async => _state;

  @override
  Future<AppIconState> setBuiltin(String id) async => _state;

  @override
  Future<Uint8List?> pickImage() async => null;

  @override
  Future<AppIconState> setCustomIcon(Uint8List pngBytes) async => _state;

  @override
  Future<AppIconState> pinCustomIcon() async => _state;
}

class _FixtureBulletinApi extends BulletinApi {
  int requests = 0;

  @override
  Future<BulletinListPage> fetchPage(Uri uri, {required int pageNumber}) async {
    requests++;
    return const BulletinListPage(
      items: [
        Bulletin(
          id: 'b1',
          title: '测试选课公告',
          url: 'https://bulletin.campus.invalid/info/1/b1.htm',
          officialCategory: '教学考试',
          publisher: '测试单位',
          publishedAt: '2026-10-20',
          topicScores: {'courses': 4},
        ),
      ],
      pageNumber: 1,
    );
  }
}

class _MemoryBulletinStore extends BulletinStore {
  _MemoryBulletinStore(this.data);

  BulletinLocalData data;

  @override
  Future<BulletinLocalData> read() async => data;

  @override
  Future<void> save(BulletinLocalData data) async => this.data = data;
}

AppRegistry _sampleRegistry(int count, {String labelPrefix = '应用'}) =>
    AppRegistry([
      for (var i = 0; i < count; i++)
        AppManifest(
          id: 'app-$i',
          label: '$labelPrefix$i',
          color: Colors.blue,
          icon: Icons.apps,
          entry: (_) => Scaffold(body: Text('页面$i')),
        ),
    ]);

AnnouncementController _idleAnnouncements() => AnnouncementController.test(
  fetch: ({etag, lastModified}) async =>
      const AnnouncementFetchResult(notModified: false, items: []),
);

void main() {
  group('main() 首帧前并行预加载', () {
    testWidgets('明暗主题与隐私选择并行启动，单项超时互不拖累且总时长不超过单次超时', (tester) async {
      var themeStarted = false;
      var privacyStarted = false;
      var privacyFinished = false;
      var allFinished = false;
      final themeGate = Completer<void>();

      final future =
          preloadBeforeFirstFrame(
            loadThemeMode: () {
              themeStarted = true;
              return themeGate.future;
            },
            loadPrivacyConsent: () async {
              privacyStarted = true;
              await Future<void>.delayed(const Duration(milliseconds: 20));
              privacyFinished = true;
            },
          ).then((_) {
            allFinished = true;
          });

      expect(themeStarted, isTrue);
      expect(privacyStarted, isTrue);

      await tester.pump(const Duration(milliseconds: 20));
      expect(privacyFinished, isTrue);
      expect(allFinished, isFalse);

      await tester.pump(const Duration(milliseconds: 279));
      expect(allFinished, isFalse);

      await tester.pump(const Duration(milliseconds: 1));
      await future;
      expect(allFinished, isTrue);
    });

    testWidgets('两项同时阻塞时总等待上界仍为单个 300ms 超时', (tester) async {
      var finished = false;
      final neverA = Completer<void>();
      final neverB = Completer<void>();

      final future =
          preloadBeforeFirstFrame(
            loadThemeMode: () => neverA.future,
            loadPrivacyConsent: () => neverB.future,
          ).then((_) {
            finished = true;
          });

      await tester.pump(const Duration(milliseconds: 299));
      expect(finished, isFalse);

      await tester.pump(const Duration(milliseconds: 1));
      await future;
      expect(finished, isTrue);
    });
  });

  group('PullToRefresh 局部刷新与去外层 Opacity', () {
    testWidgets('拖拽过程不重建外部子组件与 RefreshIndicator，无外层 Opacity，且支持上推取消与松手刷新', (
      tester,
    ) async {
      var childBuilds = 0;
      var refreshCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: appLightTheme(),
          home: Scaffold(
            body: PullToRefresh(
              onRefresh: () async {
                refreshCalls++;
              },
              child: _CountingScrollChild(onBuild: () => childBuilds++),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(childBuilds, 1);

      var pullToRefreshRebuilds = 0;
      var refreshIndicatorRebuilds = 0;
      final previousHook = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        if (builtOnce) {
          if (element.widget is PullToRefresh) pullToRefreshRebuilds++;
          if (element.widget is RefreshIndicator) refreshIndicatorRebuilds++;
        }
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previousHook);

      // 1) 下拉超过阈值后再上推回阈值以内松手 -> 取消刷新，全程不重建外壳与子组件。
      final cancelGesture = await tester.startGesture(const Offset(200, 100));
      await cancelGesture.moveBy(const Offset(0, 60));
      await tester.pump();
      await cancelGesture.moveBy(const Offset(0, 60));
      await tester.pump();

      final indicatorFinder = find.byType(RefreshProgressIndicator);
      expect(indicatorFinder, findsOneWidget);
      expect(
        find.ancestor(of: indicatorFinder, matching: find.byType(Opacity)),
        findsNothing,
      );
      final midIndicator = tester.widget<RefreshProgressIndicator>(
        indicatorFinder,
      );
      expect(midIndicator.color, isNotNull);
      expect(midIndicator.color!.a, greaterThan(0));
      expect(midIndicator.color!.a, lessThan(1));

      await cancelGesture.moveBy(const Offset(0, 100));
      await tester.pump();
      expect(
        tester.widget<RefreshProgressIndicator>(indicatorFinder).semanticsLabel,
        '松手刷新',
      );
      expect(
        tester.widget<RefreshProgressIndicator>(indicatorFinder).color!.a,
        closeTo(1.0, 0.001),
      );

      // 上推取消。
      await cancelGesture.moveBy(const Offset(0, -140));
      await tester.pump();
      expect(
        tester.widget<RefreshProgressIndicator>(indicatorFinder).semanticsLabel,
        '下拉刷新',
      );
      await cancelGesture.up();
      await tester.pump();

      expect(refreshCalls, 0);
      expect(indicatorFinder, findsNothing);
      expect(childBuilds, 1);
      expect(pullToRefreshRebuilds, 0);
      expect(refreshIndicatorRebuilds, 0);

      // 2) 再次下拉超过阈值直接松手 -> 拖拽阶段零外壳重建，松手触发刷新。
      final triggerGesture = await tester.startGesture(const Offset(200, 100));
      await triggerGesture.moveBy(const Offset(0, 90));
      await tester.pump();
      await triggerGesture.moveBy(const Offset(0, 110));
      await tester.pump();
      expect(childBuilds, 1);
      expect(pullToRefreshRebuilds, 0);
      expect(refreshIndicatorRebuilds, 0);

      await triggerGesture.up();
      await tester.pumpAndSettle();

      expect(refreshCalls, 1);
      expect(childBuilds, 1);
      expect(pullToRefreshRebuilds, 0);
      expect(tester.takeException(), isNull);
    });
  });

  group('应用图标 Image.asset 按 dpr 指定解码尺寸', () {
    testWidgets(
      'AboutPage / SettingsPage / AppIconPage 图标均传入预期 cacheWidth/Height',
      (tester) async {
        for (final dpr in [1.0, 2.625]) {
          tester.view.devicePixelRatio = dpr;
          tester.view.physicalSize = Size(400 * dpr, 900 * dpr);
          addTearDown(tester.view.reset);

          // AboutPage: 72dp
          await tester.pumpWidget(
            MaterialApp(theme: appLightTheme(), home: const AboutPage()),
          );
          await tester.pump();
          final aboutImage = tester.widget<Image>(
            find.byWidgetPredicate(
              (w) => w is Image && w.semanticLabel?.endsWith('图标') == true,
            ),
          );
          final aboutProvider = aboutImage.image as ResizeImage;
          expect(aboutProvider.width, (72 * dpr).round());
          expect(aboutProvider.height, (72 * dpr).round());
          expect(
            (aboutProvider.imageProvider as AssetImage).assetName,
            'assets/images/app_icon.png',
          );

          // SettingsPage: 44dp
          await tester.pumpWidget(
            MaterialApp(
              theme: appLightTheme(),
              home: const SettingsPage(showAppIconEntry: true),
            ),
          );
          await tester.pumpAndSettle();
          final settingsImage = tester.widget<Image>(
            find.descendant(
              of: find.byKey(const Key('settings_app_icon')),
              matching: find.byType(Image),
            ),
          );
          final settingsProvider = settingsImage.image as ResizeImage;
          expect(settingsProvider.width, (44 * dpr).round());
          expect(settingsProvider.height, (44 * dpr).round());

          // AppIconPage: 64dp (全部 3 款内置图标)
          final iconController = AppIconController(
            bridge: _FakeAppIconBridge(),
          );
          addTearDown(iconController.dispose);
          await tester.pumpWidget(
            MaterialApp(
              theme: appLightTheme(),
              home: AppIconPage(controller: iconController),
            ),
          );
          await tester.pumpAndSettle();
          for (final choice in appIconChoices) {
            final cardImage = tester.widget<Image>(
              find.descendant(
                of: find.byKey(Key('app_icon_choice_${choice.id}')),
                matching: find.byType(Image),
              ),
            );
            final cardProvider = cardImage.image as ResizeImage;
            expect(cardProvider.width, (64 * dpr).round());
            expect(cardProvider.height, (64 * dpr).round());
            expect(
              (cardProvider.imageProvider as AssetImage).assetName,
              choice.assetPath,
            );
          }
          expect(tester.takeException(), isNull);
        }
      },
    );

    testWidgets('极小 dpr 下解码尺寸兜底至少为 1，不触发断言异常', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appLightTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(devicePixelRatio: 0.001),
            child: child!,
          ),
          home: const AboutPage(),
        ),
      );
      await tester.pump();
      final aboutImage = tester.widget<Image>(
        find.byWidgetPredicate(
          (w) => w is Image && w.semanticLabel?.endsWith('图标') == true,
        ),
      );
      final provider = aboutImage.image as ResizeImage;
      expect(provider.width, 1);
      expect(provider.height, 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('HomePage 宫格去除 shrinkWrap GridView', () {
    testWidgets(
      '窄屏、320dp 大字体与宽屏均无 GridView / ShrinkWrappingViewport 且布局对齐不溢出',
      (tester) async {
        final scenarios = [
          (width: 360.0, textScale: 1.0, count: 8, dark: false),
          (width: 320.0, textScale: 2.0, count: 5, dark: false),
          (width: 320.0, textScale: 3.0, count: 5, dark: true),
          (width: 800.0, textScale: 1.0, count: 5, dark: true),
        ];

        for (final scenario in scenarios) {
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = Size(scenario.width, 900);
          addTearDown(tester.view.reset);

          final navigation = AppNavigationController();
          final announcements = _idleAnnouncements();
          addTearDown(navigation.dispose);
          addTearDown(announcements.dispose);

          await tester.pumpWidget(
            MaterialApp(
              theme: scenario.dark ? appDarkTheme() : appLightTheme(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scenario.textScale)),
                child: child!,
              ),
              home: AppNavigationScope(
                navigation: navigation,
                wide: scenario.width >= 656,
                branch: 0,
                visible: true,
                child: HomePage(
                  announcements: announcements,
                  registry: _sampleRegistry(
                    scenario.count,
                    labelPrefix: '测试入口',
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(find.byType(GridView), findsNothing);
          expect(find.byType(ShrinkWrappingViewport), findsNothing);
          expect(find.byType(AppGridItem), findsNWidgets(scenario.count));
          expect(tester.takeException(), isNull);

          // 非满行场景验证尾行首项与第一行首项列宽和左边缘对齐。
          if (scenario.count == 5 && scenario.textScale == 1.0) {
            final firstRect = tester.getRect(find.byType(AppGridItem).at(0));
            final fifthRect = tester.getRect(find.byType(AppGridItem).at(4));
            expect(fifthRect.left, closeTo(firstRect.left, 0.01));
            expect(fifthRect.width, closeTo(firstRect.width, 0.01));
            expect(fifthRect.top, closeTo(firstRect.bottom + 14, 0.01));
          }
        }
      },
    );
  });

  group('BulletinHomeCard 后台暂停周期定时器', () {
    const enabledSubscription = BulletinSubscription(
      enabled: true,
      topics: {BulletinTopic.courses},
    );

    Widget buildCard(BulletinController controller) => MaterialApp(
      theme: appLightTheme(),
      home: Scaffold(
        body: ListView(children: [BulletinHomeCard(controller: controller)]),
      ),
    );

    testWidgets('进入 paused 取消旧定时器，前台恢复后不重复请求并重新按 15 分钟轮询', (tester) async {
      final previousLifecycle = tester.binding.lifecycleState;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      addTearDown(() {
        tester.binding.handleAppLifecycleStateChanged(
          previousLifecycle ?? AppLifecycleState.resumed,
        );
      });

      final api = _FixtureBulletinApi();
      final controller = BulletinController(
        api: api,
        now: () => tester.binding.clock.now(),
        store: _MemoryBulletinStore(
          const BulletinLocalData(subscription: enabledSubscription),
        ),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(buildCard(controller));
      await tester.pumpAndSettle();
      expect(api.requests, 1);

      // 5 分钟后退后台 -> 取消原 15 分钟周期定时器。
      await tester.pump(const Duration(minutes: 5));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      // 再过 5 分钟（t=10m）回前台：受 15 分钟冷却保护不立即重复请求，但重新挂载 15 分钟定时器（将在 t=25m 触发）。
      await tester.pump(const Duration(minutes: 5));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(api.requests, 1);

      // t=16m：若旧定时器未被取消，原 t=15m 触发点已经越过 15 分钟冷却并请求；此处仍为 1 说明旧定时器确已取消。
      await tester.pump(const Duration(minutes: 6));
      expect(api.requests, 1);

      // t=25m（回前台后满 15 分钟）：新挂载的周期定时器准时触发。
      await tester.pump(const Duration(minutes: 9));
      await tester.pump();
      expect(api.requests, 2);

      // 再次退后台超过 15 分钟，后台期间零请求；回到前台立即补刷一次，再过 15 分钟周期刷新。
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(minutes: 45));
      expect(api.requests, 2);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(api.requests, 3);

      await tester.pump(const Duration(minutes: 15));
      await tester.pump();
      expect(api.requests, 4);

      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });

    testWidgets('进入 hidden 与 detached 同样暂停定时器，回前台或销毁不报错', (tester) async {
      final previousLifecycle = tester.binding.lifecycleState;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      addTearDown(() {
        tester.binding.handleAppLifecycleStateChanged(
          previousLifecycle ?? AppLifecycleState.resumed,
        );
      });

      final api = _FixtureBulletinApi();
      final controller = BulletinController(
        api: api,
        now: () => tester.binding.clock.now(),
        store: _MemoryBulletinStore(
          const BulletinLocalData(subscription: enabledSubscription),
        ),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(buildCard(controller));
      await tester.pumpAndSettle();
      expect(api.requests, 1);

      // hidden 状态暂停定时器，长时间停留在后台零请求。
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump(const Duration(minutes: 30));
      expect(api.requests, 1);

      // resumed 后刷新并恢复周期轮询。
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(api.requests, 2);

      // detached 停止定时器并在后台状态下安全销毁。
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
      await tester.pump(const Duration(minutes: 30));
      expect(api.requests, 2);

      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });

    testWidgets('处于 inactive 非前台态挂载时不启动周期定时器，切回 resumed 后再挂载轮询', (
      tester,
    ) async {
      final previousLifecycle = tester.binding.lifecycleState;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      addTearDown(() {
        tester.binding.handleAppLifecycleStateChanged(
          previousLifecycle ?? AppLifecycleState.resumed,
        );
      });

      final api = _FixtureBulletinApi();
      final controller = BulletinController(
        api: api,
        now: () => tester.binding.clock.now(),
        store: _MemoryBulletinStore(
          const BulletinLocalData(subscription: enabledSubscription),
        ),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(buildCard(controller));
      await tester.pumpAndSettle();
      expect(api.requests, 1);

      // 挂载时即为非前台态，期间推进 30 分钟不触发周期刷新。
      await tester.pump(const Duration(minutes: 30));
      expect(api.requests, 1);

      // 回到前台后补刷并挂载 15 分钟周期定时器。
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(api.requests, 2);

      await tester.pump(const Duration(minutes: 15));
      await tester.pump();
      expect(api.requests, 3);

      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  });
}
