// 冒烟测试：注册表约束、首页宫格、小程序跳转、底部页签与点击反馈。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nuist_sta_app/app.dart';
import 'package:nuist_sta_app/core/colors.dart';
import 'package:nuist_sta_app/core/theme_mode.dart';
import 'package:nuist_sta_app/mini_apps/registry.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_sheet.dart';
import 'package:nuist_sta_app/shell/home/app_grid_item.dart';

Future<void> _pumpPhone(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(const NuistApp());
}

void main() {
  test('小程序注册表 id 全局唯一且入口完整', () {
    final ids = appRegistry.apps.map((m) => m.id).toList();
    expect(ids.toSet().length, ids.length, reason: 'id 重复会导致路由 /apps/:id 冲突');
    for (final m in appRegistry.byId.values) {
      expect(
        (m.entry == null) != (m.url == null),
        isTrue,
        reason: '${m.id} 必须恰好提供 entry（原生）或 url（H5）之一',
      );
    }
  });

  testWidgets('首页宫格、学习页卡片与我的页核心入口展示', (WidgetTester tester) async {
    await _pumpPhone(tester);

    expect(find.text('NUIST++'), findsOneWidget);
    expect(find.text('信息公告'), findsNWidgets(2));
    expect(find.text('今日课表'), findsOneWidget);
    expect(find.text('课表'), findsOneWidget);
    expect(find.text('校园地图'), findsOneWidget);
    expect(find.text('空教室'), findsOneWidget);
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    expect(find.byType(AppGridItem), findsNWidgets(8));

    await tester.tap(find.text('学习'));
    await tester.pumpAndSettle();
    for (final label in const ['本学期', '学业概览', '成绩查询', '双创学分', '劳动积分']) {
      expect(find.text(label), findsOneWidget);
    }

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(find.text('统一门户'), findsOneWidget);
    expect(find.text('点击登录'), findsNothing);
    for (final label in ['设置', '关于']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('点击校园地图或空教室进入全屏小程序页（无底部页签）', (WidgetTester tester) async {
    await _pumpPhone(tester);

    final map = find.text('校园地图');
    await tester.ensureVisible(map);
    await tester.pumpAndSettle();
    await tester.tap(map);
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
    expect(find.byTooltip('地图图层'), findsOneWidget);
    expect(find.byType(BottomNavigationBar), findsNothing);
  });

  testWidgets('我的页进入设置并切换深色模式', (WidgetTester tester) async {
    addTearDown(() => AppThemeMode.instance.value = ThemeMode.system);
    await _pumpPhone(tester);

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    for (final label in ['跟随系统', '浅色', '深色']) {
      expect(find.text(label), findsOneWidget);
    }

    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(AppThemeMode.instance.value, ThemeMode.dark);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    expect(
      Theme.of(tester.element(find.text('深色'))).brightness,
      Brightness.dark,
    );

    await tester.tap(find.text('浅色'));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.text('浅色'))).brightness,
      Brightness.light,
    );
  });

  testWidgets('深色模式下从首页打开图书馆并取消、完成预测性返回', (tester) async {
    addTearDown(() => AppThemeMode.instance.value = ThemeMode.system);
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    AppThemeMode.instance.value = ThemeMode.dark;
    await tester.pumpWidget(const NuistApp());
    await tester.ensureVisible(find.text('图书馆'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('图书馆'));
    await tester.pumpAndSettle();

    final context = tester.element(find.text('馆藏查询'));
    final route = ModalRoute.of(context)! as PageRoute;
    expect(Theme.of(context).brightness, Brightness.dark);
    expect(find.text('我的借阅'), findsOneWidget);
    Future<void> gesture(String method, [double progress = 0]) async {
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

    await gesture('startBackGesture');
    await gesture('updateBackGestureProgress', 0.4);
    expect(route.animation!.value, closeTo(0.6, 0.001));
    await gesture('cancelBackGesture');
    expect(route.isCurrent, isTrue);
    expect(find.text('馆藏查询'), findsOneWidget);

    await gesture('startBackGesture');
    await gesture('updateBackGestureProgress', 0.4);
    await gesture('commitBackGesture');
    expect(find.text('馆藏查询'), findsNothing);
    expect(find.text('NUIST++'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('路由和直接推入的页面支持预测性返回及取消', (tester) async {
    addTearDown(() => AppThemeMode.instance.value = ThemeMode.system);
    AppThemeMode.instance.value = ThemeMode.light;
    await _pumpPhone(tester);
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    final context = tester.element(find.text('深色模式'));
    final settingsRoute = ModalRoute.of(context)! as PageRoute;
    final navigator = Navigator.of(context);
    expect(settingsRoute.popGestureEnabled, isTrue);
    expect(settingsRoute.isCurrent, isTrue);
    final builder = Theme.of(context)
        .pageTransitionsTheme
        .builders[TargetPlatform.android];
    expect(builder, isA<PredictiveBackPageTransitionsBuilder>());
    expect(
      (builder! as PredictiveBackPageTransitionsBuilder).fallbackColor,
      AppPalette.of(context).pageBg,
    );
    Future<void> gesture(String method, {double progress = 0}) async {
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
      expect(response, isNotNull, reason: method);
      final result = const StandardMethodCodec().decodeEnvelope(response!);
      if (method == 'startBackGesture') {
        expect(result, isTrue);
        expect(navigator.userGestureInProgress, isTrue);
      }
      await tester.pumpAndSettle();
    }

    await gesture('startBackGesture');
    await gesture('updateBackGestureProgress', progress: 0.4);
    expect(navigator.userGestureInProgress, isTrue);
    expect(settingsRoute.animation!.value, closeTo(0.6, 0.001));
    await gesture('cancelBackGesture');
    expect(navigator.userGestureInProgress, isFalse);
    expect(settingsRoute.isCurrent, isTrue);
    expect(find.text('深色模式'), findsOneWidget);

    final detailRoute = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('内部详情')),
    );
    navigator.push(detailRoute);
    await tester.pumpAndSettle();
    await gesture('startBackGesture');
    await gesture('updateBackGestureProgress', progress: 0.4);
    expect(detailRoute.animation!.value, closeTo(0.6, 0.001));
    await gesture('commitBackGesture');
    expect(find.text('内部详情'), findsNothing);
    expect(settingsRoute.isCurrent, isTrue);

    await gesture('startBackGesture');
    await gesture('updateBackGestureProgress', progress: 0.4);
    await gesture('commitBackGesture');
    expect(find.text('深色模式'), findsNothing);
    expect(find.text('统一门户'), findsOneWidget);
    expect(navigator.canPop(), isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('窄屏直启点击首页铃铛遮罩覆盖底栏且不触发切换', (tester) async {
    addTearDown(() => AppThemeMode.instance.value = ThemeMode.system);
    AppThemeMode.instance.value = ThemeMode.dark;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.padding = const FakeViewPadding(top: 43, bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(top: 43, bottom: 24);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const NuistApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('公告'));
    await tester.pumpAndSettle();

    expect(find.byType(AnnouncementDialog), findsOneWidget);
    expect(
      tester.getSize(find.byType(ModalBarrier).last),
      const Size(390, 844),
    );
    expect(find.text('学习').hitTestable(), findsNothing);

    await tester.tapAt(tester.getCenter(find.text('学习')));
    await tester.pumpAndSettle();

    expect(find.byType(AnnouncementDialog), findsNothing);
    expect(find.text('NUIST++'), findsOneWidget);
    expect(find.text('本学期'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏详情退场动画中途底栏不抢占高度，动画结束后恢复底栏', (tester) async {
    await _pumpPhone(tester);
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('首页'), findsNothing);
    final duringHeight = tester
        .getSize(find.byKey(const ValueKey('app-pane-2')))
        .height;

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('首页'), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('app-pane-2'))).height,
      duringHeight,
    );

    await tester.pumpAndSettle();
    expect(find.text('首页'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('app-pane-2'))).height,
      lessThan(duringHeight),
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
