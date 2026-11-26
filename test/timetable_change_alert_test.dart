import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/router.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_change_alert.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_change_format.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_change_log_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_copy.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_settings_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_sync_diff.dart';

TimetableChangeRecord _rec({
  required String id,
  required TimetableChangeType type,
  String name = '测试课',
  String fp = 'fp1',
  String courseWeeks = '',
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
  courseWeeks: courseWeeks,
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

  testWidgets('摘要弹层：空列表不弹、最多 5 行知道了标记及查看记录跳转', (tester) async {
    Future<void> trigger(List<TimetableChangeRecord> records) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appLightTheme(),
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    showTimetableChangeAlert(ctx, records: records),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
    }

    await trigger(const []);
    expect(find.byKey(const Key('tt_change_alert_title')), findsNothing);

    final many = [
      for (var i = 0; i < 7; i++)
        _rec(
          id: 'r$i',
          type: TimetableChangeType.added,
          name: '课$i',
          fp: 'fp$i',
          after: _snap(day: 1, start: 1, end: 2),
        ),
    ];
    TimetableChangeLogStore.debugMemory = List.of(many);
    await trigger(many);
    expect(find.byKey(const Key('tt_change_alert_row_4')), findsOneWidget);
    expect(find.byKey(const Key('tt_change_alert_row_5')), findsNothing);
    expect(find.text(TimetableCopy.changeAlertMoreLabel(7)), findsOneWidget);
    await tester.tap(find.byKey(const Key('tt_change_alert_got_it')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tt_change_alert_title')), findsNothing);
    expect(
      (await TimetableChangeLogStore.readAll()).every((r) => r.notified),
      isTrue,
    );

    final single = [
      _rec(
        id: '1',
        type: TimetableChangeType.removed,
        name: '形势与政策',
        fp: 'only',
        before: _snap(day: 1, start: 1, end: 2),
      ),
    ];
    TimetableChangeLogStore.debugMemory = List.of(single);
    await trigger(single);
    await tester.tap(find.byKey(const Key('tt_change_alert_view_log')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tt_change_log_page')), findsOneWidget);
    expect(find.text('形势与政策'), findsOneWidget);
    expect((await TimetableChangeLogStore.readAll()).single.notified, isTrue);
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

    testWidgets('后台/手动同步弹出 diff 摘要、多轮合并不叠加，查看记录与解绑清除历史', (tester) async {
      final base = jwxtCourse('1001', '高等数学');
      final added = jwxtCourse('1002', '数据结构', day: 2);
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

      // 1. 多轮后台新增后一次性合并提醒；未读关闭后不重复弹出
      c.debugSetSnapshot(snap([base], syncedAt: DateTime.now()));
      TimetableController.fetchExams = (_) async => [exam];
      await tester.runAsync(() async {
        await syncTo([base, added]);
        await syncTo([base, added]);
      });
      expect(c.pendingChangeAlerts, hasLength(2));
      await openPage(tester);
      expect(find.byKey(const Key('tt_change_alert_title')), findsOneWidget);
      expect(find.textContaining('数据结构'), findsWidgets);
      expect(find.textContaining('高等数学（考试）'), findsOneWidget);
      await tester.tap(find.byKey(const Key('tt_change_alert_got_it')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tt_change_alert_title')), findsNothing);
      expect(await TimetableChangeLogStore.readUnnotified(), isEmpty);

      // 2. 查看记录期间不叠加提醒，返回后补弹新增记录；页内手动同步含未排课也提醒
      final extra = jwxtCourse('1003', '第二轮新增', day: 3);
      await tester.runAsync(() => syncTo([base, added, other]));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tt_change_alert_title')), findsOneWidget);
      expect(find.textContaining('大学物理实验'), findsOneWidget);
      await tester.tap(find.byKey(const Key('tt_change_alert_view_log')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tt_change_log_page')), findsOneWidget);

      await tester.runAsync(() => syncTo([base, added, other, extra]));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('tt_change_alert_title'), skipOffstage: false),
        findsNothing,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tt_change_alert_title')), findsOneWidget);
      expect(c.pendingChangeAlerts.map((r) => r.courseName), ['第二轮新增']);

      // 3. 摘要期间解绑清除旧记录，点关闭旧弹窗不能吞掉重新绑定后的新记录
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

    testWidgets('详情/考试定位优先级不永久阻塞摘要，且摘要关闭后 Android 预测性返回可取消和完成', (tester) async {
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

      // 1. 先打开课程详情再关掉时恢复提醒；定位不存在课程与定位考试后也不阻塞摘要
      c.debugSetSnapshot(snap([base], syncedAt: DateTime.now()));
      await tester.runAsync(() => syncTo([base, added]));
      c.requestOpenCourse(courseId: base.id, day: 1, startNode: 1, endNode: 2);
      await openPage(tester);
      expect(find.byKey(const Key('course_detail_title')), findsOneWidget);
      expect(find.byKey(const Key('tt_change_alert_title')), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tt_change_alert_title')), findsOneWidget);

      await tester.runAsync(() async {
        TimetableChangeLogStore.debugMemory = [];
        c.debugReset();
        c.debugSetSnapshot(snap([base], syncedAt: DateTime.now()));
        await c.replaceJwxtExams([exam]);
        TimetableController.fetchExams = (_) async => null;
        await syncTo([base, added]);
      });
      await openPage(tester, focusEvent: exam);
      expect(find.byKey(const Key('tt_change_alert_title')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      // 2. 真实课表入口弹出摘要并关闭后，支持 Android 预测性返回取消与完成
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

      await tester.runAsync(() async {
        TimetableChangeLogStore.debugMemory = [];
        c.debugReset();
        c.debugSetSnapshot(snap([base], syncedAt: DateTime.now()));
        await syncTo([base, added]);
      });
      final router = buildRouter();
      await tester.pumpWidget(
        MaterialApp.router(
          theme: appDarkTheme().copyWith(platform: TargetPlatform.android),
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
      expect((ModalRoute.of(context)! as PageRoute).popGestureEnabled, isTrue);
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
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('变动记录页：空态、设置入口跳转、分组倒序与影响范围小屏大字展示', (tester) async {
      // 1. 空态 + 从设置管理入口跳转
      await tester.binding.setSurfaceSize(const Size(400, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: appLightTheme(),
          home: TimetableSettingsPage(controller: c),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tt_settings_management_entry')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('tt_settings_change_log')),
        200,
      );
      await tester.pumpAndSettle();
      final row = find.byKey(const Key('tt_settings_change_log'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tt_change_log_page')), findsOneWidget);
      expect(find.byKey(const Key('tt_change_log_empty')), findsOneWidget);
      expect(find.text(TimetableCopy.changeLogEmpty), findsOneWidget);

      // 2. 分组倒序展示与影响范围在深色窄屏大字体下完整展示
      Map<String, dynamic> raw(String weeks, {String room = '明德楼B210'}) => {
        'SKXQ': 3,
        'KSJC': 5,
        'JSJC': 6,
        'SKZC': weeks,
        'JASMC': room,
      };
      TimetableChangeLogStore.debugMemory = [
        _rec(
          id: 'old1',
          type: TimetableChangeType.added,
          fp: 'old',
          name: '旧课',
          time: DateTime(2026, 10, 20, 9, 1),
          after: raw('1', room: ''),
        ),
        _rec(
          id: 'all',
          type: TimetableChangeType.teacherChanged,
          fp: 'new',
          name: '全部周次变动',
          courseWeeks: '1111',
          before: {...raw('1111'), 'SKJS': '原教师'},
          after: {...raw('1111'), 'SKJS': '新教师'},
        ),
        _rec(
          id: 'one',
          type: TimetableChangeType.locationChanged,
          fp: 'new',
          name: '某次课变动',
          courseWeeks: '111111',
          before: raw('00001', room: '原教室'),
          after: raw('00001', room: '新教室'),
        ),
      ];
      await tester.binding.setSurfaceSize(const Size(375, 812));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        MaterialApp(
          theme: appDarkTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.8),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: const TimetableChangeLogPage(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tt_change_log_group_0')), findsOneWidget);
      expect(find.text('全部周次变动'), findsOneWidget);
      expect(find.text('某次课变动'), findsOneWidget);
      expect(find.text('第 5 周 · 周三 5–6节'), findsOneWidget);
      expect(find.text('全部周次（第 1–4 周） · 周三 5–6节'), findsOneWidget);
      expect(find.textContaining('原教室'), findsOneWidget);
      expect(find.textContaining('新教室'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
