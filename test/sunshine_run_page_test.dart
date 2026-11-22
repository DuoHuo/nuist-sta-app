import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
    RepaintBoundary(
      key: const ValueKey('sunshine-test-frame'),
      child: MaterialApp(
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
    ),
  );
  await tester.pumpAndSettle();
}

typedef _RingPixel = ({int red, int green, int blue});

class _RingRaster {
  const _RingRaster(this.bytes, this.width, this.height, this.rect);

  final ByteData bytes;
  final int width;
  final int height;
  final Rect rect;

  // 从正上方顺时针采样页面真实绘制的像素，避免读取 Painter 配置自证。
  _RingPixel pixel(double radius, double degrees) {
    final radians = degrees * math.pi / 180;
    final scaledRadius = radius * rect.width / 128;
    final point =
        rect.center +
        Offset(
          scaledRadius * math.sin(radians),
          -scaledRadius * math.cos(radians),
        );
    final x = point.dx.floor();
    final y = point.dy.floor();
    expect(x, inInclusiveRange(0, width - 1));
    expect(y, inInclusiveRange(0, height - 1));
    final offset = (y * width + x) * 4;
    return (
      red: bytes.getUint8(offset),
      green: bytes.getUint8(offset + 1),
      blue: bytes.getUint8(offset + 2),
    );
  }
}

Future<_RingRaster> _captureRing(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('sunshine-test-frame')),
  );
  final rect = tester
      .getRect(find.byKey(const ValueKey('sunshine-dual-ring')))
      .shift(-boundary.localToGlobal(Offset.zero));
  // 图像与字节转换均依赖真实异步调度，不能在 widget 测试的 fake async 中等待。
  final raster = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return _RingRaster(bytes!, image.width, image.height, rect);
    } finally {
      image.dispose();
    }
  });
  return raster!;
}

int _pixelDifference(_RingPixel first, _RingPixel second) => math.max(
  (first.red - second.red).abs(),
  math.max(
    (first.green - second.green).abs(),
    (first.blue - second.blue).abs(),
  ),
);

void _expectFadedArc(
  _RingRaster raster, {
  required double radius,
  required double middle,
  required double fadingEnd,
  required double beyondEnd,
}) {
  final track = raster.pixel(radius, 225);
  final middleDifference = _pixelDifference(
    raster.pixel(radius, middle),
    track,
  );
  expect(middleDifference, greaterThan(60), reason: '弧线中段应完整着色');
  for (final angle in [2.0, fadingEnd]) {
    expect(
      _pixelDifference(raster.pixel(radius, angle), track),
      lessThan(middleDifference * 0.35),
      reason: '弧线 $angle° 应保留 HTML 的透明渐变端点',
    );
  }
  for (final angle in [356.0, beyondEnd]) {
    expect(
      _pixelDifference(raster.pixel(radius, angle), track),
      lessThanOrEqualTo(8),
      reason: '弧线外 $angle° 应只显示轨道，不能增加圆角端头',
    );
  }
}

void _expectBlue(_RingPixel pixel) {
  expect(pixel.blue - pixel.red, greaterThan(25));
  expect(pixel.blue - pixel.green, greaterThan(15));
}

void _expectGreen(_RingPixel pixel) {
  expect(pixel.green - pixel.red, greaterThan(25));
  expect(pixel.green - pixel.blue, greaterThan(15));
}

void _expectSun(_RingPixel pixel) {
  expect(pixel.red - pixel.blue, greaterThan(50));
  expect(pixel.green - pixel.blue, greaterThan(25));
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

void _expectRingProgress(WidgetTester tester, int total, int morning) {
  final data = tester
      .getSemantics(find.byKey(const ValueKey('sunshine-dual-ring')))
      .getSemanticsData();
  expect(data.value, '总完成率 $total%，晨跑完成率 $morning%');
}

void _expectUnclippedText(WidgetTester tester, Finder finder) {
  // 字形选择框与段落布局存在亚像素舍入差异，允许半个逻辑像素的边界误差。
  const tolerance = 0.5;
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  expect(paragraph.didExceedMaxLines, isFalse);
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(
      baseOffset: 0,
      extentOffset: paragraph.text.toPlainText().length,
    ),
  );
  expect(boxes, isNotEmpty);
  for (final box in boxes) {
    expect(box.left, greaterThanOrEqualTo(-tolerance));
    expect(box.right, lessThanOrEqualTo(paragraph.size.width + tolerance));
    expect(box.top, greaterThanOrEqualTo(-tolerance));
    expect(box.bottom, lessThanOrEqualTo(paragraph.size.height + tolerance));
  }
}

