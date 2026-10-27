// 冒烟测试：注册表约束、首页宫格、小程序跳转、底部页签与点击反馈。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nuist_sta_app/app.dart';
import 'package:nuist_sta_app/core/theme_mode.dart';
import 'package:nuist_sta_app/mini_apps/registry.dart';

void main() {
  test('小程序注册表 id 全局唯一且入口完整', () {
    final ids = appRegistry.map((m) => m.id).toList();
    expect(ids.toSet().length, ids.length, reason: 'id 重复会导致路由 /apps/:id 冲突');
    for (final m in appRegistry) {
      expect(
        (m.entry == null) != (m.url == null),
        isTrue,
        reason: '${m.id} 必须恰好提供 entry（原生）或 url（H5）之一',
      );
    }
  });

  testWidgets('首页展示 NUIST++ 标题与校园地图入口', (WidgetTester tester) async {
    await tester.pumpWidget(const NuistApp());

    expect(find.text('NUIST++'), findsOneWidget);
    expect(find.text('信息公告'), findsNWidgets(2));
    expect(find.text('今日课表'), findsOneWidget);
    expect(find.text('课表'), findsOneWidget);
    expect(find.text('校园地图'), findsOneWidget);
    expect(find.text('空教室'), findsOneWidget);
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
  });

  testWidgets('点击校园地图进入小程序页（全屏、无底部页签）', (WidgetTester tester) async {
    await tester.pumpWidget(const NuistApp());

    final map = find.text('校园地图');
    await tester.ensureVisible(map);
    await tester.pumpAndSettle();
    await tester.tap(map);
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
    expect(find.byTooltip('地图图层'), findsOneWidget);
    expect(find.byType(BottomNavigationBar), findsNothing);
  });

  testWidgets('点击空教室进入查询页（全屏、无底部页签）', (WidgetTester tester) async {
    await tester.pumpWidget(const NuistApp());

    final free = find.text('空教室');
    await tester.ensureVisible(free);
    await tester.pumpAndSettle();
    await tester.tap(free);
    await tester.pumpAndSettle();

    // 测试环境下安全存储 / 文件读取永远不会完成，页面停在初始态即可；
    // 这里只确认入口链路通、页面能布局出来。
    expect(find.widgetWithText(AppBar, '空教室'), findsOneWidget);
    expect(find.text('选择教学楼'), findsOneWidget);
    expect(find.text('今天'), findsOneWidget);
    expect(find.byType(BottomNavigationBar), findsNothing);
  });

  testWidgets('切到我的页展示用户卡片与功能列表', (WidgetTester tester) async {
    await tester.pumpWidget(const NuistApp());

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();

    // 测试环境读不到安全存储，表头停在加载态。
    expect(find.text('统一门户'), findsOneWidget);
    expect(find.text('点击登录'), findsNothing);
    expect(find.text('我的社团'), findsNothing);
    expect(find.text('我的活动'), findsNothing);
    for (final label in ['设置', '关于']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('切到学习页展示五张卡片的标题', (WidgetTester tester) async {
    await tester.pumpWidget(const NuistApp());

    await tester.tap(find.text('学习'));
    await tester.pumpAndSettle();

    // 测试环境没有平台通道，各卡读不到本地状态、也不会去请求网络，
    // 只保证壳把五张卡都摆出来了。
    for (final label in ['本学期', '学业概览', '成绩查询', '双创学分', '劳动积分']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('我的页进入设置并切换深色模式', (WidgetTester tester) async {
    addTearDown(() => AppThemeMode.instance.value = ThemeMode.system);
    await tester.pumpWidget(const NuistApp());

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

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('${mode.name} 下路由和直接推入的页面支持预测性返回及取消', (tester) async {
      addTearDown(() => AppThemeMode.instance.value = ThemeMode.system);
      AppThemeMode.instance.value = mode;
      await tester.pumpWidget(const NuistApp());
      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();

      final context = tester.element(find.text('深色模式'));
      final settingsRoute = ModalRoute.of(context)! as PageRoute;
      final navigator = Navigator.of(context);
      final edge = mode == ThemeMode.light ? 0 : 1;
      expect(settingsRoute.popGestureEnabled, isTrue);
      expect(settingsRoute.isCurrent, isTrue);
      expect(Theme.of(context).platform, TargetPlatform.android);
      expect(settingsRoute.navigator, same(navigator));
      expect(
        Theme.of(context).pageTransitionsTheme.builders[TargetPlatform.android],
        isA<PredictiveBackPageTransitionsBuilder>(),
      );
      Future<void> gesture(String method, {double progress = 0}) async {
        ByteData? response;
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'flutter/backgesture',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, {
              'touchOffset': [edge == 0 ? 5.0 : 795.0, 300.0],
              'progress': progress,
              'swipeEdge': edge,
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

      // 使用实际 go_router 页面，取消时应保留页面及其路由栈。
      await gesture('startBackGesture');
      await gesture('updateBackGestureProgress', progress: 0.4);
      expect(navigator.userGestureInProgress, isTrue);
      expect(settingsRoute.animation!.value, closeTo(0.6, 0.001));
      expect(find.text('统一门户'), findsOneWidget);
      await gesture('cancelBackGesture');
      expect(navigator.userGestureInProgress, isFalse);
      expect(settingsRoute.isCurrent, isTrue);
      expect(settingsRoute.animation!.value, 1);
      expect(find.text('深色模式'), findsOneWidget);

      // 小程序内部直接 push 的 MaterialPageRoute 也应使用同一套手势。
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
  }
}
