import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/app.dart';
import 'package:nuist_sta_app/core/colors.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/core/theme_mode.dart';
import 'package:nuist_sta_app/mini_apps/registry.dart';
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

Future<void> _gesture(
  WidgetTester tester,
  String method, [
  double progress = 0,
]) async {
  ByteData? response;
  const codec = StandardMethodCodec();
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    codec.encodeMethodCall(
      MethodCall(method, {
        'touchOffset': [5.0, 300.0],
        'progress': progress,
        'swipeEdge': 0,
      }),
    ),
    (data) => response = data,
  );
  if (method == 'startBackGesture') {
    expect(codec.decodeEnvelope(response!), isTrue);
  }
  await tester.pumpAndSettle();
}

void main() {
  test('阳光跑是首页原生入口并使用跑步图标', () {
    final manifest = appRegistry.byId['sunshine-run']!;
    expect(appRegistry.homeGridApps, contains(manifest));
    expect(manifest.label, '阳光跑');
    expect(manifest.entry, isNotNull);
    expect(manifest.url, isNull);
    expect(manifest.icon, Icons.directions_run_rounded);
  });

  testWidgets('实际活动控件各增加一场，增减和快捷输入按场次折算', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await _pumpPage(tester, controller);
    for (final activity in kSunshineRunActivities) {
      await _tap(tester, find.byKey(ValueKey('sunshine-plus-${activity.id}')));
    }
    expect(controller.result.total, 7);
    expect(controller.result.morning, 6);
    await _tap(
      tester,
      find.byKey(const ValueKey('sunshine-minus-fluorescent')),
    );
    expect(controller.result.total, 5);
    expect(controller.result.morning, 4);
    await _tap(tester, find.byKey(const ValueKey('sunshine-quick-morning')));
    expect(controller.state.activities['morning'], 6);
    expect(controller.result.total, 10);
    expect(controller.result.morning, 9);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已有次数拒绝非法整数和晨跑超过总数，保存不清空新增场次', (tester) async {
    final controller = _controller(
      initial: SunshineRunState.initial().withActivity('regular', 2),
    );
    addTearDown(controller.dispose);
    await _pumpPage(tester, controller);
    await _tap(tester, find.byKey(const ValueKey('sunshine-edit-baseline')));
    await tester.enterText(
      find.byKey(const ValueKey('sunshine-base-total')),
      '1.5',
    );
    await _tap(tester, find.widgetWithText(FilledButton, '保存'));
    expect(find.textContaining('已有总次数请填写非负整数'), findsWidgets);
    expect(controller.state.baseTotal, 0);
    await tester.enterText(
      find.byKey(const ValueKey('sunshine-base-total')),
      '12',
    );
    await tester.enterText(
      find.byKey(const ValueKey('sunshine-base-morning')),
      '15',
    );
    await _tap(tester, find.widgetWithText(FilledButton, '保存'));
    expect(find.textContaining('晨跑'), findsWidgets);
    expect(controller.state.baseTotal, 0);
    await tester.enterText(
      find.byKey(const ValueKey('sunshine-base-total')),
      '24',
    );
    await _tap(tester, find.widgetWithText(FilledButton, '保存'));
    expect(controller.state.baseTotal, 24);
    expect(controller.state.baseMorning, 15);
    expect(controller.state.activities['regular'], 2);
    expect(controller.result.total, 26);
    expect(find.byKey(const ValueKey('sunshine-base-total')), findsNothing);
  });

  testWidgets('活动编辑支持任意场次及快捷增加，取消不改变记录', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await _pumpPage(tester, controller);
    await _tap(tester, find.byKey(const ValueKey('sunshine-count-monday')));
    await tester.enterText(
      find.byKey(const ValueKey('sunshine-activity-input')),
      '7',
    );
    await _tap(tester, find.widgetWithText(TextButton, '+10 场'));
    await _tap(tester, find.widgetWithText(FilledButton, '保存'));
    expect(controller.state.activities['monday'], 17);
    expect(controller.result.total, 51);
    expect(controller.result.morning, 51);
    await _tap(tester, find.byKey(const ValueKey('sunshine-count-monday')));
    await tester.enterText(
      find.byKey(const ValueKey('sunshine-activity-input')),
      '0',
    );
    await _tap(tester, find.widgetWithText(TextButton, '取消'));
    expect(controller.state.activities['monday'], 17);
  });

  testWidgets('自定义活动可添加、修改折算、删除和撤销', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await _pumpPage(tester, controller);
    await _tap(
      tester,
      find.widgetWithText(OutlinedButton, '添加其他活动（自定义总次数与晨跑）'),
    );
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
    expect(controller.result.total, 12);
    expect(controller.result.morning, 8);
    await _tap(tester, find.byTooltip('修改健身操设置'));
    await tester.enterText(
      find.byKey(const ValueKey('sunshine-custom-total')),
      '4',
    );
    await _tap(tester, find.widgetWithText(FilledButton, '保存'));
    expect(controller.result.total, 16);
    expect(controller.result.morning, 8);
    await _tap(tester, find.byTooltip('删除健身操'));
    expect(controller.state.customActivities, isEmpty);
    await _tap(tester, find.widgetWithText(SnackBarAction, '撤销'));
    expect(controller.result.total, 16);
    expect(controller.state.customActivities.single.label, '健身操');
  });

  testWidgets('半免与全免互斥并可取消，保留实际次数', (tester) async {
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
    expect(controller.result.total, 15);
    await _tap(tester, find.widgetWithText(TextButton, '全免 100%'));
    expect(controller.state.exemption, SunshineRunExemption.none);
    expect(controller.result.total, 15);
    expect(controller.result.status, SunshineRunStatus.incomplete);
  });

  testWidgets('总次数48晨跑14显示100%仍未达标，并明确晨跑差值', (tester) async {
    final controller = _controller(
      initial: SunshineRunState.initial().withBaseline(48, 14),
    );
    addTearDown(controller.dispose);
    await _pumpPage(tester, controller);
    expect(find.text('100%'), findsOneWidget);
    expect(find.text('未达标'), findsOneWidget);
    expect(find.text('总次数已满，还差 1 次晨跑即可满分'), findsOneWidget);
    expect(find.text('差 1 次'), findsOneWidget);
  });

  testWidgets('长按连增结束后停止，一次撤销恢复整个长按操作', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await _pumpPage(tester, controller);
    final button = find.byKey(const ValueKey('sunshine-plus-regular'));
    await tester.ensureVisible(button);
    final gesture = await tester.startGesture(tester.getCenter(button));
    await tester.pump(const Duration(milliseconds: 650));
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pumpAndSettle();
    final count = controller.state.activities['regular']!;
    expect(count, greaterThan(1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.state.activities['regular'], count);
    await _tap(tester, find.widgetWithText(SnackBarAction, '撤销'));
    expect(controller.state.activities['regular'], 0);
    expect(controller.canUndo, isFalse);
  });

  testWidgets('步进器不取得文本焦点时Ctrl+Z仍可撤销', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await _pumpPage(tester, controller);
    await _tap(tester, find.byKey(const ValueKey('sunshine-plus-regular')));
    expect(controller.result.total, 1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(controller.result.total, 0);
  });

  testWidgets('重置保留已有次数；零场次自定义与减免仍可清空全部', (tester) async {
    final controller = _controller(
      initial: SunshineRunState.initial()
          .withBaseline(5, 2)
          .withActivity('regular', 3)
          .withCustomAdded(
            SunshineRunCustomActivity(
              id: 'exercise',
              label: '健身操',
              total: 2,
              morning: 1,
              count: 2,
            ),
          ),
    );
    addTearDown(controller.dispose);
    await _pumpPage(tester, controller, width: 320);
    await _tap(tester, find.byTooltip('重置记录'));
    await _tap(tester, find.widgetWithText(OutlinedButton, '仅清空新增活动场次'));
    expect(controller.result.total, 5);
    expect(controller.result.morning, 2);
    expect(controller.state.customActivities.single.count, 0);
    await controller.setBaseline(0, 0);
    await controller.toggleExemption(SunshineRunExemption.half);
    await tester.pumpAndSettle();
    await _tap(tester, find.byTooltip('重置记录'));
    await _tap(tester, find.widgetWithText(OutlinedButton, '清空全部跑步记录'));
    expect(controller.state.customActivities, isEmpty);
    expect(controller.state.exemption, SunshineRunExemption.none);
    expect(controller.result.total, 0);
  });

  testWidgets('保存失败仍计算并显示即时警告与重试入口', (tester) async {
    final controller = _controller(saveFails: true);
    addTearDown(controller.dispose);
    await _pumpPage(tester, controller);
    await _tap(tester, find.byKey(const ValueKey('sunshine-plus-regular')));
    expect(controller.result.total, 1);
    await _show(tester, find.text('重试保存'));
    expect(find.text('重试保存'), findsOneWidget);
    expect(find.text('修改已用于当前计算，但本次未保存。'), findsOneWidget);
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('${mode.name}下320px两倍字号及键盘弹层均可滚动访问', (tester) async {
      final controller = _controller(
        initial: SunshineRunState.initial().withBaseline(48, 14),
      );
      addTearDown(controller.dispose);
      await _pumpPage(tester, controller, mode: mode, width: 320, scale: 2);
      expect(tester.takeException(), isNull);
      await _tap(tester, find.widgetWithText(TextButton, '半免 50%'));
      expect(tester.takeException(), isNull);
      await _tap(
        tester,
        find.widgetWithText(OutlinedButton, '添加其他活动（自定义总次数与晨跑）'),
      );
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
      await _tap(tester, find.byTooltip('计算规则'));
      await _tap(tester, find.widgetWithText(FilledButton, '知道了'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('${mode.name}下从真实首页进入并取消、完成预测性返回', (tester) async {
      final temp = await tester.runAsync(
        () => Directory.systemTemp.createTemp('nuist-sunshine-entry-'),
      );
      SunshineRunStore.debugDirectory = temp;
      addTearDown(() async {
        SunshineRunStore.debugDirectory = null;
        if (temp != null && await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });
      addTearDown(() => AppThemeMode.instance.value = ThemeMode.system);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      AppThemeMode.instance.value = mode;
      await tester.pumpWidget(const NuistApp());
      await tester.runAsync(() async {
        await SunshineRunController.instance.ensureStarted();
        await SunshineRunController.instance.resetAll();
      });
      await tester.pumpAndSettle();
      await _tap(tester, find.text('阳光跑'));
      expect(find.byType(SunshineRunPage), findsOneWidget);
      expect(find.byType(BottomNavigationBar), findsNothing);
      final context = tester.element(find.text('阳光跑计算器'));
      final route = ModalRoute.of(context)! as PageRoute;
      expect(
        AppPalette.of(context).brightness,
        mode == ThemeMode.dark ? Brightness.dark : Brightness.light,
      );
      expect(route.popGestureEnabled, isTrue);
      await _gesture(tester, 'startBackGesture');
      await _gesture(tester, 'updateBackGestureProgress', 0.4);
      expect(route.animation!.value, closeTo(0.6, 0.001));
      await _gesture(tester, 'cancelBackGesture');
      expect(route.isCurrent, isTrue);
      expect(find.byType(SunshineRunPage), findsOneWidget);
      await _gesture(tester, 'startBackGesture');
      await _gesture(tester, 'updateBackGestureProgress', 0.4);
      await _gesture(tester, 'commitBackGesture');
      expect(find.byType(SunshineRunPage), findsNothing);
      expect(find.text('NUIST++'), findsOneWidget);
      expect(find.text('阳光跑'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
}