void _expectActivityColumns(WidgetTester tester, {required bool twoColumns}) {
  final tiles = [
    for (final activity in kSunshineRunActivities)
      tester.getRect(find.byKey(ValueKey('sunshine-tile-${activity.id}'))),
  ];
  if (twoColumns) {
    expect(tiles[0].top, closeTo(tiles[1].top, 0.01));
    expect(tiles[2].top, closeTo(tiles[3].top, 0.01));
    expect(tiles[0].left, closeTo(tiles[2].left, 0.01));
    expect(tiles[1].left, closeTo(tiles[3].left, 0.01));
    expect(tiles[0].width, closeTo(tiles[1].width, 0.01));
    expect(tiles[0].height, closeTo(tiles[1].height, 0.01));
    expect(tiles[2].height, closeTo(tiles[3].height, 0.01));
    final fluorescent = tester.getRect(
      find.byKey(const ValueKey('sunshine-count-fluorescent')),
    );
    final monday = tester.getRect(
      find.byKey(const ValueKey('sunshine-count-monday')),
    );
    expect(fluorescent.center.dy, closeTo(monday.center.dy, 0.5));
    expect(tiles[1].left - tiles[0].right, closeTo(8, 0.01));
    expect(tiles[3].left - tiles[2].right, closeTo(8, 0.01));
    final firstRowBottom = tiles[0].bottom > tiles[1].bottom
        ? tiles[0].bottom
        : tiles[1].bottom;
    expect(tiles[2].top - firstRowBottom, closeTo(8, 0.01));
  } else {
    for (var index = 1; index < tiles.length; index++) {
      expect(tiles[index].left, closeTo(tiles[0].left, 0.01));
      expect(tiles[index].width, closeTo(tiles[0].width, 0.01));
      expect(tiles[index].top - tiles[index - 1].bottom, closeTo(8, 0.01));
    }
  }
}

