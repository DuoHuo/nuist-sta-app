import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/colors.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_api.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_controller.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_home_card.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_models.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_store.dart';

const _subscription = BulletinSubscription(
  enabled: true,
  topics: {BulletinTopic.courses},
);
const _old = Bulletin(
  id: 'old',
  title: '已缓存的选课通知',
  url: 'https://bulletin.campus.invalid/info/1/old.htm',
  officialCategory: '教学考试',
  publisher: '测试单位',
  publishedAt: '2026-10-18',
  topicScores: {'courses': 4},
);
const _new = Bulletin(
  id: 'new',
  title: '新的选课通知',
  url: 'https://bulletin.campus.invalid/info/1/new.htm',
  officialCategory: '教学考试',
  publisher: '测试单位',
  publishedAt: '2026-10-19',
  topicScores: {'courses': 4},
);

class _FixtureApi extends BulletinApi {
  int requests = 0;
  int failuresRemaining = 0;
  BulletinListPage page = const BulletinListPage(
    items: [_new, _old],
    pageNumber: 1,
  );
  Completer<BulletinListPage>? pending;

  @override
  Future<BulletinListPage> fetchPage(Uri uri, {required int pageNumber}) async {
    requests++;
    if (pending != null) return pending!.future;
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw TimeoutException('DioException: 测试连接超时');
    }
    return page;
  }
}

class _MemoryStore extends BulletinStore {
  _MemoryStore([this.data = const BulletinLocalData()]);

  BulletinLocalData data;

  @override
  Future<BulletinLocalData> read() async => data;

  @override
  Future<void> save(BulletinLocalData data) async => this.data = data;
}

Widget _home(BulletinController controller) => MaterialApp(
  theme: appDarkTheme(),
  home: Scaffold(
    body: ListView(children: [BulletinHomeCard(controller: controller)]),
  ),
);

