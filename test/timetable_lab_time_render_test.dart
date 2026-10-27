import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_home_card.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_notify_plan.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_notify_service.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

/// 脱敏样例周二「数据结构课程设计」四段实验课（压缩小课间后）应显示的时刻。
/// UI 用 en-dash；小组件 payload 用 ASCII hyphen。
const _uiTimes = ['08:00–09:30', '10:10–11:40', '13:45–15:15', '15:55–17:25'];
const _payloadTimes = [
  '08:00-09:30',
  '10:10-11:40',
  '13:45-15:15',
  '15:55-17:25',
];

const _courseName = '数据结构课程设计';
final _samplePath = File('test/fixtures/timetable/kb_lab_tuesday_sample.json');

/// 2026-08-31 为第 1 周周一 → 第 18 周周二。
final _termStart = DateTime(2026, 8, 31);
final _tuesday = DateTime(2026, 12, 29);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final ctl = TimetableController.instance;
  late Directory tmp;

  void loadSample() {
    final raw =
        jsonDecode(_samplePath.readAsStringSync()) as Map<String, dynamic>;
    final rows = ((raw['datas'] as Map)['cxxszhxqkb'] as Map)['rows'] as List;
    final courses = TimetableParser.parseKbRows(rows).courses;
    ctl.debugSetSnapshot(
      TimetableSnapshot(
        courses: courses,
        periods: TimetableController.defaultPeriods(),
        settings: TimetableSettings(
          termStartDate: _termStart,
          homeMaxItems: 4,
          widgetCourseCount: 3,
          showLocation: false,
          showTeacher: false,
        ),
        syncedAt: _termStart,
      ),
      viewingWeek: 18,
    );
  }

  // Sync IO：testWidgets 的 FakeAsync 下 await createTemp / readAsString 会挂死。
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('lab_time_render_');
    TimetableStore.debugDirectory = tmp;
    ctl.debugReset();
  });

  tearDown(() {
    ctl.debugReset();
    TimetableStore.debugDirectory = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  final sampleMissing = !_samplePath.existsSync();

  testWidgets('周格课程格：周二数据结构课程设计显示四段实验时刻', (tester) async {
    loadSample();
    final cells = ctl
        .cellsForDay(18, 2)
        .where((c) => c.course.name == _courseName && c.activeThisWeek)
        .toList();
    expect(cells, hasLength(4));

    // 逐格泵入，与 device_regression 周格用例同构。
    for (var i = 0; i < cells.length; i++) {
      final cell = cells[i];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 180,
              child: CourseCell(
                cell: cell,
                controller: ctl,
                width: 200,
                height: 180,
                radius: 4,
              ),
            ),
          ),
        ),
      );
      expect(
        find.text(_uiTimes[i]),
        findsOneWidget,
        reason: 'week cell ${cell.slot.startNode}-${cell.slot.endNode}',
      );
      expect(find.textContaining(_courseName), findsOneWidget);
    }
  }, skip: sampleMissing);

  testWidgets('首页今日课卡片：周二数据结构课程设计显示四段实验时刻', (tester) async {
    loadSample();
    // 07:00：四段均未开始，不会被「已上完」过滤掉。
    final now = DateTime(2026, 12, 29, 7);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: TimetableHomeCard(now: () => now)),
        ),
      ),
    );
    // 不用 pumpAndSettle：RefreshButton 等 ticker 会挂住。
    await tester.pump();

    for (final t in _uiTimes) {
      expect(
        find.textContaining(t),
        findsOneWidget,
        reason: 'home card should display $t',
      );
    }
    expect(find.text(_courseName), findsNWidgets(4));
  }, skip: sampleMissing);

  test('小组件数据导出：周二数据结构课程设计 payload 含四段实验时刻', () {
    loadSample();
    final svc = TimetableNotifyService(controller: ctl);
    final classes = svc
        .classesOn(_tuesday)
        .where((c) => c.name == _courseName)
        .toList();
    expect(classes.map((c) => c.timeRange), _payloadTimes);

    final payload = buildWidgetPayload(
      now: DateTime(2026, 12, 29, 7),
      classesOn: svc.classesOn,
      prefs: const WidgetPrefs(courseCount: 3, showPeriod: true),
      lastSyncedAt: _termStart,
    );
    expect(payload['state'], 'ok');
    final days = payload['days'] as List;
    expect(days, isNotEmpty);
    final items = (days.first as Map)['items'] as List;
    final labItems = items
        .where((e) => (e as Map)['name'] == _courseName)
        .toList();
    expect(labItems, hasLength(4));
    final displayed = [
      for (final e in labItems)
        // periodTime 形如「第1-2节 08:00-09:30」；断言 DISPLAYED 时段段。
        ((e as Map)['periodTime'] as String).split(' ').last,
    ];
    expect(displayed, _payloadTimes);
    // 关节次时 periodTime 只剩时间段，仍须四段。
    final bare = buildWidgetPayload(
      now: DateTime(2026, 12, 29, 7),
      classesOn: svc.classesOn,
      prefs: const WidgetPrefs(courseCount: 3, showPeriod: false),
      lastSyncedAt: _termStart,
    );
    final bareItems = ((bare['days'] as List).first as Map)['items'] as List;
    expect([
      for (final e in bareItems)
        if ((e as Map)['name'] == _courseName) e['periodTime'],
    ], _payloadTimes);
  }, skip: sampleMissing ? 'desensitized sample not present' : false);
}
