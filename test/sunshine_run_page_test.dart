import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/sunshine_run/sunshine_run_controller.dart';
import 'package:nuist_sta_app/mini_apps/sunshine_run/sunshine_run_models.dart';
import 'package:nuist_sta_app/mini_apps/sunshine_run/sunshine_run_page.dart';
import 'package:nuist_sta_app/mini_apps/sunshine_run/sunshine_run_store.dart';

SunshineRunController _controller({
  SunshineRunState? initial,
  bool saveFails = false,
}) => SunshineRunController.forTesting(
  read: () async =>
      SunshineRunStoreReadResult(state: initial ?? SunshineRunState.initial()),
  save: (_, {bool replaceCorrupt = false}) async => !saveFails,
);

Future<void> _pumpPage(
  WidgetTester tester,
  SunshineRunController controller, {
  ThemeMode mode = ThemeMode.light,
  double width = 390,
  double scale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await controller.ensureStarted();
  await tester.pumpWidget(
    MaterialApp(
      theme: appLightTheme(),
      darkTheme: appDarkTheme(),
      themeMode: mode,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: SunshineRunPage(controller: controller),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _show(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    final scrollable = find.byType(Scrollable).first;
    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(position.minScrollExtent);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: scrollable,
      maxScrolls: 50,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _show(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('实际活动增减、批量修改与自定义活动增删改、撤销', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await _pumpPage(tester, controller);
    expect(controller.state.grade, 2);
    expect(find.text('满分 48 次 · 晨跑 15 次'), findsOneWidget);

    for (final activity in kSunshineRunActivities) {
      await _tap(tester, find.byKey(ValueKey('sunshine-plus-${activity.id}')));
    }
    expect(controller.result.total, 6);
    expect(controller.result.morning, 5);
    await _tap(
      tester,
      find.byKey(const ValueKey('sunshine-minus-fluorescent')),
    );
    expect(controller.result.total, 4);
    await _tap(tester, find.byKey(const ValueKey('sunshine-count-morning')));
    await _tap(tester, find.widgetWithText(TextButton, '+5 场'));
    await _tap(tester, find.widgetWithText(FilledButton, '保存'));
    expect(controller.state.activities['morning'], 6);
    expect(controller.result.total, 9);

    await _tap(tester, find.byKey(const ValueKey('sunshine-add-custom')));
    await tester.enterText(
      find.byKey(const ValueKey('sunshine-custom-name')),
      '健身操',
    );
    await tester.enterText(
      find.byKey(const ValueKey('sunshine-custom-total')),
      '3',
    );
    await tester.enterText(
      find.byKey(const ValueKey('sunshine-custom-morning')),
      '2',
    );
    await tester.enterText(
      find.byKey(const ValueKey('sunshine-custom-count')),
      '4',
    );
    await _tap(tester, find.widgetWithText(FilledButton, '添加'));
    expect(controller.result.total, 21);

    await _tap(tester, find.byTooltip('修改健身操设置'));
    await tester.enterText(
      find.byKey(const ValueKey('sunshine-custom-total')),
      '4',
    );
    await _tap(tester, find.widgetWithText(FilledButton, '保存'));
    expect(controller.result.total, 25);

    await _tap(tester, find.byTooltip('删除健身操'));
    expect(controller.state.customActivities, isEmpty);
    await _tap(tester, find.widgetWithText(SnackBarAction, '撤销'));
    expect(controller.state.customActivities.single.label, '健身操');
  });

  testWidgets('半免与全免互斥取消；保存失败仍计算并提示重试', (tester) async {
    final controller = _controller(
      initial: SunshineRunState.initial().withBaseline(15, 15),
    );
    addTearDown(controller.dispose);
    await _pumpPage(tester, controller);
    await _tap(tester, find.widgetWithText(TextButton, '半免 50%'));
    expect(controller.state.exemption, SunshineRunExemption.half);
    expect(controller.result.status, SunshineRunStatus.passed);
    await _tap(tester, find.widgetWithText(TextButton, '全免 100%'));
    expect(controller.state.exemption, SunshineRunExemption.full);
    expect(controller.result.percentage, 100);
    await _tap(tester, find.widgetWithText(TextButton, '全免 100%'));
    expect(controller.state.exemption, SunshineRunExemption.none);
    expect(controller.result.status, SunshineRunStatus.incomplete);

    await tester.pumpWidget(const SizedBox.shrink());
    final failingController = _controller(saveFails: true);
    addTearDown(failingController.dispose);
    await _pumpPage(tester, failingController);
    await _tap(tester, find.byKey(const ValueKey('sunshine-plus-regular')));
    expect(failingController.result.total, 1);
    await _show(tester, find.text('重试保存'));
    expect(find.text('重试保存'), findsOneWidget);
    expect(find.text('修改已用于当前计算，但本次未保存。'), findsOneWidget);
  });

  testWidgets('320px 两倍字号及键盘弹层均可滚动访问且无溢出', (tester) async {
    final controller = _controller(
      initial: SunshineRunState.initial().withBaseline(48, 14),
    );
    addTearDown(controller.dispose);
    await _pumpPage(
      tester,
      controller,
      mode: ThemeMode.dark,
      width: 320,
      scale: 2,
    );
    expect(tester.takeException(), isNull);
    await _tap(tester, find.widgetWithText(TextButton, '半免 50%'));
    expect(tester.takeException(), isNull);
    await _tap(tester, find.byKey(const ValueKey('sunshine-add-custom')));
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('sunshine-custom-total')),
      '1',
    );
    await tester.enterText(
      find.byKey(const ValueKey('sunshine-custom-morning')),
      '2',
    );
    await _tap(tester, find.widgetWithText(FilledButton, '添加'));
    expect(controller.state.customActivities, isEmpty);
    expect(tester.takeException(), isNull);
    await _tap(tester, find.widgetWithText(TextButton, '取消'));
    expect(tester.takeException(), isNull);
    await _tap(tester, find.byKey(const ValueKey('sunshine-rules')));
    await _tap(tester, find.widgetWithText(FilledButton, '知道了'));
    expect(tester.takeException(), isNull);
  });
}
