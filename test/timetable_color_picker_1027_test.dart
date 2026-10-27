// 颜色交互以主线连续取色面板为准：实时预览，保存一次返回，取消不生效。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_color_picker.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';

void main() {
  late Directory tmp;
  TimetableColorPick? result;
  late bool completed;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_cpick_1027');
    TimetableStore.debugDirectory = tmp;
    result = null;
    completed = false;
  });

  tearDown(() {
    TimetableStore.debugDirectory = null;
    tmp.deleteSync(recursive: true);
  });

  Future<void> open(
    WidgetTester tester, {
    bool dark = false,
    int opacity = 100,
    CellTextColorMode textColorMode = CellTextColorMode.auto,
  }) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: dark ? appDarkTheme() : appLightTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showTimetableColorPicker(
                  context,
                  current: const Color(0xFF3366CC),
                  defaultColor: const Color(0xFFAACCEE),
                  showReset: true,
                  previewTitle: '数据结构',
                  opacity: opacity,
                  textColorMode: textColorMode,
                );
                completed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Color? previewBg(WidgetTester tester) =>
      (tester
                  .widget<Container>(
                    find.byKey(const Key('tt_color_display_swatch')),
                  )
                  .decoration!
              as BoxDecoration)
          .color;

  test('最近自定义存储仍去重插前，最多 6 条', () async {
    expect(await TimetableStore.readRecentCustomColors(), isEmpty);
    await TimetableStore.pushRecentCustomColor(0xFF112233);
    await TimetableStore.pushRecentCustomColor(0xFF445566);
    await TimetableStore.pushRecentCustomColor(0xFF112233);
    expect(await TimetableStore.readRecentCustomColors(), [
      0xFF112233,
      0xFF445566,
    ]);
    for (var i = 0; i < 8; i++) {
      await TimetableStore.pushRecentCustomColor(0xFF000000 | (i + 1));
    }
    final recent = await TimetableStore.readRecentCustomColors();
    expect(recent, hasLength(6));
    expect(recent.first, 0xFF000008);
  });

  testWidgets('连续面板直接显示 HSV；输入色号立即预览，保存一次返回原色', (tester) async {
    await open(tester);
    expect(find.byKey(const Key('tt_color_sv_panel')), findsOneWidget);
    expect(find.byKey(const Key('tt_color_hue')), findsOneWidget);
    expect(find.byKey(const Key('tt_color_custom_plus')), findsNothing);
    await tester.enterText(find.byKey(const Key('tt_color_hex')), '445566');
    await tester.pump();
    expect(previewBg(tester), const Color(0xFF445566));
    expect(completed, isFalse);
    await tester.tap(find.byKey(const Key('tt_color_custom_apply')));
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(result!.color, const Color(0xFF445566));
    expect(result!.reset, isFalse);
    expect(find.byKey(const Key('tt_color_picker')), findsNothing);
  });

  testWidgets('六位 HEX 支持 # 与大小写，键盘提交后保存', (tester) async {
    await open(tester);
    await tester.enterText(find.byKey(const Key('tt_color_hex')), '#aAbBcC');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(previewBg(tester), const Color(0xFFAABBCC));
    await tester.tap(find.byKey(const Key('tt_color_custom_apply')));
    await tester.pumpAndSettle();
    expect(result!.color, const Color(0xFFAABBCC));
  });

  testWidgets('非法和三位 HEX 不保存，修正后可保存', (tester) async {
    await open(tester);
    for (final invalid in ['', '#', 'abc', 'gggggg', '12345']) {
      await tester.enterText(find.byKey(const Key('tt_color_hex')), invalid);
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('tt_color_custom_apply')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('tt_color_custom_apply')));
      await tester.pumpAndSettle();
      expect(completed, isFalse);
      expect(find.textContaining('请输入 6 位十六进制色号'), findsOneWidget);
      expect(previewBg(tester), const Color(0xFF3366CC));
    }
    await tester.enterText(find.byKey(const Key('tt_color_hex')), '112233');
    // 主线由 ValueListenableBuilder 在下一帧重新启用保存按钮。
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('tt_color_custom_apply')))
          .onPressed,
      isNotNull,
    );
    expect(previewBg(tester), const Color(0xFF112233));
    await tester.tap(find.byKey(const Key('tt_color_custom_apply')));
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(result, isNotNull);
    expect(result!.color, const Color(0xFF112233));
  });

  testWidgets('取消返回 null，输入不生效', (tester) async {
    await open(tester);
    await tester.enterText(find.byKey(const Key('tt_color_hex')), '112233');
    await tester.tap(find.byKey(const Key('tt_color_cancel')));
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(result, isNull);
  });

  testWidgets('恢复默认先预览，保存返回 reset', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('tt_color_reset')));
    await tester.pumpAndSettle();
    expect(previewBg(tester), const Color(0xFFAACCEE));
    expect(completed, isFalse);
    await tester.tap(find.byKey(const Key('tt_color_custom_apply')));
    await tester.pumpAndSettle();
    expect(result!.reset, isTrue);
    expect(result!.color, isNull);
  });

  for (final dark in [false, true]) {
    testWidgets('预览尊重${dark ? '深色' : '浅色'}主题、不透明度与强制文字颜色', (tester) async {
      await open(
        tester,
        dark: dark,
        opacity: 60,
        textColorMode: CellTextColorMode.white,
      );
      await tester.enterText(find.byKey(const Key('tt_color_hex')), '3873A2');
      await tester.pump();
      expect(
        previewBg(tester),
        TimetableTheme.blendCellBg(const Color(0xFF3873A2), 60, dark: dark),
      );
      expect(
        tester.widget<Text>(find.text('数据结构')).style!.color,
        TimetableTheme.forcedWhiteText,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
