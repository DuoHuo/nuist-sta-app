import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_exams_card.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_home_card.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_import_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_home_row.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

final _c = TimetableController.instance;

/// 开学 2026-08-31（周一）；第 7 周为 2026-10-12–2026-10-18。
final _termStart = DateTime(2026, 8, 31);
const _week = 7;

Course _course(
  String id,
  String name, {
  int day = 1,
  int start = 1,
  int end = 2,
  String weeks = '11111111111111111111',
  String location = '测试楼 A101',
  String teacher = '张老师',
  CourseKind? kind,
  CourseSource source = CourseSource.manual,
}) => Course(
  id: id,
  name: name,
  source: source,
  slots: [
    CourseSlot(
      day: day,
      startNode: start,
      endNode: end,
      weeks: weeks,
      location: location,
      teacher: teacher,
      kind: kind,
    ),
  ],
);

ScheduleEvent _event(
  String id, {
  ScheduleKind kind = ScheduleKind.exam,
  String title = '测试考试甲',
  required DateTime date,
  TimeOfDayMinutes start = const TimeOfDayMinutes(14, 0),
  TimeOfDayMinutes end = const TimeOfDayMinutes(16, 0),
  String location = '测试楼 B202',
  String note = '',
}) => ScheduleEvent(
  id: id,
  kind: kind,
  source: ScheduleSource.manual,
  title: title,
  date: date,
  start: start,
  end: end,
  location: location,
  note: note,
);

void _seed({
  List<Course> manual = const [],
  List<Course> jwxt = const [],
  int week = _week,
  TimetableSettings? settings,
  DateTime? syncedAt,
}) {
  _c.debugSetSnapshot(
    TimetableSnapshot(
      courses: jwxt,
      periods: TimetableController.defaultPeriods(),
      settings:
          settings ??
          TimetableSettings(termStartDate: _termStart, homeMaxItems: 5),
      syncedAt: syncedAt ?? DateTime(2026, 10, 12, 8),
    ),
    viewingWeek: week,
    manualCourses: manual,
  );
}

