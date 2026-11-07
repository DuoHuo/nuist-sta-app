// 公告 UI：铃铛红点、列表模态框、悬浮条、自动弹出、不可关闭弹窗。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/colors.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_api.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_controller.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_models.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_overlay.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_sheet.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_web_page.dart';
// 复用现有 WebView 插件的平台接口，不新增测试依赖。
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

Announcement a(
  String id, {
  AnnouncementRemind remind = AnnouncementRemind.none,
  bool dismissible = true,
  DateTime? expiresAt,
  String content = '',
  AnnouncementLink? link,
}) => Announcement(
  id: id,
  title: '标题$id',
  summary: '摘要$id',
  content: content,
  remind: remind,
  dismissible: dismissible,
  expiresAt: expiresAt,
  link: link,
);

DateTime clock = DateTime.utc(2026, 1, 1);

AnnouncementController controllerWith(
  List<Announcement> items, {
  Future<AnnouncementFetchResult> Function()? fetch,
}) {
  clock = DateTime.utc(2026, 1, 1);
  return AnnouncementController.test(
    fetch: ({etag, lastModified}) =>
        fetch?.call() ??
        Future.value(AnnouncementFetchResult(notModified: false, items: items)),
    now: () => clock,
  );
}

Widget app(AnnouncementController c) => MaterialApp(
  home: Scaffold(
    appBar: AppBar(actions: [AnnouncementBell(controller: c)]),
    body: AnnouncementOverlay(controller: c, child: const SizedBox.expand()),
  ),
);

bool redDot(WidgetTester tester) =>
    tester.widget<Badge>(find.byType(Badge)).isLabelVisible;

