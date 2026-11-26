// 课表：「+」三选一、考试 / 其他日程表单与周视图、教务课编辑 / 删除 / 恢复、
// 首页卡片日程（design/timetable-spec.md §13.15、§14.1–§14.4）。
// 编号对齐课表测试用例 §24（EV / EX / JE / HT）。
// 全部为虚构数据（「测试课甲」「张老师」「测试楼 A101」），不读真实样例。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/app_select.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_edit_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_manual_course_form.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_overrides.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event_detail_sheet.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event_edit_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
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
  void Function(BuildContext context) open, {
  ThemeData? theme,
}) async {
  _bigView(tester);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
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

/// 通过系统通道发送返回手势，覆盖路由是否真正接收事件。
Future<Object?> _backGesture(
  WidgetTester tester,
  String method, {
  double progress = 0,
  int edge = 0,
}) async {
  ByteData? response;
  final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    const StandardMethodCodec().encodeMethodCall(
      MethodCall(method, {
        'touchOffset': [edge == 0 ? 5.0 : width - 5, 300.0],
        'progress': progress,
        'swipeEdge': edge,
      }),
    ),
    (data) => response = data,
  );
  expect(response, isNotNull, reason: method);
  final result = const StandardMethodCodec().decodeEnvelope(response!);
  await tester.pumpAndSettle();
  return result;
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

  Set<int> selectedWeeks(WidgetTester tester) => {
    for (var w = 1; w <= 20; w++)
      if (tester
          .widget<FilterChip>(find.byKey(Key('course_form_week_$w')))
          .selected)
        w,
  };

  testWidgets('手动课添加、周次快捷/节次联动与冲突提示、编辑与删除（含窄屏深色键盘焦点）', (tester) async {
    _load(
      jwxt: [
        _course('j_bg', '数据结构', source: CourseSource.jwxt, start: 1, end: 2),
      ],
    );
    await tester.pumpWidget(const MaterialApp(home: TimetablePage()));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // 1. 从「+ -> 课程」进入添加表单，校验必填与周次快捷互斥/清空限制
    await tester.tap(find.byTooltip('添加'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('课程'));
    await tester.pumpAndSettle();
    tester
        .widget<AppSelectFormField<int>>(
          find.byKey(const Key('manual_course_day')),
        )
        .onChanged!(1);
    await tester.pump();
    await tester.tap(find.byKey(const Key('manual_course_save')));
    await tester.pumpAndSettle();
    expect(find.text('请填写课程名称'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('manual_course_name')), '自习课');
    await tester.ensureVisible(find.byKey(const Key('course_form_weeks')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('course_form_weeks')));
    await tester.pumpAndSettle();
    expect(selectedWeeks(tester), {for (var w = _week; w <= 20; w++) w});
    await tester.tap(find.text('全部'));
    await tester.pump();
    expect(selectedWeeks(tester), {for (var w = 1; w <= 20; w++) w});
    await tester.tap(find.byKey(const Key('course_form_weeks_clear')));
    await tester.tap(find.byKey(const Key('course_form_weeks_confirm')));
    await tester.pump();
    expect(find.text('请至少选择一周'), findsOneWidget);

    await tester.tap(find.text('双周'));
    await tester.pump();
    expect(selectedWeeks(tester), {for (var w = 2; w <= 20; w += 2) w});
    await tester.tap(find.text('单周'));
    await tester.pump();
    await tester.tap(find.text('单周'));
    await tester.pump();
    expect(selectedWeeks(tester), {for (var w = 1; w <= 20; w += 2) w});
    await tester.tap(find.byKey(const Key('course_form_weeks_confirm')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('manual_course_save')));
    await _settleIo(tester);
    final saved = _c.manualCourses.single;
    expect(saved.isManual, isTrue);
    expect(saved.slots.single.occursInWeek(8), isFalse);
    expect(saved.slots.single.occursInWeek(7), isTrue);

    // 2. 节次联动与冲突提示 + 窄屏深色键盘备注自动聚焦
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      MaterialApp(
        home: ManualCourseForm(
          controller: _c,
          initialSlot: _c.jwxtCourses.single.slots.single,
        ),
      ),
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
        find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              (w.decoration?.hintText?.startsWith('搜索') ?? false),
        ),
        '第 $start 节',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(
              of: find.byType(MiuixPopupHost),
              matching: find.text('第 $start 节'),
            )
            .last,
      );
      await tester.pumpAndSettle();
    }

    expect((value('start'), value('end')), (1, 2));
    expect(find.byKey(const Key('manual_course_conflict')), findsOneWidget);
    await startAt(5);
    expect((value('start'), value('end')), (5, 6));
    expect(find.byKey(const Key('manual_course_conflict')), findsNothing);
    await startAt(_c.lastPeriod);
    expect((value('start'), value('end')), (_c.lastPeriod, _c.lastPeriod));
    await startAt(2);
    expect((value('start'), value('end')), (2, 3));

    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
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
    tester.view.reset();

    // 3. 手动课详情编辑预填与二次确认删除
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await _pumpLauncher(
      tester,
      (ctx) => showCourseDetailSheet(
        ctx,
        cell: GridCell(
          course: saved,
          slot: saved.slots.single,
          conflictCount: 0,
          activeThisWeek: true,
        ),
        controller: _c,
      ),
    );
    expect(find.text('手动添加'), findsOneWidget);
    expect(find.byKey(const Key('course_detail_jwxt_edit')), findsNothing);
    expect(find.text('恢复原课程'), findsNothing);
    await tester.tap(find.byKey(const Key('course_detail_edit')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('manual_course_name')),
      '自习课新版',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manual_course_save')));
    await tester.pumpAndSettle();
    await _settleIo(tester);
    expect(
      _c
          .cellsForDay(7, 1)
          .firstWhere((c) => c.course.id == saved.id)
          .course
          .name,
      '自习课新版',
    );

    await tester.tap(find.byKey(const Key('launcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('course_detail_delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('course_delete_confirm')));
    await _settleIo(tester);
    expect(_c.manualCourses, isEmpty);
  });

  testWidgets('Android 预测性返回：未改可取消/完成，未保存退出提示保留与放弃', (tester) async {
    final jwxt = _course('j1', '测试课甲', source: CourseSource.jwxt);
    final manual = _course('m1', '测试课乙');
    _load(jwxt: [jwxt], manual: [manual]);

    // 1. 详情页进教务编辑：未修改支持预测性返回手势取消与完成
    await _pumpLauncher(
      tester,
      (context) => showCourseDetailSheet(
        context,
        cell: _c.cellsForDay(_week, 1).firstWhere((c) => c.course.id == 'j1'),
        controller: _c,
      ),
      theme: appLightTheme(),
    );
    final detail = find.byKey(const Key('course_detail_title'));
    final detailRoute = ModalRoute.of(tester.element(detail))!;
    await tester.tap(find.byKey(const Key('course_detail_jwxt_edit')));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('jwxt_edit_name'));
    final editRoute = ModalRoute.of(tester.element(field))! as PageRoute;
    expect(editRoute.fullscreenDialog, isFalse);
    expect(editRoute.popGestureEnabled, isTrue);
    expect(await _backGesture(tester, 'startBackGesture', edge: 1), isTrue);
    await _backGesture(
      tester,
      'updateBackGestureProgress',
      progress: 0.4,
      edge: 1,
    );
    expect(editRoute.animation!.value, closeTo(0.6, 0.001));
    await _backGesture(tester, 'cancelBackGesture', edge: 1);
    expect(editRoute.isCurrent, isTrue);

    expect(await _backGesture(tester, 'startBackGesture', edge: 1), isTrue);
    await _backGesture(
      tester,
      'updateBackGestureProgress',
      progress: 0.4,
      edge: 1,
    );
    await _backGesture(tester, 'commitBackGesture', edge: 1);
    expect(field, findsNothing);
    expect(detailRoute.isCurrent, isTrue);

    // 2. 手动添加表单有改动时关闭弹出未保存拦截；恢复原值后重新放行返回，选放弃则不保存
    await _pumpLauncher(
      tester,
      (context) => showManualCourseForm(context, controller: _c),
      theme: appDarkTheme(),
    );
    final mField = find.byKey(const Key('manual_course_name'));
    await tester.enterText(mField, '待保存课程');
    await tester.pump();
    expect(
      tester
          .widget<PopScope<Object?>>(find.byType(PopScope<Object?>).last)
          .canPop,
      isFalse,
    );
    tester.widget<TextFormField>(mField).controller!.clear();
    await tester.pump();
    expect(
      tester
          .widget<PopScope<Object?>>(find.byType(PopScope<Object?>).last)
          .canPop,
      isTrue,
    );

    await tester.enterText(mField, '待保存的课程');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('course_form_close')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('course_form_discard_cancel')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextFormField>(mField).controller!.text, '待保存的课程');
    await tester.tap(find.byKey(const Key('course_form_close')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('course_form_discard_confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('manual_course_name')), findsNothing);
    expect(_c.manualCourses, hasLength(1));
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('教务课编辑、单日修改 diff 与恢复、删除二次确认及课程转独立考试', (tester) async {
    final jwxt = _course('j1', '测试课甲', source: CourseSource.jwxt).copyWith(
      classId: '02',
      credit: 3,
      slots: [
        const CourseSlot(
          day: 1,
          startNode: 3,
          endNode: 4,
          weeks: '11111111111111111111',
          location: '测试楼 A101',
          teacher: '张老师',
        ),
        const CourseSlot(
          day: 3,
          startNode: 5,
          endNode: 6,
          weeks: '11111111111111111111',
          location: '测试楼 A101',
          teacher: '张老师',
        ),
      ],
    );

    GridCell cellOf(String id) =>
        _c.cellsForDay(_week, 1).firstWhere((c) => c.course.id == id);

    // 1. 教务课详情未修改无恢复入口；修改字段后显示「课程已修改」diff 并可恢复
    _load(jwxt: [jwxt]);
    await _pumpLauncher(
      tester,
      (ctx) => showCourseDetailSheet(ctx, cell: cellOf('j1'), controller: _c),
    );
    expect(find.byKey(const Key('course_detail_jwxt_edit')), findsOneWidget);
    expect(find.byKey(const Key('course_detail_jwxt_delete')), findsOneWidget);
    expect(find.text('恢复原课程'), findsNothing);
    expect(find.text('已修改'), findsNothing);
    expect(find.text('添加备注…'), findsOneWidget);

    await tester.runAsync(() => _c.editJwxtCourse('j1', location: '测试楼 B202'));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await _pumpLauncher(
      tester,
      (ctx) => showCourseDetailSheet(ctx, cell: cellOf('j1'), controller: _c),
    );
    expect(find.text('课程已修改'), findsOneWidget);
    await tester.tap(find.byKey(const Key('course_detail_modified')));
    await tester.pumpAndSettle();
    final diffCourse = find.byKey(const Key('course_detail_diff_course'));
    expect(
      find.descendant(of: diffCourse, matching: find.text('修改前：测试楼 A101')),
      findsNWidgets(2),
    );
    expect(
      find.descendant(of: diffCourse, matching: find.text('修改后：测试楼 B202')),
      findsNWidgets(2),
    );
    await tester.tap(find.byKey(const Key('course_detail_restore_course')));
    await _settleIo(tester);
    expect(_c.isJwxtOverridden(courseId: 'j1'), isFalse);

    // 2. 教务课表单改类型/节次，范围选择取消保留草稿、选单次只改本周
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      MaterialApp(
        home: JwxtCourseEditPage(controller: _c, cell: cellOf('j1')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('jwxt_edit_name')), '测试课乙');
    tester
        .widget<AppSelectFormField<CourseKind>>(
          find.byKey(const Key('course_form_kind')),
        )
        .onChanged!(CourseKind.lab);
    await tester.pump();
    final start = find.descendant(
      of: find.byKey(const Key('course_form_start')),
      matching: find.byType(AppSelectFormField<int>),
    );
    tester.widget<AppSelectFormField<int>>(start).onChanged!(5);
    await tester.pump();
    await tester.tap(find.byKey(const Key('jwxt_edit_save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('course_form_scope_sheet')), findsOneWidget);
    await tester.tap(find.byKey(const Key('course_form_scope_cancel')));
    await tester.pumpAndSettle();
    expect(_c.cellsForDay(_week, 1).single.course.name, '测试课甲');

    await tester.tap(find.byKey(const Key('jwxt_edit_save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('course_form_scope_once')));
    await _settleIo(tester);
    final edited = _c.cellsForDay(_week, 1).single;
    expect(edited.course.name, '测试课乙');
    expect((edited.slot.startNode, edited.slot.endNode), (5, 6));
    expect(
      courseKindOf(course: edited.course, slot: edited.slot),
      CourseKind.lab,
    );
    expect(_c.cellsForDay(_week + 1, 1).single.course.name, '测试课甲');

    // 3. 单日挪课叠加改节次 diff 可恢复底层原位置
    _c.debugReset();
    _load(jwxt: [jwxt]);
    await tester.runAsync(
      () => _c.moveSlot(
        _c.courses.single,
        0,
        toDay: 2,
        toStartPeriod: 5,
        week: _week,
        scope: MoveScope.thisWeek,
      ),
    );
    await tester.runAsync(
      () => _c.editOccurrence(_c.cellsForDay(_week, 2).single, toStart: 7),
    );
    await _pumpLauncher(
      tester,
      (context) => showCourseDetailSheet(
        context,
        cell: _c.cellsForDay(_week, 2).single,
        controller: _c,
      ),
    );
    await tester.tap(find.byKey(const Key('course_detail_date_edit')));
    await tester.pumpAndSettle();
    final position = find.byKey(const Key('course_detail_diff_position'));
    expect(
      find.descendant(of: position, matching: find.text('修改后：周二 第 5–6 节')),
      findsOneWidget,
    );
    final restore = find.byKey(const Key('course_detail_restore'));
    await tester.ensureVisible(restore);
    await tester.tap(restore);
    await _settleIo(tester);
    expect(_c.slotOverrides, isEmpty);
    expect(_c.cellsForDay(_week, 1).single.slot.startNode, 3);

    // 4. 教务课转独立考试提示且只迁移本次；随后恢复原文并测删除全部时段二次确认
    _c.debugReset();
    _load(jwxt: [jwxt]);
    await _pumpLauncher(
      tester,
      (ctx) => showCourseDetailSheet(ctx, cell: cellOf('j1'), controller: _c),
    );
    await tester.tap(find.byKey(const Key('course_detail_jwxt_edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('course_form_kind')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('考试').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('jwxt_edit_name')), '测试课甲考试');
    await tester.enterText(
      find.byKey(const Key('jwxt_edit_location')),
      '测试楼 B202',
    );
    await tester.tap(find.byKey(const Key('jwxt_edit_save')));
    await tester.pumpAndSettle();
    expect(find.text('仅修改本周这节课'), findsOneWidget);
    await tester.tap(find.byKey(const Key('course_form_exam_cancel')));
    await tester.pumpAndSettle();
    expect(_c.scheduleEvents, isEmpty);

    await tester.tap(find.byKey(const Key('jwxt_edit_save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('course_form_exam_confirm')));
    await _settleIo(tester);
    expect(_c.cellsForDay(_week, 1).where((c) => c.activeThisWeek), isEmpty);
    expect(_c.cellsForDay(_week + 1, 1).single.course.name, '测试课甲');
    expect(_c.cellsForDay(_week, 3).single.course.name, '测试课甲');
    final exam = _c.scheduleEvents.single;
    expect(exam.kind, ScheduleKind.exam);
    expect(exam.title, '测试课甲考试');

    // 通过日程详情修改转换后的考试地点
    await _pumpLauncher(
      tester,
      (ctx) => showScheduleEventDetailSheet(ctx, event: exam, controller: _c),
    );
    await tester.tap(find.byKey(const Key('schedule_detail_edit')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('schedule_form_location')),
      '测试楼 C303',
    );
    await tester.tap(find.byKey(const Key('schedule_form_save')));
    await _settleIo(tester);
    expect(_c.scheduleEvents.single.location, '测试楼 C303');

    // 删除全部时段二次确认（取消保留、确认记录本地删除）
    _c.debugReset();
    _load(jwxt: [jwxt]);
    await _pumpLauncher(
      tester,
      (ctx) => showCourseDetailSheet(
        ctx,
        cell: _c.cellsForDay(_week, 3).single,
        controller: _c,
      ),
    );
    await tester.tap(find.byKey(const Key('course_detail_jwxt_delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('这门课程的全部时间段'));
    await tester.pumpAndSettle();
    expect(find.text('删除这门课？同步后也不会恢复，可在设置里一键恢复。'), findsOneWidget);
    await tester.tap(find.byKey(const Key('jwxt_delete_cancel')));
    await tester.pumpAndSettle();
    expect(_c.courseEditOf('j1'), isNull);

    await tester.tap(find.byKey(const Key('course_detail_jwxt_delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('这门课程的全部时间段'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('jwxt_delete_confirm')));
    await _settleIo(tester);
    expect(_c.courseEditOf('j1')?.deleted, isTrue);
    expect(_c.courses.where((c) => c.id == 'j1'), isEmpty);
  });

  for (final dark in [false, true]) {
    testWidgets('${dark ? '深色' : '浅色'}日程表单未修改支持预测性返回，修改后拦截并可恢复', (
      tester,
    ) async {
      _load();
      await _pumpLauncher(
        tester,
        (context) => showScheduleEventEditPage(
          context,
          controller: _c,
          kind: ScheduleKind.other,
        ),
        theme: dark ? appDarkTheme() : appLightTheme(),
      );
      final titleField = find.byKey(const Key('schedule_form_title'));
      final route = ModalRoute.of(tester.element(titleField))! as PageRoute;
      expect(route.popGestureEnabled, isTrue);

      await tester.enterText(titleField, '临时日程');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(route.popGestureEnabled, isFalse);
      expect(await _backGesture(tester, 'startBackGesture'), isFalse);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget);

      await tester.tap(find.byKey(const Key('schedule_form_discard_cancel')));
      await tester.pumpAndSettle();
      expect(find.text('临时日程'), findsOneWidget);

      await tester.enterText(titleField, '');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(route.popGestureEnabled, isTrue);

      expect(await _backGesture(tester, 'startBackGesture'), isTrue);
      await _backGesture(tester, 'updateBackGestureProgress', progress: 0.4);
      await _backGesture(tester, 'commitBackGesture');
      expect(find.byKey(const Key('schedule_form_title')), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
}
