// spec-next-1019 item 9：课程自选颜色（预设 / 自定义 / 恢复默认）、考试统一颜色、深色换算。
// 构造数据，不读真实样例。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_colors.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_color.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_detail_sheet.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_manual_course_form.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_appearance_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_settings_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

final _c = TimetableController.instance;
final _termStart = DateTime(2026, 8, 31);

Course _jwxt(String id, String name, {int day = 1}) => Course(
  id: id,
  name: name,
  code: 'T$id',
  source: CourseSource.jwxt,
  slots: [
    CourseSlot(
      day: day,
      startNode: 1,
      endNode: 2,
      weeks: '11111111111111111111',
      location: '测试楼 A101',
      teacher: '张老师',
    ),
  ],
);

final _a = _jwxt('a', '测试课甲');
final _b = _jwxt('b', '测试课乙', day: 2);

void _load() {
  _c.debugSetSnapshot(
    TimetableSnapshot(
      courses: [_a, _b],
      periods: TimetableController.defaultPeriods(),
      settings: TimetableSettings(termStartDate: _termStart),
    ),
    viewingWeek: 7,
  );
}

/// 让真实文件 IO / 底栏动画走完：FakeAsync 下 dart:io 不会推进，必须用 runAsync。
/// 不用 pumpAndSettle，避免周视图上可能残留的定时器导致挂死。
Future<void> _settleIo(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpGrid(WidgetTester tester, {bool dark = false}) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? appDarkTheme() : appLightTheme(),
      home: Scaffold(
        body: ListenableBuilder(
          listenable: _c,
          builder: (context, _) => WeekGrid(
            week: 7,
            controller: _c,
            onCourseTap: (cell) =>
                showCourseDetailSheet(context, cell: cell, controller: _c),
          ),
        ),
      ),
    ),
  );
  await _settleIo(tester);
}

Color? _cellBg(WidgetTester tester, String name) =>
    (tester
                .widget<Ink>(
                  find.descendant(
                    of: find.widgetWithText(CourseCell, name),
                    matching: find.byType(Ink),
                  ),
                )
                .decoration!
            as BoxDecoration)
        .color;

Future<void> _openColorPicker(WidgetTester tester, String name) async {
  await tester.tap(find.widgetWithText(CourseCell, name));
  await _settleIo(tester);
  await tester.ensureVisible(find.byKey(const Key('course_detail_color')));
  await tester.tap(find.byKey(const Key('course_detail_color')));
  await _settleIo(tester);
  expect(find.byKey(const Key('tt_color_picker')), findsOneWidget);
}

Future<void> _chooseColor(WidgetTester tester, Color color) async {
  await tester.enterText(
    find.byKey(const Key('tt_color_hex')),
    color.toARGB32().toRadixString(16).substring(2),
  );
  await tester.ensureVisible(find.byKey(const Key('tt_color_custom_apply')));
  await tester.tap(find.byKey(const Key('tt_color_custom_apply')));
  await _settleIo(tester);
}

Future<void> _globalScope(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('course_color_scope_all')));
  await _settleIo(tester);
}

Map<String, dynamic> _colorsFile(Directory dir) => jsonDecode(
  File('${dir.path}/${TimetableStore.courseColorsFile}').readAsStringSync(),
) as Map<String, dynamic>;