void main() {
  for (final dark in [false, true]) {
    for (final scenario in [
      (name: '小屏', size: const Size(320, 640), scale: 1.0, keyboard: 0.0),
      (name: '大字', size: const Size(320, 640), scale: 2.0, keyboard: 0.0),
      (name: '横屏', size: const Size(740, 360), scale: 1.3, keyboard: 0.0),
      (name: '键盘', size: const Size(375, 667), scale: 1.3, keyboard: 300.0),
      (name: '平板', size: const Size(1024, 768), scale: 1.0, keyboard: 0.0),
    ]) {
      testWidgets('${dark ? '深色' : '浅色'}公告${scenario.name}下正文可读、末尾可达并能关闭', (
        tester,
      ) async {
        tester.view.physicalSize = scenario.size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final c = controllerWith([
          Announcement(
            id: 'long',
            title: '这是一条需要换行显示完整内容的公告标题',
            summary: '摘要与正文之间保持紧凑而清晰的间距',
            content: [
              '第一段保留段内换行\n这一行属于同一段。',
              for (var i = 0; i < 12; i++) '第 $i 段：正文可以滚动阅读，不能被固定高度裁掉。',
              '最后一段',
            ].join('\n\n'),
          ),
          a('末条', content: '全部公告阅读完成'),
        ]);
        addTearDown(c.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? appDarkTheme() : appLightTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scenario.scale),
                viewInsets: EdgeInsets.only(bottom: scenario.keyboard),
              ),
              child: child!,
            ),
            home: Scaffold(
              appBar: AppBar(actions: [AnnouncementBell(controller: c)]),
              body: AnnouncementOverlay(
                controller: c,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('公告'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final panel = tester.getRect(find.byType(AnnouncementListPanel));
        expect(panel.left, greaterThanOrEqualTo(20));
        expect(panel.right, lessThanOrEqualTo(scenario.size.width - 20));
        expect(panel.width, lessThanOrEqualTo(480));
        expect(
          panel.bottom,
          lessThanOrEqualTo(scenario.size.height - scenario.keyboard - 24),
        );
        final dialog = tester.widget<Dialog>(find.byType(Dialog));
        expect(
          dialog.backgroundColor,
          dark ? AppPalette.dark.surface : AppPalette.light.surface,
        );
        expect(find.text('第一段保留段内换行\n这一行属于同一段。'), findsOneWidget);
        await tester.ensureVisible(find.text('全部公告阅读完成'));
        await tester.pumpAndSettle();
        expect(find.text('全部公告阅读完成').hitTestable(), findsOneWidget);
        await tester.ensureVisible(find.text('我知道了'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('我知道了'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('${dark ? '深色' : '浅色'}空公告也有关闭操作，长链接能完整换行', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = controllerWith([]);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? appDarkTheme() : appLightTheme(),
          home: Scaffold(
            appBar: AppBar(actions: [AnnouncementBell(controller: c)]),
          ),
        ),
      );
      await c.ensureStarted();
      await tester.tap(find.byTooltip('公告'));
      await tester.pumpAndSettle();
      expect(find.text('暂无公告'), findsOneWidget);
      await tester.tap(find.text('我知道了'));
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(AnnouncementBell));
      showAnnouncementDialog(context, [
        a(
          '链接',
          link: const AnnouncementLink(
            label: '查看本次更新的完整内容与详细使用说明',
            url: 'https://example.com',
          ),
        ),
      ]);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final button = tester.getRect(find.byType(TextButton));
      final label = tester.getRect(find.text('查看本次更新的完整内容与详细使用说明'));
      expect(button.contains(label.topLeft), isTrue);
      expect(
        button.contains(label.bottomRight - const Offset(0.1, 0.1)),
        isTrue,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    });
  }

  testWidgets('公告网页仅在有历史时拦截返回，旧查询不能覆盖最新状态', (tester) async {
    final previousPlatform = WebViewPlatform.instance;
    final platform = _AnnouncementWebViewPlatform();
    WebViewPlatform.instance = platform;
    addTearDown(() {
      if (previousPlatform != null) WebViewPlatform.instance = previousPlatform;
    });
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: appLightTheme(),
        navigatorKey: navKey,
        home: const Scaffold(body: Text('公告入口')),
      ),
    );
    final route = MaterialPageRoute<void>(
      builder: (_) => const AnnouncementWebPage(
        link: AnnouncementLink(label: '公告详情', url: 'https://example.com'),
      ),
    );
    navKey.currentState!.push(route);
    await tester.pumpAndSettle();
    expect(route.popDisposition, RoutePopDisposition.pop);
    expect(route.popGestureEnabled, isTrue);

    // URL 变化包括网页自身的历史跳转，不必等整个页面加载结束。
    final controller = platform.controller;
    final delegate = platform.delegate;
    controller.hasHistory = true;
    delegate.urlChange(const UrlChange(url: 'https://example.com/detail'));
    await tester.pumpAndSettle();
    expect(route.popDisposition, RoutePopDisposition.doNotPop);
    expect(route.popGestureEnabled, isFalse);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(controller.backCalls, 1);
    expect(find.text('公告详情'), findsOneWidget);
    expect(route.popDisposition, RoutePopDisposition.pop);

    controller.hasHistory = true;
    delegate.pageStarted('https://example.com/detail');
    await tester.pumpAndSettle();
    expect(route.popDisposition, RoutePopDisposition.doNotPop);
    controller.hasHistory = false;
    delegate.pageFinished('https://example.com');
    await tester.pumpAndSettle();
    expect(route.popDisposition, RoutePopDisposition.pop);

    final staleHistory = Completer<bool>();
    final latestHistory = Completer<bool>();
    controller.historyResponses.addAll([
      staleHistory.future,
      latestHistory.future,
    ]);
    delegate.urlChange(const UrlChange(url: 'https://example.com/detail'));
    delegate.urlChange(const UrlChange(url: 'https://example.com'));
    latestHistory.complete(false);
    await tester.pumpAndSettle();
    staleHistory.complete(true);
    await tester.pumpAndSettle();
    expect(route.popDisposition, RoutePopDisposition.pop);
    expect(route.popGestureEnabled, isTrue);

    // 历史耗尽后交给路由退出，不会再次触发网页后退。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(controller.backCalls, 1);
    expect(find.text('公告详情'), findsNothing);
    expect(find.text('公告入口'), findsOneWidget);
  });

  testWidgets('铃铛红点：打开列表后标为已读并熄灭', (tester) async {
    final c = controllerWith([a('1')]);
    await tester.pumpWidget(app(c));
    await tester.pumpAndSettle();
    expect(redDot(tester), isTrue);
    expect(find.text('标题1'), findsNothing);
    await tester.tap(find.byTooltip('公告'));
    await tester.pumpAndSettle();
    expect(find.text('标题1'), findsOneWidget);
    expect(find.text('摘要1'), findsOneWidget);
    expect(redDot(tester), isFalse);
  });

  testWidgets('居中对话框，无需点击即显示完整正文，无链接不显示按钮', (tester) async {
    final c = controllerWith([a('1', content: '正文内容')]);
    await tester.pumpWidget(app(c));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('公告'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('正文内容'), findsOneWidget);
    expect(find.byIcon(Icons.open_in_new), findsNothing);
  });

  testWidgets('点链接关闭对话框并打开应用内页面', (tester) async {
    final old = announcementWebPageBuilder;
    addTearDown(() => announcementWebPageBuilder = old);
    announcementWebPageBuilder = (link) =>
        Scaffold(body: Text('网页:${link.url}'));
    final c = controllerWith([
      a(
        '1',
        content: '正文内容',
        link: const AnnouncementLink(label: '去看看', url: 'https://e.com'),
      ),
    ]);
    await tester.pumpWidget(app(c));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('公告'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('去看看'));
    await tester.pumpAndSettle();
    expect(find.text('网页:https://e.com'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('不可关闭弹窗点链接在其上打开页面，返回后弹窗仍在', (tester) async {
    final old = announcementWebPageBuilder;
    addTearDown(() => announcementWebPageBuilder = old);
    announcementWebPageBuilder = (link) => const Scaffold(body: Text('网页'));
    final c = controllerWith([
      a(
        'x',
        dismissible: false,
        expiresAt: DateTime.utc(2026, 1, 2),
        link: const AnnouncementLink(label: '详情', url: 'https://e.com'),
      ),
    ]);
    await tester.pumpWidget(app(c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('详情'));
    await tester.pumpAndSettle();
    expect(find.text('网页'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('网页'), findsNothing);
    expect(find.text('标题x'), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
  });

  testWidgets('不可关闭弹窗在网页打开期间过期：只移除弹窗，网页保留', (tester) async {
    final old = announcementWebPageBuilder;
    addTearDown(() => announcementWebPageBuilder = old);
    announcementWebPageBuilder = (link) => const Scaffold(body: Text('网页'));
    final c = controllerWith([
      a(
        'x',
        dismissible: false,
        expiresAt: DateTime.utc(2026, 1, 1, 0, 1),
        link: const AnnouncementLink(label: '详情', url: 'https://e.com'),
      ),
      a('p', remind: AnnouncementRemind.popup),
    ]);
    await tester.pumpWidget(app(c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('详情'));
    await tester.pumpAndSettle();
    expect(find.text('网页'), findsOneWidget);

    clock = DateTime.utc(2026, 1, 1, 0, 2);
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(find.text('网页'), findsOneWidget);
    expect(find.text('标题x'), findsNothing);

    // 返回首页后弹窗不残留，并接着弹未读 popup。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('网页'), findsNothing);
    expect(find.text('标题x'), findsNothing);
    expect(find.text('标题p'), findsOneWidget);
  });

  testWidgets('悬浮条单条显示标题，点 X 收起不标已读', (tester) async {
    final c = controllerWith([a('1', remind: AnnouncementRemind.badge)]);
    await tester.pumpWidget(app(c));
    await tester.pumpAndSettle();
    expect(find.text('标题1'), findsOneWidget);
    await tester.tap(find.byTooltip('收起'));
    await tester.pumpAndSettle();
    expect(find.text('标题1'), findsNothing);
    expect(c.hasUnread, isTrue);
    expect(c.unreadBadge, hasLength(1));
  });

  testWidgets('悬浮条多条显示条数，8 秒自动收起不标已读', (tester) async {
    final c = controllerWith([
      a('1', remind: AnnouncementRemind.badge),
      a('2', remind: AnnouncementRemind.badge),
    ]);
    await tester.pumpWidget(app(c));
    await tester.pump();
    await tester.pump();
    expect(find.text('共 2 条公告'), findsOneWidget);
    await tester.pump(const Duration(seconds: 9));
    expect(find.text('共 2 条公告'), findsNothing);
    expect(c.hasUnread, isTrue);
  });

  testWidgets('点悬浮条打开列表并标为已读', (tester) async {
    final c = controllerWith([a('1', remind: AnnouncementRemind.badge)]);
    await tester.pumpWidget(app(c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标题1'));
    await tester.pumpAndSettle();
    expect(find.text('公告'), findsOneWidget);
    expect(c.hasUnread, isFalse);
  });

  testWidgets('popup 自动弹出，关闭后标为已读', (tester) async {
    final c = controllerWith([a('1', remind: AnnouncementRemind.popup)]);
    await tester.pumpWidget(app(c));
    await tester.pumpAndSettle();
    expect(find.text('标题1'), findsOneWidget);
    expect(c.hasUnread, isTrue);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('标题1'), findsNothing);
    expect(c.hasUnread, isFalse);
  });

  testWidgets('不可关闭弹窗：无关闭按钮、拦截返回，过期后释放并接着弹 popup', (tester) async {
    final c = controllerWith([
      a(
        'x',
        dismissible: false,
        expiresAt: DateTime.utc(2026, 1, 1, 0, 1),
        content: '维护中',
      ),
      a('p', remind: AnnouncementRemind.popup),
    ]);
    await tester.pumpWidget(app(c));
    await tester.pumpAndSettle();
    expect(find.text('维护中'), findsOneWidget);
    expect(find.text('标题p'), findsNothing);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byTooltip('关闭'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('维护中'), findsOneWidget);
    // 已读不压制。
    await c.markAllVisibleRead();
    await tester.pumpAndSettle();
    expect(find.text('维护中'), findsOneWidget);

    clock = DateTime.utc(2026, 1, 1, 0, 2);
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(find.text('维护中'), findsNothing);
    // popup 已在上面被标为已读，故此时不再弹；铃铛仍可查看。
    expect(find.text('标题p'), findsNothing);
  });

  testWidgets('不可关闭弹窗过期后接着弹未读 popup', (tester) async {
    final c = controllerWith([
      a('x', dismissible: false, expiresAt: DateTime.utc(2026, 1, 1, 0, 1)),
      a('p', remind: AnnouncementRemind.popup),
    ]);
    await tester.pumpWidget(app(c));
    await tester.pumpAndSettle();
    expect(find.text('标题x'), findsOneWidget);
    clock = DateTime.utc(2026, 1, 1, 0, 2);
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(find.text('标题x'), findsNothing);
    expect(find.text('标题p'), findsOneWidget);
  });

  testWidgets('首页不在栈顶时不弹，回到首页后再弹', (tester) async {
    final done = Completer<AnnouncementFetchResult>();
    final c = controllerWith([], fetch: () => done.future);
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        home: Scaffold(
          body: AnnouncementOverlay(
            controller: c,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pump();
    navKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('小程序页')),
    );
    await tester.pumpAndSettle();
    done.complete(
      AnnouncementFetchResult(
        notModified: false,
        items: [a('p', remind: AnnouncementRemind.popup)],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('小程序页'), findsOneWidget);
    expect(find.text('标题p'), findsNothing);
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('标题p'), findsOneWidget);
  });
}

class _AnnouncementWebViewPlatform extends WebViewPlatform {
  late _AnnouncementWebController controller;
  late _AnnouncementNavigationDelegate delegate;

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => controller = _AnnouncementWebController(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => delegate = _AnnouncementNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _AnnouncementWebWidget(params);
}

class _AnnouncementWebController extends PlatformWebViewController {
  _AnnouncementWebController(super.params) : super.implementation();

  bool hasHistory = false;
  int backCalls = 0;
  final historyResponses = <Future<bool>>[];

  @override
  Future<bool> canGoBack() => historyResponses.isEmpty
      ? Future.value(hasHistory)
      : historyResponses.removeAt(0);

  @override
  Future<void> goBack() async {
    backCalls++;
    hasHistory = false;
  }

  @override
  Future<String?> getTitle() async => null;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}

  @override
  Future<void> loadRequest(LoadRequestParams params) async {}
}

class _AnnouncementNavigationDelegate extends PlatformNavigationDelegate {
  _AnnouncementNavigationDelegate(super.params) : super.implementation();

  late PageEventCallback pageStarted;
  late PageEventCallback pageFinished;
  late UrlChangeCallback urlChange;

  @override
  Future<void> setOnPageStarted(PageEventCallback callback) async =>
      pageStarted = callback;

  @override
  Future<void> setOnPageFinished(PageEventCallback callback) async =>
      pageFinished = callback;

  @override
  Future<void> setOnUrlChange(UrlChangeCallback callback) async =>
      urlChange = callback;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback callback,
  ) async {}

  @override
  Future<void> setOnProgress(ProgressCallback callback) async {}

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback callback) async {}
}

class _AnnouncementWebWidget extends PlatformWebViewWidget {
  _AnnouncementWebWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
