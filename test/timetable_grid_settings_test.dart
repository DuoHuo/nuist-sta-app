import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_settings_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

final _c = TimetableController.instance;

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_grid_settings');
    TimetableStore.debugDirectory = tmp;
    _c.debugReset();
  });

  tearDown(() {
    TimetableStore.debugDirectory = null;
    _c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Course manual(
    String id,
    String name,
    int day,
    String weeks, {
    int start = 1,
    int end = 2,
    String location = '',
    String classId = '',
  }) => Course(
    id: id,
    name: name,
    classId: classId,
    slots: [
      CourseSlot(
        day: day,
        startNode: start,
        endNode: end,
        weeks: weeks,
        location: location,
      ),
    ],
  );

  void setUpCourses(
    List<Course> courses, {
    int week = 1,
    bool weekend = true,
    bool showNonCurrent = false,
    double periodHeight = 64,
  }) {
    _c.debugSetSnapshot(
      TimetableSnapshot(
        periods: TimetableController.defaultPeriods(),
        settings: TimetableSettings(
          termStartDate: DateTime(2026, 9, 7),
          showSaturday: weekend,
          showSunday: weekend,
          showNonCurrentWeek: showNonCurrent,
          periodHeight: periodHeight,
        ),
      ),
      viewingWeek: week,
      manualCourses: courses,
    );
  }

  Future<void> pumpGrid(WidgetTester tester, int week) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WeekGrid(week: week, controller: _c),
        ),
      ),
    );
    await tester.pump();
  }

  group('S01 周末列：设置开启 或 本周该日有课', () {
    testWidgets('设置关 + 周六有本周手动课 → 显示周六列，周日仍隐藏', (tester) async {
      setUpCourses([manual('s', '周六课', 6, '1' * 20)], weekend: false);
      await pumpGrid(tester, 1);
      expect(find.text('六'), findsOneWidget);
      expect(find.text('日'), findsNothing);
      expect(find.byType(CourseCell), findsOneWidget);
    });

    testWidgets('设置关 + 周日只有非本周课（即使显示非本周开启）→ 隐藏', (tester) async {
      setUpCourses(
        [manual('o', '单周课', 7, '10' * 10)],
        week: 2,
        weekend: false,
        showNonCurrent: true,
      );
      await pumpGrid(tester, 2);
      expect(find.text('日'), findsNothing);
      expect(find.text('六'), findsNothing);
      expect(find.byType(CourseCell), findsNothing);
    });

    testWidgets('切换周次随之更新', (tester) async {
      setUpCourses([manual('o', '单周课', 6, '10' * 10)], weekend: false);
      await pumpGrid(tester, 1);
      expect(find.text('六'), findsOneWidget);
      await pumpGrid(tester, 2);
      expect(find.text('六'), findsNothing);
      await pumpGrid(tester, 3);
      expect(find.text('六'), findsOneWidget);
    });
  });

  group('S02 格子内容按高度自适应', () {
    for (final h in [52.0, 90.0]) {
      testWidgets('格高 $h：叠放「2 门」、单周胶囊、长课名均不溢出', (tester) async {
        setUpCourses([
          // 周一 1 节：两门叠放。
          manual('a', '数据结构', 1, '1' * 20, end: 1, location: '明德楼A101'),
          manual('b', '操作系统', 1, '1' * 20, end: 1, classId: '01'),
          // 周二 1 节：单周课（第 1 周为本周）。
          manual('o', '单周课程', 2, '10' * 10, end: 1, location: '文德楼B202'),
          // 周三 1-2 节：长课名 + 班号 + 地点。
          manual(
            'l',
            '马克思主义基本原理概论与中国特色社会主义理论体系（2）',
            3,
            '1' * 20,
            location: '学而楼C303多媒体教室',
            classId: '2026001',
          ),
        ], periodHeight: h);
        await pumpGrid(tester, 1);
        expect(tester.takeException(), isNull);
        expect(find.text('2 门'), findsOneWidget);
        expect(find.text('单周'), findsOneWidget);
        expect(find.byType(CourseCell), findsNWidgets(3));
        // 课名至少显示一行。
        for (final t in tester.widgetList<Text>(
          find.descendant(
            of: find.byType(CourseNameText),
            matching: find.byType(Text),
          ),
        )) {
          expect(t.maxLines, greaterThanOrEqualTo(1));
        }
        if (h == 52) {
          // 单节 52dp（§13.9 / LC）：地点永不隐藏、不截断；代码最先让位，课名至少 1 行。
          // 每个格子：所显示那门课有地点，就完整显示（叠放格只显示其中一门）。
          for (final c in tester.widgetList<CourseCell>(
            find.byType(CourseCell),
          )) {
            final loc = c.cell.slot.location;
            if (loc.isEmpty) continue;
            expect(
              find.descendant(
                of: find.byWidget(c),
                matching: find.text(cellLocationText(loc)),
              ),
              findsOneWidget,
              reason: loc,
            );
          }
          expect(find.text(cellLocationText('文德楼B202')), findsOneWidget);
          expect(find.text('[01]'), findsNothing);
          final odd = tester
              .widgetList<CourseNameText>(find.byType(CourseNameText))
              .firstWhere((w) => w.name == '单周课程');
          expect(odd.maxLines, greaterThanOrEqualTo(1));
        } else {
          // 两节 180dp 的长课名格：课名多行，地点仍可显示。
          final longName = tester
              .widgetList<CourseNameText>(find.byType(CourseNameText))
              .firstWhere((w) => w.name.startsWith('马克思'));
          expect(longName.maxLines, greaterThan(3));
          expect(find.text(cellLocationText('学而楼C303多媒体教室')), findsOneWidget);
        }
      });
    }

    testWidgets('格高 64 单节：地点完整，班号隐藏，课名至少 1 行', (tester) async {
      setUpCourses([
        manual(
          'm',
          '高等数学分析',
          1,
          '1' * 20,
          end: 1,
          location: '明德楼A101',
          classId: '2026001',
        ),
      ]);
      await pumpGrid(tester, 1);
      expect(tester.takeException(), isNull);
      final name = tester.widget<CourseNameText>(find.byType(CourseNameText));
      expect(name.maxLines, greaterThanOrEqualTo(1));
      expect(find.text(cellLocationText('明德楼A101')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('course_cell_location')))
            .maxLines,
        isNull,
      );
      expect(find.text('[2026001]'), findsNothing);
    });

    test('设置页滑块范围 52–90，默认 64', () {
      expect(const TimetableSettings().periodHeight, 64);
    });

    testWidgets('滑块范围 52–90、步长 2', (tester) async {
      setUpCourses(const []);
      await tester.pumpWidget(
        MaterialApp(home: TimetableSettingsPage(controller: _c)),
      );
      final s = tester.widget<Slider>(
        find.byKey(const Key('tt_settings_period_height')),
      );
      expect(s.min, 52);
      expect(s.max, 90);
      expect(s.divisions, 19);
      expect(s.value, 64);
    });
  });

  group('S03b 读取时钳制格高（不回写）', () {
    TimetableSettings parse(Object? v) =>
        TimetableSettings.fromJson({'periodHeight': v});

    test('44→52，200→90，"abc"→64，缺省→64，"70"→70', () {
      expect(parse(44).periodHeight, 52);
      expect(parse(200).periodHeight, 90);
      expect(parse('abc').periodHeight, 64);
      expect(parse(null).periodHeight, 64);
      expect(parse('70').periodHeight, 70);
    });

    testWidgets('磁盘存 44：启动后 UI 显示 52，settings.json 仍为 44；页面不溢出', (
      tester,
    ) async {
      final file = File('${tmp.path}/settings.json');
      file.writeAsStringSync(
        jsonEncode({...const TimetableSettings().toJson(), 'periodHeight': 44}),
      );
      TimetableController.bindingCheck = () async => false;
      await tester.runAsync(_c.ensureStarted);
      expect(_c.settings.periodHeight, 52);

      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(home: TimetableSettingsPage(controller: _c)),
      );
      await tester.pump();
      // §13.3 / ST31：格子高度右边只显示数字，不写「dp」。
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('tt_settings_period_height_value')),
            )
            .data,
        '52',
      );
      expect(find.textContaining('dp'), findsNothing);
      expect(tester.takeException(), isNull);

      await pumpGrid(tester, _c.viewingWeek);
      expect(tester.takeException(), isNull);

      final stored = jsonDecode(file.readAsStringSync()) as Map;
      expect(stored['periodHeight'], 44);
    });
  });
}
