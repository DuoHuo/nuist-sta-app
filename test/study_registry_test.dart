import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/app_manifest.dart';
import 'package:nuist_sta_app/core/app_registry.dart';
import 'package:nuist_sta_app/core/pull_to_refresh.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/registry.dart';
import 'package:nuist_sta_app/router.dart';
import 'package:nuist_sta_app/shell/study/study_page.dart';

Widget _entry(BuildContext context) => const Scaffold(body: Text('测试详情'));

AppManifest _card(
  String id, {
  int order = 0,
  Future<void> Function()? onRefresh,
}) => AppManifest.cardOnly(
  id: id,
  label: id,
  studyCard: StudyCardContribution(
    builder: (_) => Text(id),
    order: order,
    onRefresh: onRefresh,
  ),
);

Future<void> _pumpStudy(WidgetTester tester, AppRegistry registry) =>
    tester.pumpWidget(
      MaterialApp(
        theme: appLightTheme(),
        home: StudyPage(registry: registry),
      ),
    );

Future<void> _refreshStudy(WidgetTester tester) =>
    tester.widget<PullToRefresh>(find.byType(PullToRefresh)).onRefresh();

void main() {
  group('小程序注册能力', () {
    test('普通小程序缺少入口或同时声明两种入口时拒绝构造', () {
      expect(
        () => AppManifest(id: 'empty', label: '空入口', color: Colors.blue),
        throwsAssertionError,
      );
      expect(
        () => AppManifest(
          id: 'both',
          label: '双入口',
          color: Colors.blue,
          entry: _entry,
          url: 'https://example.com',
        ),
        throwsAssertionError,
      );
    });

    test('纯卡片不进入宫格或路由，隐藏的详情仍可通过路由访问', () {
      final card = _card('semester');
      final registry = AppRegistry([
        card,
        const AppManifest(
          id: 'detail',
          label: '学习详情',
          color: Colors.blue,
          entry: _entry,
          showInHomeGrid: false,
        ),
        const AppManifest(
          id: 'home',
          label: '首页入口',
          color: Colors.blue,
          entry: _entry,
        ),
      ]);

      expect(card.hasEntry, isFalse);
      expect(card.color, isNull);
      expect(card.showInHomeGrid, isFalse);
      expect(registry.homeGridApps.map((app) => app.id), ['home']);
      expect(registry.studyApps.map((app) => app.id), ['semester']);
      expect(registry.byId.keys, unorderedEquals(['detail', 'home']));
    });

    test('同一 id 即使分属纯卡片与详情也会被拒绝', () {
      expect(
        () => AppRegistry([
          _card('duplicate'),
          const AppManifest(
            id: 'duplicate',
            label: '重复详情',
            color: Colors.blue,
            entry: _entry,
          ),
        ]),
        throwsArgumentError,
      );
      expect(
        () => AppRegistry([_card('duplicate'), _card('duplicate')]),
        throwsArgumentError,
      );
    });

    test('学习顺序独立于登记顺序，同序按 id 稳定排列', () {
      final registry = AppRegistry([
        _card('late', order: 30),
        _card('second', order: 20),
        _card('first', order: 20),
        _card('early', order: 10),
      ]);
      expect(registry.studyApps.map((app) => app.id), [
        'early',
        'first',
        'second',
        'late',
      ]);
    });

    test('构造后不受源列表增删影响，派生集合不能被外部修改', () {
      final source = [_card('original')];
      final registry = AppRegistry(source);
      source.clear();

      expect(registry.apps.single.id, 'original');
      expect(() => registry.apps.clear(), throwsUnsupportedError);
      expect(() => registry.studyApps.clear(), throwsUnsupportedError);
      expect(() => registry.homeGridApps.clear(), throwsUnsupportedError);
      expect(() => registry.byId.clear(), throwsUnsupportedError);
    });

    test('实际学习页保持五卡及三个详情入口', () {
      expect(appRegistry.studyApps.map((app) => app.id), [
        'student-info',
        'academic',
        'scores',
        'innovation-credit',
        'labor-score',
      ]);
      expect(appRegistry.homeGridApps, hasLength(6));
      expect(appRegistry.byId.containsKey('student-info'), isFalse);
      expect(appRegistry.byId.containsKey('academic'), isFalse);
      for (final id in ['scores', 'innovation-credit', 'labor-score']) {
        expect(appRegistry.byId[id]?.hasEntry, isTrue);
      }
    });
  });

  group('学习页卡片与刷新联动', () {
    testWidgets('增删注册项同时改变展示与刷新，静态卡片无需回调', (tester) async {
      final refreshed = <String>[];
      final oldCard = _card('旧卡片', onRefresh: () async => refreshed.add('旧'));
      final newCard = _card('新卡片', onRefresh: () async => refreshed.add('新'));
      final staticCard = _card('静态卡片', order: 1);

      await _pumpStudy(tester, AppRegistry([oldCard, staticCard]));
      expect(find.text('旧卡片'), findsOneWidget);
      expect(find.text('静态卡片'), findsOneWidget);
      await _refreshStudy(tester);
      expect(refreshed, ['旧']);

      await _pumpStudy(tester, AppRegistry([newCard, staticCard]));
      expect(find.text('旧卡片'), findsNothing);
      expect(find.text('新卡片'), findsOneWidget);
      await _refreshStudy(tester);
      expect(refreshed, ['旧', '新']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('并发启动所有刷新，最后一项完成前不会结束', (tester) async {
      final started = <String>[];
      final first = Completer<void>();
      final second = Completer<void>();
      await _pumpStudy(
        tester,
        AppRegistry([
          _card(
            'first',
            onRefresh: () {
              started.add('first');
              return first.future;
            },
          ),
          _card(
            'second',
            onRefresh: () {
              started.add('second');
              return second.future;
            },
          ),
        ]),
      );

      var completed = false;
      final refresh = _refreshStudy(tester).then((_) => completed = true);
      await tester.pump();
      expect(started, unorderedEquals(['first', 'second']));
      expect(completed, isFalse);

      second.complete();
      await tester.pump();
      expect(completed, isFalse);
      first.complete();
      await refresh;
      expect(completed, isTrue);
    });

    for (final asynchronous in [false, true]) {
      testWidgets('${asynchronous ? '异步' : '同步'}抛错不会阻断其他卡片刷新或提前结束', (
        tester,
      ) async {
        final remaining = Completer<void>();
        var remainingStarted = false;
        await _pumpStudy(
          tester,
          AppRegistry([
            _card(
              'broken',
              onRefresh: () {
                final error = StateError('合成刷新失败');
                if (asynchronous) return Future<void>.error(error);
                throw error;
              },
            ),
            _card(
              'remaining',
              onRefresh: () {
                remainingStarted = true;
                return remaining.future;
              },
            ),
          ]),
        );

        var completed = false;
        final refresh = _refreshStudy(tester).then((_) => completed = true);
        await tester.pump();
        expect(remainingStarted, isTrue);
        expect(completed, isFalse);
        remaining.complete();
        await refresh;
        expect(completed, isTrue);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('没有卡片时仍可完成下拉刷新', (tester) async {
      await _pumpStudy(tester, AppRegistry([]));
      expect(find.widgetWithText(AppBar, '学习'), findsOneWidget);
      expect(find.byType(PullToRefresh), findsOneWidget);
      await _refreshStudy(tester);
      expect(tester.takeException(), isNull);
    });
  });

  group('学习详情路由', () {
    testWidgets('三个新入口全屏打开并返回学习页', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final router = buildRouter();
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(theme: appLightTheme(), routerConfig: router),
      );
      router.go('/study');
      await tester.pumpAndSettle();
      final bottomNavigation = find.byWidgetPredicate(
        (widget) => widget is Scaffold && widget.bottomNavigationBar != null,
      );

      for (final entry in const {
        'scores': '成绩查询',
        'innovation-credit': '双创学分',
        'labor-score': '劳动积分',
      }.entries) {
        final pushed = router.push<void>('/apps/${entry.key}');
        await tester.pumpAndSettle();
        expect(find.widgetWithText(AppBar, entry.value), findsOneWidget);
        expect(bottomNavigation, findsNothing);
        expect(router.canPop(), isTrue);

        await tester.pageBack();
        await tester.pumpAndSettle();
        await pushed;
        expect(find.widgetWithText(AppBar, '学习'), findsOneWidget);
        expect(bottomNavigation, findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('纯卡片与未知 id 进入未找到页，旧路径不再匹配', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final router = buildRouter();
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(theme: appLightTheme(), routerConfig: router),
      );

      for (final id in ['student-info', 'academic', 'missing-study-app']) {
        router.go('/apps/$id');
        await tester.pumpAndSettle();
        expect(find.text('小程序「$id」不存在或已下线'), findsOneWidget);
      }
      for (final path in ['/scores', '/innovation-credit', '/labor-score']) {
        router.go(path);
        await tester.pumpAndSettle();
        expect(router.routerDelegate.currentConfiguration.error, isNotNull);
      }
      expect(tester.takeException(), isNull);
    });
  });
}
