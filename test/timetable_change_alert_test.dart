import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/app.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_notify_bridge.dart';
import 'package:nuist_sta_app/router.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_change_alert.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_change_format.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_change_log_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_copy.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_exams_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_import_models.dart';
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

    test('单周与离散周次跟上具体日期，连续周段、单双周循环与无开学日不显示日期', () {
      // 2026-08-31 为第 1 周周一：
      // 第 1 周周一=8月31日；第 5 周周三=9月30日；第 3 周周二=9月15日，第 7 周周二=10月13日；第 4 周周一=9月21日
      final termStart = DateTime(2026, 8, 31);

      expect(TimetableChangeFormat.isNonRepeatingDiscreteWeeks({5}), isTrue);
      expect(TimetableChangeFormat.isNonRepeatingDiscreteWeeks({2, 4}), isTrue);
      expect(
        TimetableChangeFormat.isNonRepeatingDiscreteWeeks({2, 5, 9}),
        isTrue,
      );
      expect(
        TimetableChangeFormat.isNonRepeatingDiscreteWeeks({1, 4, 8, 12}),
        isTrue,
      );
      // 不适当场景：连续周、含连续段的混合周、≥3 周单双周循环、超过 4 次
      expect(
        TimetableChangeFormat.isNonRepeatingDiscreteWeeks({1, 2}),
        isFalse,
      );
      expect(
        TimetableChangeFormat.isNonRepeatingDiscreteWeeks({1, 2, 5}),
        isFalse,
      );
      expect(
        TimetableChangeFormat.isNonRepeatingDiscreteWeeks({1, 3, 5}),
        isFalse,
      );
      expect(
        TimetableChangeFormat.isNonRepeatingDiscreteWeeks({2, 4, 6, 8}),
        isFalse,
      );
      expect(
        TimetableChangeFormat.isNonRepeatingDiscreteWeeks({1, 3, 6, 9, 12}),
        isFalse,
      );

      // 1. 原有课程新排单周 1 节课（added，第 5 周周三）
      final singleAdded = TimetableChangeRecord(
        id: 'sa',
        time: DateTime(2026, 9, 10),
        type: TimetableChangeType.added,
        slotKey: 'k|sa',
        fingerprint: 'fp_sa',
        courseName: '计算机网络',
        courseWeeks: '1111111111111111',
        termStartDate: '2026-08-31',
        after: _snap(day: 3, start: 5, end: 6, loc: '明德楼N203', weeks: '00001'),
      );
      expect(
        TimetableChangeFormat.alertBody(singleAdded),
        '计算机网络 · 周三 5–6节 · 明德楼N203 · 第 5 周（9月30日）',
      );
      expect(
        TimetableChangeFormat.scopeOf(singleAdded),
        '影响范围：第 5 周 · 周三 5–6节（9月30日）',
      );

      // 2. 多节分离周次变动（第 3、7 周周二换教室）
      final discreteLoc = TimetableChangeRecord(
        id: 'dl',
        time: DateTime(2026, 9, 10),
        type: TimetableChangeType.locationChanged,
        slotKey: 'k|dl',
        fingerprint: 'fp_dl',
        courseName: '嵌入式实验',
        courseWeeks: '0010001',
        termStartDate: '2026-08-31',
        before: _snap(
          day: 2,
          start: 3,
          end: 4,
          loc: '滨江BS301',
          weeks: '0010001',
        ),
        after: _snap(
          day: 2,
          start: 3,
          end: 4,
          loc: '滨江BS405',
          weeks: '0010001',
        ),
      );
      expect(
        TimetableChangeFormat.alertBody(discreteLoc),
        '嵌入式实验 滨江BS301 → 滨江BS405 · 第 3、7 周（9月15日、10月13日）',
      );
      expect(
        TimetableChangeFormat.scopeOf(discreteLoc),
        '影响范围：全部周次（第 3、7 周） · 周二 3–4节（9月15日、10月13日）',
      );

      // 3. 单节调课：第 5 周周一 1–2节 → 第 6 周周四 3–4节（前后均带具体日期）
      final singleMoved = TimetableChangeRecord(
        id: 'sm',
        time: DateTime(2026, 9, 10),
        type: TimetableChangeType.timeChanged,
        slotKey: 'k|sm',
        fingerprint: 'fp_sm',
        courseName: '操作系统',
        courseWeeks: '11111111',
        termStartDate: '2026-08-31',
        before: _snap(day: 1, start: 1, end: 2, weeks: '00001'),
        after: _snap(day: 4, start: 3, end: 4, weeks: '000001'),
      );
      expect(
        TimetableChangeFormat.alertBody(singleMoved),
        '操作系统 第 5 周 · 周一 1–2节（9月28日） → 第 6 周 · 周四 3–4节（10月8日）',
      );
      expect(
        TimetableChangeFormat.scopeOf(singleMoved),
        '影响范围：第 5–6 周 · 周一 1–2节（9月28日） → 周四 3–4节（10月8日）',
      );

      // 4. 连续周微调单周（第 1–4 周 → 第 1–3 周，仅少第 4 周周一=9月21日）
      final shrinkOneWeek = TimetableChangeRecord(
        id: 'sw',
        time: DateTime(2026, 9, 10),
        type: TimetableChangeType.timeChanged,
        slotKey: 'k|sw',
        fingerprint: 'fp_sw',
        courseName: '信号与系统',
        courseWeeks: '1111',
        termStartDate: '2026-08-31',
        before: _snap(day: 1, start: 5, end: 6, weeks: '1111'),
        after: _snap(day: 1, start: 5, end: 6, weeks: '1110'),
      );
      expect(
        TimetableChangeFormat.scopeOf(shrinkOneWeek),
        '影响范围：第 4 周 · 周一 5–6节（9月21日）',
      );
      expect(
        TimetableChangeFormat.detailOf(shrinkOneWeek),
        '第 1–4 周 · 周一 5–6节 → 第 1–3 周 · 周一 5–6节（9月21日）',
      );

      // 5. 重复循环（1–16 周常规课 / 单双周）即使有 termStartDate 也不附加具体日期
      final repeating = TimetableChangeRecord(
        id: 'rep',
        time: DateTime(2026, 9, 10),
        type: TimetableChangeType.added,
        slotKey: 'k|rep',
        fingerprint: 'fp_rep',
        courseName: '编译原理',
        courseWeeks: '1' * 16,
        termStartDate: '2026-08-31',
        after: _snap(day: 2, start: 1, end: 2, loc: '文德楼N102', weeks: '1' * 16),
      );
      expect(
        TimetableChangeFormat.alertBody(repeating),
        '编译原理 · 周二 1–2节 · 文德楼N102',
      );
      expect(
        TimetableChangeFormat.scopeOf(repeating),
        '影响范围：全部周次（第 1–16 周） · 周二 1–2节',
      );

      // 6. 开学日未知且无 fallback 时不盲算日期
      final unknownTermStart = TimetableChangeRecord(
        id: 'uk',
        time: DateTime(2026, 9, 10),
        type: TimetableChangeType.added,
        slotKey: 'k|uk',
        fingerprint: 'fp_uk',
        courseName: '离散数学',
        xnxqdm: '2032-2033-1',
        after: _snap(day: 5, start: 1, end: 2, loc: '气象楼101', weeks: '001'),
      );
      expect(
        TimetableChangeFormat.scopeOf(unknownTermStart),
        '影响范围：第 3 周 · 周五 1–2节',
      );
      // 传入 fallbackTermStart 后即可补齐日期（第 3 周周五 = 9月18日）
      expect(
        TimetableChangeFormat.scopeOf(
          unknownTermStart,
          fallbackTermStart: termStart,
        ),
        '影响范围：第 3 周 · 周五 1–2节（9月18日）',
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

    test('同步返回新 termCode 时按真实学期拉取考试，且旧空 termCode 升级不丢考试变动', () async {
      final base = jwxtCourse('1001', '基础课程');
      String? requestedExamTerm;
      ScheduleEvent exam(String loc) => ScheduleEvent(
        id: 'exam-1001',
        kind: ScheduleKind.exam,
        source: ScheduleSource.jwxt,
        title: '基础课程',
        date: DateTime(2027, 6, 20),
        start: const TimeOfDayMinutes(9, 0),
        end: const TimeOfDayMinutes(11, 0),
        location: loc,
        courseCode: '1001',
      );

      // 模拟旧缓存 termCode 为空但已有课程与考试基线，本次同步由教务补齐真实学期 2026-2027-2
      c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [base],
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termCode: '',
            termStartDate: termStart,
            termStartFromJwxt: true,
          ),
          syncedAt: DateTime(2026, 9, 7, 8),
        ),
      );
      await c.replaceJwxtExams([exam('明德楼N201')]);

      TimetableController.fetchSnapshot = (_, {baseSettings}) async =>
          TimetableSnapshot(
            courses: [base],
            periods: TimetableController.defaultPeriods(),
            settings: TimetableSettings(
              termCode: '2026-2027-2',
              termStartDate: termStart,
              termStartFromJwxt: true,
            ),
            syncedAt: DateTime(2026, 9, 7, 9),
          );
      TimetableController.fetchExams = (term) async {
        requestedExamTerm = term;
        return [exam('文德楼C305')];
      };

      await c.syncFromJwxt();
      expect(requestedExamTerm, '2026-2027-2');
      expect(c.pendingChangeAlerts, hasLength(1));
      expect(
        c.pendingChangeAlerts.single.type,
        TimetableChangeType.locationChanged,
      );
      expect(
        TimetableChangeFormat.alertBody(c.pendingChangeAlerts.single),
        '基础课程（考试） 明德楼N201 → 文德楼C305',
      );
    });

    test('考试 A→B→A 改回与撤下再发布不会因历史已读指纹而静默漏弹，且同时改时间地点完整展示', () async {
      final base = jwxtCourse('1001', '高等数学');
      ScheduleEvent exam({
        DateTime? date,
        String loc = '明德楼N201',
        String? code = '1001',
      }) => ScheduleEvent(
        id: 'exam-${(date ?? DateTime(2027, 1, 12)).day}-$loc',
        kind: ScheduleKind.exam,
        source: ScheduleSource.jwxt,
        title: '高等数学',
        date: date ?? DateTime(2027, 1, 12),
        start: const TimeOfDayMinutes(9, 0),
        end: const TimeOfDayMinutes(11, 0),
        location: loc,
        courseCode: code,
      );

      c.debugSetSnapshot(snap([base], syncedAt: DateTime.now()));
      await c.replaceJwxtExams([exam(loc: '明德楼N201')]);

      // 第一次：新增另一场无课程号考试 -> 确认已读
      final extraExam = ScheduleEvent(
        id: 'exam-nocode-1',
        kind: ScheduleKind.exam,
        source: ScheduleSource.jwxt,
        title: '大学英语口语',
        date: DateTime(2027, 1, 15),
        start: const TimeOfDayMinutes(14, 0),
        end: const TimeOfDayMinutes(16, 0),
        location: '文德楼S102',
      );
      TimetableController.fetchExams = (_) async => [
        exam(loc: '明德楼N201'),
        extraExam,
      ];
      await syncTo([base]);
      expect(c.pendingChangeAlerts, hasLength(1));
      await c.acknowledgeChangeAlerts(
        c.pendingChangeAlerts.map((r) => r.fingerprint),
        revision: c.changeAlertRevision,
      );
      expect(c.pendingChangeAlerts, isEmpty);

      // 第二次：该考试被撤下 -> 确认已读
      TimetableController.fetchExams = (_) async => [exam(loc: '明德楼N201')];
      await syncTo([base]);
      expect(c.pendingChangeAlerts.single.type, TimetableChangeType.removed);
      await c.acknowledgeChangeAlerts(
        c.pendingChangeAlerts.map((r) => r.fingerprint),
        revision: c.changeAlertRevision,
      );

      // 第三次：该考试按原时间原地点重新发布 -> 仍必须重新弹窗提醒！
      TimetableController.fetchExams = (_) async => [
        exam(loc: '明德楼N201'),
        extraExam,
      ];
      await syncTo([base]);
      expect(c.pendingChangeAlerts, hasLength(1));
      expect(c.pendingChangeAlerts.single.type, TimetableChangeType.added);
      expect(c.pendingChangeAlerts.single.courseName, '大学英语口语');
      await c.acknowledgeChangeAlerts(
        c.pendingChangeAlerts.map((r) => r.fingerprint),
        revision: c.changeAlertRevision,
      );

      // 第四次：无课程号考试同时改日期+改地点 -> 识别为单条 timeChanged 且展示地点变化
      final movedExtra = extraExam.copyWith(
        id: 'exam-nocode-2',
        date: DateTime(2027, 1, 16),
        location: '气象楼201',
      );
      TimetableController.fetchExams = (_) async => [
        exam(loc: '明德楼N201'),
        movedExtra,
      ];
      await syncTo([base]);
      expect(c.pendingChangeAlerts, hasLength(1));
      expect(
        c.pendingChangeAlerts.single.type,
        TimetableChangeType.timeChanged,
      );
      expect(
        TimetableChangeFormat.alertBody(c.pendingChangeAlerts.single),
        contains('文德楼S102 → 气象楼201'),
      );
    });

    testWidgets('考试安排页直接打开时弹出考试变动，且小组件热启动临时收起弹窗不吞未读状态', (tester) async {
      final base = jwxtCourse('1001', '线性代数');
      final e1 = ScheduleEvent(
        id: 'exam-1001',
        kind: ScheduleKind.exam,
        source: ScheduleSource.jwxt,
        title: '线性代数',
        date: DateTime(2027, 1, 10),
        start: const TimeOfDayMinutes(9, 0),
        end: const TimeOfDayMinutes(11, 0),
        location: '明德楼N101',
        courseCode: '1001',
      );
      final e2 = e1.copyWith(location: '揽江楼N202');

      c.debugSetSnapshot(snap([base], syncedAt: DateTime.now()));
      await tester.runAsync(() async {
        await c.replaceJwxtExams([e1]);
        TimetableController.fetchExams = (_) async => [e2];
        await syncTo([base]);
      });
      expect(c.pendingChangeAlerts, hasLength(1));

      // 1. 直接打开考试安排页就能看到变动弹窗
      await tester.pumpWidget(
        MaterialApp(theme: appLightTheme(), home: const TimetableExamsPage()),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tt_change_alert_title')), findsOneWidget);
      expect(find.textContaining('线性代数（考试）'), findsOneWidget);

      // 2. 模拟桌面小组件路由跳转带 kTimetableChangeAlertDeferAcknowledge 临时收起弹层：不消费未读
      final sheetCtx = tester.element(
        find.byKey(const Key('tt_change_alert_title')),
      );
      Navigator.of(sheetCtx).pop(kTimetableChangeAlertDeferAcknowledge);
      await tester.pumpAndSettle();
      expect(c.pendingChangeAlerts, hasLength(1));
      // 同一可见页面自动重新补弹
      expect(find.byKey(const Key('tt_change_alert_title')), findsOneWidget);

      // 用户主动点击「知道了」才真正消费
      await tester.tap(find.byKey(const Key('tt_change_alert_got_it')));
      await tester.pumpAndSettle();
      expect(c.pendingChangeAlerts, isEmpty);
      expect(find.byKey(const Key('tt_change_alert_title')), findsNothing);
    });

    testWidgets('热启动从小组件打开组件设置页，关闭设置返回课表后自动补弹待通知变动', (tester) async {
      final base = jwxtCourse('1001', '高等数学');
      final added = jwxtCourse('1002', '编译原理', day: 4);
      c.debugSetSnapshot(snap([base], syncedAt: DateTime.now()));

      await tester.pumpWidget(
        MaterialApp(theme: appLightTheme(), home: const TimetablePage()),
      );
      await tester.pumpAndSettle();

      // 热启动复用已挂载 TimetablePage，传入 openWidgetSettings
      await tester.pumpWidget(
        MaterialApp(
          theme: appLightTheme(),
          home: TimetablePage(
            openWidgetSettings: true,
            widgetLaunchRequest: TimetableWidgetLaunchRequest(focusToken: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 在组件设置页打开期间后台同步产生变动：设置页上不叠加弹出
      await tester.runAsync(() => syncTo([base, added]));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('tt_change_alert_title'), skipOffstage: false),
        findsNothing,
      );

      // 返回课表页后自动补弹
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tt_change_alert_title')), findsOneWidget);
      expect(find.textContaining('编译原理'), findsWidgets);
    });

    test('多课表切换主课表不丢失默认课表未读考试变动，且跨学期归档迁移 sync_changes.json', () async {
      TimetableChangeLogStore.debugMemory = null;
      final base = jwxtCourse('1001', '概率论');
      final e1 = ScheduleEvent(
        id: 'exam-1001',
        kind: ScheduleKind.exam,
        source: ScheduleSource.jwxt,
        title: '概率论',
        date: DateTime(2027, 1, 8),
        start: const TimeOfDayMinutes(9, 0),
        end: const TimeOfDayMinutes(11, 0),
        location: '明德楼N101',
        courseCode: '1001',
      );

      // 1. 默认课表首次同步建立基线，随后考试改地点产生未读变动
      TimetableController.fetchExams = (_) async => [e1];
      await syncTo([base]);
      expect(c.pendingChangeAlerts, isEmpty);

      TimetableController.fetchExams = (_) async => [
        e1.copyWith(location: '文德楼N301'),
      ];
      await syncTo([base]);
      expect(c.pendingChangeAlerts, hasLength(1));

      // 2. 导入外部课表并设为主课表，再切回默认课表设为主课表 -> 未读考试变动完整恢复
      final imported = await c.importWakeupSchedule(
        WakeupImportResult(
          defaultName: '同伴课表',
          snapshot: TimetableSnapshot(
            courses: [base.copyWith(id: 'imp-1', source: CourseSource.manual)],
            periods: TimetableController.defaultPeriods(),
            settings: TimetableSettings(
              scheduleName: '同伴课表',
              termStartDate: termStart,
            ),
          ),
          courseCount: 1,
          slotCount: 1,
        ),
        name: '同伴课表',
        setAsPrimary: true,
      );
      expect(c.primaryScheduleId, imported.id);
      expect(c.pendingChangeAlerts, isEmpty);

      await c.setPrimarySchedule('default');
      expect(c.primaryScheduleId, 'default');
      expect(c.pendingChangeAlerts, hasLength(1));
      expect(
        c.pendingChangeAlerts.single.type,
        TimetableChangeType.locationChanged,
      );

      // 3. 跨学期归档时，旧学期的 sync_changes.json 随课表归档到历史目录，新学期基线清空
      TimetableController.fetchSnapshot = (_, {baseSettings}) async =>
          TimetableSnapshot(
            courses: [jwxtCourse('2001', '软件工程')],
            periods: TimetableController.defaultPeriods(),
            settings: TimetableSettings(
              termCode: '2026-2027-2',
              termStartDate: DateTime(2027, 2, 22),
              termStartFromJwxt: true,
            ),
            syncedAt: DateTime(2027, 2, 22, 8),
          );
      TimetableController.fetchExams = (_) async => const [];
      await c.syncFromJwxt();
      expect(c.pendingChangeAlerts, isEmpty);

      await c.switchViewingSchedule('jwxt_2026-2027-1');
      final archivedLog = await c.viewingController
          .readChangeHistoryNewestFirst();
      expect(archivedLog, hasLength(1));
      expect(archivedLog.single.courseName, '概率论');
    });

    test('首次同步课程成功但考试失败时，下次首次拉到考试只建基线不误报新增', () async {
      TimetableChangeLogStore.debugMemory = null;
      final base = jwxtCourse('1001', '概率论');
      final e1 = ScheduleEvent(
        id: 'exam-1001',
        kind: ScheduleKind.exam,
        source: ScheduleSource.jwxt,
        title: '概率论',
        date: DateTime(2027, 1, 8),
        start: const TimeOfDayMinutes(9, 0),
        end: const TimeOfDayMinutes(11, 0),
        location: '明德楼N101',
        courseCode: '1001',
      );
      final e2 = ScheduleEvent(
        id: 'exam-1002',
        kind: ScheduleKind.exam,
        source: ScheduleSource.jwxt,
        title: '大学英语',
        date: DateTime(2027, 1, 9),
        start: const TimeOfDayMinutes(14, 0),
        end: const TimeOfDayMinutes(16, 0),
        location: '文德楼N201',
        courseCode: '1002',
      );

      // 首次同步：课表成功，但考试接口失败
      TimetableController.fetchExams = (_) async =>
          throw StateError('首次考试接口超时');
      await syncTo([base]);
      expect(c.pendingChangeAlerts, isEmpty);

      // 模拟重启后再次同步：这次考试接口恢复，拉到已有考试 e1 -> 只建立基线，不误报
      c.debugReset();
      await c.ensureStarted();
      TimetableController.fetchExams = (_) async => [e1];
      await syncTo([base]);
      expect(c.pendingChangeAlerts, isEmpty);

      // 之后真正新增 e2 -> 正常弹出提醒
      TimetableController.fetchExams = (_) async => [e1, e2];
      await syncTo([base]);
      expect(c.pendingChangeAlerts, hasLength(1));
      expect(c.pendingChangeAlerts.single.courseName, '大学英语');
      expect(c.pendingChangeAlerts.single.type, TimetableChangeType.added);
    });

    testWidgets('挂起调度期间不重弹，释放及根层遮挡解除后自动补弹', (tester) async {
      final base = jwxtCourse('1001', '高等数学');
      final added = jwxtCourse('1002', '离散数学', day: 3);
      c.debugSetSnapshot(snap([base], syncedAt: DateTime.now()));
      await tester.runAsync(() => syncTo([base, added]));

      final release = TimetableChangeAlertCoordinator.deferPresentation();
      await openPage(tester);
      expect(find.byKey(const Key('tt_change_alert_title')), findsNothing);

      release();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tt_change_alert_title')), findsOneWidget);
      await tester.tap(find.byKey(const Key('tt_change_alert_got_it')));
      await tester.pumpAndSettle();
      expect(c.pendingChangeAlerts, isEmpty);
    });

    testWidgets('原有课程新排单周课与新增考试同时同步时，弹窗展示课程具体日期与考试详情', (tester) async {
      final base = jwxtCourse('1001', '计算机组成原理', day: 1);
      // 原有课程 1001|01 新排了第 5 周周三（2026-09-30）的一节实验/补课
      final withExtraSlot = Course(
        id: base.id,
        name: base.name,
        code: base.code,
        classId: base.classId,
        source: CourseSource.jwxt,
        slots: [
          ...base.slots,
          const CourseSlot(
            day: 3,
            startNode: 5,
            endNode: 6,
            weeks: '00001',
            teacher: '张老师',
            location: '明德楼N302',
          ),
        ],
      );
      final newExam = ScheduleEvent(
        id: 'jwxt-exam:1001|2027-01-14|09:00',
        kind: ScheduleKind.exam,
        source: ScheduleSource.jwxt,
        title: '计算机组成原理',
        date: DateTime(2027, 1, 14),
        start: const TimeOfDayMinutes(9, 0),
        end: const TimeOfDayMinutes(11, 0),
        location: '揽江楼W201',
        courseCode: '1001',
      );

      c.debugSetSnapshot(snap([base], syncedAt: DateTime.now()));
      TimetableController.fetchExams = (_) async => [newExam];
      await tester.runAsync(() => syncTo([withExtraSlot]));

      expect(c.pendingChangeAlerts, hasLength(2));
      await openPage(tester);
      expect(find.byKey(const Key('tt_change_alert_title')), findsOneWidget);
      // 原有课程新排单周课：带第 5 周与 9月30日
      expect(
        find.text('计算机组成原理 · 周三 5–6节 · 明德楼N302 · 第 5 周（9月30日）'),
        findsOneWidget,
      );
      // 新增考试：同弹窗展示
      expect(
        find.text('计算机组成原理（考试） · 1月14日 09:00–11:00 · 揽江楼W201'),
        findsOneWidget,
      );

      // 点击「查看记录」，变动记录页将同批次两条合并在同一组，且范围行含（9月30日）
      await tester.tap(find.byKey(const Key('tt_change_alert_view_log')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tt_change_log_page')), findsOneWidget);
      expect(find.byKey(const Key('tt_change_log_group_0')), findsOneWidget);
      expect(find.byKey(const Key('tt_change_log_group_1')), findsNothing);
      expect(find.text('第 5 周 · 周三 5–6节（9月30日）'), findsOneWidget);
      expect(find.text('考试 · 1月14日 09:00–11:00'), findsOneWidget);
    });

    testWidgets('桌面小组件冷启动直达课表（含首次考试基线失败后满 90 分钟重拉）与热启动 replace 均正常弹窗且不吞未读', (
      tester,
    ) async {
      TimetableChangeLogStore.debugMemory = null;
      final messenger = tester.binding.defaultBinaryMessenger;
      const channel = MethodChannel('dev.duohuo.nuist_sta_app/notify_widget');
      final origSyncClock = TimetableController.syncClock;
      var fakeNow = DateTime(2026, 9, 7, 8);
      TimetableController.syncClock = () => fakeNow;
      TimetableNotifyBridge.debugIsAndroid = true;
      String? pendingLaunchRoute = '/apps/timetable';
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'takeLaunchRoute') {
          final r = pendingLaunchRoute;
          pendingLaunchRoute = null;
          return r;
        }
        return null;
      });
      addTearDown(() {
        TimetableController.syncClock = origSyncClock;
        TimetableNotifyBridge.debugIsAndroid = null;
        messenger.setMockMethodCallHandler(channel, null);
        tester.platformDispatcher.clearDefaultRouteNameTestValue();
      });

      final base = jwxtCourse('1001', '软件工程');
      final exam1 = ScheduleEvent(
        id: 'jwxt-exam:1001|2027-01-15|14:00',
        kind: ScheduleKind.exam,
        source: ScheduleSource.jwxt,
        title: '软件工程',
        date: DateTime(2027, 1, 15),
        start: const TimeOfDayMinutes(14, 0),
        end: const TimeOfDayMinutes(16, 0),
        location: '文德楼C201',
        courseCode: '1001',
      );
      final exam2 = ScheduleEvent(
        id: 'jwxt-exam:1002|2027-01-18|09:00',
        kind: ScheduleKind.exam,
        source: ScheduleSource.jwxt,
        title: '计算机网络',
        date: DateTime(2027, 1, 18),
        start: const TimeOfDayMinutes(9, 0),
        end: const TimeOfDayMinutes(11, 0),
        location: '明德楼A105',
        courseCode: '1002',
      );

      // 1. 同一天首次同步课表成功，但考试接口超时（建立课程基线，考试基线挂起待补）
      await tester.runAsync(() async {
        TimetableController.fetchExams = (_) async => throw StateError('考试超时');
        TimetableController.fetchSnapshot = (_, {baseSettings}) async =>
            snap([base], syncedAt: fakeNow);
        await c.onAppStart();
        expect(c.needsSync, isTrue, reason: '考试基线未建立时同一天仍保持 needsSync');

        // 91 分钟后仍在同一天，补建考试基线 exam1（不误报），随后新增 exam2 落盘未读
        fakeNow = fakeNow.add(const Duration(minutes: 91));
        TimetableController.fetchExams = (_) async => [exam1];
        await c.autoSyncIfNeeded();
        expect(c.needsSync, isFalse);
        expect(c.pendingChangeAlerts, isEmpty);

        TimetableController.fetchExams = (_) async => [exam1, exam2];
        await c.syncFromJwxt();
        expect(c.pendingChangeAlerts, hasLength(1));

        // 模拟进程被杀后冷启动从小组件进入
        c.debugReset();
      });

      tester.platformDispatcher.defaultRouteNameTestValue = '/apps/timetable';
      await tester.runAsync(() async {
        await tester.pumpWidget(const NuistApp());
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      // 冷启动从小组件进入课表：立即弹出未读新增考试提醒
      expect(find.byType(TimetablePage), findsOneWidget);
      expect(find.byKey(const Key('tt_change_alert_title')), findsOneWidget);
      expect(find.textContaining('计算机网络（考试）'), findsOneWidget);

      // 2. 弹窗正开着时，用户切桌面点击小组件触发热启动 openRoute('/apps/timetable?focus=tomorrow')
      // 路由执行 _router.replace 前先以 defer 方式收起弹窗，不会把未读吞掉，并在新页面立即补弹！
      await tester.runAsync(() async {
        await messenger.handlePlatformMessage(
          'dev.duohuo.nuist_sta_app/notify_widget',
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('openRoute', '/apps/timetable?focus=tomorrow'),
          ),
          (_) {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();

      expect(c.pendingChangeAlerts, hasLength(1));
      expect(find.byKey(const Key('tt_change_alert_title')), findsOneWidget);

      // 用户主动点「知道了」才消除
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('tt_change_alert_got_it')));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(c.pendingChangeAlerts, isEmpty);
      expect(find.byKey(const Key('tt_change_alert_title')), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  });
}
