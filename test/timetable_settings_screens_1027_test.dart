// 360dp + 最大系统字号：设置首页 / 外观页（含折叠预览）浅深截图与溢出自查。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_settings_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';

final _c = TimetableController.instance;

/// Android 常见「最大」系统字号档（与 RG05 同量级并略抬高）。
const _maxTextScale = 2.0;

/// 优先单字重 TTF（FontLoader 对 TTC 不稳定），再回退 Noto CJK TTC。
const _cjkFontCandidates = <String>[
  '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
  '/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf',
  '/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  final outDir = Directory('build/screens-1027-regroup');
  var fontReady = false;
  String? fontPathUsed;

  setUpAll(() async {
    outDir.createSync(recursive: true);
    for (final path in _cjkFontCandidates) {
      final file = File(path);
      if (!file.existsSync()) continue;
      try {
        final bytes = file.readAsBytesSync();
        await (FontLoader(
          'NotoCJK',
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        fontReady = true;
        fontPathUsed = path;
        break;
      } catch (_) {
        // 试下一个候选。
      }
    }
    // ignore: avoid_print
    print(
      fontReady
          ? 'CJK font loaded: $fontPathUsed'
          : 'CJK font NOT found; screenshots may show tofu; skipping font bind',
    );

    final flutterRoot =
        Platform.environment['FLUTTER_ROOT'] ??
        '/home/tjredwolf/.local/share/nuist-dev/flutter';
    final icons = File(
      '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (icons.existsSync()) {
      await (FontLoader('MaterialIcons')..addFont(
            Future.value(ByteData.sublistView(icons.readAsBytesSync())),
          ))
          .load();
    }
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_screens_1027');
    TimetableStore.debugDirectory = tmp;
    _c.debugReset();
    _c.debugSetSnapshot(
      TimetableSnapshot(
        periods: TimetableController.defaultPeriods(),
        settings: TimetableSettings(termStartDate: DateTime(2026, 8, 31)),
        courses: [
          Course(
            id: 'a',
            name: '高等数学',
            slots: [
              CourseSlot(
                day: 1,
                startNode: 1,
                endNode: 2,
                weeks: '1' * 16,
                location: '教1-101',
                teacher: '张老师',
              ),
            ],
          ),
        ],
      ),
      viewingWeek: 1,
    );
  });

  tearDown(() {
    TimetableStore.debugDirectory = null;
    _c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  List<String> collectOverflows(List<FlutterErrorDetails> errors) {
    return [
      for (final e in errors)
        if (e.toString().contains('overflowed') ||
            (e.exceptionAsString().contains('overflowed')))
          e.exceptionAsString(),
    ];
  }

  Future<void> capture(
    WidgetTester tester,
    GlobalKey boundaryKey,
    String name,
  ) async {
    await tester.runAsync(() async {
      final render =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('${outDir.path}/$name.png');
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.pump();
  }

  ThemeData themeWithCjk(ThemeData base) {
    if (!fontReady) return base;
    // 与 timetable_cell_layout_test 一致：ThemeData.fontFamily 才能落到自定义 TextStyle。
    return ThemeData(
      brightness: base.brightness,
      colorScheme: base.colorScheme,
      fontFamily: 'NotoCJK',
      scaffoldBackgroundColor: base.scaffoldBackgroundColor,
      appBarTheme: base.appBarTheme,
      cardTheme: base.cardTheme,
      dividerColor: base.dividerColor,
      switchTheme: base.switchTheme,
      sliderTheme: base.sliderTheme,
      chipTheme: base.chipTheme,
      textButtonTheme: base.textButtonTheme,
      outlinedButtonTheme: base.outlinedButtonTheme,
      dialogTheme: base.dialogTheme,
      useMaterial3: base.useMaterial3,
      // 重建主题时保留 AppPalette 等扩展，否则深色截图会退化成浅色色板。
      extensions: base.extensions.values,
    );
  }

  Future<void> pumpCapture({
    required WidgetTester tester,
    required ThemeData theme,
    required Widget home,
    required String name,
    required Size logicalSize,
    Future<void> Function(WidgetTester tester)? afterPump,
  }) async {
    final errors = <FlutterErrorDetails>[];
    final oldOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      errors.add(details);
      oldOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = oldOnError);

    final boundary = GlobalKey();
    tester.view.physicalSize = logicalSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final themed = themeWithCjk(theme);
    await tester.pumpWidget(
      MaterialApp(
        theme: themed,
        builder: (context, child) {
          Widget built = MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(_maxTextScale),
              disableAnimations: true,
            ),
            child: child!,
          );
          if (fontReady) {
            built = DefaultTextStyle.merge(
              style: const TextStyle(fontFamily: 'NotoCJK'),
              child: built,
            );
          }
          return built;
        },
        home: RepaintBoundary(key: boundary, child: home),
      ),
    );
    await tester.pump();
    await settleIo(tester);
    if (afterPump != null) await afterPump(tester);
    await tester.pumpAndSettle();

    final overflows = collectOverflows(errors);
    expect(overflows, isEmpty, reason: '$name overflows: $overflows');
    final pending = tester.takeException();
    if (pending != null) {
      expect(
        pending.toString().contains('overflowed'),
        isFalse,
        reason: '$name pending overflow: $pending',
      );
    }
    await capture(tester, boundary, name);
  }

  testWidgets('截图 设置首页 浅/深 360dp 大字号无溢出', (tester) async {
    await pumpCapture(
      tester: tester,
      theme: appLightTheme(),
      home: TimetableSettingsPage(controller: _c, showReminderCard: true),
      name: 'settings-home-light',
      logicalSize: const Size(360, 1400),
      afterPump: (tester) async {
        // 卡片标题改为「上课提醒」；开关同行文案相同，至少两处。
        expect(find.text(TtSettingsText.reminderCard), findsWidgets);
        expect(find.text(TtSettingsText.keepAliveEntry), findsOneWidget);

        // 箭头固定在右侧：图标 left > 文案 left，且两者 top 接近（同一行）。
        final entryText = find.descendant(
          of: find.byKey(const Key('tt_settings_keepalive_entry')),
          matching: find.text(TtSettingsText.keepAliveEntry),
        );
        final entryIcon = find.descendant(
          of: find.byKey(const Key('tt_settings_keepalive_entry')),
          matching: find.byIcon(Icons.chevron_right),
        );
        expect(entryText, findsOneWidget);
        expect(entryIcon, findsOneWidget);
        final textBox = tester.getRect(entryText);
        final iconBox = tester.getRect(entryIcon);
        expect(
          iconBox.left,
          greaterThan(textBox.left),
          reason: 'keepalive chevron should stay on the right of the label',
        );
        expect(
          (iconBox.center.dy - textBox.center.dy).abs(),
          lessThan(textBox.height),
          reason: 'keepalive chevron must not drop to the next line alone',
        );
        final entryBox = tester.getRect(
          find.byKey(const Key('tt_settings_keepalive_entry')),
        );
        expect(
          entryBox.right - iconBox.right,
          lessThan(24),
          reason: 'keepalive chevron must stay pinned to the entry right edge',
        );
      },
    );
    await pumpCapture(
      tester: tester,
      theme: appDarkTheme(),
      home: TimetableSettingsPage(controller: _c, showReminderCard: true),
      name: 'settings-home-dark',
      logicalSize: const Size(360, 1400),
    );
  });

  testWidgets('设置首页：外观为置顶独立单行卡（无分组标题/副标题）；其他卡行序；点击进入外观页', (tester) async {
    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: TimetableSettingsPage(controller: _c, showReminderCard: true),
      ),
    );
    await tester.pump();

    final card = find.byKey(const Key('tt_settings_appearance_card'));
    final entry = find.byKey(const Key('tt_settings_appearance_entry'));
    expect(card, findsOneWidget);
    expect(entry, findsOneWidget);
    expect(
      tester.getTopLeft(card).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const Key('tt_settings_group_home'))).dy,
      ),
      reason: '外观卡应在「首页」卡片之前',
    );
    // 卡上方没有「外观」分组标题：整页只有行标题这一处「外观」。
    expect(find.text('外观'), findsOneWidget);
    // 行内只有标题一个 Text，没有副标题。
    expect(
      find.descendant(of: entry, matching: find.byType(Text)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: entry, matching: find.byIcon(Icons.chevron_right)),
      findsOneWidget,
    );

    // 课表管理 → 独立恢复操作 → 调试项；移除账号入口。
    expect(find.byKey(const Key('tt_settings_account')), findsNothing);
    expect(find.byKey(const Key('tt_settings_restore_jwxt')), findsNothing);
    await tester.tap(find.byKey(const Key('tt_settings_management_entry')));
    await tester.pumpAndSettle();
    final otherYs = [
      for (final k in [
        'tt_settings_day_swaps',
        'tt_settings_change_log',
        'tt_settings_restore_jwxt',
      ])
        tester.getTopLeft(find.byKey(Key(k))).dy,
    ];
    for (var i = 1; i < otherYs.length; i++) {
      expect(otherYs[i], greaterThan(otherYs[i - 1]), reason: 'other[$i]');
    }
    final debugClear = find.byKey(const Key('tt_settings_debug_clear'));
    if (debugClear.evaluate().isNotEmpty) {
      expect(
        tester.getTopLeft(debugClear).dy,
        greaterThan(otherYs.last),
        reason: '恢复教务课程应在 debug 项之前',
      );
    }
    expect(find.text('教务系统绑定'), findsNothing);

    Navigator.of(tester.element(find.byType(TimetableManagementPage))).pop();
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '外观'), findsOneWidget);
    expect(find.byKey(const Key('tt_appearance_preview_grid')), findsOneWidget);
  });

  testWidgets('设置首页外观卡：浅/深都用当前主题的卡片 surface', (tester) async {
    Future<void> pumpWith(ThemeData theme, Brightness brightness) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: TimetableSettingsPage(controller: _c, showReminderCard: true),
        ),
      );
      await tester.pumpAndSettle();
      final card = find.byKey(const Key('tt_settings_appearance_card'));
      final material = find.descendant(
        of: card,
        matching: find.byType(Material),
      );
      expect(material, findsOneWidget);
      expect(
        tester.widget<Material>(material).color,
        TimetableTheme.colorsForBrightness(brightness).surface,
      );
    }

    await pumpWith(appLightTheme(), Brightness.light);
    expect(
      TimetableTheme.colorsForBrightness(Brightness.light).surface,
      isNot(TimetableTheme.colorsForBrightness(Brightness.dark).surface),
      reason: '浅深卡片 surface 必须不同，避免写死颜色',
    );
    await pumpWith(appDarkTheme(), Brightness.dark);
  });

  testWidgets('截图 外观页折叠 浅/深 360dp 大字号无溢出', (tester) async {
    await pumpCapture(
      tester: tester,
      theme: appLightTheme(),
      home: TimetableAppearancePage(controller: _c),
      name: 'appearance-collapsed-light',
      logicalSize: const Size(360, 800),
      afterPump: (tester) async {
        expect(
          find.byKey(const Key('tt_appearance_preview_collapse_bar')),
          findsOneWidget,
        );
        // 「文字颜色」「格子字号」与「不透明度」左缘对齐（允许 1px 误差）。
        final colorLeft = tester.getTopLeft(find.text('文字颜色')).dx;
        final opacityLeft = tester.getTopLeft(find.text('不透明度')).dx;
        final fontLeft = tester.getTopLeft(find.text('格子字号')).dx;
        expect(
          (colorLeft - opacityLeft).abs(),
          lessThan(1.5),
          reason: '文字颜色 left=$colorLeft vs 不透明度 left=$opacityLeft',
        );
        expect(
          (fontLeft - opacityLeft).abs(),
          lessThan(1.5),
          reason: '格子字号 left=$fontLeft vs 不透明度 left=$opacityLeft',
        );
      },
    );
    await pumpCapture(
      tester: tester,
      theme: appDarkTheme(),
      home: TimetableAppearancePage(controller: _c),
      name: 'appearance-collapsed-dark',
      logicalSize: const Size(360, 800),
    );
  });

  testWidgets('截图 外观页展开预览 浅/深 360dp 大字号无溢出', (tester) async {
    Future<void> expand(WidgetTester tester) async {
      final bar = find.byKey(const Key('tt_appearance_preview_collapse_bar'));
      expect(bar, findsOneWidget);
      await tester.tap(bar);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('tt_appearance_preview_expanded')),
        findsOneWidget,
      );
    }

    await pumpCapture(
      tester: tester,
      theme: appLightTheme(),
      home: TimetableAppearancePage(controller: _c),
      name: 'appearance-page-light',
      logicalSize: const Size(360, 900),
      afterPump: expand,
    );
    await pumpCapture(
      tester: tester,
      theme: appDarkTheme(),
      home: TimetableAppearancePage(controller: _c),
      name: 'appearance-page-dark',
      logicalSize: const Size(360, 900),
      afterPump: expand,
    );
  });
}
