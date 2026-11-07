import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/app_select.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_detail_sheet.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_manual_course_form.dart';

final _c = TimetableController.instance;

TimetableSnapshot _snapshot() => TimetableSnapshot(
  courses: [
    Course(
      id: 'ds',
      name: '数据结构',
      source: CourseSource.jwxt,
      slots: [CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: '1' * 20)],
    ),
  ],
  periods: TimetableController.defaultPeriods(),
  settings: TimetableSettings(
    termStartDate: DateTime(2026, 9, 7),
    periodHeight: TimetableTheme.periodHeight,
    cellRadius: TimetableTheme.cellRadius,
  ),
);

/// 让真实磁盘 IO（store 写入）完成。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

/// 从课表入口打开添加课程表单。
Future<void> _openAddForm(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: TimetablePage()));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.tap(find.byTooltip('添加'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('add_entry_course')));
  await tester.pumpAndSettle();
}

/// 当前表单里被选中的周次。
Set<int> _selectedWeeks(WidgetTester tester) => {
  for (var w = 1; w <= 20; w++)
    if (tester
        .widget<FilterChip>(find.byKey(Key('course_form_week_$w')))
        .selected)
      w,
};

Widget _detail(Course course) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (context) => Center(
        child: ElevatedButton(
          onPressed: () => showCourseDetailSheet(
            context,
            cell: GridCell(
              course: course,
              slot: course.slots.first,
              conflictCount: 0,
              activeThisWeek: true,
            ),
            controller: _c,
          ),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

void main() {
  late Directory tmp;
  final origClock = TimetableController.clock;
  final origBinding = TimetableController.bindingCheck;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('tt_form');
    TimetableStore.debugDirectory = tmp;
    TimetableController.clock = () => DateTime(2026, 9, 7, 9);
    TimetableController.bindingCheck = () async => false;
    _c.debugReset();
  });

  tearDown(() {
    TimetableStore.debugDirectory = null;
    TimetableController.clock = origClock;
    TimetableController.bindingCheck = origBinding;
    _c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  testWidgets('添加表单保存手动课程并出现在课表', (tester) async {
    _c.debugSetSnapshot(_snapshot(), viewingWeek: 1, manualCourses: const []);
    await tester.pumpWidget(const MaterialApp(home: TimetablePage()));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    await tester.tap(find.byTooltip('添加'));
    await tester.pumpAndSettle();
    // EV01：「+」先弹三选一，「课程」进入原手动课表单。
    await tester.tap(find.byKey(const Key('add_entry_course')));
    await tester.pumpAndSettle();
    expect(find.text('添加课程'), findsWidgets);
    tester
        .widget<AppSelectFormField<int>>(
          find.byKey(const Key('manual_course_day')),
        )
        .onChanged!(1);
    await tester.pump();

    // 课程名必填。
    await tester.tap(find.byKey(const Key('manual_course_save')));
    await tester.pumpAndSettle();
    expect(find.text('请填写课程名称'), findsOneWidget);
    expect(_c.manualCourses, isEmpty);

    await tester.enterText(find.byKey(const Key('manual_course_name')), '自习课');
    await tester.ensureVisible(find.byKey(const Key('course_form_weeks')));
    await tester.tap(find.byKey(const Key('course_form_weeks')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('单周'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('course_form_weeks_confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manual_course_save')));
    await _settle(tester);

    expect(_c.manualCourses, hasLength(1));
    final saved = _c.manualCourses.single;
    expect(saved.isManual, isTrue);
    expect(saved.name, '自习课');
    expect(saved.slots.single.occursInWeek(1), isTrue);
    expect(saved.slots.single.occursInWeek(2), isFalse);
    expect(find.text('添加课程'), findsNothing);
    // 与同时段的「数据结构」叠放（B01）：一格 +「2 门」，点开列表可见自习课。
    expect(find.text('2 门'), findsOneWidget);
    await tester.tap(find.text('2 门'));
    await tester.pumpAndSettle();
    expect(find.text('自习课'), findsWidgets);
  });

  testWidgets('手动课详情显示 手动添加/编辑/删除，删除后移除', (tester) async {
    _c.debugSetSnapshot(_snapshot(), viewingWeek: 1, manualCourses: const []);
    final course = await tester.runAsync(
      () => _c.addManualCourse(
        Course(
          id: '',
          name: '社团活动',
          slots: [
            CourseSlot(
              day: 3,
              startNode: 5,
              endNode: 6,
              weeks: '1' * 20,
              note: '带电脑',
            ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(_detail(course!));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('手动添加'), findsOneWidget);
    expect(find.byKey(const Key('course_detail_edit')), findsOneWidget);
    expect(find.byKey(const Key('course_detail_delete')), findsOneWidget);
    expect(find.text('带电脑'), findsOneWidget);

    await tester.tap(find.byKey(const Key('course_detail_delete')));
    await tester.pumpAndSettle();
    expect(find.text('删除课程'), findsOneWidget);
    await tester.tap(find.byKey(const Key('course_delete_confirm')));
    await _settle(tester);

    expect(_c.manualCourses, isEmpty);
    expect(find.text('手动添加'), findsNothing);
  });

  testWidgets('编辑预填并通过 update 保存', (tester) async {
    _c.debugSetSnapshot(_snapshot(), viewingWeek: 1, manualCourses: const []);
    final course = await tester.runAsync(
      () => _c.addManualCourse(
        Course(
          id: '',
          name: '旧名',
          slots: [
            CourseSlot(day: 2, startNode: 3, endNode: 4, weeks: '1' * 20),
          ],
        ),
      ),
    );
    await tester.pumpWidget(_detail(course!));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('course_detail_edit')));
    await tester.pumpAndSettle();
    expect(find.text('编辑课程'), findsOneWidget);
    expect(find.text('旧名'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('manual_course_name')), '新名');
    await tester.tap(find.byKey(const Key('manual_course_save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('course_form_scope_confirm')));
    await _settle(tester);
    expect(_c.manualCourses.single.id, course.id);
    expect(_c.cellsForDay(1, 2).single.course.name, '新名');
    expect(_c.manualCourses.single.slots.single.startNode, 3);
  });

  testWidgets('教务课详情保留空备注入口、无手动添加标签', (tester) async {
    _c.debugSetSnapshot(_snapshot(), viewingWeek: 1, manualCourses: const []);
    await tester.pumpWidget(_detail(_snapshot().courses.single));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('备注（可不填）'), findsNothing);
    expect(find.text('备注（选填）'), findsNothing);
    expect(find.byIcon(Icons.notes_outlined), findsOneWidget);
    expect(find.text('添加备注…'), findsOneWidget);
    expect(find.text('手动添加'), findsNothing);
    // D07 已作废（§24 JE01/JE18）：教务课改为「编辑」「删除」走本地覆盖层，
    // 不是手动课的删除按钮。
    expect(find.byKey(const Key('course_detail_delete')), findsNothing);
    expect(find.byKey(const Key('course_detail_jwxt_delete')), findsOneWidget);
  });

  testWidgets('周次快捷按钮保持幂等，清空需要单独操作且不能确认', (tester) async {
    _c.debugSetSnapshot(_snapshot(), viewingWeek: 1, manualCourses: const []);
    await _openAddForm(tester);
    await tester.ensureVisible(find.byKey(const Key('course_form_weeks')));
    await tester.tap(find.byKey(const Key('course_form_weeks')));
    await tester.pumpAndSettle();

    expect(_selectedWeeks(tester), {for (var w = 1; w <= 20; w++) w});

    await tester.tap(find.text('全部'));
    await tester.pump();
    expect(_selectedWeeks(tester), {for (var w = 1; w <= 20; w++) w});

    await tester.tap(find.byKey(const Key('course_form_weeks_clear')));
    await tester.tap(find.byKey(const Key('course_form_weeks_confirm')));
    await tester.pump();
    expect(find.text('请至少选择一周'), findsOneWidget);
    expect(_c.manualCourses, isEmpty);
  });

  testWidgets('周次快捷按钮：重复点击单周保持选择', (tester) async {
    _c.debugSetSnapshot(_snapshot(), viewingWeek: 1, manualCourses: const []);
    await _openAddForm(tester);
    await tester.ensureVisible(find.byKey(const Key('course_form_weeks')));
    await tester.tap(find.byKey(const Key('course_form_weeks')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('单周'));
    await tester.pump();
    expect(_selectedWeeks(tester), {for (var w = 1; w <= 20; w += 2) w});

    await tester.tap(find.text('单周'));
    await tester.pump();
    expect(_selectedWeeks(tester), {for (var w = 1; w <= 20; w += 2) w});
  });

  testWidgets('周次快捷按钮：单周/双周/全部互斥切换', (tester) async {
    _c.debugSetSnapshot(_snapshot(), viewingWeek: 1, manualCourses: const []);
    await _openAddForm(tester);
    await tester.ensureVisible(find.byKey(const Key('course_form_weeks')));
    await tester.tap(find.byKey(const Key('course_form_weeks')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('单周'));
    await tester.pump();
    expect(_selectedWeeks(tester), {for (var w = 1; w <= 20; w += 2) w});

    await tester.tap(find.text('双周'));
    await tester.pump();
    expect(_selectedWeeks(tester), {for (var w = 2; w <= 20; w += 2) w});

    await tester.tap(find.text('全部'));
    await tester.pump();
    expect(_selectedWeeks(tester), {for (var w = 1; w <= 20; w++) w});

    // 再点双周仍保持双周。
    await tester.tap(find.text('双周'));
    await tester.pump();
    expect(_selectedWeeks(tester), {for (var w = 2; w <= 20; w += 2) w});
    await tester.tap(find.text('双周'));
    await tester.pump();
    expect(_selectedWeeks(tester), {for (var w = 2; w <= 20; w += 2) w});
  });

  testWidgets('修改开始节次联动结束节次，保留跨度并限制到当天末节', (tester) async {
    _c.debugSetSnapshot(_snapshot(), viewingWeek: 1, manualCourses: const []);
    await tester.pumpWidget(
      MaterialApp(home: ManualCourseForm(controller: _c)),
    );
    await tester.pumpAndSettle();
    Finder field(String name) => find.descendant(
      of: find.byKey(Key('course_form_$name')),
      matching: find.byType(AppSelectFormField<int>),
    );
    int? value(String name) =>
        tester.widget<AppSelectFormField<int>>(field(name)).initialValue;
    Future<void> startAt(int start) async {
      await tester.ensureVisible(field('start'));
      await tester.pumpAndSettle();
      await tester.tap(field('start'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(TextField),
        ),
        '第 $start 节',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.text('第 $start 节'),
            )
            .last,
      );
      await tester.pumpAndSettle();
    }

    expect((value('start'), value('end')), (1, 2));
    await startAt(5);
    expect((value('start'), value('end')), (5, 6));
    await startAt(3);
    expect((value('start'), value('end')), (3, 4));
    await startAt(_c.lastPeriod);
    expect((value('start'), value('end')), (_c.lastPeriod, _c.lastPeriod));
    await startAt(2);
    expect((value('start'), value('end')), (2, 3), reason: '末节截断后仍记住原连堂跨度');
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏大字深色表单兼容键盘，备注入口仍能获得焦点', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    addTearDown(tester.view.reset);
    _c.debugSetSnapshot(_snapshot(), viewingWeek: 1, manualCourses: const []);
    await tester.pumpWidget(
      MaterialApp(
        theme: appDarkTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: ManualCourseForm(controller: _c, autofocusNote: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final note = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('manual_course_note')),
        matching: find.byType(EditableText),
      ),
    );
    expect(note.focusNode.hasFocus, isTrue);
    final save = tester.getRect(find.byKey(const Key('manual_course_save')));
    expect(save.bottom, lessThanOrEqualTo(400));
  });

  testWidgets('返回时提醒未保存，继续编辑保留内容，放弃不创建课程', (tester) async {
    _c.debugSetSnapshot(_snapshot(), viewingWeek: 1, manualCourses: const []);
    await _openAddForm(tester);
    await tester.enterText(
      find.byKey(const Key('manual_course_name')),
      '待保存的课程',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('course_form_close')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('course_form_discard_cancel')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('manual_course_name')))
          .controller!
          .text,
      '待保存的课程',
    );
    await tester.tap(find.byKey(const Key('course_form_close')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('course_form_discard_confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('manual_course_name')), findsNothing);
    expect(_c.manualCourses, isEmpty);
  });
}
