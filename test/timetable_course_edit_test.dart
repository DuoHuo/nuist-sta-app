// 课表：「+」三选一、考试 / 其他日程表单与周视图、教务课编辑 / 删除 / 恢复、
// 首页卡片日程（design/timetable-spec.md §13.15、§14.1–§14.4）。
// 编号对齐课表测试用例 §24（EV / EX / JE / HT）。
// 全部为虚构数据（「测试课甲」「张老师」「测试楼 A101」），不读真实样例。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/app_select.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_edit_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_manual_course_form.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event_detail_sheet.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event_edit_page.dart';
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
  void Function(BuildContext context) open, {
  ThemeData? theme,
}) async {
  _bigView(tester);
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

  group('表单预测性返回', () {
    final jwxt = _course('j1', '测试课甲', source: CourseSource.jwxt);
    final manual = _course('m1', '测试课乙');
    final entries =
        <
          ({
            String label,
            Future<Object?> Function(BuildContext) open,
            String nameKey,
            String initialName,
          })
        >[
          (
            label: '教务课程编辑',
            open: (context) => showJwxtCourseEditPage(
              context,
              controller: _c,
              cell: _c
                  .cellsForDay(_week, 1)
                  .firstWhere((c) => c.course.id == 'j1'),
            ),
            nameKey: 'jwxt_edit_name',
            initialName: jwxt.name,
          ),
          (
            label: '手动课程添加',
            open: (context) => showManualCourseForm(context, controller: _c),
            nameKey: 'manual_course_name',
            initialName: '',
          ),
          (
            label: '手动课程编辑',
            open: (context) =>
                showManualCourseForm(context, controller: _c, initial: manual),
            nameKey: 'manual_course_name',
            initialName: manual.name,
          ),
          for (final kind in ScheduleKind.values)
            for (final editing in [false, true])
              (
                label:
                    '${kind == ScheduleKind.exam ? '考试' : '其他日程'}${editing ? '编辑' : '添加'}',
                open: (context) => showScheduleEventEditPage(
                  context,
                  controller: _c,
                  kind: kind,
                  initial: editing
                      ? ScheduleEvent(
                          id: 'event-${kind.name}',
                          kind: kind,
                          source: ScheduleSource.manual,
                          title: '测试安排',
                          date: DateTime(2026, 10, 19),
                          start: const TimeOfDayMinutes(10, 10),
                          end: const TimeOfDayMinutes(11, 50),
                        )
                      : null,
                ),
                nameKey: 'schedule_form_title',
                initialName: editing ? '测试安排' : '',
              ),
        ];

    for (final (index, entry) in entries.indexed) {
      final dark = index.isOdd;
      final edge = dark ? 1 : 0;
      testWidgets('${entry.label}真实入口支持跟随、取消和完成（深色 $dark）', (tester) async {
        _load(jwxt: [jwxt], manual: [manual]);
        var returned = false;
        Object? result;
        await _pumpLauncher(tester, (context) {
          entry.open(context).then((value) {
            returned = true;
            result = value;
          });
        }, theme: dark ? appDarkTheme() : appLightTheme());
        final field = find.byKey(Key(entry.nameKey));
        final fieldController = tester.widget<TextFormField>(field).controller!;
        final route = ModalRoute.of(tester.element(field))! as PageRoute;
        final navigator = route.navigator!;
        expect(fieldController.text, entry.initialName);
        expect(route.fullscreenDialog, isFalse);
        expect(route.popGestureEnabled, isTrue);

        expect(
          await _backGesture(tester, 'startBackGesture', edge: edge),
          isTrue,
        );
        await _backGesture(
          tester,
          'updateBackGestureProgress',
          progress: 0.4,
          edge: edge,
        );
        expect(navigator.userGestureInProgress, isTrue);
        expect(route.animation!.value, closeTo(0.6, 0.001));
        await _backGesture(tester, 'cancelBackGesture', edge: edge);
        expect(navigator.userGestureInProgress, isFalse);
        expect(route.isCurrent, isTrue);
        expect(route.animation!.value, 1);
        expect(returned, isFalse);
        expect(
          tester.widget<TextFormField>(field).controller,
          same(fieldController),
        );
        expect(fieldController.text, entry.initialName);

        expect(
          await _backGesture(tester, 'startBackGesture', edge: edge),
          isTrue,
        );
        await _backGesture(
          tester,
          'updateBackGestureProgress',
          progress: 0.4,
          edge: edge,
        );
        await _backGesture(tester, 'commitBackGesture', edge: edge);
        expect(field, findsNothing);
        expect(find.byKey(const Key('launcher')), findsOneWidget);
        expect(navigator.canPop(), isFalse);
        expect(returned, isTrue);
        expect(result, isNull, reason: '返回不应被调用方视为保存成功');
      }, variant: TargetPlatformVariant.only(TargetPlatform.android));
    }

    for (final entry in [entries[0], entries[2]]) {
      final dark = entry.nameKey == 'manual_course_name';
      testWidgets('${entry.label}未保存时拦截，继续编辑保留内容，恢复后允许手势', (tester) async {
        _load(jwxt: [jwxt], manual: [manual]);
        await _pumpLauncher(
          tester,
          (context) => entry.open(context),
          theme: dark ? appDarkTheme() : appLightTheme(),
        );
        final field = find.byKey(Key(entry.nameKey));
        final route = ModalRoute.of(tester.element(field))! as PageRoute;
        await tester.enterText(field, '待保存修改');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        expect(route.popDisposition, RoutePopDisposition.doNotPop);
        expect(route.popGestureEnabled, isFalse);
        expect(await _backGesture(tester, 'startBackGesture'), isFalse);
        await _backGesture(tester, 'commitBackGesture');
        expect(find.text('放弃未保存的修改？'), findsOneWidget);
        await tester.tap(find.byKey(const Key('course_form_discard_cancel')));
        await tester.pumpAndSettle();
        expect(route.isCurrent, isTrue);
        expect(tester.widget<TextFormField>(field).controller!.text, '待保存修改');
        expect(route.popGestureEnabled, isFalse);

        await tester.enterText(field, entry.initialName);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        expect(route.popDisposition, RoutePopDisposition.pop);
        expect(route.popGestureEnabled, isTrue);
        expect(await _backGesture(tester, 'startBackGesture'), isTrue);
        await _backGesture(tester, 'updateBackGestureProgress', progress: 0.4);
        await _backGesture(tester, 'commitBackGesture');
        expect(field, findsNothing);
        expect(find.byKey(const Key('launcher')), findsOneWidget);
        expect(_c.jwxtCourses.single.name, jwxt.name);
        expect(_c.manualCourses.single.name, manual.name);
      }, variant: TargetPlatformVariant.only(TargetPlatform.android));
    }

    testWidgets('从详情弹层进入编辑时预测性返回保留详情', (tester) async {
      _load(jwxt: [jwxt]);
      await _pumpLauncher(
        tester,
        (context) => showCourseDetailSheet(
          context,
          cell: _c.cellsForDay(_week, 1).single,
          controller: _c,
        ),
        theme: appDarkTheme(),
      );
      final detail = find.byType(CourseDetailSheet);
      final detailRoute = ModalRoute.of(tester.element(detail))!;
      expect(detailRoute, isA<ModalBottomSheetRoute<void>>());
      await tester.tap(find.byKey(const Key('course_detail_jwxt_edit')));
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('jwxt_edit_name'));
      final editRoute = ModalRoute.of(tester.element(field))! as PageRoute;
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
      expect(editRoute.animation!.value, 1);
      expect(tester.widget<TextFormField>(field).controller!.text, jwxt.name);
      expect(detailRoute.isActive, isTrue);

      expect(await _backGesture(tester, 'startBackGesture', edge: 1), isTrue);
      await _backGesture(
        tester,
        'updateBackGestureProgress',
        progress: 0.4,
        edge: 1,
      );
      await _backGesture(tester, 'commitBackGesture', edge: 1);
      expect(field, findsNothing);
      expect(detail, findsOneWidget);
      expect(ModalRoute.of(tester.element(detail)), same(detailRoute));
      expect(detailRoute.isCurrent, isTrue);
      expect(find.byKey(const Key('course_detail_jwxt_edit')), findsOneWidget);
      expect(_c.courseEditOf(jwxt.id), isNull);
      expect(find.text('已保存'), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('Android 适配不改变 iOS 三类入口的全屏模态行为', (tester) async {
      _load(jwxt: [jwxt], manual: [manual]);
      for (final entry in [entries[0], entries[1], entries[3]]) {
        await _pumpLauncher(
          tester,
          (context) => entry.open(context),
          theme: appLightTheme(),
        );
        final route =
            ModalRoute.of(tester.element(find.byKey(Key(entry.nameKey))))!
                as PageRoute;
        expect(route.fullscreenDialog, isTrue, reason: entry.label);
        expect(route.popGestureEnabled, isFalse, reason: entry.label);
        route.navigator!.pop();
        await tester.pumpAndSettle();
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });

  for (final source in CourseSource.values) {
    final dark = source == CourseSource.manual;
    testWidgets('课程转独立考试只迁移本次，确认前提示且可取消（${source.name}，深色 $dark）', (
      tester,
    ) async {
      final original = _course('convert', '测试课甲', source: source);
      final course = original.copyWith(
        slots: [
          ...original.slots,
          original.slots.single.copyWith(day: 3, startNode: 5, endNode: 6),
        ],
      );
      _load(
        manual: source == CourseSource.manual ? [course] : const [],
        jwxt: source == CourseSource.jwxt ? [course] : const [],
      );
      final theme = dark ? appDarkTheme() : appLightTheme();
      await _pumpLauncher(
        tester,
        (context) => showCourseDetailSheet(
          context,
          cell: _c.cellsForDay(_week, 1).single,
          controller: _c,
        ),
        theme: theme,
      );
      await tester.tap(
        find.byKey(
          Key(
            source == CourseSource.manual
                ? 'course_detail_edit'
                : 'course_detail_jwxt_edit',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('course_form_kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('考试').last);
      await tester.pumpAndSettle();
      final prefix = source == CourseSource.manual
          ? 'manual_course_'
          : 'jwxt_edit_';
      await tester.enterText(find.byKey(Key('${prefix}name')), '测试课甲考试');
      await tester.enterText(find.byKey(Key('${prefix}location')), '测试楼 B202');
      await tester.tap(find.byKey(Key('${prefix}save')));
      await tester.pumpAndSettle();
      expect(find.text('仅修改本周这节课'), findsOneWidget);
      expect(find.byKey(const Key('course_form_scope_sheet')), findsNothing);
      expect(find.byKey(const Key('course_form_repeat_sheet')), findsNothing);
      expect(_c.scheduleEvents, isEmpty);
      expect(_c.cellsForDay(_week, 1).single.course.name, '测试课甲');

      await tester.tap(find.byKey(const Key('course_form_exam_cancel')));
      await tester.pumpAndSettle();
      expect(find.text('仅修改本周这节课'), findsNothing);
      expect(_c.scheduleEvents, isEmpty);
      expect(_c.courseDateEdits, isEmpty);
      expect(
        tester
            .widget<TextFormField>(find.byKey(Key('${prefix}name')))
            .controller!
            .text,
        '测试课甲考试',
      );

      await tester.tap(find.byKey(Key('${prefix}save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('course_form_exam_confirm')));
      await _settleIo(tester);
      expect(tester.takeException(), isNull);
      expect(
        _c.cellsForDay(_week, 1).where((cell) => cell.activeThisWeek),
        isEmpty,
      );
      expect(_c.cellsForDay(_week + 1, 1).single.course.name, '测试课甲');
      expect(_c.cellsForDay(_week, 3).single.course.name, '测试课甲');
      final exam = _c.scheduleEvents.single;
      expect(exam.kind, ScheduleKind.exam);
      expect(exam.source, ScheduleSource.manual);
      expect(exam.title, '测试课甲考试');
      expect(exam.date, DateTime(2026, 10, 19));
      expect(exam.start, const TimeOfDayMinutes(10, 10));
      expect(exam.end, const TimeOfDayMinutes(11, 50));
      expect(exam.location, '测试楼 B202');

      await _pumpLauncher(
        tester,
        (context) =>
            showScheduleEventDetailSheet(context, event: exam, controller: _c),
        theme: theme,
      );
      await tester.tap(find.byKey(const Key('schedule_detail_edit')));
      await tester.pumpAndSettle();
      expect(find.text('编辑考试'), findsOneWidget);
      expect(find.byKey(const Key('course_form_kind')), findsNothing);
      expect(find.byKey(const Key('schedule_form_kind')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('schedule_form_location')),
        '测试楼 C303',
      );
      await tester.tap(find.byKey(const Key('schedule_form_save')));
      await _settleIo(tester);
      expect(_c.scheduleEvents.single.location, '测试楼 C303');
      expect(
        _c.cellsForDay(_week, 1).where((cell) => cell.activeThisWeek),
        isEmpty,
      );
      expect(_c.cellsForDay(_week + 1, 1).single.slot.location, '测试楼 A101');
      expect(_c.cellsForDay(_week, 3).single.slot.location, '测试楼 A101');
      expect(tester.takeException(), isNull);
    });
  }

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

    testWidgets('教务课可改类型与节次，保存时选择范围，保留其他周', (tester) async {
      _load(jwxt: [jwxt]);
      _bigView(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: JwxtCourseEditPage(controller: _c, cell: cellOf('j1')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextFormField), findsNWidgets(4));
      expect(find.byKey(const Key('jwxt_edit_teacher')), findsOneWidget);
      expect(find.byKey(const Key('jwxt_edit_note')), findsOneWidget);
      expect(find.byKey(const Key('course_form_scope_sheet')), findsNothing);
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
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('jwxt_edit_name')))
            .controller!
            .text,
        '测试课乙',
      );
      expect(_c.cellsForDay(_week, 1).single.course.name, '测试课甲');
      await tester.tap(find.byKey(const Key('jwxt_edit_save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('course_form_scope_once')));
      await tester.tap(find.byKey(const Key('course_form_scope_confirm')));
      await _settleIo(tester);
      final edited = _c.cellsForDay(_week, 1).single;
      expect(edited.course.name, '测试课乙');
      expect((edited.slot.startNode, edited.slot.endNode), (5, 6));
      expect(
        courseKindOf(course: edited.course, slot: edited.slot),
        CourseKind.lab,
      );
      expect(edited.slot.teacher, '张老师');
      final other = _c.cellsForDay(_week + 1, 1).single;
      expect(other.course.name, '测试课甲');
      expect((other.slot.startNode, other.slot.endNode), (3, 4));
      expect(
        courseKindOf(course: other.course, slot: other.slot),
        CourseKind.standard,
      );
      expect(_c.jwxtCourses.single.name, '测试课甲');
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