void main() {
  late Directory tmp;
  final origClock = TimetableController.clock;
  final origBinding = TimetableController.bindingCheck;
  final origFetch = TimetableController.fetchSnapshot;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_ucolor');
    TimetableStore.debugDirectory = tmp;
    _c.debugReset();
    TimetableController.bindingCheck = () async => false;
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        throw const SocketException('offline (test)');
    TimetableController.clock = () => DateTime(2026, 10, 12, 12);
  });
  tearDown(() {
    TimetableController.clock = origClock;
    TimetableController.bindingCheck = origBinding;
    TimetableController.fetchSnapshot = origFetch;
    TimetableStore.debugDirectory = null;
    _c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('UC 存储（course_colors.json · userColors）', () {
    test('UC01 往返；与配色表互不覆盖；旧文件无此键 → 空；user 非 true 的项跳过', () async {
      expect(await TimetableStore.readUserCourseColors(), isEmpty);
      await TimetableStore.saveCourseColors(CoursePaletteScheme.soft, {'x': 3});
      expect(await TimetableStore.readUserCourseColors(), isEmpty);
      await TimetableStore.saveUserCourseColors({'a': 0xFF3366CC});
      expect(await TimetableStore.readUserCourseColors(), {'a': 0xFF3366CC});
      await TimetableStore.saveCourseColors(CoursePaletteScheme.soft, {'x': 5});
      expect(await TimetableStore.readUserCourseColors(), {'a': 0xFF3366CC});
      expect((await TimetableStore.readCourseColors())!.map, {'x': 5});
      final raw = _colorsFile(tmp);
      expect(raw['userColors'], {
        'a': {'argb': 0xFF3366CC, 'user': true},
      });
      raw['userColors'] = {
        'a': {'argb': 0xFF3366CC, 'user': false},
        'b': {'argb': 'bad', 'user': true},
      };
      File('${tmp.path}/${TimetableStore.courseColorsFile}')
          .writeAsStringSync(jsonEncode(raw));
      expect(await TimetableStore.readUserCourseColors(), isEmpty);
    });
  });

  group('UC 课程颜色', () {
    testWidgets('UC02 色号直接保存到全局：颜色预览、格子与存储同步', (tester) async {
      _load();
      await _pumpGrid(tester);
      await _openColorPicker(tester, '测试课甲');
      const preset = Color(0xFF43856B);
      await _chooseColor(tester, preset);
      expect(_c.userColorOf(_a), isNull);
      await _globalScope(tester);
      for (final key in [
        'course_detail_color_swatch',
        'course_detail_color_bar',
      ]) {
        final preview = tester.widget<Container>(find.byKey(Key(key)));
        expect((preview.decoration! as BoxDecoration).color, preset);
      }
      expect(find.text('颜色（已自选）'), findsNothing);
      expect(_c.userColorOf(_a), preset.toARGB32());
      Navigator.of(tester.element(find.byType(WeekGrid))).pop();
      await _settleIo(tester);
      expect(_cellBg(tester, '测试课甲'), preset);
      await _settleIo(tester);
      expect(await tester.runAsync(TimetableStore.readUserCourseColors), {
        'a': preset.toARGB32(),
      });
    });

    testWidgets('UC03 拖动色相并保存：仅本周这一节变化', (tester) async {
      _load();
      await _pumpGrid(tester);
      final original = _cellBg(tester, '测试课甲');
      await _openColorPicker(tester, '测试课甲');
      expect(find.byKey(const Key('tt_color_sv_panel')), findsOneWidget);
      await tester.drag(
        find.byKey(const Key('tt_color_hue')),
        const Offset(80, 0),
      );
      final panel = find.byKey(const Key('tt_color_sv_panel'));
      final size = tester.getSize(panel);
      await tester.tapAt(
        tester.getTopLeft(panel) +
            Offset(size.width * 0.62, size.height * 0.38),
      );
      await tester.pump();
      final value =
          int.parse(
            tester
                .widget<TextField>(find.byKey(const Key('tt_color_hex')))
                .controller!
                .text,
            radix: 16,
          ) |
          0xFF000000;
      await tester.tap(find.byKey(const Key('tt_color_custom_apply')));
      await _settleIo(tester);
      await tester.tap(find.byKey(const Key('course_color_scope_this')));
      await _settleIo(tester);
      expect(_c.userColorOf(_a), isNull);
      final current = _c.cellsForDay(7, 1).single;
      expect(_c.userColorOf(current.course), value);
      expect(
        coursePairFor(_c, _c.cellsForDay(8, 1).single.course).bg,
        original,
      );
      for (final key in [
        'course_detail_color_swatch',
        'course_detail_color_bar',
      ]) {
        final preview = tester.widget<Container>(find.byKey(Key(key)));
        expect((preview.decoration! as BoxDecoration).color, Color(value));
      }
      await tester.tap(find.byKey(const Key('course_detail_color')));
      await _settleIo(tester);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('tt_color_hex')))
            .controller!
            .text,
        value.toRadixString(16).substring(2).toUpperCase(),
      );
    });

    for (final dark in [false, true]) {
      testWidgets('预览与色号、单节课及全局一致；键盘升降不重建色盘（dark=$dark）', (tester) async {
        _load();
        await _pumpGrid(tester, dark: dark);
        await _openColorPicker(tester, '测试课甲');
        expect(
          find.byKey(const Key('course_detail_color_swatch')),
          findsOneWidget,
        );
        await tester.enterText(find.byKey(const Key('tt_color_hex')), '43856B');
        await tester.pump();
        final preview = tester.widget<Container>(
          find.byKey(const Key('tt_color_display_swatch')),
        );
        expect(
          (preview.decoration! as BoxDecoration).color!.toARGB32(),
          0xFF43856B,
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('tt_color_hex')))
              .decoration!
              .suffixIcon,
          isNull,
        );
        final panelBefore = tester.widget(
          find.byKey(const Key('tt_color_sv_panel')),
        );
        final hueBefore = tester.widget(find.byKey(const Key('tt_color_hue')));
        for (var inset = 0; inset <= 300; inset += 30) {
          tester.view.viewInsets = FakeViewPadding(
            bottom: inset.toDouble() * 3,
          );
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(
          identical(
            tester.widget(find.byKey(const Key('tt_color_sv_panel'))),
            panelBefore,
          ),
          isTrue,
        );
        expect(
          identical(
            tester.widget(find.byKey(const Key('tt_color_hue'))),
            hueBefore,
          ),
          isTrue,
        );
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const Key('tt_color_custom_apply')));
        await _settleIo(tester);
        await tester.tap(find.byKey(const Key('course_color_scope_this')));
        await _settleIo(tester);
        Navigator.of(tester.element(find.byType(WeekGrid))).pop();
        await _settleIo(tester);
        expect(_cellBg(tester, '测试课甲')!.toARGB32(), 0xFF43856B);
        await tester.runAsync(() => _c.setUserCourseColor('a', 0xFF43856B));
        await tester.pump();
        expect(_cellBg(tester, '测试课甲')!.toARGB32(), 0xFF43856B);
      });
    }

    testWidgets('选色弹层键盘动画不改变背景周课表尺寸', (tester) async {
      _load();
      await tester.runAsync(() => TimetableStore.saveSnapshot(_c.snapshot));
      await tester.runAsync(() => _c.ensureStarted());
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(theme: appLightTheme(), home: const TimetablePage()),
      );
      await _settleIo(tester);
      final grid = find.byType(WeekGrid).first;
      final sizeBefore = tester.getSize(grid);
      await _openColorPicker(tester, '测试课甲');
      await tester.tap(find.byKey(const Key('tt_color_hex')));
      for (var inset = 0; inset <= 300; inset += 30) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset.toDouble() * 3);
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getSize(grid), sizeBefore);
      }
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('UC04 恢复默认：清掉自选标记，回到自动色', (tester) async {
      _load();
      await tester.runAsync(() => _c.setUserCourseColor('a', 0xFF3366CC));
      await _pumpGrid(tester);
      final before = _cellBg(tester, '测试课甲');
      expect(before, isNotNull);
      await _openColorPicker(tester, '测试课甲');
      await tester.tap(find.byKey(const Key('tt_color_reset')));
      await tester.tap(find.byKey(const Key('tt_color_custom_apply')));
      await _settleIo(tester);
      await _globalScope(tester);
      expect(_c.userColorOf(_a), isNull);
      await _settleIo(tester);
      expect(
        await tester.runAsync(TimetableStore.readUserCourseColors),
        isEmpty,
      );
    });

    testWidgets('无效色号不可保存；取消范围不落盘；深色预填保持原始色号', (tester) async {
      _load();
      await tester.runAsync(() => _c.setUserCourseColor('a', 0xFF43856B));
      await _pumpGrid(tester, dark: true);
      await _openColorPicker(tester, '测试课甲');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('tt_color_hex')))
            .controller!
            .text,
        '43856B',
      );
      await tester.enterText(find.byKey(const Key('tt_color_hex')), 'bad!');
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('tt_color_custom_apply')),
            )
            .onPressed,
        isNull,
      );
      await _chooseColor(tester, const Color(0xFF753AC5));
      await tester.tap(find.text('取消'));
      await _settleIo(tester);
      expect(_c.userColorOf(_a), 0xFF43856B);
      expect(await tester.runAsync(ScheduleStore.readCourseDateEdits), isEmpty);
    });

    test('局部颜色往返与重启；全局覆盖只清颜色，保留改名备注', () async {
      _load();
      await TimetableStore.saveSnapshot(_c.snapshot);
      await _c.editOccurrence(
        _c.cellsForDay(7, 1).single,
        name: '测试课习题',
        note: '保留备注',
      );
      await _c.setOccurrenceColor(_c.cellsForDay(7, 1).single, 0xFF753AC5);
      final records = await ScheduleStore.readCourseDateEdits();
      expect(records.single.color, 0xFF753AC5);
      _c.debugReset();
      await _c.ensureStarted();
      expect(_c.userColorOf(_c.cellsForDay(7, 1).single.course), 0xFF753AC5);
      expect(_c.userColorOf(_c.cellsForDay(8, 1).single.course), isNull);
      await _c.setUserCourseColor('a', 0xFF43856B);
      final current = _c.cellsForDay(7, 1).single;
      expect(_c.userColorOf(current.course), 0xFF43856B);
      expect(current.course.name, '测试课习题');
      expect(current.slot.note, '保留备注');
      expect(_c.courseDateEdits.single.color, isNull);
    });

    testWidgets('手动课表单只改颜色：保存后选范围，不扩散局部备注', (tester) async {
      _load();
      final manual = await tester.runAsync(
        () => _c.addManualCourse(
          _a.copyWith(id: '', source: CourseSource.manual),
        ),
      );
      final original = _c
          .cellsForDay(7, 1)
          .firstWhere((cell) => cell.course.id == manual!.id);
      await tester.runAsync(() => _c.editOccurrence(original, note: '仅这一节的备注'));
      final cell = _c
          .cellsForDay(7, 1)
          .firstWhere((cell) => cell.course.id == manual!.id);
      await tester.pumpWidget(
        MaterialApp(
          theme: appLightTheme(),
          home: ManualCourseForm(
            controller: _c,
            initial: cell.course,
            initialSlot: cell.slot,
            cell: cell,
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('manual_course_color')));
      await tester.pumpAndSettle();
      await _chooseColor(tester, const Color(0xFF386F95));
      expect(find.byKey(const Key('course_color_scope_sheet')), findsNothing);
      await tester.tap(find.byKey(const Key('manual_course_save')));
      await _settleIo(tester);
      await tester.tap(find.byKey(const Key('course_color_scope_this')));
      await _settleIo(tester);
      expect(_c.userColorOf(_c.manualCourses.single), isNull);
      expect(_c.manualCourses.single.slots.single.note, isEmpty);
      final current = _c
          .cellsForDay(7, 1)
          .firstWhere((cell) => cell.course.id == manual!.id);
      expect(_c.userColorOf(current.course), 0xFF386F95);
      expect(current.slot.note, '仅这一节的备注');
    });

    test('同一天的其他时段保持原色', () async {
      _load();
      final course = _a.copyWith(
        slots: [
          ..._a.slots,
          const CourseSlot(
            day: 1,
            startNode: 5,
            endNode: 6,
            weeks: '11111111111111111111',
          ),
        ],
      );
      _c.debugSetSnapshot(
        _c.snapshot.copyWith(courses: [course]),
        viewingWeek: 7,
      );
      await _c.setOccurrenceColor(_c.cellsForDay(7, 1).first, 0xFF386F95);
      expect(_c.userColorOf(_c.cellsForDay(7, 1).first.course), 0xFF386F95);
      expect(_c.userColorOf(_c.cellsForDay(7, 1).last.course), isNull);
    });

    test('多周修改只为当前周新增局部颜色；恢复继承全局', () async {
      _load();
      final original = _c.cellsForDay(7, 1).single;
      await _c.editOccurrenceWeeks(original, weeks: [7, 8], note: '多周备注');
      await _c.setOccurrenceColor(_c.cellsForDay(8, 1).single, 0xFF753AC5);
      expect(_c.userColorOf(_c.cellsForDay(7, 1).single.course), isNull);
      expect(_c.userColorOf(_c.cellsForDay(8, 1).single.course), 0xFF753AC5);
      expect(_c.cellsForDay(8, 1).single.slot.note, '多周备注');
      await _c.setOccurrenceColor(_c.cellsForDay(8, 1).single, null);
      expect(_c.userColorOf(_c.cellsForDay(8, 1).single.course), isNull);
      expect(_c.cellsForDay(8, 1).single.slot.note, '多周备注');
    });

    test('UC05 自动配色跳过自选色的课（不占色号）', () async {
      _load();
      expect(_c.courseColorMap.keys.any((k) => k.contains('甲')), isTrue);
      await _c.setUserCourseColor('a', 0xFF3366CC);
      _load(); // 新快照 → 重建配色表
      expect(_c.courseColorMap.keys.any((k) => k.contains('甲')), isFalse);
      expect(_c.courseColorMap.keys.any((k) => k.contains('乙')), isTrue);
    });

    testWidgets('UC06 深色：自选色保持原始色值并自动选择对比度高的文字', (tester) async {
      _load();
      const strong = Color(0xFF1565C0);
      const light = Color(0xFFDCE8FB);
      await tester.runAsync(() async {
        await _c.setUserCourseColor('a', light.toARGB32());
        await _c.setUserCourseColor('b', strong.toARGB32());
      });
      await _pumpGrid(tester, dark: true);
      final pa = TimetableTheme.userCoursePair(light, dark: true);
      final pb = TimetableTheme.userCoursePair(strong, dark: true);
      expect(_cellBg(tester, '测试课甲'), light);
      expect(pa.fg, TimetableTheme.forcedBlackText);
      expect(_cellBg(tester, '测试课乙'), strong);
      expect(pb.fg, TimetableTheme.forcedWhiteText);
      // 只存原始值，没有第二份深色色值。
      expect(await tester.runAsync(TimetableStore.readUserCourseColors), {
        'a': light.toARGB32(),
        'b': strong.toARGB32(),
      });
    });
  });

  group('UC 考试统一颜色', () {
    ScheduleEvent exam(String title, DateTime date) => ScheduleEvent(
      id: '',
      kind: ScheduleKind.exam,
      source: ScheduleSource.manual,
      title: title,
      date: date,
      start: const TimeOfDayMinutes(10, 10),
      end: const TimeOfDayMinutes(11, 50),
      location: '测试楼 A101',
    );

    testWidgets('UC07 设置输入考试色号：所有考试格都换色', (tester) async {
      _load();
      await tester.runAsync(() async {
        await _c.addScheduleEvent(exam('测试考试一', DateTime(2026, 10, 13)));
        await _c.addScheduleEvent(exam('测试考试二', DateTime(2026, 10, 14)));
      });
      tester.view.physicalSize = const Size(1200, 6000);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(home: TimetableAppearancePage(controller: _c)),
      );
      await _settleIo(tester);
      await tester.tap(find.byKey(const Key('tt_settings_exam_color')));
      await _settleIo(tester);
      expect(find.byKey(const Key('tt_color_picker')), findsOneWidget);
      const chosen = Color(0xFF933C69);
      await _chooseColor(tester, chosen);
      expect(_c.settings.examColor, chosen.toARGB32());
      await _pumpGrid(tester);
      expect(_c.scheduleEvents, hasLength(2));
      for (final e in _c.scheduleEvents) {
        expect(find.byKey(Key('schedule_cell_${e.id}')), findsOneWidget);
        final ink = tester.widget<Ink>(
          find.descendant(
            of: find.byKey(Key('schedule_cell_${e.id}')),
            matching: find.byType(Ink),
          ),
        );
        expect((ink.decoration! as BoxDecoration).color, chosen);
      }
      expect(_c.scheduleEvents, hasLength(2));
    });
  });
}
