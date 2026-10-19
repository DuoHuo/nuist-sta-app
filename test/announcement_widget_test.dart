// 公告 UI：铃铛红点、列表模态框、悬浮条、自动弹出、不可关闭弹窗。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_api.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_controller.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_models.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_overlay.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_web_page.dart';

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
