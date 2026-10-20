// 课表 UI 侧用例（design/timetable-spec.md §13.8–§13.16），
// 编号对齐课表测试用例 §24（NW / LC / SW / CD / TB / HT / HP / SN / AS / EV / EX）。
// 全部为构造数据（课名「测试课甲」、老师「张老师」、地点「测试楼 A101」），不读真实样例。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_colors.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

final _c = TimetableController.instance;

/// 第 7 周（单周）：10/12–10/18；开学 2026-08-31。
const _week = 7;
final _termStart = DateTime(2026, 8, 31);

Course _course(
  String id,
  String name, {
  int day = 1,
  int start = 1,
  int end = 2,
  String weeks = '11111111111111111111',
  String location = '测试楼 A101',
  String teacher = '张老师',
  String classId = '',
  CourseSource source = CourseSource.manual,
}) => Course(
  id: id,
  name: name,
  classId: classId,
  source: source,
  slots: [
    CourseSlot(
      day: day,
      startNode: start,
      endNode: end,
      weeks: weeks,
      location: location,
      teacher: teacher,
    ),
  ],
);

void _load({
  TimetableSettings? settings,
  List<Course> manual = const [],
  List<Course> jwxt = const [],
  int week = _week,
  DateTime? syncedAt,
}) {
  _c.debugSetSnapshot(
    TimetableSnapshot(
      courses: jwxt,
      periods: TimetableController.defaultPeriods(),
      settings: settings ?? TimetableSettings(termStartDate: _termStart),
      syncedAt: syncedAt,
    ),
    viewingWeek: week,
    manualCourses: manual,
  );
}

void _bigView(WidgetTester tester, {Size size = const Size(1080, 2400)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
}

Future<void> _pumpGrid(
  WidgetTester tester, {
  int week = _week,
  double textScale = 1.0,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: WeekGrid(key: ValueKey(week), week: week, controller: _c),
      ),
    ),
  );
  await tester.pump();
}

Finder _cell(String name) => find.widgetWithText(CourseCell, name);

/// 非本周格的描边覆盖层（不在格内时返回 null）。
BoxDecoration? _cellBorder(WidgetTester tester, String name) {
  final f = find.descendant(
    of: _cell(name),
    matching: find.byKey(const Key('course_cell_off_week_border')),
  );
  if (f.evaluate().isEmpty) return null;
  return tester.widget<DecoratedBox>(f).decoration as BoxDecoration;
}

