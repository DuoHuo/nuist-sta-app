import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_detail_sheet.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

Future<void> _pumpPage(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: TimetablePage()));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('空课表显示空状态与登录/同步入口', (tester) async {
    TimetableController.instance.debugSetSnapshot(
      TimetableSnapshot(
        periods: TimetableController.defaultPeriods(),
        settings: TimetableSettings(
          termStartDate: DateTime(2026, 9, 7),
          periodHeight: TimetableTheme.periodHeight,
          cellRadius: TimetableTheme.cellRadius,
        ),
      ),
      viewingWeek: 5,
    );

    await _pumpPage(tester);

    expect(find.text('还没有课程'), findsOneWidget);
    expect(find.textContaining('[DEBUG]'), findsNothing);
    expect(find.text('去登录'), findsOneWidget);
  });

  testWidgets('mock 数据可画出课程格', (tester) async {
    TimetableController.instance.debugSetSnapshot(
      TimetableSnapshot(
        courses: [
          Course(
            id: 'ds',
            name: '数据结构',
            classId: '02',
            slots: [
              CourseSlot(
                day: 1,
                startNode: 1,
                endNode: 2,
                weeks: '1' * 20,
                location: '揽江楼 N407',
                teacher: '教师M',
              ),
            ],
          ),
        ],
        periods: TimetableController.defaultPeriods(),
        settings: TimetableSettings(
          termStartDate: DateTime(2026, 9, 7),
          periodHeight: TimetableTheme.periodHeight,
          cellRadius: TimetableTheme.cellRadius,
        ),
      ),
      viewingWeek: 5,
    );

    await _pumpPage(tester);

    expect(find.byType(WeekGrid), findsOneWidget);
    expect(find.text('数据结构'), findsWidgets);
    expect(find.textContaining('@揽江楼'), findsWidgets);
  });
  testWidgets('无开学日时顶栏显示「周次待同步」', (tester) async {
    TimetableController.instance.debugSetSnapshot(
      TimetableSnapshot(
        periods: TimetableController.defaultPeriods(),
        settings: const TimetableSettings(),
      ),
      viewingWeek: 1,
    );
    await _pumpPage(tester);
    expect(find.text('周次待同步 · 点此选择'), findsOneWidget);
    expect(find.textContaining('第 1 周', findRichText: true), findsOneWidget);
  });

  Widget detailFor(CourseSource source) {
    final slot = CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: '1' * 16);
    return MaterialApp(
      home: Scaffold(
        body: CourseDetailSheet(
          cell: GridCell(
            course: Course(id: 'c', name: '高数', source: source, slots: [slot]),
            slot: slot,
            conflictCount: 0,
            activeThisWeek: true,
          ),
          controller: TimetableController.instance,
        ),
      ),
    );
  }

  testWidgets('教务课详情：无手动课表单入口，改为教务课「编辑」（JE01，替代 D07）', (tester) async {
    await tester.pumpWidget(detailFor(CourseSource.jwxt));
    expect(find.byKey(const Key('course_detail_jwxt_edit')), findsOneWidget);
    expect(find.byKey(const Key('course_detail_delete')), findsNothing);
    expect(find.text('所有周'), findsNothing);
    expect(find.text('地点未填写'), findsOneWidget);
    expect(find.text('教师未填写'), findsOneWidget);
  });

  testWidgets('手动课详情保留编辑按钮', (tester) async {
    await tester.pumpWidget(detailFor(CourseSource.manual));
    expect(find.byKey(const Key('course_detail_edit')), findsOneWidget);
  });
}
