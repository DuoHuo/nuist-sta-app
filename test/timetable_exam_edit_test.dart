// 课表：「+」三选一、考试 / 其他日程表单与周视图、教务课编辑 / 删除 / 恢复、
// 首页卡片日程（design/timetable-spec.md §13.15、§14.1–§14.4）。
// 编号对齐课表测试用例 §24（EV / EX / JE / HT）。
// 全部为虚构数据（「测试课甲」「张老师」「测试楼 A101」），不读真实样例。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event_detail_sheet.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

final _c = TimetableController.instance;

/// 开学 2026-08-31；第 8 周 10/19（周一）–10/25（双周）。
final _termStart = DateTime(2026, 8, 31);
const _week = 8;
final _tuesday = DateTime(2026, 10, 20);

Course _course(
  String id,
  String name, {
  int day = 1,
  int start = 3,
  int end = 4,
  CourseSource source = CourseSource.manual,
  String location = '测试楼 A101',
}) => Course(
  id: id,
  name: name,
  source: source,
  slots: [
    CourseSlot(
      day: day,
      startNode: start,
      endNode: end,
      weeks: '11111111111111111111',
      location: location,
      teacher: '张老师',
    ),
  ],
);

ScheduleEvent _event(
  String id, {
  ScheduleKind kind = ScheduleKind.exam,
  ScheduleSource source = ScheduleSource.manual,
  String title = '测试考试甲',
  DateTime? date,
  TimeOfDayMinutes start = const TimeOfDayMinutes(8, 0),
  TimeOfDayMinutes end = const TimeOfDayMinutes(9, 40),
  String? courseCode,
}) => ScheduleEvent(
  id: id,
  kind: kind,
  source: source,
  title: title,
  date: date ?? _tuesday,
  start: start,
  end: end,
  location: '测试楼 B202',
  courseCode: courseCode,
);

void _load({
  List<Course> manual = const [],
  List<Course> jwxt = const [],
  bool showExams = true,
}) {
  _c.debugSetSnapshot(
    TimetableSnapshot(
      courses: jwxt,
      periods: TimetableController.defaultPeriods(),
      settings: TimetableSettings(
        termStartDate: _termStart,
        showExams: showExams,
      ),
    ),
    viewingWeek: _week,
    manualCourses: manual,
  );
}

/// 让真实文件 IO 走完：controller 先改内存、写完盘才 notify，写盘有多个 await，
/// 每个都要一轮 runAsync + pump。
Future<void> _settleIo(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
}

/// 在空页面上用按钮打开弹层（便于点按钮后观察弹层关闭）。
Future<void> _pumpLauncher(
  WidgetTester tester,
  void Function(BuildContext context) open,
) async {
  _bigView(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              key: const Key('launcher'),
              onPressed: () => open(context),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('launcher')));
  await tester.pumpAndSettle();
}

void main() {
  late Directory tmp;
  final origClock = TimetableController.clock;
  final origBinding = TimetableController.bindingCheck;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_mobile_a');
    TimetableStore.debugDirectory = tmp;
    TimetableController.bindingCheck = () async => false;
    TimetableController.clock = () => DateTime(2026, 10, 19, 7);
    _c.debugReset();
  });

  tearDown(() {
    TimetableController.clock = origClock;
    TimetableController.bindingCheck = origBinding;
    TimetableStore.debugDirectory = null;
    _c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('EX 教务考试编辑 / 恢复', () {
    testWidgets('EX17 教务考试经同一表单编辑后，详情显示「已修改」+「恢复原考试」；EX23 手动考试没有', (
      tester,
    ) async {
      _load(manual: [_course('m1', '测试课甲')]);
      await tester.runAsync(
        () => _c.replaceJwxtExams([
          _event('j1', source: ScheduleSource.jwxt, courseCode: 'TEST01'),
        ]),
      );
      final exam = _c.scheduleEvents.single;
      await _pumpLauncher(
        tester,
        (ctx) => showScheduleEventDetailSheet(ctx, event: exam, controller: _c),
      );
      expect(find.byKey(const Key('schedule_detail_restore')), findsNothing);

      await tester.tap(find.byKey(const Key('schedule_detail_edit')));
      await tester.pumpAndSettle();
      expect(find.text('编辑考试'), findsOneWidget);
      // 教务考试：类型固定，课程号只读。
      expect(find.byKey(const Key('schedule_form_kind')), findsNothing);
      await tester.enterText(
        find.byKey(const Key('schedule_form_location')),
        '测试楼 C303',
      );
      await tester.tap(find.byKey(const Key('schedule_form_save')));
      await _settleIo(tester);
      final key = _c.jwxtExamKeyOf('j1')!;
      expect(_c.isJwxtOverridden(examKey: key), isTrue);
      expect(_c.scheduleEvents.single.location, '测试楼 C303');
      expect(find.text('已修改'), findsOneWidget);
      expect(find.text('恢复原考试'), findsOneWidget);

      await tester.tap(find.byKey(const Key('schedule_detail_restore')));
      await _settleIo(tester);
      expect(_c.isJwxtOverridden(examKey: key), isFalse);
      expect(_c.scheduleEvents.single.location, '测试楼 B202');
      expect(find.byKey(const Key('schedule_detail_restore')), findsNothing);
    });

    testWidgets('EX17 改了日期后仍按原 examKey 判断「已修改」（不用展示事件的 jwxtKey）', (
      tester,
    ) async {
      _load(manual: [_course('m1', '测试课甲')]);
      await tester.runAsync(() async {
        await _c.replaceJwxtExams([
          _event('j1', source: ScheduleSource.jwxt, courseCode: 'TEST01'),
        ]);
        await _c.updateScheduleEvent(
          _c.scheduleEvents.single.copyWith(date: DateTime(2026, 10, 22)),
        );
      });
      final shown = _c.scheduleEvents.single;
      expect(shown.jwxtKey, isNot(_c.jwxtExamKeyOf('j1')));
      await _pumpLauncher(
        tester,
        (ctx) =>
            showScheduleEventDetailSheet(ctx, event: shown, controller: _c),
      );
      expect(find.text('恢复原考试'), findsOneWidget);
      expect(find.text('10月22日 周四'), findsOneWidget);
    });

    testWidgets('EX23 手动考试详情无「恢复原考试」', (tester) async {
      _load();
      late ScheduleEvent e;
      await tester.runAsync(
        () async => e = await _c.addScheduleEvent(_event('')),
      );
      await _pumpLauncher(
        tester,
        (ctx) => showScheduleEventDetailSheet(ctx, event: e, controller: _c),
      );
      expect(find.text('恢复原考试'), findsNothing);
      expect(find.text('已修改'), findsNothing);
    });
  });
}
