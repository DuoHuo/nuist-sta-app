// 课表：「+」三选一、考试 / 其他日程表单与周视图、教务课编辑 / 删除 / 恢复、
// 首页卡片日程（design/timetable-spec.md §13.15、§14.1–§14.4）。
// 编号对齐课表测试用例 §24（EV / EX / JE / HT）。
// 全部为虚构数据（「测试课甲」「张老师」「测试楼 A101」），不读真实样例。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_edit_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_detail_sheet.dart';

final _c = TimetableController.instance;

/// 开学 2026-08-31；第 8 周 10/19（周一）–10/25（双周）。
final _termStart = DateTime(2026, 8, 31);
const _week = 8;

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

  group('JE 教务课编辑 / 删除 / 恢复', () {
    final jwxt = _course('j1', '测试课甲', source: CourseSource.jwxt);

    GridCell cellOf(String id) =>
        _c.cellsForDay(_week, 1).firstWhere((c) => c.course.id == id);

    Future<void> openDetail(WidgetTester tester, String id) => _pumpLauncher(
      tester,
      (ctx) => showCourseDetailSheet(ctx, cell: cellOf(id), controller: _c),
    );

    testWidgets('JE01 教务课详情顶部有编辑、删除；未修改时无恢复入口', (tester) async {
      _load(jwxt: [jwxt]);
      await openDetail(tester, 'j1');
      expect(find.byKey(const Key('course_detail_jwxt_edit')), findsOneWidget);
      expect(
        find.byKey(const Key('course_detail_jwxt_delete')),
        findsOneWidget,
      );
      expect(find.text('恢复原课程'), findsNothing);
      expect(find.text('已修改'), findsNothing);
    });

    testWidgets('JE02/JE03/JE04 删除二次确认文案逐字；取消不变；确认后记本地删除', (tester) async {
      _load(jwxt: [jwxt]);
      await openDetail(tester, 'j1');
      await tester.tap(find.byKey(const Key('course_detail_jwxt_delete')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('delete_scope_sheet')), findsOneWidget);
      await tester.tap(find.byKey(const Key('delete_scope_whole_course')));
      await tester.pumpAndSettle();
      expect(find.text('删除这门课？同步后也不会恢复，可在设置里一键恢复。'), findsOneWidget);
      final del = tester.widget<TextButton>(
        find.byKey(const Key('jwxt_delete_confirm')),
      );
      expect(
        del.style?.foregroundColor?.resolve(const {}),
        // item 12：Colors.red.shade600 → danger token（浅色 #F53F3F）。
        TimetableColors.light.danger,
      );
      await tester.tap(find.byKey(const Key('jwxt_delete_cancel')));
      await tester.pumpAndSettle();
      expect(_c.courseEditOf('j1'), isNull);

      await tester.tap(find.byKey(const Key('course_detail_jwxt_delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete_scope_whole_course')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('jwxt_delete_confirm')));
      await _settleIo(tester);
      expect(_c.courseEditOf('j1')?.deleted, isTrue);
      expect(_c.deletedJwxtCourses.map((c) => c.id), ['j1']);
      expect(_c.courses.where((c) => c.id == 'j1'), isEmpty);
      expect(_c.jwxtCourses.single.name, '测试课甲', reason: '教务原数据不变');
    });

    testWidgets('JE18/JE19/JE22 编辑页：4 项可输入；时间与周次只读 + 灰字提示；保存课名', (
      tester,
    ) async {
      _load(jwxt: [jwxt]);
      _bigView(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: JwxtCourseEditPage(controller: _c, cell: cellOf('j1')),
        ),
      );
      await tester.pump();
      expect(find.byType(TextFormField), findsNWidgets(4));
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('jwxt_edit_name')))
            .controller
            ?.text,
        '测试课甲',
      );
      expect(find.byKey(const Key('jwxt_edit_time')), findsOneWidget);
      expect(find.byKey(const Key('jwxt_edit_weeks')), findsOneWidget);
      final hint = tester.widget<Text>(
        find.byKey(const Key('jwxt_edit_time_hint')),
      );
      expect(hint.data, '拖动课程可调整时间');
      expect(hint.style?.color, TimetableTheme.hint);
      // 时间/周次行不在任何输入框里，点了不弹选择器。
      expect(
        find.ancestor(
          of: find.byKey(const Key('jwxt_edit_time')),
          matching: find.byType(TextField),
        ),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('jwxt_edit_time')));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);

      expect(find.byKey(const Key('jwxt_edit_apply_weeks')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('jwxt_edit_name')), '测试课乙');
      // 选「全选」→ 所有周，改课程本身。
      await tester.tap(find.byKey(const Key('jwxt_edit_apply_weeks')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('apply_weeks_sheet')), findsOneWidget);
      await tester.tap(find.byKey(const Key('apply_weeks_all')));
      await tester.tap(find.byKey(const Key('apply_weeks_done')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('jwxt_edit_save')));
      await _settleIo(tester);
      final edit = _c.courseEditOf('j1')!;
      expect(edit.name, '测试课乙');
      expect(edit.teacher, isNull, reason: '未改的字段传 null 保持原样');
      expect(edit.location, isNull);
      expect(_c.courses.firstWhere((c) => c.id == 'j1').name, '测试课乙');
      final slot = _c.courses.firstWhere((c) => c.id == 'j1').slots.single;
      expect((slot.day, slot.startNode, slot.endNode), (1, 3, 4));
    });

    testWidgets('JE06/JE07 修改标签打开恢复入口，恢复后回到教务值', (tester) async {
      _load(jwxt: [jwxt]);
      await tester.runAsync(
        () => _c.editJwxtCourse('j1', location: '测试楼 B202'),
      );
      await openDetail(tester, 'j1');
      expect(find.text('测试楼 B202'), findsOneWidget);
      expect(find.text('课程已修改'), findsOneWidget);
      await tester.tap(find.byKey(const Key('course_detail_modified')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('course_detail_restore_course')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('course_detail_restore_course')));
      await _settleIo(tester);
      expect(_c.isJwxtOverridden(courseId: 'j1'), isFalse);
      expect(_c.courseEditOf('j1'), isNull);
      expect(
        _c.courses.firstWhere((c) => c.id == 'j1').slots.single.location,
        '测试楼 A101',
      );
    });

    testWidgets('JE17 手动课仍用原编辑器：无「恢复原课程」与教务按钮', (tester) async {
      _load(manual: [_course('m1', '测试课丙')]);
      await openDetail(tester, 'm1');
      expect(find.byKey(const Key('course_detail_delete')), findsOneWidget);
      expect(find.byKey(const Key('course_detail_jwxt_edit')), findsNothing);
      expect(find.text('恢复原课程'), findsNothing);
    });
  });

  for (final width in [320.0, 400.0]) {
    for (final dark in [false, true]) {
      testWidgets('详情长标题与按钮居中、长备注可滚动（宽 $width，深色 $dark）', (tester) async {
        tester.view.physicalSize = Size(width * 3, 568 * 3);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        final course = _course(
          'j1',
          '计算机网络原理与综合实验',
          source: CourseSource.jwxt,
        ).copyWith(classId: '02', credit: 3);
        _load(jwxt: [course]);
        await tester.runAsync(
          () => _c.editOccurrence(
            _c.cellsForDay(_week, 1).single,
            note: List.filled(12, '请提前准备实验报告并核对课堂安排。').join(),
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: appLightTheme(),
            darkTheme: appDarkTheme(),
            themeMode: dark ? ThemeMode.dark : ThemeMode.light,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.6)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () => showCourseDetailSheet(
                      context,
                      cell: _c.cellsForDay(_week, 1).single,
                      controller: _c,
                    ),
                    child: const Text('打开详情'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开详情'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final title = tester.getRect(
          find.byKey(const Key('course_detail_title')),
        );
        final actions = tester.getRect(
          find.byKey(const Key('course_detail_actions')),
        );
        expect(actions.center.dy, closeTo(title.center.dy, 0.5));
        for (final key in [
          'course_detail_color',
          'course_detail_jwxt_edit',
          'course_detail_jwxt_delete',
        ]) {
          final size = tester.getSize(find.byKey(Key(key)));
          expect(size.width, greaterThanOrEqualTo(48));
          expect(size.height, greaterThanOrEqualTo(48));
        }
        final scroll = tester.state<ScrollableState>(
          find.descendant(
            of: find.byKey(const Key('course_detail_scroll')),
            matching: find.byType(Scrollable),
          ),
        );
        expect(scroll.position.maxScrollExtent, greaterThan(0));
        await tester.ensureVisible(find.byKey(const Key('course_detail_note')));
        await tester.tapAt(
          tester.getTopLeft(find.byKey(const Key('course_detail_note'))) +
              const Offset(50, 20),
        );
        await tester.pumpAndSettle();
        final note = tester.widget<EditableText>(
          find.descendant(
            of: find.byKey(const Key('jwxt_edit_note')),
            matching: find.byType(EditableText),
          ),
        );
        expect(note.focusNode.hasFocus, isTrue);
        expect(note.controller.text, contains('实验报告'));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('空备注入口进入手动课编辑并聚焦备注', (tester) async {
    _load(manual: [_course('m1', '测试课丙')]);
    await _pumpLauncher(
      tester,
      (context) => showCourseDetailSheet(
        context,
        cell: _c.cellsForDay(_week, 1).single,
        controller: _c,
      ),
    );
    expect(find.text('添加备注…'), findsOneWidget);
    await tester.tap(find.byKey(const Key('course_detail_note')));
    await tester.pumpAndSettle();
    final note = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('manual_course_note')),
        matching: find.byType(EditableText),
      ),
    );
    expect(note.focusNode.hasFocus, isTrue);
    expect(note.controller.text, isEmpty);
  });
}
