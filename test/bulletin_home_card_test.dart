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
const _historical = Bulletin(
  id: 'historical',
  title: '往年的选课说明',
  url: 'https://bulletin.campus.invalid/info/1/historical.htm',
  officialCategory: '教学考试',
  publisher: '测试单位',
  publishedAt: '2016-02-01',
  topicScores: {'courses': 4},
);
const _unmatched = Bulletin(
  id: 'unmatched',
  title: '讲座通知',
  url: 'https://bulletin.campus.invalid/info/1/unmatched.htm',
  officialCategory: '学术报告',
  publisher: '测试单位',
  publishedAt: '2026-10-20',
  topicScores: {'academicTalks': 4},
);

class _FixtureApi extends BulletinApi {
  int requests = 0;
  int failuresRemaining = 0;
  final otherPages = <int, BulletinListPage>{};
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
    return pageNumber == 1 ? page : otherPages[pageNumber]!;
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
  testWidgets('首次开启订阅即展示最近两条匹配公告', (tester) async {
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
    expect(controller.feed, [_new, _old]);
    expect(store.data.feed, [_new, _old]);
  });

  testWidgets('刷新按 2 秒和 4 秒重试，已有公告仍显示且不会重复', (tester) async {
    final api = _FixtureApi()..failuresRemaining = 2;
    final store = _MemoryStore(
      const BulletinLocalData(subscription: _subscription, feed: [_old]),
    );
    final controller = BulletinController(api: api, store: store);
    addTearDown(controller.dispose);
    await controller.ensureStarted();
    await tester.pump();
    expect(api.requests, 1);
    expect(controller.feedLoading, isTrue);
    await tester.pumpWidget(_home(controller));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text(_old.title), findsOneWidget);
    expect(find.text('1 条动态'), findsOneWidget);

    await controller.refreshFeed();
    expect(api.requests, 1);
    await tester.pump(const Duration(seconds: 2));
    expect(api.requests, 2);
    await tester.pump(const Duration(seconds: 4));

    expect(api.requests, 3);
    expect(controller.feedLoading, isFalse);
    expect(controller.feedUnavailable, isFalse);
    expect(controller.feed.map((item) => item.id), ['new', 'old']);
    expect(store.data.feed, [_new, _old]);
    await controller.refreshFeed();
    expect(controller.feed.map((item) => item.id), ['new', 'old']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('初始化自动重试，成功后展示已缓存且仍符合条件的公告', (tester) async {
    final api = _FixtureApi()..failuresRemaining = 1;
    final store = _MemoryStore(
      const BulletinLocalData(subscription: _subscription, feed: [_old]),
    );
    final controller = BulletinController(api: api, store: store);
    addTearDown(controller.dispose);
    await controller.ensureStarted();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(api.requests, 2);
    expect(controller.feed, [_new, _old]);
    expect(controller.feedUnavailable, isFalse);
  });

  testWidgets('按发布时间和主题选最近两条，首页不足时翻页补入更早的公告', (tester) async {
    final index = BulletinCategory.all.first.uri;
    final api = _FixtureApi()
      ..page = BulletinListPage(
        items: const [_unmatched, _new],
        pageNumber: 1,
        nextUrl: index.resolve('index_2.htm').toString(),
      )
      ..otherPages[2] = BulletinListPage(
        items: const [_new, _historical],
        pageNumber: 2,
        nextUrl: index.resolve('index_3.htm').toString(),
      );
    final controller = BulletinController(
      api: api,
      store: _MemoryStore(const BulletinLocalData(subscription: _subscription)),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_home(controller));
    await tester.pumpAndSettle();

    expect(api.requests, 2);
    expect(controller.feed, [_new, _historical]);
    expect(find.text('2 条动态'), findsOneWidget);
    expect(find.text(_historical.title), findsOneWidget);
    expect(find.text(_unmatched.title), findsNothing);

    api.page = const BulletinListPage(
      items: [_historical, _old, _new, _unmatched, _new],
      pageNumber: 1,
    );
    await controller.refreshFeed();
    await tester.pumpAndSettle();
    expect(controller.feed, [_new, _old]);
    expect(find.text(_historical.title), findsNothing);
    expect(find.text(_new.title), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('修改订阅主题会立即刷新已发布的匹配公告', (tester) async {
    final api = _FixtureApi()
      ..page = const BulletinListPage(
        items: [_new, _old, _unmatched],
        pageNumber: 1,
      );
    final controller = BulletinController(
      api: api,
      store: _MemoryStore(const BulletinLocalData(subscription: _subscription)),
    );
    addTearDown(controller.dispose);
    await controller.ensureStarted();
    await tester.pump();
    expect(controller.feed, [_new, _old]);

    await controller.configureSubscription(
      enabled: true,
      topics: {BulletinTopic.academicTalks},
    );
    await tester.pump();
    expect(api.requests, 2);
    expect(controller.feed, [_unmatched]);
  });

  testWidgets('较旧的置顶公告不会挤掉后一页的较新公告', (tester) async {
    final api = _FixtureApi()
      ..page = BulletinListPage(
        items: const [_historical, _new, _unmatched],
        pageNumber: 1,
        nextUrl: BulletinCategory.all.first.uri
            .resolve('index_2.htm')
            .toString(),
      )
      ..otherPages[2] = const BulletinListPage(items: [_old], pageNumber: 2);
    final controller = BulletinController(
      api: api,
      store: _MemoryStore(const BulletinLocalData(subscription: _subscription)),
    );
    addTearDown(controller.dispose);
    await controller.ensureStarted();
    await tester.pump();
    expect(api.requests, 2);
    expect(controller.feed, [_new, _old]);
  });

  testWidgets('持续失败只保留首页入口，定时刷新成功后恢复动态', (tester) async {
    final api = _FixtureApi()..failuresRemaining = 3;
    final controller = BulletinController(
      api: api,
      now: () => tester.binding.clock.now(),
      store: _MemoryStore(
        const BulletinLocalData(subscription: _subscription, feed: [_old]),
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
    expect(find.text('暂时没有匹配的公告'), findsNothing);
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

  testWidgets('返回前台自动刷新受十五分钟冷却，失败也冷却且手动绕过', (tester) async {
    var now = DateTime(2026, 11, 17, 12);
    final api = _FixtureApi()..failuresRemaining = 3;
    final controller = BulletinController(
      api: api,
      now: () => now,
      store: _MemoryStore(const BulletinLocalData(subscription: _subscription)),
    );
    addTearDown(controller.dispose);
    await controller.ensureStarted();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 4));
    expect(api.requests, 3);
    await controller.refreshFeed(automatic: true);
    expect(api.requests, 3);
    now = now.add(const Duration(minutes: 15));
    await controller.refreshFeed(automatic: true);
    expect(api.requests, 4);
    await controller.refreshFeed(automatic: true);
    expect(api.requests, 4);
    await controller.refreshFeed();
    expect(api.requests, 5);
    await controller.configureSubscription(
      enabled: true,
      topics: {BulletinTopic.academicTalks},
    );
    await tester.pump();
    expect(api.requests, 6);
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

  testWidgets('关闭后重新开启会丢弃旧请求，再展示当前主题匹配项', (tester) async {
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
    expect(store.data.feed, [_new, _old]);
    expect(controller.feed, [_new, _old]);
    expect(controller.feedUnavailable, isFalse);
  });

  testWidgets('未订阅时仍显示开启提示，不发送请求', (tester) async {
    final api = _FixtureApi();
    final controller = BulletinController(api: api, store: _MemoryStore());
    addTearDown(controller.dispose);
    await tester.pumpWidget(_home(controller));

    expect(find.text('开启主题订阅，在这里查看最近匹配的公告'), findsOneWidget);
    expect(api.requests, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