void main() {
  testWidgets('首次开启订阅可修改空缓存，不再触发不可修改集合异常', (tester) async {
    final api = _FixtureApi();
    final store = _MemoryStore();
    final controller = BulletinController(api: api, store: store);
    addTearDown(controller.dispose);

    await controller.configureSubscription(
      enabled: true,
      topics: _subscription.topics,
    );
    await tester.pump();

    expect(api.requests, 1);
    expect(controller.feedUnavailable, isFalse);
    expect(controller.feedLoading, isFalse);
    expect(controller.feed, isEmpty);
    expect(store.data.baselineReady, isTrue);
    expect(store.data.knownIds, {'new', 'old'});
  });

  testWidgets('刷新超时按 2 秒和 4 秒重试，成功后只加入一次新公告', (tester) async {
    final api = _FixtureApi()..failuresRemaining = 2;
    final store = _MemoryStore(
      const BulletinLocalData(
        subscription: _subscription,
        baselineReady: true,
        knownIds: {'old'},
        feed: [_old],
      ),
    );
    final controller = BulletinController(api: api, store: store);
    addTearDown(controller.dispose);
    await controller.ensureStarted();
    await tester.pump();
    expect(api.requests, 1);
    expect(controller.feedLoading, isTrue);

    await controller.refreshFeed();
    expect(api.requests, 1);
    await tester.pump(const Duration(seconds: 2));
    expect(api.requests, 2);
    await tester.pump(const Duration(seconds: 4));

    expect(api.requests, 3);
    expect(controller.feedLoading, isFalse);
    expect(controller.feedUnavailable, isFalse);
    expect(controller.feed.map((item) => item.id), ['new', 'old']);
    expect(store.data.knownIds, {'old', 'new'});
    await controller.refreshFeed();
    expect(controller.feed.map((item) => item.id), ['new', 'old']);
  });

  testWidgets('初始化也会自动重试，成功建立基线时不把旧公告当作新动态', (tester) async {
    final api = _FixtureApi()..failuresRemaining = 1;
    final store = _MemoryStore(
      const BulletinLocalData(subscription: _subscription),
    );
    final controller = BulletinController(api: api, store: store);
    addTearDown(controller.dispose);
    await controller.ensureStarted();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(api.requests, 2);
    expect(store.data.baselineReady, isTrue);
    expect(controller.feed, isEmpty);
    expect(controller.feedUnavailable, isFalse);
  });

  testWidgets('持续失败只保留首页入口，定时刷新成功后恢复动态', (tester) async {
    final api = _FixtureApi()..failuresRemaining = 3;
    final controller = BulletinController(
      api: api,
      store: _MemoryStore(
        const BulletinLocalData(
          subscription: _subscription,
          baselineReady: true,
          knownIds: {'old'},
          feed: [_old],
        ),
      ),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_home(controller));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 4));

    expect(api.requests, 3);
    expect(controller.feedUnavailable, isTrue);
    expect(find.text('信息公告'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('信息公告')).style?.color,
      AppPalette.dark.titleText,
    );
    final card = tester.widget<Container>(
      find
          .ancestor(of: find.text('信息公告'), matching: find.byType(Container))
          .first,
    );
    expect((card.decoration! as BoxDecoration).color, AppPalette.dark.surface);
    expect(find.byType(InkWell), findsOneWidget);
    expect(find.text(_old.title), findsNothing);
    expect(find.textContaining('条动态'), findsNothing);
    expect(find.text('暂时没有匹配的新公告'), findsNothing);
    expect(find.textContaining('失败'), findsNothing);
    expect(find.textContaining('DioException'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // 网络恢复后，沿用首页每 15 分钟刷新机制恢复显示。
    await tester.pump(const Duration(minutes: 15));
    await tester.pump();

    expect(api.requests, 4);
    expect(controller.feedUnavailable, isFalse);
    expect(find.text(_new.title), findsOneWidget);
    expect(find.text(_old.title), findsOneWidget);
    expect(find.text('2 条动态'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('空订阅初始化持续失败时不显示错误或空状态提示，且不会无限重试', (tester) async {
    final api = _FixtureApi()..failuresRemaining = 100;
    final controller = BulletinController(
      api: api,
      store: _MemoryStore(const BulletinLocalData(subscription: _subscription)),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_home(controller));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(minutes: 1));

    expect(api.requests, 3);
    expect(controller.feedLoading, isFalse);
    expect(controller.feedUnavailable, isTrue);
    expect(find.text('信息公告'), findsOneWidget);
    expect(find.byType(Text), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('关闭订阅会停止剩余自动尝试', (tester) async {
    final api = _FixtureApi()..failuresRemaining = 100;
    final controller = BulletinController(
      api: api,
      store: _MemoryStore(const BulletinLocalData(subscription: _subscription)),
    );
    addTearDown(controller.dispose);
    await controller.ensureStarted();
    await tester.pump();
    await controller.configureSubscription(enabled: false, topics: {});
    await tester.pump(const Duration(seconds: 10));

    expect(api.requests, 1);
    expect(controller.feedUnavailable, isFalse);
    expect(controller.feedLoading, isFalse);
  });

  testWidgets('关闭后重新开启会丢弃旧请求，再建立新的订阅基线', (tester) async {
    final pending = Completer<BulletinListPage>();
    final api = _FixtureApi()..pending = pending;
    final store = _MemoryStore(
      const BulletinLocalData(subscription: _subscription),
    );
    final controller = BulletinController(api: api, store: store);
    addTearDown(controller.dispose);
    await controller.ensureStarted();
    await tester.pump();
    await controller.configureSubscription(enabled: false, topics: {});
    await controller.configureSubscription(
      enabled: true,
      topics: _subscription.topics,
    );
    api.pending = null;
    pending.complete(const BulletinListPage(items: [_old], pageNumber: 1));
    await tester.pump();

    expect(api.requests, 2);
    expect(store.data.knownIds, {'new', 'old'});
    expect(store.data.baselineReady, isTrue);
    expect(controller.feed, isEmpty);
    expect(controller.feedUnavailable, isFalse);
  });

  testWidgets('未订阅时仍显示开启提示，不发送请求', (tester) async {
    final api = _FixtureApi();
    final controller = BulletinController(api: api, store: _MemoryStore());
    addTearDown(controller.dispose);
    await tester.pumpWidget(_home(controller));

    expect(find.text('开启主题订阅，感兴趣的新公告会显示在这里'), findsOneWidget);
    expect(api.requests, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
