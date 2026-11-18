import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/router.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_change_alert.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_change_format.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_copy.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_sync_diff.dart';

TimetableChangeRecord _rec({
  required String id,
  required TimetableChangeType type,
  String name = '测试课',
  String fp = 'fp1',
  Map<String, dynamic>? before,
  Map<String, dynamic>? after,
  bool notified = false,
  DateTime? time,
}) => TimetableChangeRecord(
  id: id,
  time: time ?? DateTime(2026, 10, 27, 14, 32),
  type: type,
  slotKey: 'k|$id',
  fingerprint: fp,
  courseName: name,
  before: before,
  after: after,
  notified: notified,
);

Map<String, dynamic> _snap({
  int day = 1,
  int start = 1,
  int end = 2,
  String loc = '明德楼B210',
  String teacher = '张三',
  String weeks = '1111',
  int istk = 0,
}) => {
  'KCH': '1',
  'KXH': '1',
  'KCM': 'x',
  'SKXQ': day,
  'KSJC': start,
  'JSJC': end,
  'SKZC': weeks,
  'JASMC': loc,
  'SKJS': teacher,
  'ISTK': istk,
};

void main() {
  setUp(() {
    TimetableChangeLogStore.debugMemory = [];
  });
  tearDown(() {
    TimetableChangeLogStore.debugMemory = null;
  });

  group('TimetableChangeFormat', () {
    test('时间/地点/教师/调课标记摘要', () {
      expect(TimetableChangeFormat.weekdayZh(3), '周三');
      expect(
        TimetableChangeFormat.timeOf(_snap(day: 3, start: 5, end: 6)),
        '周三 5–6节',
      );
      final added = _rec(
        id: 'a',
        type: TimetableChangeType.added,
        name: '大学英语',
        after: _snap(day: 3, start: 5, end: 6, loc: '明德楼B210'),
      );
      expect(
        TimetableChangeFormat.alertBody(added),
        '大学英语 · 周三 5–6节 · 明德楼B210',
      );
      final time = _rec(
        id: 't',
        type: TimetableChangeType.timeChanged,
        name: '数据结构',
        before: _snap(day: 1, start: 3, end: 4),
        after: _snap(day: 2, start: 5, end: 6),
      );
      expect(TimetableChangeFormat.alertBody(time), '数据结构 周一 3–4节 → 周二 5–6节');
      expect(
        TimetableChangeFormat.groupTitle(
          DateTime(2026, 10, 27, 14, 32),
          now: DateTime(2026, 10, 27, 18),
        ),
        '今天 14:32',
      );
      expect(
        TimetableChangeFormat.groupTitle(
          DateTime(2026, 10, 20, 9, 1),
          now: DateTime(2026, 10, 27, 18),
        ),
        '10月20日 09:01',
      );
    });
  });

  testWidgets('空列表不弹', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appLightTheme(),
        home: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => showTimetableChangeAlert(ctx, records: const []),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tt_change_alert_title')), findsNothing);
  });

  testWidgets('展示最多 5 行，超出显示等共 N 项；知道了标记 notified', (tester) async {
    final records = [
      for (var i = 0; i < 7; i++)
        _rec(
          id: 'r$i',
          type: TimetableChangeType.added,
          name: '课$i',
          fp: 'fp$i',
          after: _snap(day: 1, start: 1, end: 2),
        ),
    ];
    TimetableChangeLogStore.debugMemory = List.of(records);

    await tester.pumpWidget(
      MaterialApp(
        theme: appLightTheme(),
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () => showTimetableChangeAlert(ctx, records: records),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tt_change_alert_title')), findsOneWidget);
    expect(find.byKey(const Key('tt_change_alert_row_0')), findsOneWidget);
    expect(find.byKey(const Key('tt_change_alert_row_4')), findsOneWidget);
    expect(find.byKey(const Key('tt_change_alert_row_5')), findsNothing);
    expect(find.text(TimetableCopy.changeAlertMoreLabel(7)), findsOneWidget);
    expect(find.text(TimetableChangeType.added.labelZh), findsWidgets);

    await tester.tap(find.byKey(const Key('tt_change_alert_got_it')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tt_change_alert_title')), findsNothing);
    final all = await TimetableChangeLogStore.readAll();
    expect(all.every((r) => r.notified), isTrue);
  });

  testWidgets('查看记录标记 notified 并打开记录页', (tester) async {
    final records = [
      _rec(
        id: '1',
        type: TimetableChangeType.removed,
        name: '形势与政策',
        fp: 'only',
        before: _snap(day: 1, start: 1, end: 2),
      ),
    ];
    TimetableChangeLogStore.debugMemory = List.of(records);

    await tester.pumpWidget(
      MaterialApp(
        theme: appLightTheme(),
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () => showTimetableChangeAlert(ctx, records: records),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tt_change_alert_view_log')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tt_change_log_page')), findsOneWidget);
    expect(find.text('形势与政策'), findsOneWidget);
    final all = await TimetableChangeLogStore.readAll();
    expect(all.single.notified, isTrue);
  });

  group('同步新增课程与考试弹窗集成', () {
    late Directory tmp;
    final c = TimetableController.instance;
    final origBinding = TimetableController.bindingCheck;
    final origFetchSnapshot = TimetableController.fetchSnapshot;
    final origFetchExams = TimetableController.fetchExams;
    final origClock = TimetableController.clock;
    final termStart = DateTime(2026, 8, 31);

    Course jwxtCourse(
      String code,
      String name, {
      int day = 1,
      String location = '明德楼B210',
    }) => Course(
      id: '$code|01',
      name: name,
      code: code,
      classId: '01',
      source: CourseSource.jwxt,
      slots: [
        CourseSlot(
          day: day,
          startNode: 1,
          endNode: 2,
          weeks: '1' * 16,
          teacher: '张老师',
          location: location,
        ),
      ],
    );

    TimetableSnapshot snap(List<Course> courses, {DateTime? syncedAt}) =>
        TimetableSnapshot(
          courses: courses,
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termCode: '2026-2027-1',
            termStartDate: termStart,
            termStartFromJwxt: true,
          ),
          syncedAt: syncedAt ?? DateTime(2026, 9, 7, 8),
        );

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tt_alert_sync_');
      TimetableStore.debugDirectory = tmp;
      TimetableChangeLogStore.debugMemory = [];
      TimetableController.clock = () => DateTime(2026, 9, 7);
      TimetableController.bindingCheck = () async => true;
      TimetableController.fetchExams = (_) async => <ScheduleEvent>[];
      c.debugReset();
    });

    tearDown(() {
      TimetableStore.debugDirectory = null;
      TimetableChangeLogStore.debugMemory = null;
      TimetableController.bindingCheck = origBinding;
      TimetableController.fetchSnapshot = origFetchSnapshot;
      TimetableController.fetchExams = origFetchExams;
      TimetableController.clock = origClock;
      c.debugReset();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    testWidgets('后台同步多出课程与考试后，打开课表页即弹出 diff 摘要且关闭后不再重复弹', (tester) async {
      final base = jwxtCourse('1001', '高等数学');
      final added = jwxtCourse('1002', '数据结构', day: 2);
      final exam = ScheduleEvent(
        id: 'jwxt-exam:1001|2027-01-12|09:00',
        kind: ScheduleKind.exam,
        source: ScheduleSource.jwxt,
        title: '高等数学',
        date: DateTime(2027, 1, 12),
        start: const TimeOfDayMinutes(9, 0),
        end: const TimeOfDayMinutes(11, 0),
        location: '文德楼N101',
        courseCode: '1001',
      );

      c.debugSetSnapshot(snap([base], syncedAt: DateTime.now()));
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          snap([base, added], syncedAt: DateTime.now());
      TimetableController.fetchExams = (term) async => [exam];

      // 后台同步（课表页未打开）多出一门课与一场考试。
      await tester.runAsync(() => c.syncFromJwxt());
      expect(c.pendingChangeAlerts, hasLength(2));

      await tester.pumpWidget(
        MaterialApp(theme: appLightTheme(), home: const TimetablePage()),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tt_change_alert_title')), findsOneWidget);
      expect(find.textContaining('数据结构'), findsWidgets);
      expect(find.textContaining('高等数学（考试）'), findsOneWidget);

      await tester.tap(find.byKey(const Key('tt_change_alert_got_it')));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byKey(const Key('tt_change_alert_title')), findsNothing);
      expect(await TimetableChangeLogStore.readUnnotified(), isEmpty);

      // 再次进入课表页不再重复弹出。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        MaterialApp(theme: appLightTheme(), home: const TimetablePage()),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tt_change_alert_title')), findsNothing);
    });

    testWidgets('课表页内手动同步多出未排课课程与考试时弹出 diff 摘要', (tester) async {
      final base = jwxtCourse('1001', '高等数学');
      final other = Course(
        id: 'other:9001|01|jxb1',
        name: '大学物理实验',
        code: '9001',
        classId: '01',
        source: CourseSource.jwxt,
        slots: const [
          CourseSlot(
            day: 0,
            startNode: 0,
            endNode: 0,
            weeks: '',
            weeksLabel: '3-15周',
            teacher: '赵老师',
          ),
        ],
      );
      final exam = ScheduleEvent(
        id: 'jwxt-exam:1001|2027-01-12|09:00',
        kind: ScheduleKind.exam,
        source: ScheduleSource.jwxt,
        title: '高等数学',
        date: DateTime(2027, 1, 12),
        start: const TimeOfDayMinutes(9, 0),
        end: const TimeOfDayMinutes(11, 0),
        location: '文德楼N101',
        courseCode: '1001',
      );

      c.debugSetSnapshot(snap([base], syncedAt: DateTime.now()));
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          snap([base, other], syncedAt: DateTime.now());
      TimetableController.fetchExams = (term) async => [exam];

      await tester.pumpWidget(
        MaterialApp(theme: appLightTheme(), home: const TimetablePage()),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tt_change_alert_title')), findsNothing);

      await tester.runAsync(() => c.manualSync());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('tt_change_alert_title')), findsOneWidget);
      expect(find.textContaining('大学物理实验'), findsOneWidget);
      expect(find.textContaining('高等数学（考试）'), findsOneWidget);
    });

    Future<void> syncTo(List<Course> courses) async {
      TimetableController.fetchSnapshot = (_, {baseSettings}) async =>
          snap(courses, syncedAt: DateTime.now());
      await c.syncFromJwxt();
    }

    Future<void> openPage(
      WidgetTester tester, {
      bool dark = false,
      ScheduleEvent? focusEvent,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? appDarkTheme() : appLightTheme(),
          home: TimetablePage(focusEvent: focusEvent),
        ),
      );
      await tester.pumpAndSettle();
    }

    for (final dark in [false, true]) {
      testWidgets('多轮后台新增及无变动同步后合并提醒，关闭后不重复（深色=$dark）', (tester) async {
        final base = jwxtCourse('1001', '基础课程');
        final first = jwxtCourse('1002', '第一轮新增', day: 2);
        final second = jwxtCourse('1003', '第二轮新增', day: 3);
        c.debugSetSnapshot(snap([base], syncedAt: DateTime.now()));
        await tester.runAsync(() async {
          await syncTo([base, first]);
          await syncTo([base, first, second]);
          await syncTo([base, first, second]);
        });
        expect(c.pendingChangeAlerts, hasLength(2));
        expect(c.lastSyncDiff!.toNotify, isEmpty);
        await openPage(tester, dark: dark);
        expect(find.byKey(const Key('tt_change_alert_row_1')), findsOneWidget);
        await tester.tap(find.byKey(const Key('tt_change_alert_got_it')));
        await tester.pumpAndSettle();
        expect(c.pendingChangeAlerts, isEmpty);
        expect(await TimetableChangeLogStore.readUnnotified(), isEmpty);
      });

      testWidgets('摘要期间新同步不叠加，关闭后只补弹新增记录（深色=$dark）', (tester) async {
        final base = jwxtCourse('1001', '基础课程');
        final first = jwxtCourse('1002', '第一轮新增', day: 2);
        final second = jwxtCourse('1003', '第二轮新增', day: 3);
        c.debugSetSnapshot(snap([base], syncedAt: DateTime.now()));
        await tester.runAsync(() => syncTo([base, first]));
        await openPage(tester, dark: dark);
        await tester.runAsync(() => syncTo([base, first, second]));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('tt_change_alert_title'), skipOffstage: false),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('tt_change_alert_got_it')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('tt_change_alert_title')), findsOneWidget);
        expect(find.textContaining('第二轮新增'), findsWidgets);
        expect(c.pendingChangeAlerts.map((r) => r.courseName), ['第二轮新增']);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(c.pendingChangeAlerts, isEmpty);
      });
    }

    testWidgets('查看记录期间不叠加提醒，返回后补弹新同步', (tester) async {
      final base = jwxtCourse('1001', '基础课程');
      final first = jwxtCourse('1002', '第一轮新增', day: 2);
      final second = jwxtCourse('1003', '第二轮新增', day: 3);
      c.debugSetSnapshot(snap([base], syncedAt: DateTime.now()));
      await tester.runAsync(() => syncTo([base, first]));
      await openPage(tester);
      await tester.tap(find.byKey(const Key('tt_change_alert_view_log')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tt_change_log_page')), findsOneWidget);
      await tester.runAsync(() => syncTo([base, first, second]));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('tt_change_alert_title'), skipOffstage: false),
        findsNothing,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tt_change_alert_title')), findsOneWidget);
      expect(c.pendingChangeAlerts.map((r) => r.courseName), ['第二轮新增']);
    });

    testWidgets('首页详情关闭与课程定位失败后都恢复提醒', (tester) async {
      final base = jwxtCourse('1001', '基础课程');
      final added = jwxtCourse('1002', '新增课程', day: 2);
      for (final courseId in [base.id, 'missing']) {
        c.debugSetSnapshot(snap([base], syncedAt: DateTime.now()));
        await tester.runAsync(() => syncTo([base, added]));
        c.requestOpenCourse(
          courseId: courseId,
          day: 1,
          startNode: 1,
          endNode: 2,
        );
        await openPage(tester);
        if (courseId == base.id) {
          expect(find.byKey(const Key('course_detail_title')), findsOneWidget);
          expect(find.byKey(const Key('tt_change_alert_title')), findsNothing);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
        }
        expect(find.byKey(const Key('tt_change_alert_title')), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    });

    testWidgets('考试定位成功或失败都不会永久阻止待通知摘要', (tester) async {
      final base = jwxtCourse('1001', '基础课程');
      final added = jwxtCourse('1002', '新增课程', day: 2);
      final exam = ScheduleEvent(
        id: 'exam-focus',
        kind: ScheduleKind.exam,
        source: ScheduleSource.jwxt,
        title: '测试考试',
        date: DateTime(2026, 9, 8),
        start: const TimeOfDayMinutes(9, 0),
        end: const TimeOfDayMinutes(11, 0),
        courseCode: '1001',
      );
      for (final present in [false, true]) {
        await tester.runAsync(() async {
          c.debugReset();
          c.debugSetSnapshot(snap([base], syncedAt: DateTime.now()));
          if (present) await c.replaceJwxtExams([exam]);
          TimetableController.fetchExams = (_) async => null;
          await syncTo([base, added]);
        });
        await openPage(tester, focusEvent: exam);
        expect(find.byKey(const Key('tt_change_alert_title')), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    });

    test('首次全量同步清除残留历史；空列表成功基线重启后新增仍提醒', () async {
      TimetableChangeLogStore.debugMemory = null;
      await TimetableChangeLogStore.upsertCandidates([
        _rec(id: 'stale', fp: 'stale', type: TimetableChangeType.added),
      ]);
      await c.ensureStarted();
      expect(c.pendingChangeAlerts, isEmpty);
      await syncTo([]);
      expect(await TimetableChangeLogStore.readAll(), isEmpty);
      c.debugReset();
      await c.ensureStarted();
      final base = jwxtCourse('1001', '基础课程');
      await syncTo([base]);
      expect(c.pendingChangeAlerts.single.type, TimetableChangeType.added);
      c.debugReset();
      await c.ensureStarted();
      expect(c.pendingChangeAlerts.single.courseName, '基础课程');
    });

    test('首次同时同步普通课、未排课、考试不提示，后续新考试正常提示', () async {
      c.debugSetSnapshot(const TimetableSnapshot());
      final base = jwxtCourse('1001', '基础课程');
      final other = Course(
        id: 'other:9001',
        code: '9001',
        name: '实践课程',
        source: CourseSource.jwxt,
        slots: const [],
      );
      ScheduleEvent exam(String code) => ScheduleEvent(
        id: 'exam-$code',
        kind: ScheduleKind.exam,
        source: ScheduleSource.jwxt,
        title: '测试考试',
        date: DateTime(2027, 1, 12),
        start: const TimeOfDayMinutes(9, 0),
        end: const TimeOfDayMinutes(11, 0),
        courseCode: code,
      );
      TimetableController.fetchExams = (_) async => [exam('1001')];
      await syncTo([base, other]);
      expect(c.pendingChangeAlerts, isEmpty);
      expect(await TimetableChangeLogStore.readAll(), isEmpty);
      TimetableController.fetchExams = (_) async => [
        exam('1001'),
        exam('9001'),
      ];
      await syncTo([base, other]);
      expect(c.pendingChangeAlerts.single.type, TimetableChangeType.added);
      expect(c.pendingChangeAlerts.single.after!['KIND'], 'exam');
    });

    testWidgets('解绑清除未读历史，旧摘要不能确认重新绑定后的新记录', (tester) async {
      final base = jwxtCourse('1001', '基础课程');
      final added = jwxtCourse('1002', '新增课程', day: 2);
      c.debugSetSnapshot(snap([base], syncedAt: DateTime.now()));
      await tester.runAsync(() => syncTo([base, added]));
      await openPage(tester);
      await tester.runAsync(() async {
        await c.handleLogout();
        expect(await TimetableChangeLogStore.readAll(), isEmpty);
        await syncTo([base]);
        expect(c.pendingChangeAlerts, isEmpty);
        await syncTo([base, added]);
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tt_change_alert_got_it')));
      await tester.pumpAndSettle();
      expect(c.pendingChangeAlerts, hasLength(1));
      expect(find.byKey(const Key('tt_change_alert_title')), findsOneWidget);
      expect(await TimetableChangeLogStore.readUnnotified(), hasLength(1));
    });

    test('同步失败保留待通知记录；考试失败仍提醒普通课程新增', () async {
      final base = jwxtCourse('1001', '基础课程');
      final added = jwxtCourse('1002', '新增课程', day: 2);
      c.debugSetSnapshot(snap([base], syncedAt: DateTime.now()));
      await syncTo([base, added]);
      TimetableController.fetchSnapshot = (_, {baseSettings}) async =>
          throw StateError('测试同步失败');
      await c.syncFromJwxt();
      expect(c.pendingChangeAlerts.single.courseName, '新增课程');
      TimetableController.fetchExams = (_) async => throw StateError('测试考试失败');
      final more = jwxtCourse('1003', '另一新增', day: 3);
      await syncTo([base, added, more]);
      expect(c.syncStatus, TimetableSyncStatus.success);
      expect(c.pendingChangeAlerts, hasLength(2));
    });

    test('切换学期首次同步不比较旧学期或恢复旧未读', () async {
      final base = jwxtCourse('1001', '基础课程');
      final added = jwxtCourse('1002', '新增课程', day: 2);
      c.debugSetSnapshot(snap([base], syncedAt: DateTime.now()));
      await syncTo([base, added]);
      TimetableController.fetchSnapshot = (_, {baseSettings}) async =>
          snap([base]).copyWith(
            settings: snap([base]).settings.copyWith(termCode: '2026-2027-2'),
          );
      await c.syncFromJwxt();
      expect(c.pendingChangeAlerts, isEmpty);
      expect(await TimetableChangeLogStore.readAll(), isEmpty);
    });

    testWidgets('真实课表入口在摘要关闭后支持返回手势取消与完成', (tester) async {
      final base = jwxtCourse('1001', '基础课程');
      final added = jwxtCourse('1002', '新增课程', day: 2);
      Future<void> gesture(String method, {double progress = 0}) async {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'flutter/backgesture',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, {
              'touchOffset': [5.0, 300.0],
              'progress': progress,
              'swipeEdge': 0,
            }),
          ),
          (_) {},
        );
        await tester.pumpAndSettle();
      }

      for (final dark in [false, true]) {
        await tester.runAsync(() async {
          TimetableChangeLogStore.debugMemory = [];
          c.debugReset();
          c.debugSetSnapshot(snap([base], syncedAt: DateTime.now()));
          await syncTo([base, added]);
        });
        final router = buildRouter();
        await tester.pumpWidget(
          MaterialApp.router(
            theme: (dark ? appDarkTheme() : appLightTheme()).copyWith(
              platform: TargetPlatform.android,
            ),
            routerConfig: router,
          ),
        );
        await tester.pumpAndSettle();
        router.push<void>('/apps/timetable');
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('tt_change_alert_title')), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(c.pendingChangeAlerts, isEmpty);
        final context = tester.element(find.byType(TimetablePage));
        expect(
          (ModalRoute.of(context)! as PageRoute).popGestureEnabled,
          isTrue,
        );
        await gesture('startBackGesture');
        await gesture('updateBackGestureProgress', progress: 0.4);
        expect(Navigator.of(context).userGestureInProgress, isTrue);
        await gesture('cancelBackGesture');
        expect(find.byType(TimetablePage), findsOneWidget);
        await gesture('startBackGesture');
        await gesture('updateBackGestureProgress', progress: 0.4);
        await gesture('commitBackGesture');
        expect(find.byType(TimetablePage), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        router.dispose();
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });
}
