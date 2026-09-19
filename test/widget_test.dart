// 冒烟测试：注册表约束、首页宫格、小程序跳转、底部页签与点击反馈。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nuist_sta_app/app.dart';
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

  testWidgets('首页展示 NUIST STA 标题与校园地图入口', (WidgetTester tester) async {
    await tester.pumpWidget(const NuistApp());

    expect(find.text('NUIST STA'), findsOneWidget);
    expect(find.text('校园地图'), findsOneWidget);
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
  });

  testWidgets('点击校园地图进入小程序页（全屏、无底部页签）', (WidgetTester tester) async {
    await tester.pumpWidget(const NuistApp());

    await tester.tap(find.text('校园地图'));
    await tester.pumpAndSettle();

    expect(find.text('建设中'), findsOneWidget);
    expect(find.byType(BottomNavigationBar), findsNothing);
  });

  testWidgets('切到我的页展示用户卡片与功能列表', (WidgetTester tester) async {
    await tester.pumpWidget(const NuistApp());

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();

    expect(find.text('点击登录'), findsOneWidget);
    expect(find.text('登录后同步我的社团与活动'), findsOneWidget);
    for (final label in ['绑定统一门户', '我的社团', '我的活动', '设置', '关于']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('我的页点击设置显示开发中提示', (WidgetTester tester) async {
    await tester.pumpWidget(const NuistApp());

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('设置'));
    await tester.pump(); // 触发 SnackBar 入场

    expect(find.text('「设置」开发中'), findsOneWidget);
  });
}
