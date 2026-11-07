import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/colors.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/innovation_credit/innovation_credit_controller.dart';
import 'package:nuist_sta_app/mini_apps/innovation_credit/innovation_credit_models.dart';
import 'package:nuist_sta_app/mini_apps/innovation_credit/innovation_credit_page.dart';
import 'package:nuist_sta_app/mini_apps/score/score_controller.dart';
import 'package:nuist_sta_app/mini_apps/score/score_models.dart';
import 'package:nuist_sta_app/mini_apps/score/score_page.dart';

void main() {
  testWidgets('成绩详情页在窄屏初始态正常布局', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      // 直接用线上主题，避免测试里自备一份 ThemeData 与实现脱节。
      MaterialApp(theme: appLightTheme(), home: const ScorePage()),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, '成绩查询'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            const {'未绑定统一门户', '暂无成绩数据', '正在获取成绩…'}.contains(widget.data),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    final mode = dark ? '深色' : '浅色';

    testWidgets('$mode下 200 门成绩按可视范围挂载且可滚动至末行', (tester) async {
      final report = ScoreReport(
        records: [
          for (var index = 0; index < 200; index++)
            ScoreRecord.fromJson({
              'term': '2026-2027-1',
              'courseName': '测试课程 $index',
              'score': '80',
              'credit': '1',
            }),
        ],
        fetchedAt: DateTime.now(),
      );
      final controller = _scoreController(report);
      addTearDown(controller.dispose);
      await _pumpPage(tester, ScorePage(controller: controller), dark: dark);

      // 课程总数和通过数均为 200，两个概览指标都保留。
      expect(find.text('200 门'), findsNWidgets(2));
      await _expectLazyRows(tester, '测试课程', dark: dark);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$mode下 200 项双创学分按可视范围挂载且可滚动至末行', (tester) async {
      final credit = InnovationCredit(
        total: '200',
        grade: '合格',
        items: [
          for (var index = 0; index < 200; index++)
            InnovationCreditItem.fromJson({
              'name': '测试项目 $index',
              'score': '1',
              'date': '2026-10-01',
              'status': '审核通过',
            }),
        ],
        fetchedAt: DateTime.now(),
      );
      final controller = _innovationController(credit);
      addTearDown(controller.dispose);
      await _pumpPage(
        tester,
        InnovationCreditPage(controller: controller),
        dark: dark,
      );

      await _expectLazyRows(tester, '测试项目', dark: dark);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$mode下成绩与双创的空记录卡片保留', (tester) async {
      final score = _scoreController(
        ScoreReport(records: const [], fetchedAt: DateTime.now()),
      );
      final innovation = _innovationController(
        InnovationCredit(
          total: '0',
          grade: '',
          items: const [],
          fetchedAt: DateTime.now(),
        ),
      );
      addTearDown(score.dispose);
      addTearDown(innovation.dispose);
      await _pumpPage(tester, ScorePage(controller: score), dark: dark);
      expect(find.text('这个学期还没有成绩记录'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await _pumpPage(
        tester,
        InnovationCreditPage(controller: innovation),
        dark: dark,
      );
      expect(find.text('暂无已认定的双创学分'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

ScoreController _scoreController(ScoreReport report) =>
    ScoreController.forTesting(
      readCache: () async => report,
      saveCache: (_) async {},
      fetch: () async => report,
      bindingCheck: () async => true,
    );

InnovationCreditController _innovationController(InnovationCredit credit) =>
    InnovationCreditController.forTesting(
      readCache: () async => credit,
      saveCache: (_) async {},
      fetch: () async => credit,
      bindingCheck: () async => true,
    );

Future<void> _pumpPage(
  WidgetTester tester,
  Widget page, {
  required bool dark,
}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: dark ? appDarkTheme() : appLightTheme(), home: page),
  );
  await tester.pumpAndSettle();
}

Future<void> _expectLazyRows(
  WidgetTester tester,
  String prefix, {
  required bool dark,
}) async {
  expect(find.text('$prefix 0'), findsOneWidget);
  expect(find.text('$prefix 199', skipOffstage: false), findsNothing);
  expect(
    find
        .byWidgetPredicate(
          (widget) =>
              widget is Text && (widget.data?.startsWith(prefix) ?? false),
          skipOffstage: false,
        )
        .evaluate()
        .length,
    lessThan(30),
  );
  final decoration =
      tester.widget<DecoratedSliver>(find.byType(DecoratedSliver)).decoration
          as BoxDecoration;
  expect(
    decoration.color,
    dark ? AppPalette.dark.surface : AppPalette.light.surface,
  );
  expect(decoration.borderRadius, BorderRadius.circular(12));

  await tester.scrollUntilVisible(
    find.text('$prefix 199'),
    600,
    scrollable: find.byType(Scrollable),
    maxScrolls: 80,
  );
  await tester.pumpAndSettle();
  expect(find.text('$prefix 199').hitTestable(), findsOneWidget);
  expect(find.text('$prefix 0', skipOffstage: false), findsNothing);
}