void _expectBottomStepper(WidgetTester tester, String id) {
  final tileFinder = find.byKey(ValueKey('sunshine-tile-$id'));
  expect(find.byKey(ValueKey('sunshine-quick-$id')), findsNothing);
  for (final label in ['+5', '+5 场']) {
    expect(
      find.descendant(of: tileFinder, matching: find.text(label)),
      findsNothing,
      reason: '卡片不提供独立的批量增加按钮',
    );
  }
  final tile = tester.getRect(tileFinder);
  final minus = tester.getRect(find.byKey(ValueKey('sunshine-minus-$id')));
  final count = tester.getRect(find.byKey(ValueKey('sunshine-count-$id')));
  final plus = tester.getRect(find.byKey(ValueKey('sunshine-plus-$id')));
  for (final control in [minus, count, plus]) {
    // 大字号数字可以高于按钮，同行以真实布局的垂直中心判断。
    expect(control.center.dy, closeTo(count.center.dy, 0.5));
    expect(control.left, greaterThanOrEqualTo(tile.left));
    expect(control.right, lessThanOrEqualTo(tile.right));
    expect(control.top, greaterThanOrEqualTo(tile.top));
    expect(control.bottom, lessThanOrEqualTo(tile.bottom));
  }
  expect(minus.center.dx, lessThan(count.center.dx));
  expect(count.center.dx, lessThan(plus.center.dx));
  expect(minus.right, lessThanOrEqualTo(count.left + 0.5));
  expect(count.right, lessThanOrEqualTo(plus.left + 0.5));
  final row = minus.expandToInclude(count).expandToInclude(plus);
  expect(
    tile.bottom - row.bottom,
    inInclusiveRange(0, row.height / 2),
    reason: '减号、次数与加号应位于卡片最后一行',
  );
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

  testWidgets('默认大二，仅展示当前标准与底坞，不提供年级选择及来源提示', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await _pumpPage(tester, controller);
    expect(controller.state.grade, 2);
    expect(find.text('满分 48 次 · 晨跑 15 次'), findsOneWidget);
    expect(find.byKey(const ValueKey('sunshine-dual-ring')), findsOneWidget);
    _expectRingProgress(tester, 0, 0);
    expect(find.bySemanticsLabel('选择年级'), findsNothing);
    expect(find.widgetWithText(TextButton, '大一'), findsNothing);
    expect(find.widgetWithText(TextButton, '大二'), findsNothing);
    expect(find.text('当前年级'), findsNothing);
    expect(find.byKey(const ValueKey('sunshine-grade-source')), findsNothing);
    expect(find.byTooltip('重新识别年级'), findsNothing);
    expect(
      find.byKey(const ValueKey('sunshine-edit-baseline')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('sunshine-add-custom')), findsOneWidget);
    expect(find.byKey(const ValueKey('sunshine-reset')), findsOneWidget);
    expect(find.byKey(const ValueKey('sunshine-rules')), findsOneWidget);
    expect(find.byTooltip('添加其他活动'), findsOneWidget);
    expect(find.byTooltip('重置记录'), findsOneWidget);
    expect(find.byTooltip('计算规则'), findsOneWidget);
    expect(find.text('其他活动'), findsNothing);
    expect(find.text('重置'), findsOneWidget);
    expect(find.text('规则'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('实际活动控件各增加一场，增减和弹层批量输入按场次折算', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await _pumpPage(tester, controller);
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
    expect(controller.result.morning, 3);
    await _tap(tester, find.byKey(const ValueKey('sunshine-count-morning')));
    await _tap(tester, find.widgetWithText(TextButton, '+5 场'));
    expect(controller.state.activities['morning'], 1);
    await _tap(tester, find.widgetWithText(FilledButton, '保存'));
    expect(controller.state.activities['morning'], 6);
    expect(controller.result.total, 9);
    expect(controller.result.morning, 8);
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
    expect(find.text('周一晨跑活动（2km）'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('sunshine-count-monday')));
    await tester.enterText(
      find.byKey(const ValueKey('sunshine-activity-input')),
      '7',
    );
    await _tap(tester, find.widgetWithText(TextButton, '+10 场'));
    await _tap(tester, find.widgetWithText(FilledButton, '保存'));
    expect(controller.state.activities['monday'], 17);
    expect(controller.result.total, 34);
    expect(controller.result.morning, 34);
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
    await _show(tester, find.byKey(const ValueKey('sunshine-dual-ring')));
    _expectRingProgress(tester, 63, 100);
    await _tap(tester, find.widgetWithText(TextButton, '全免 100%'));
    expect(controller.state.exemption, SunshineRunExemption.full);
    expect(controller.result.percentage, 100);
    expect(controller.result.total, 15);
    await _show(tester, find.byKey(const ValueKey('sunshine-dual-ring')));
    _expectRingProgress(tester, 100, 100);
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
    expect(find.textContaining('总次数已满，还差 1 次晨跑'), findsOneWidget);
    _expectRingProgress(tester, 100, 93);
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
    await _tap(tester, find.byKey(const ValueKey('sunshine-reset')));
    await _tap(tester, find.widgetWithText(OutlinedButton, '仅清空新增活动场次'));
    expect(controller.result.total, 5);
    expect(controller.result.morning, 2);
    expect(controller.state.customActivities.single.count, 0);
    await controller.setBaseline(0, 0);
    await controller.toggleExemption(SunshineRunExemption.half);
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const ValueKey('sunshine-reset')));
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
    testWidgets('${mode.name}下卡片底部同行计数，点击数字后可批量加五并保存', (tester) async {
      final controller = _controller();
      addTearDown(controller.dispose);
      await _pumpPage(tester, controller, mode: mode);
      await _show(tester, find.byKey(const ValueKey('sunshine-tile-regular')));
      for (final activity in kSunshineRunActivities) {
        _expectBottomStepper(tester, activity.id);
      }

      final count = find.byKey(const ValueKey('sunshine-count-morning'));
      await _tap(tester, count);
      expect(
        find.widgetWithText(TextButton, '+5 场').hitTestable(),
        findsOneWidget,
      );
      await _tap(tester, find.widgetWithText(TextButton, '+5 场'));
      expect(find.text('5'), findsOneWidget);
      expect(controller.state.activities['morning'], 0);
      await _tap(tester, find.widgetWithText(FilledButton, '保存'));
      expect(controller.state.activities['morning'], 5);
      expect(controller.result.total, 5);
      expect(controller.result.morning, 5);
      expect(
        find.byKey(const ValueKey('sunshine-activity-input')),
        findsNothing,
      );
      await _show(tester, count);
      expect(
        find.descendant(of: count, matching: find.text('5')),
        findsOneWidget,
      );
      await _tap(tester, find.byKey(const ValueKey('sunshine-plus-morning')));
      expect(controller.state.activities['morning'], 6);
      await _tap(tester, find.byKey(const ValueKey('sunshine-minus-morning')));
      expect(controller.state.activities['morning'], 5);
      _expectBottomStepper(tester, 'morning');
      expect(tester.takeException(), isNull);
    });

    testWidgets('${mode.name}下参考次数与居中双环、底部并排指标一致', (tester) async {
      final controller = _controller(
        initial: SunshineRunState.initial().withBaseline(31, 8),
      );
      addTearDown(controller.dispose);
      await _pumpPage(tester, controller, mode: mode);
      expect(find.text('65%'), findsOneWidget);
      expect(find.text('进行中'), findsOneWidget);
      _expectRingProgress(tester, 65, 53);
      expect(controller.result.status, SunshineRunStatus.incomplete);
      final ring = tester.getRect(
        find.byKey(const ValueKey('sunshine-dual-ring')),
      );
      final summary = tester.getRect(
        find.byKey(const ValueKey('sunshine-summary')),
      );
      final totalLabel = tester.getRect(find.text('累计总次数'));
      final morningLabel = tester.getRect(find.text('其中晨跑'));
      final totalFinder = find.byKey(const ValueKey('sunshine-total'));
      final morningFinder = find.byKey(const ValueKey('sunshine-morning'));
      final total = tester.getRect(totalFinder);
      final morning = tester.getRect(morningFinder);
      expect(tester.widget<Text>(totalFinder).data, '31');
      expect(tester.widget<Text>(morningFinder).data, '8');
      expect(ring.center.dx, closeTo(summary.center.dx, 0.01));
      expect(totalLabel.top, greaterThan(ring.bottom));
      expect(morningLabel.top, closeTo(totalLabel.top, 0.01));
      expect(morningLabel.left, greaterThan(totalLabel.right));
      expect(morning.top, closeTo(total.top, 0.01));
      _expectUnclippedText(tester, totalFinder);
      _expectUnclippedText(tester, morningFinder);
      expect(tester.takeException(), isNull);
    });

    testWidgets('${mode.name}下双环保持228dp、相邻环带和透明渐变端点', (tester) async {
      final controller = _controller(
        initial: SunshineRunState.initial().withBaseline(12, 6),
      );
      addTearDown(controller.dispose);
      await _pumpPage(tester, controller, mode: mode);
      _expectRingProgress(tester, 25, 40);
      final raster = await _captureRing(tester);
      expect(raster.rect.size, const Size(228, 228));
      _expectBlue(raster.pixel(58.5, 45));
      _expectSun(raster.pixel(48, 60));

      // 连接处的抗锯齿可能混合蓝橙色，应比较轨道色差而非饱和度。
      for (final radius in [51.0, 52.0, 53.0, 54.0, 55.0]) {
        expect(
          _pixelDifference(raster.pixel(radius, 45), raster.pixel(radius, 225)),
          greaterThan(40),
          reason: '归一半径 $radius 的两环连接处不能出现轨道间隙',
        );
      }
      _expectFadedArc(
        raster,
        radius: 58.5,
        middle: 45,
        fadingEnd: 87,
        beyondEnd: 94,
      );
      _expectFadedArc(
        raster,
        radius: 48,
        middle: 60,
        fadingEnd: 141,
        beyondEnd: 148,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('${mode.name}下达标、满分和全免保持双环颜色与整环连续', (tester) async {
      final controller = _controller();
      addTearDown(controller.dispose);
      await _pumpPage(tester, controller, mode: mode);
      final tracks = await _captureRing(tester);

      await controller.setBaseline(24, 15);
      await tester.pumpAndSettle();
      final passed = await _captureRing(tester);
      _expectRingProgress(tester, 50, 100);
      _expectGreen(passed.pixel(58.5, 60));
      _expectGreen(passed.pixel(48, 60));

      await controller.setBaseline(48, 15);
      await tester.pumpAndSettle();
      final full = await _captureRing(tester);
      _expectRingProgress(tester, 100, 100);
      _expectBlue(full.pixel(58.5, 60));
      _expectGreen(full.pixel(48, 60));

      await controller.toggleExemption(SunshineRunExemption.full);
      await tester.pumpAndSettle();
      final exempt = await _captureRing(tester);
      _expectRingProgress(tester, 100, 100);
      _expectBlue(exempt.pixel(58.5, 60));
      _expectBlue(exempt.pixel(48, 60));

      for (final raster in [full, exempt]) {
        for (final radius in [48.0, 58.5]) {
          for (final angle in [0.0, 90.0, 180.0, 270.0, 359.0]) {
            expect(
              _pixelDifference(
                raster.pixel(radius, angle),
                tracks.pixel(radius, angle),
              ),
              greaterThan(60),
              reason: '100% 时半径 $radius dp 的 $angle° 应完整着色',
            );
          }
          expect(
            _pixelDifference(
              raster.pixel(radius, 0),
              raster.pixel(radius, 359),
            ),
            lessThanOrEqualTo(8),
            reason: '100% 整环首尾应使用相同颜色连续相接',
          );
          expect(
            _pixelDifference(
              raster.pixel(radius, 0),
              raster.pixel(radius, 180),
            ),
            greaterThan(30),
            reason: '100% 整环仍需保留从起点到半环再返回的色彩渐变',
          );
        }
      }
      expect(tester.takeException(), isNull);
    });

    for (final layout in const [
      (390.0, 1.0, true),
      (320.0, 1.0, true),
      (360.0, 1.4, true),
      (390.0, 2.0, true),
      (280.0, 1.0, false),
    ]) {
      testWidgets('${mode.name}下${layout.$1}px、${layout.$2}倍字号活动列数与8dp间距正确', (
        tester,
      ) async {
        final controller = _controller();
        addTearDown(controller.dispose);
        await _pumpPage(
          tester,
          controller,
          mode: mode,
          width: layout.$1,
          scale: layout.$2,
        );
        expect(tester.takeException(), isNull);
        final dockTop = tester.getTopLeft(
          find.byKey(const ValueKey('sunshine-edit-baseline')),
        );
        await _show(
          tester,
          find.byKey(const ValueKey('sunshine-tile-regular')),
        );
        _expectActivityColumns(tester, twoColumns: layout.$3);
        for (final activity in kSunshineRunActivities) {
          _expectBottomStepper(tester, activity.id);
        }
        expect(
          tester.getTopLeft(
            find.byKey(const ValueKey('sunshine-edit-baseline')),
          ),
          dockTop,
        );
        for (final key in [
          'sunshine-edit-baseline',
          'sunshine-reset',
          'sunshine-rules',
        ]) {
          expect(find.byKey(ValueKey(key)).hitTestable(), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('${mode.name}下加号卡片跟随自定义活动排列，添加后仍在网格末尾', (tester) async {
      final controller = _controller(
        initial: SunshineRunState.initial().withCustomAdded(
          SunshineRunCustomActivity(
            id: 'gymnastics',
            label: '健身操',
            total: 1,
            morning: 0,
            count: 1,
          ),
        ),
      );
      addTearDown(controller.dispose);
      await _pumpPage(tester, controller, mode: mode);
      final add = find.byKey(const ValueKey('sunshine-add-custom'));
      await _show(tester, add);
      final customRect = tester.getRect(
        find.byKey(const ValueKey('sunshine-tile-gymnastics')),
      );
      final addRect = tester.getRect(add);
      expect(addRect.left - customRect.right, closeTo(8, 0.01));
      expect(addRect.top, closeTo(customRect.top, 0.01));
      expect(addRect.height, closeTo(customRect.height, 0.01));
      final icon = find.descendant(
        of: add,
        matching: find.byIcon(Icons.add_rounded),
      );
      expect(icon, findsOneWidget);
      final material = tester.widget<Material>(
        find.descendant(of: add, matching: find.byType(Material)),
      );
      expect(material.color!.b, greaterThan(material.color!.r));
      expect(
        find.descendant(of: find.byType(Scaffold), matching: add),
        findsOneWidget,
      );
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(
        find.descendant(
          of: find.byWidget(scaffold.bottomNavigationBar!),
          matching: add,
        ),
        findsNothing,
      );
      await _tap(tester, add);
      await tester.enterText(
        find.byKey(const ValueKey('sunshine-custom-name')),
        '健身房',
      );
      await tester.enterText(
        find.byKey(const ValueKey('sunshine-custom-total')),
        '2',
      );
      await _tap(tester, find.widgetWithText(FilledButton, '添加'));
      expect(controller.state.customActivities.length, 2);
      final latest = controller.state.customActivities.last;
      await _show(tester, add);
      final latestRect = tester.getRect(
        find.byKey(ValueKey('sunshine-tile-${latest.id}')),
      );
      final moved = tester.getRect(add);
      expect(moved.top - latestRect.bottom, closeTo(8, 0.01));
      expect(moved.left, closeTo(customRect.left, 0.01));
      expect(tester.takeException(), isNull);
    });

    testWidgets('${mode.name}下调整窗口与字号不会把手机活动卡片变为整行', (tester) async {
      final initial = SunshineRunState.initial()
          .withActivity('regular', 28)
          .withActivity('morning', 6)
          .withActivity('fluorescent', 5);
      final controller = _controller(initial: initial);
      addTearDown(controller.dispose);
      for (final layout in const [
        (390.0, 1.0),
        (360.0, 1.4),
        (320.0, 2.0),
        (390.0, 1.0),
      ]) {
        await _pumpPage(
          tester,
          controller,
          mode: mode,
          width: layout.$1,
          scale: layout.$2,
        );
        await _show(tester, find.byKey(const ValueKey('sunshine-tile-monday')));
        _expectActivityColumns(tester, twoColumns: true);
        for (final activity in kSunshineRunActivities) {
          _expectBottomStepper(tester, activity.id);
        }
        expect(controller.state, initial);
        expect(controller.result.total, 44);
        expect(controller.result.morning, 16);
        expect(tester.takeException(), isNull);
      }
    });

    for (final layout in const [(390.0, 1.0), (320.0, 2.0)]) {
      testWidgets('${mode.name}下${layout.$1}px、${layout.$2}倍字号完整显示长名称和大整数', (
        tester,
      ) async {
        final largeCount = kSunshineRunMaxCount ~/ 4;
        final longName = List.filled(30, '跑').join();
        final controller = _controller(
          initial: SunshineRunState.initial()
              .withBaseline(largeCount, 15)
              .withActivity('regular', largeCount)
              .withCustomAdded(
                SunshineRunCustomActivity(
                  id: 'long-name',
                  label: longName,
                  total: 1,
                  morning: 0,
                  count: 0,
                ),
              ),
        );
        addTearDown(controller.dispose);
        await _pumpPage(
          tester,
          controller,
          mode: mode,
          width: layout.$1,
          scale: layout.$2,
        );
        expect(tester.takeException(), isNull);
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('sunshine-total')))
              .data,
          '${largeCount * 2}',
        );
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('sunshine-morning')))
              .data,
          '15',
        );
        _expectUnclippedText(
          tester,
          find.byKey(const ValueKey('sunshine-total')),
        );
        await _show(
          tester,
          find.byKey(const ValueKey('sunshine-count-regular')),
        );
        final countText = find.descendant(
          of: find.byKey(const ValueKey('sunshine-count-regular')),
          matching: find.text('$largeCount'),
        );
        expect(countText, findsOneWidget);
        _expectUnclippedText(tester, countText);
        await _show(
          tester,
          find.byKey(const ValueKey('sunshine-tile-long-name')),
        );
        _expectBottomStepper(tester, 'long-name');
        expect(find.text(longName), findsOneWidget);
        _expectUnclippedText(tester, find.text(longName));
        final nameRect = tester.getRect(find.text(longName));
        final tileRect = tester.getRect(
          find.byKey(const ValueKey('sunshine-tile-long-name')),
        );
        expect(nameRect.left, greaterThanOrEqualTo(tileRect.left));
        expect(nameRect.right, lessThanOrEqualTo(tileRect.right));
        expect(nameRect.bottom, lessThanOrEqualTo(tileRect.bottom));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('${mode.name}下320px两倍字号的少量记录不会溢出环内文案', (tester) async {
      final controller = _controller(
        initial: SunshineRunState.initial().withActivity('regular', 1),
      );
      addTearDown(controller.dispose);
      await _pumpPage(tester, controller, mode: mode, width: 320, scale: 2);
      _expectRingProgress(tester, 2, 0);
      expect(find.text('进行中'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('${mode.name}下320px两倍字号及键盘弹层均可滚动访问', (tester) async {
      final controller = _controller(
        initial: SunshineRunState.initial().withBaseline(48, 14),
      );
      addTearDown(controller.dispose);
      await _pumpPage(tester, controller, mode: mode, width: 320, scale: 2);
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
        await SunshineRunController.instance.setBaseline(5, 2);
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
      expect(SunshineRunController.instance.result.total, 5);
      expect(SunshineRunController.instance.result.morning, 2);
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