bool _isOrInsideWidgetType(Element element, Type targetType) {
  if (element.widget.runtimeType == targetType) return true;
  var found = false;
  element.visitAncestorElements((ancestor) {
    if (ancestor.widget.runtimeType == targetType) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

/// 校验首页行单遍 Stack 布局的左侧 3dp 色条与右侧 11dp 左边距像素对齐。
void _expectSinglePassAccentBar(
  WidgetTester tester, {
  required Finder rowStackFinder,
  required Finder contentColumnFinder,
  required double minExpectedHeight,
}) {
  expect(rowStackFinder, findsOneWidget);
  final stackRect = tester.getRect(rowStackFinder);
  expect(stackRect.height, greaterThanOrEqualTo(minExpectedHeight));

  final positionedFinder = find.descendant(
    of: rowStackFinder,
    matching: find.byType(Positioned),
  );
  expect(positionedFinder, findsOneWidget);
  final barFinder = find.descendant(
    of: positionedFinder,
    matching: find.byType(DecoratedBox),
  );
  expect(barFinder, findsOneWidget);

  final barRect = tester.getRect(barFinder);
  expect(barRect.left, closeTo(stackRect.left, 0.01));
  expect(barRect.width, closeTo(3.0, 0.01));
  expect(barRect.top, closeTo(stackRect.top + 2.0, 0.01));
  expect(barRect.bottom, closeTo(stackRect.bottom - 2.0, 0.01));
  expect(barRect.height, closeTo(stackRect.height - 4.0, 0.01));

  final box =
      tester.widget<DecoratedBox>(barFinder).decoration as BoxDecoration;
  expect(box.borderRadius, BorderRadius.circular(1.5));

  final contentRect = tester.getRect(contentColumnFinder);
  expect(contentRect.left, closeTo(stackRect.left + 11.0, 0.01));
  expect(contentRect.height, greaterThanOrEqualTo(40.0));
}

void main() {
  late Directory tmp;
  final origClock = TimetableController.clock;
  final origSyncClock = TimetableController.syncClock;
  final origBinding = TimetableController.bindingCheck;
  final origFetch = TimetableController.fetchSnapshot;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_s3');
    TimetableStore.debugDirectory = tmp;
    _c.debugReset();
    TimetableController.bindingCheck = () async => false;
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        throw const SocketException('offline (test)');
    TimetableController.clock = () => DateTime(2026, 10, 12, 8, 30);
    TimetableController.syncClock = () => DateTime(2026, 10, 12, 8, 30);
  });

  tearDown(() {
    TimetableController.clock = origClock;
    TimetableController.syncClock = origSyncClock;
    TimetableController.bindingCheck = origBinding;
    TimetableController.fetchSnapshot = origFetch;
    TimetableStore.debugDirectory = null;
    _c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('S3 viewingWeek 独立 ValueNotifier 隔离（controller）', () {
    test('setViewingWeek / goToCurrentWeek / jumpToCurrentWeek 仅通知周次监听', () {
      _seed(manual: [_course('c1', '测试课甲')]);
      expect(_c.currentWeek, 7);
      expect(_c.viewingWeek, 7);
      expect(_c.viewingWeekListenable.value, 7);
      expect(_c.isViewingCurrentWeek, isTrue);

      var controllerCalls = 0;
      final weekValues = <int>[];
      void onController() => controllerCalls++;
      void onWeek() => weekValues.add(_c.viewingWeekListenable.value);

      _c.addListener(onController);
      _c.viewingWeekListenable.addListener(onWeek);
      addTearDown(() {
        _c.removeListener(onController);
        _c.viewingWeekListenable.removeListener(onWeek);
      });

      _c.setViewingWeek(10);
      expect(_c.viewingWeek, 10);
      expect(_c.isViewingCurrentWeek, isFalse);
      expect(weekValues, [10]);
      expect(controllerCalls, 0);

      // 同周不重复通知；超界按 1..totalWeeks 钳制。
      _c.setViewingWeek(10);
      _c.setViewingWeek(99);
      _c.setViewingWeek(25);
      _c.setViewingWeek(0);
      expect(_c.viewingWeek, 1);
      expect(weekValues, [10, 20, 1]);
      expect(controllerCalls, 0);

      _c.goToCurrentWeek();
      expect(_c.viewingWeek, 7);
      expect(_c.isViewingCurrentWeek, isTrue);
      expect(weekValues, [10, 20, 1, 7]);
      expect(controllerCalls, 0);

      // 已在本周时再次 goToCurrentWeek / jumpToCurrentWeek 不通知。
      _c.goToCurrentWeek();
      _c.jumpToCurrentWeek();
      expect(weekValues, [10, 20, 1, 7]);
      expect(controllerCalls, 0);

      _c.setViewingWeek(12);
      _c.jumpToCurrentWeek();
      expect(_c.viewingWeek, 7);
      expect(_c.isViewingCurrentWeek, isTrue);
      expect(weekValues, [10, 20, 1, 7, 12, 7]);
      expect(controllerCalls, 0);
    });

    test('clearViewingWeek 与 debugReset 静默复位且不触发监听', () {
      _seed(manual: [_course('c1', '测试课甲')], week: 11);
      expect(_c.viewingWeek, 11);

      var controllerCalls = 0;
      var weekCalls = 0;
      void onController() => controllerCalls++;
      void onWeek() => weekCalls++;

      _c.addListener(onController);
      _c.viewingWeekListenable.addListener(onWeek);
      addTearDown(() {
        _c.removeListener(onController);
        _c.viewingWeekListenable.removeListener(onWeek);
      });

      _c.clearViewingWeek();
      expect(_c.viewingWeek, 7);
      expect(_c.viewingWeekListenable.value, 7);
      expect(controllerCalls, 0);
      expect(weekCalls, 0);

      _c.setViewingWeek(15);
      weekCalls = 0;

      _c.debugReset();
      expect(_c.viewingWeek, 1);
      expect(_c.viewingWeekListenable.value, 1);
      expect(controllerCalls, 0);
      expect(weekCalls, 0);
    });

    test('跨周 onAppResumed 仍同时更新周次监听与主监听（保证首页跨周刷新）', () async {
      final sunday = DateTime(2026, 10, 18, 22); // 第 7 周周日
      TimetableController.clock = () => sunday;
      TimetableController.syncClock = () => sunday;
      await TimetableStore.saveSnapshot(
        TimetableSnapshot(
          courses: [_course('c1', '测试课甲', source: CourseSource.jwxt)],
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(termStartDate: _termStart),
          syncedAt: sunday,
        ),
      );
      await ScheduleStore.saveLastSyncSuccess(sunday);
      await _c.ensureStarted();
      expect(_c.viewingWeek, 7);

      var controllerCalls = 0;
      final weekValues = <int>[];
      void onController() => controllerCalls++;
      void onWeek() => weekValues.add(_c.viewingWeekListenable.value);

      _c.addListener(onController);
      _c.viewingWeekListenable.addListener(onWeek);
      addTearDown(() {
        _c.removeListener(onController);
        _c.viewingWeekListenable.removeListener(onWeek);
      });

      // 跨到第 8 周周一：viewingWeek 拉回 8，且日期变化通知主监听刷新首页卡片。
      TimetableController.clock = () => DateTime(2026, 10, 19, 8);
      expect(await _c.onAppResumed(), isTrue);
      await pumpEventQueue();
      expect(_c.viewingWeek, 8);
      expect(weekValues, [8]);
      expect(controllerCalls, 1);

      // 同日再次回前台：无冗余通知。
      expect(await _c.onAppResumed(), isTrue);
      await pumpEventQueue();
      expect(weekValues, [8]);
      expect(controllerCalls, 1);

      // 同周跨天（周二）：只通知主监听刷新今日课表，不通知周次监听。
      TimetableController.clock = () => DateTime(2026, 10, 20, 8);
      expect(await _c.onAppResumed(), isTrue);
      await pumpEventQueue();
      expect(_c.viewingWeek, 8);
      expect(weekValues, [8]);
      expect(controllerCalls, 2);
    });
  });

  group('S3 翻周不重建栈底首页卡片且顶栏/回本周联动', () {
    testWidgets('左右翻周、滑条选周、点本周与代码跳周均不重建首页课表与考试卡片', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final now = DateTime(2026, 10, 12, 8, 30);
      _seed(manual: [_course('c1', '测试课甲')]);
      await tester.runAsync(
        () => _c.addScheduleEvent(
          _event('e1', date: DateTime(2026, 10, 14), title: '高等数学期中'),
        ),
      );

      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          theme: appLightTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  TimetableHomeCard(now: () => now),
                  const SizedBox(height: 12),
                  TimetableExamsCard(now: () => now),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home_card_title')), findsOneWidget);
      expect(find.byKey(const Key('exams_card_title')), findsOneWidget);

      // 从首页推入 TimetablePage：首页两张卡片留在路由栈底。
      navKey.currentState!.push<void>(
        MaterialPageRoute<void>(builder: (_) => const TimetablePage()),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TimetablePage), findsOneWidget);
      expect(find.textContaining('第 7 周', findRichText: true), findsOneWidget);
      expect(find.textContaining('(非本周)', findRichText: true), findsNothing);

      var homeCardRebuilds = 0;
      var examsCardRebuilds = 0;
      var controllerMainNotifies = 0;
      void onMainNotify() => controllerMainNotifies++;
      _c.addListener(onMainNotify);

      final prevRebuildCallback = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (Element e, bool builtOnce) {
        if (_isOrInsideWidgetType(e, TimetableHomeCard)) homeCardRebuilds++;
        if (_isOrInsideWidgetType(e, TimetableExamsCard)) examsCardRebuilds++;
        prevRebuildCallback?.call(e, builtOnce);
      };
      addTearDown(() {
        debugOnRebuildDirtyWidget = prevRebuildCallback;
        _c.removeListener(onMainNotify);
      });

      // 1. 左滑到第 8 周：顶栏联动显示「第 8 周 (非本周)」，栈底两卡零重建。
      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(_c.viewingWeek, 8);
      expect(find.textContaining('第 8 周', findRichText: true), findsOneWidget);
      expect(find.textContaining('(非本周)', findRichText: true), findsOneWidget);
      expect(homeCardRebuilds, 0);
      expect(examsCardRebuilds, 0);
      expect(controllerMainNotifies, 0);

      // 2. 再左滑到第 9 周，再右滑回第 8 周。
      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(_c.viewingWeek, 9);
      expect(find.textContaining('第 9 周', findRichText: true), findsOneWidget);

      await tester.drag(find.byType(PageView), const Offset(600, 0));
      await tester.pumpAndSettle();
      expect(_c.viewingWeek, 8);
      expect(find.textContaining('第 8 周', findRichText: true), findsOneWidget);
      expect(homeCardRebuilds, 0);
      expect(examsCardRebuilds, 0);
      expect(controllerMainNotifies, 0);

      // 3. 打开顶栏周条，用滑条选第 12 周，再点「本周」回到第 7 周。
      await tester.tap(find.textContaining('第 8 周', findRichText: true));
      await tester.pumpAndSettle();
      final slider = tester.widget<Slider>(
        find.byKey(const Key('timetable_week_slider')),
      );
      slider.onChanged?.call(12);
      await tester.pump();
      slider.onChangeEnd?.call(12);
      await tester.pumpAndSettle();
      expect(_c.viewingWeek, 12);
      expect(find.textContaining('第 12 周', findRichText: true), findsOneWidget);
      expect(find.textContaining('(非本周)', findRichText: true), findsOneWidget);

      await tester.tap(find.byKey(const Key('timetable_week_strip_current')));
      await tester.pumpAndSettle();
      expect(_c.viewingWeek, 7);
      expect(find.textContaining('第 7 周', findRichText: true), findsOneWidget);
      expect(find.textContaining('(非本周)', findRichText: true), findsNothing);
      expect(
        tester.widget<PageView>(find.byType(PageView)).controller!.page,
        closeTo(6, 0.001),
      );
      expect(homeCardRebuilds, 0);
      expect(examsCardRebuilds, 0);
      expect(controllerMainNotifies, 0);

      // 4. 代码调用 setViewingWeek / goToCurrentWeek / jumpToCurrentWeek：
      // 顶栏与 PageView 正常联动，首页两张卡片依然零重建。
      _c.setViewingWeek(14);
      await tester.pumpAndSettle();
      expect(find.textContaining('第 14 周', findRichText: true), findsOneWidget);
      expect(find.textContaining('(非本周)', findRichText: true), findsOneWidget);
      expect(
        tester.widget<PageView>(find.byType(PageView)).controller!.page,
        closeTo(13, 0.001),
      );

      _c.goToCurrentWeek();
      await tester.pumpAndSettle();
      expect(find.textContaining('第 7 周', findRichText: true), findsOneWidget);
      expect(find.textContaining('(非本周)', findRichText: true), findsNothing);
      expect(
        tester.widget<PageView>(find.byType(PageView)).controller!.page,
        closeTo(6, 0.001),
      );

      _c.setViewingWeek(15);
      await tester.pumpAndSettle();
      _c.jumpToCurrentWeek();
      await tester.pumpAndSettle();
      expect(find.textContaining('第 7 周', findRichText: true), findsOneWidget);
      expect(find.textContaining('(非本周)', findRichText: true), findsNothing);
      expect(homeCardRebuilds, 0);
      expect(examsCardRebuilds, 0);
      expect(controllerMainNotifies, 0);

      // 对照验证：课程数据真实变化时，栈底首页两卡仍正常收到通知并重建。
      _seed(manual: [_course('c1', '测试课甲（已更新）')], week: 7);
      await tester.pumpAndSettle();
      expect(controllerMainNotifies, greaterThan(0));
      expect(homeCardRebuilds, greaterThan(0));
      expect(examsCardRebuilds, greaterThan(0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('切换到导入子课表后翻周与跳周正常联动且不触发主监听', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      _seed(manual: [_course('c1', '测试课甲')]);
      final api = TimetableImportApi();
      final importedResult = await tester.runAsync(
        () => api.fetchByShareText(TimetableImportApi.demoShareText),
      );
      api.close();
      final importedMeta = (await tester.runAsync(
        () => _c.importWakeupSchedule(importedResult!, name: '同学课表'),
      ))!;

      await tester.pumpWidget(
        MaterialApp(theme: appLightTheme(), home: const TimetablePage()),
      );
      await tester.pumpAndSettle();

      final scoped = _c.viewingController;
      expect(identical(scoped, _c), isFalse);
      expect(_c.viewingScheduleId, importedMeta.id);

      var hostCalls = 0;
      var scopedCalls = 0;
      void onHost() => hostCalls++;
      void onScoped() => scopedCalls++;
      _c.addListener(onHost);
      scoped.addListener(onScoped);
      addTearDown(() {
        _c.removeListener(onHost);
        scoped.removeListener(onScoped);
      });

      final targetWeek = scoped.viewingWeek == 3 ? 5 : 3;
      scoped.setViewingWeek(targetWeek);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('第 $targetWeek 周', findRichText: true),
        findsOneWidget,
      );
      expect(
        tester.widget<PageView>(find.byType(PageView)).controller!.page,
        closeTo(targetWeek - 1, 0.001),
      );
      expect(hostCalls, 0);
      expect(scopedCalls, 0);

      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(scoped.viewingWeek, targetWeek + 1);
      expect(
        find.textContaining('第 ${targetWeek + 1} 周', findRichText: true),
        findsOneWidget,
      );
      expect(hostCalls, 0);
      expect(scopedCalls, 0);
      expect(tester.takeException(), isNull);
    });
  });

  group('S3 首页卡片去 IntrinsicHeight 单遍布局与对齐', () {
    for (final brightness in Brightness.values) {
      testWidgets(
        '${brightness.name}：窄屏大字号多行内容下课程行/日程行/考试行无 IntrinsicHeight、无溢出且色条对齐',
        (tester) async {
          tester.view.physicalSize = const Size(320, 960);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);

          final now = DateTime(2026, 10, 12, 8, 30);
          TimetableController.clock = () => now;
          _seed(
            manual: [
              _course(
                'lab_long',
                '超长多行实验课程名称用于验证大字号换行时左侧色条等高拉伸与零溢出',
                day: 1,
                start: 1,
                end: 2,
                location: '大气科学与环境实验教学中心超长教学楼名称三层 305 实验室',
                teacher: '张老师、李老师联合授课',
                kind: CourseKind.lab,
              ),
            ],
          );
          await tester.runAsync(() async {
            await _c.addScheduleEvent(
              _event(
                'other_long',
                kind: ScheduleKind.other,
                title: '超长多行日程标题用于验证首页日程行在大字号下的换行与色条等高拉伸',
                date: DateTime(2026, 10, 12),
                start: const TimeOfDayMinutes(14, 0),
                end: const TimeOfDayMinutes(16, 0),
                location: '大学生活动中心报告厅东侧多功能研讨室二楼',
              ),
            );
            await _c.addScheduleEvent(
              _event(
                'exam_long',
                kind: ScheduleKind.exam,
                title: '超长多行期末考试科目名称用于验证考试卡片行大字号不溢出且色条等高',
                date: DateTime(2026, 10, 15),
                start: const TimeOfDayMinutes(9, 0),
                end: const TimeOfDayMinutes(11, 0),
                location: '明德楼南侧超长考场地点描述四层 S408 阶梯教室',
                note: '请携带学生证、身份证及无存储功能科学计算器提前二十分钟入场',
              ),
            );
          });

          await tester.pumpWidget(
            MaterialApp(
              theme: brightness == Brightness.dark
                  ? appDarkTheme()
                  : appLightTheme(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2.0)),
                child: child!,
              ),
              home: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      TimetableHomeCard(now: () => now),
                      const SizedBox(height: 12),
                      TimetableExamsCard(now: () => now),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
          expect(find.byType(IntrinsicHeight), findsNothing);

          // 1. 课程行（含实验胶囊 + 上课中进度条 + 多行文本）
          final courseTime = find.byKey(const Key('home_course_time'));
          expect(courseTime, findsOneWidget);
          expect(find.byKey(const Key('home_course_lab_pill')), findsOneWidget);
          expect(find.byKey(const Key('home_course_progress')), findsOneWidget);
          final courseStack = find
              .ancestor(of: courseTime, matching: find.byType(Stack))
              .first;
          final courseColumn = find
              .ancestor(of: courseTime, matching: find.byType(Column))
              .first;
          _expectSinglePassAccentBar(
            tester,
            rowStackFinder: courseStack,
            contentColumnFinder: courseColumn,
            minExpectedHeight: 80,
          );

          // 2. 日程行（ScheduleHomeRow）
          final scheduleRow = find.byType(ScheduleHomeRow);
          expect(scheduleRow, findsOneWidget);
          final scheduleStack = find.descendant(
            of: scheduleRow,
            matching: find.byType(Stack),
          );
          final scheduleColumn = find.descendant(
            of: scheduleStack,
            matching: find.byType(Column),
          );
          _expectSinglePassAccentBar(
            tester,
            rowStackFinder: scheduleStack,
            contentColumnFinder: scheduleColumn,
            minExpectedHeight: 60,
          );

          // 3. 考试卡片行（_ExamRow，含考场与备注）
          final examRow = find.byKey(const Key('exams_card_row_exam_long'));
          expect(examRow, findsOneWidget);
          final examStack = find.descendant(
            of: examRow,
            matching: find.byType(Stack),
          );
          final examColumn = find.descendant(
            of: examStack,
            matching: find.byType(Column),
          );
          _expectSinglePassAccentBar(
            tester,
            rowStackFinder: examStack,
            contentColumnFinder: examColumn,
            minExpectedHeight: 80,
          );
        },
      );
    }

    testWidgets('简短单行内容保持 minHeight: 40、左侧 3dp 色条与 11dp 对齐', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final now = DateTime(2026, 10, 12, 7, 0);
      TimetableController.clock = () => now;
      _seed(
        manual: [_course('short_course', '高数', location: '', teacher: '')],
      );
      await tester.runAsync(() async {
        await _c.addScheduleEvent(
          _event(
            'short_other',
            kind: ScheduleKind.other,
            title: '班会',
            date: DateTime(2026, 10, 12),
            location: '',
          ),
        );
        await _c.addScheduleEvent(
          _event(
            'short_exam',
            kind: ScheduleKind.exam,
            title: '高数',
            date: DateTime(2026, 10, 15),
            location: '',
            note: '',
          ),
        );
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: appLightTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  TimetableHomeCard(now: () => now),
                  const SizedBox(height: 12),
                  TimetableExamsCard(now: () => now),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(IntrinsicHeight), findsNothing);

      final courseTime = find.byKey(const Key('home_course_time'));
      final courseStack = find
          .ancestor(of: courseTime, matching: find.byType(Stack))
          .first;
      final courseColumn = find
          .ancestor(of: courseTime, matching: find.byType(Column))
          .first;
      _expectSinglePassAccentBar(
        tester,
        rowStackFinder: courseStack,
        contentColumnFinder: courseColumn,
        minExpectedHeight: 40,
      );

      final scheduleRow = find.byType(ScheduleHomeRow);
      final scheduleStack = find.descendant(
        of: scheduleRow,
        matching: find.byType(Stack),
      );
      final scheduleColumn = find.descendant(
        of: scheduleStack,
        matching: find.byType(Column),
      );
      _expectSinglePassAccentBar(
        tester,
        rowStackFinder: scheduleStack,
        contentColumnFinder: scheduleColumn,
        minExpectedHeight: 40,
      );

      final examRow = find.byKey(const Key('exams_card_row_short_exam'));
      final examStack = find.descendant(
        of: examRow,
        matching: find.byType(Stack),
      );
      final examColumn = find.descendant(
        of: examStack,
        matching: find.byType(Column),
      );
      _expectSinglePassAccentBar(
        tester,
        rowStackFinder: examStack,
        contentColumnFinder: examColumn,
        minExpectedHeight: 40,
      );
    });
  });
}
