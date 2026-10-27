// 首页宫格课表入口：图形图标（方案 A 白色日历格）与旧 glyph / icon 回退。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/app_manifest.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_manifest.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_manifest.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_tile_icon.dart';
import 'package:nuist_sta_app/shell/home/app_grid_item.dart';

Future<void> _pumpApp(WidgetTester tester, AppManifest app) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: AppGridItem(app: app, onTap: () {}),
        ),
      ),
    ),
  );
}

/// 宫格色块（入口卡片里第一个有底色的 Container）。
BoxDecoration _tileDecoration(WidgetTester tester) {
  final container = tester.widget<Container>(
    find
        .descendant(
          of: find.byType(AppGridItem),
          matching: find.byType(Container),
        )
        .first,
  );
  return container.decoration! as BoxDecoration;
}

void main() {
  group('课表入口 manifest', () {
    test('改用自定义图形图标：glyph 清空、底色与标签不变', () {
      expect(timetableManifest.iconWidget, isNotNull);
      expect(timetableManifest.glyph, isNull);
      expect(timetableManifest.color, const Color(0xFF0082EF));
      expect(timetableManifest.label, '课表');
    });
  });

  group('AppGridItem 渲染', () {
    testWidgets('课表入口不再显示「课」字，改画白色日历格', (tester) async {
      await _pumpApp(tester, timetableManifest);

      expect(find.text('课'), findsNothing);
      expect(find.text('课表'), findsOneWidget);
      expect(find.byType(TimetableTileIcon), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(TimetableTileIcon),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );
      // 图形按 24dp 摆。
      expect(
        tester.getSize(find.byType(TimetableTileIcon)),
        const Size(24, 24),
      );
      // 色块仍是品牌蓝。
      expect(_tileDecoration(tester).color, const Color(0xFF0082EF));
      expect(tester.takeException(), isNull);
    });

    testWidgets('其它小程序仍走 Material 图标，不受影响', (tester) async {
      await _pumpApp(tester, bulletinManifest);

      expect(find.byIcon(Icons.campaign_outlined), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AppGridItem),
          matching: find.byType(CustomPaint),
        ),
        findsNothing,
      );
      expect(_tileDecoration(tester).color, const Color(0xFF1687E8));
    });

    testWidgets('没有图形字段时 glyph 回退仍然生效', (tester) async {
      const glyphApp = AppManifest(
        id: 'glyph-demo',
        label: '示例',
        color: Color(0xFF123456),
        glyph: '示',
        url: 'https://example.com',
      );
      await _pumpApp(tester, glyphApp);

      expect(find.text('示'), findsOneWidget);
      expect(find.byType(TimetableTileIcon), findsNothing);
      expect(_tileDecoration(tester).color, const Color(0xFF123456));
    });
  });
}