BoxDecoration _cellDecoration(WidgetTester tester, String name) =>
    tester
            .widget<Ink>(
              find.descendant(of: _cell(name), matching: find.byType(Ink)),
            )
            .decoration!
        as BoxDecoration;

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  late Directory tmp;
  final origClock = TimetableController.clock;
  final origBinding = TimetableController.bindingCheck;
  final origFetch = TimetableController.fetchSnapshot;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_ui');
    TimetableStore.debugDirectory = tmp;
    _c.debugReset();
    TimetableController.bindingCheck = () async => false;
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        throw const SocketException('offline (test)');
    TimetableController.clock = () => DateTime(2026, 10, 12, 9);
  });

  tearDown(() {
    TimetableController.clock = origClock;
    TimetableController.bindingCheck = origBinding;
    TimetableController.fetchSnapshot = origFetch;
    TimetableStore.debugDirectory = null;
    _c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // ---------------------------------------------------------------- NW
  group('NW 非本周样式（§13.8）', () {
    test('NW11 offWeekText = #6B7280，白底对比度 ≥ 4.5；描边 #DADDE3、底 #FFFFFF', () {
      expect(TimetableTheme.offWeekText, const Color(0xFF6B7280));
      expect(TimetableTheme.offWeekBorder, const Color(0xFFDADDE3));
      expect(TimetableTheme.offWeekBg, const Color(0xFFFFFFFF));
      expect(TimetableTheme.offWeekBorderWidth, 1);
      final ratio = _contrast(
        TimetableTheme.offWeekText,
        TimetableTheme.offWeekBg,
      );
      expect(ratio, greaterThanOrEqualTo(4.5));
      expect(ratio, closeTo(4.83, 0.05));
    });

    test('NW09 A/B/C 48 个底色都不是白色、文字色都不是 offWeekText', () {
      for (final scheme in CoursePaletteScheme.values) {
        final pairs = TimetableTheme.pairsOf(scheme);
        expect(pairs.length, 16);
        for (final p in pairs) {
          expect(p.bg, isNot(TimetableTheme.offWeekBg), reason: '$scheme');
          expect(p.fg, isNot(TimetableTheme.offWeekText), reason: '$scheme');
        }
      }
    });

    test('NW12 非本周颜色只在主题里定义一次，格子引用 token；旧灰值无残留', () {
      final hits = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final src = f.readAsStringSync();
        if (RegExp(r'0x[fF]{2}6[bB]7280').hasMatch(src)) hits.add(f.path);
        expect(
          RegExp(r'0x[fF]{2}6[bB]7080|0x[fF]{2}[eE][eE][fF]0[fF]3')
              .hasMatch(src),
          isFalse,
          reason: f.path,
        );
      }
      expect(hits, [endsWith('timetable_theme.dart')], reason: '$hits');
      final cell = File('lib/mini_apps/timetable/timetable_course_cell.dart')
          .readAsStringSync();
      // item 12：经 TimetableTheme.colorsOf(context) 取明暗对应的 offWeek token。
      expect(cell, contains('TimetableTheme.colorsOf(context)'));
      expect(cell, contains('colors.offWeekText'));
      expect(cell, contains('colors.offWeekBorder'));
      expect(cell, isNot(contains('[非本周]')));
    });

    for (final scheme in ['A', 'B', 'C']) {
      for (final opacity in [100, 30]) {
        testWidgets('NW01/NW02 方案 $scheme · 不透明度 $opacity%：非本周白底 + 1px 描边 + '
            'offWeekText；本周课照常', (tester) async {
          _bigView(tester);
          _load(
            settings: TimetableSettings(
              termStartDate: _termStart,
              paletteScheme: scheme,
              cellOpacity: opacity,
              showNonCurrentWeek: true,
              showTeacher: true,
            ),
            manual: [
              _course('off', '测试课甲', weeks: '01' * 10, classId: '02'),
              _course('on', '测试课乙', day: 2),
            ],
          );
          await _pumpGrid(tester);
          expect(tester.takeException(), isNull);
          final off = _cellDecoration(tester, '测试课甲');
          expect(off.color, TimetableTheme.offWeekBg);
          expect(off.border, isNull);
          final ob = _cellBorder(tester, '测试课甲')!;
          expect(
            ob.border,
            Border.all(color: TimetableTheme.offWeekBorder, width: 1),
          );
          expect(ob.borderRadius, BorderRadius.circular(4));
          expect(off.borderRadius, BorderRadius.circular(4));
          for (final t in tester.widgetList<Text>(
            find.descendant(of: _cell('测试课甲'), matching: find.byType(Text)),
          )) {
            expect(
              t.style?.color,
              TimetableTheme.offWeekText,
              reason: t.data ?? '',
            );
          }
          final on = _cellDecoration(tester, '测试课乙');
          expect(on.color, isNot(TimetableTheme.offWeekBg));
          expect(on.border, isNull);
          expect(_cellBorder(tester, '测试课乙'), isNull);
          if (opacity < 100) {
            // 未自选时本周格走 hueStepped 自动色，与 A/B/C 无关。
            final bgs = [
              for (var i = 0; i < kCoursePaletteSize; i++)
                TimetableTheme.blendCellBg(
                  TimetableTheme.autoCoursePair(i).bg,
                  opacity,
                ),
            ];
            expect(bgs, contains(on.color));
          }
        });
      }
    }

    testWidgets('NW03 「非本周」胶囊与「单周」胶囊同样式、同位置；描边和字为 offWeekText；'
        'NW05 语义只念一次「非本周」', (tester) async {
      _bigView(tester);
      final semantics = tester.ensureSemantics();
      _load(
        settings: TimetableSettings(
          termStartDate: _termStart,
          showNonCurrentWeek: true,
        ),
        manual: [
          // 双周课：第 7 周非本周。
          _course('off', '测试课甲', weeks: '01' * 10),
          // 单周课：第 7 周本周，带「单周」胶囊。
          _course('odd', '测试课乙', day: 2, weeks: '10' * 10),
        ],
      );
      await _pumpGrid(tester);
      final offPill = find.byKey(const Key('course_cell_off_week_pill'));
      final parityPill = find.byKey(const Key('course_cell_parity_pill'));
      expect(offPill, findsOneWidget);
      expect(parityPill, findsOneWidget);
      expect(find.text('非本周'), findsOneWidget);
      expect(find.text('单周'), findsOneWidget);
      expect(find.textContaining('[非本周]'), findsNothing);
      final a = tester.widget<Container>(offPill);
      final b = tester.widget<Container>(parityPill);
      final da = a.decoration! as BoxDecoration;
      final db = b.decoration! as BoxDecoration;
      expect(a.padding, b.padding);
      expect(da.borderRadius, db.borderRadius);
      expect((da.border! as Border).top.color, TimetableTheme.offWeekText);
      expect(
        (da.border! as Border).top.width,
        (db.border! as Border).top.width,
      );
      final ta = tester.widget<Text>(find.text('非本周'));
      final tb = tester.widget<Text>(find.text('单周'));
      expect(ta.style!.color, TimetableTheme.offWeekText);
      expect(ta.style!.fontSize, tb.style!.fontSize);
      // 位置：距格子底边与水平居中都一致。
      final ca = tester.getRect(_cell('测试课甲'));
      final cb = tester.getRect(_cell('测试课乙'));
      final ra = tester.getRect(offPill);
      final rb = tester.getRect(parityPill);
      expect(ca.bottom - ra.bottom, closeTo(cb.bottom - rb.bottom, 0.01));
      expect(ra.height, closeTo(rb.height, 0.01));
      expect(ra.center.dx - ca.center.dx, closeTo(0, 0.6));
      // 语义：格子标签「非本周，测试课甲，…」，胶囊本身不再朗读。
      final label = tester.getSemantics(_cell('测试课甲')).getSemanticsData().label;
      expect(label, startsWith('非本周，测试课甲，'));
      expect('非本周'.allMatches(label).length, 1);
      expect(find.bySemanticsLabel('非本周'), findsNothing);
      semantics.dispose();
    });

    testWidgets('NW06/HP09 非本周格长按移动不拖起、不震动', (tester) async {
      _bigView(tester);
      final haptics = _mockHaptics(tester);
      _load(
        settings: TimetableSettings(
          termStartDate: _termStart,
          showNonCurrentWeek: true,
        ),
        manual: [_course('off', '测试课甲', weeks: '01' * 10)],
      );
      await _pumpGrid(tester);
      final g = await tester.startGesture(tester.getCenter(_cell('测试课甲')));
      await tester.pump(const Duration(milliseconds: 900));
      await g.moveBy(const Offset(80, 120));
      await tester.pump();
      expect(find.byKey(const Key('week_grid_dragging_cell')), findsNothing);
      await g.up();
      await tester.pumpAndSettle();
      expect(find.text('此更改应用范围？'), findsNothing);
      expect(haptics, isEmpty);
    });

    testWidgets('NW08 非本周课与本周课同一时段：无冲突圆点和「N 门」，本周课按普通格显示', (tester) async {
      _bigView(tester);
      _load(
        settings: TimetableSettings(
          termStartDate: _termStart,
          showNonCurrentWeek: true,
        ),
        manual: [
          // 本周课（课名排序最前，避免与叠放首格的排序混淆）。
          _course('on', '测试课一'),
          // 同一时段的双周课：第 7 周为非本周。
          _course('off', '测试课甲', weeks: '01' * 10),
        ],
      );
      await _pumpGrid(tester);
      expect(tester.takeException(), isNull);
      expect(_cell('测试课一'), findsOneWidget);
      final on = _cellDecoration(tester, '测试课一');
      expect(on.color, isNot(TimetableTheme.offWeekBg));
      expect(_cellBorder(tester, '测试课一'), isNull);
      expect(find.byKey(const Key('course_cell_conflict_dot')), findsNothing);
      expect(find.textContaining('门'), findsNothing);
      expect(find.byKey(const Key('course_cell_off_week_pill')), findsNothing);
    });
  });

  // ---------------------------------------------------------------- LC
  group('LC 地点完整与让位顺序（§13.9）', () {
    const nameStyle = TextStyle(
      fontSize: 12,
      height: 1.2,
      fontWeight: FontWeight.w600,
    );
    const subStyle = TextStyle(fontSize: 11, height: 1.15);
    const width = 60.0;
    final loc = cellLocationText('测试楼 A101 综合实验中心三层东侧');

    double h(
      String text,
      TextStyle s, {
      TextScaler scaler = TextScaler.noScaling,
    }) {
      final p = TextPainter(
        text: TextSpan(text: text, style: s),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout(maxWidth: width);
      final v = p.height;
      p.dispose();
      return v;
    }

    CellContentPlan plan(
      double maxHeight, {
      String name = '测试课甲乙丙丁',
      String? location,
      bool hasClass = true,
      bool hasTeacher = true,
      TextScaler scaler = TextScaler.noScaling,
    }) => planCellContent(
      name: name,
      location: location ?? loc,
      hasClass: hasClass,
      hasTeacher: hasTeacher,
      nameStyle: nameStyle,
      subStyle: subStyle,
      nameSize: 12,
      subSize: 11,
      maxWidth: width,
      maxHeight: maxHeight,
      textScaler: scaler,
    );

    final nameAll = h('测试课甲乙丙丁', nameStyle);
    final nameLine = h('课', nameStyle);
    final sub = h('课', subStyle);
    final locH = h(loc, subStyle);

    test('前提：地点多行、课名多行', () {
      expect(locH, greaterThan(sub * 2));
      expect(nameAll, greaterThan(nameLine * 1.5));
    });

    test('空间足够：课名、代码、地点、老师全显示', () {
      final p = plan(nameAll + sub + locH + sub + 1);
      expect(p.showClass, isTrue);
      expect(p.showTeacher, isTrue);
      expect(p.fits, isTrue);
      expect(p.nameSize, 12);
    });

    test('LC02 略不足：先隐藏课程代码，其余保持', () {
      final p = plan(nameAll + locH + sub + sub / 2);
      expect(p.showClass, isFalse);
      expect(p.showTeacher, isTrue);
      expect(p.nameLines, greaterThanOrEqualTo(2));
      expect(p.nameSize, 12);
    });

    test('LC03 更紧：代码和老师都隐藏，课名、地点完整', () {
      final p = plan(nameAll + locH + sub / 2);
      expect(p.showClass, isFalse);
      expect(p.showTeacher, isFalse);
      expect(p.nameLines * nameLine, closeTo(nameAll, 0.5));
      expect(p.nameSize, 12);
    });

    test('LC04 再紧：课名截断（至少 1 行），字号不变', () {
      final p = plan(nameLine + locH + 0.5);
      expect(p.nameLines, 1);
      expect(p.showClass, isFalse);
      expect(p.showTeacher, isFalse);
      expect(p.nameSize, 12);
      expect(p.fits, isTrue);
    });

    test('LC05 再紧：本格字号逐级缩小（每级 1sp），最小 10sp', () {
      final p = plan(nameLine + locH - 2);
      expect(p.nameSize, lessThan(12));
      expect(p.nameSize, greaterThanOrEqualTo(10));
      expect(p.subSize, greaterThanOrEqualTo(10));
      expect(p.nameLines, greaterThanOrEqualTo(1));
      // 极端：放不下也不低于 10sp；地点完整、课名 1 行。
      final x = plan(4);
      expect(x.nameSize, 10);
      expect(x.subSize, 10);
      expect(x.nameLines, 1);
      expect(x.fits, isFalse);
      // 系统字号 ×2：实际字号（×2）同样不低于 10sp。
      final y = plan(4, scaler: const TextScaler.linear(2));
      expect(y.nameSize * 2, closeTo(10, 1e-6));
      expect(y.subSize * 2, closeTo(10, 1e-6));
    });

    test('LC08 地点为空：让位从课程代码开始照常', () {
      final p = plan(nameAll + sub + sub / 2, location: '');
      expect(p.showClass, isFalse);
      expect(p.showTeacher, isTrue);
    });

    for (final (hgt, scale) in [
      (52.0, 1.0),
      (52.0, 2.0),
      (90.0, 1.0),
      (90.0, 2.0),
    ]) {
      testWidgets('LC01/LC06/LC07 格高 $hgt · 系统字号 ×$scale · 字号大 · 窄格：地点完整、'
          '不溢出、字号 ≥10sp', (tester) async {
        // 360dp 宽、7 列：窄格。
        tester.view.physicalSize = const Size(360 * 3, 1600 * 3);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        const longLoc = '测试楼 A101（实验室）综合实验中心三层东侧';
        _load(
          settings: TimetableSettings(
            termStartDate: _termStart,
            periodHeight: hgt,
            fontScale: CellFontScale.large,
            showTeacher: true,
            showNonCurrentWeek: true,
          ),
          manual: [
            _course('a', '测试课甲', end: 1, location: longLoc, classId: '02'),
            _course(
              'b',
              '测试课程名称很长很长很长很长（2）',
              day: 2,
              location: longLoc,
              classId: '02',
            ),
            _course(
              'c',
              '测试课丙',
              day: 3,
              end: 1,
              weeks: '01' * 10,
              location: longLoc,
            ),
          ],
        );
        await _pumpGrid(tester, textScale: scale);
        expect(tester.takeException(), isNull);
        final locs = find.byKey(const Key('course_cell_location'));
        expect(locs, findsNWidgets(3));
        for (final t in tester.widgetList<Text>(locs)) {
          expect(t.maxLines, isNull);
          expect(t.overflow, isNot(TextOverflow.ellipsis));
          expect(t.data!.replaceAll('\u200B', ''), '@$longLoc');
          expect(t.style!.fontSize! * scale, greaterThanOrEqualTo(10 - 1e-6));
        }
        for (final n in tester.widgetList<CourseNameText>(
          find.byType(CourseNameText),
        )) {
          expect(n.maxLines, greaterThanOrEqualTo(1));
          expect(n.style.fontSize! * scale, greaterThanOrEqualTo(10 - 1e-6));
        }
      });
    }
  });

  // ---------------------------------------------------------------- CD
}

/// 拦截 `SystemChannels.platform` 的 HapticFeedback.vibrate，记录参数。
List<String?> _mockHaptics(WidgetTester tester) {
  final calls = <String?>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') {
      calls.add(call.arguments as String?);
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return calls;
}
