// 首页冒烟测试：顶栏标题、应用宫格、底部页签与点击反馈。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nuist_sta_app/main.dart';

void main() {
  testWidgets('首页展示 APP名称 标题与校园地图入口', (WidgetTester tester) async {
    await tester.pumpWidget(const NuistApp());

    expect(find.text('APP名称'), findsOneWidget);
    expect(find.text('校园地图'), findsOneWidget);
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
  });

  testWidgets('点击校园地图显示开发中提示', (WidgetTester tester) async {
    await tester.pumpWidget(const NuistApp());

    await tester.tap(find.text('校园地图'));
    await tester.pump(); // 触发 SnackBar 入场

    expect(find.text('「校园地图」开发中'), findsOneWidget);
  });
}
