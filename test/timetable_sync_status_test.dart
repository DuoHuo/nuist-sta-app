import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/logging/app_log.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

Course _course(String id, String weeks) => Course(
  id: id,
  name: 'C $id',
  source: CourseSource.jwxt,
  slots: [CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: weeks)],
);

void main() {
  late Directory tmp;
  final c = TimetableController.instance;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tt_sync');
    TimetableStore.debugDirectory = tmp;
    TimetableController.clock = () => DateTime(2026, 10, 11);
    c.debugReset();
  });

  tearDown(() async {
    TimetableStore.debugDirectory = null;
    TimetableController.clock = TimetableApi.shanghaiToday;
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        throw UnimplementedError();
    c.debugReset();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('syncStatus: idle → syncing → success', () async {
    await c.ensureStarted();
    final records = <Map<String, Object?>>[];
    AppLog.recordListenerForTesting = records.add;
    addTearDown(() => AppLog.recordListenerForTesting = null);
    expect(c.syncStatus, TimetableSyncStatus.idle);
    expect(c.statusIsSuccess, isFalse);
    final seen = <TimetableSyncStatus>[];
    void l() => seen.add(c.syncStatus);
    c.addListener(l);
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        TimetableSnapshot(
          courses: [_course('a', '1' * 16)],
          settings: baseSettings ?? const TimetableSettings(),
        );
    await c.syncFromJwxt();
    c.removeListener(l);
    expect(seen.first, TimetableSyncStatus.syncing);
    expect(c.syncStatus, TimetableSyncStatus.success);
    expect(c.statusIsSuccess, isTrue);
    final completed = records.singleWhere(
      (record) => record['event'] == 'sync.completed',
    );
    final started = records.singleWhere(
      (record) => record['event'] == 'sync.started',
    );
    expect(completed['level'], 'INFO');
    expect((completed['attrs'] as Map)['course_count'], 1);
    expect((completed['attrs'] as Map)['duration_ms'], isNonNegative);
    expect(completed['trace_id'], started['trace_id']);
    expect(completed['span_id'], started['span_id']);
  });

  test('syncStatus: failure', () async {
    await c.ensureStarted();
    final records = <Map<String, Object?>>[];
    AppLog.recordListenerForTesting = records.add;
    addTearDown(() => AppLog.recordListenerForTesting = null);
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        throw Exception('boom');
    await c.syncFromJwxt();
    expect(c.syncStatus, TimetableSyncStatus.failure);
    expect(c.statusIsSuccess, isFalse);
    final syncRecords = records
        .where(
          (record) =>
              record['scope'] == 'timetable.controller' &&
              '${record['event']}'.startsWith('sync.'),
        )
        .toList();
    expect(syncRecords.map((record) => record['event']), [
      'sync.started',
      'sync.failed',
    ]);
    expect(syncRecords.last['level'], 'WARNING');
    expect((syncRecords.last['attrs'] as Map)['duration_ms'], isNonNegative);
    expect(syncRecords.last['trace_id'], syncRecords.first['trace_id']);
    expect(syncRecords.last['span_id'], syncRecords.first['span_id']);
  });

  test(
    'builtin 2026-08-31 fallback populates termStartDate; not pending',
    () async {
      await c.ensureStarted();
      expect(c.settings.termCode, '2026-2027-1');
      expect(c.settings.termStartDate, DateTime(2026, 8, 31));
      expect(c.settings.termStartFromJwxt, isFalse);
      expect(c.weekPending, isFalse);
      expect(c.currentWeek, 6);
    },
  );

  test('weekPending only when no start at all', () {
    c.debugSetSnapshot(
      const TimetableSnapshot(
        settings: TimetableSettings(termCode: '2030-2031-1'),
      ),
    );
    expect(c.weekPending, isTrue);
    expect(c.currentWeek, 1);
  });

  test('viewingWeek 钳到 1..totalWeeks（=最晚有课周）；currentWeek 不截断', () {
    c.debugSetSnapshot(
      TimetableSnapshot(
        courses: [_course('a', '1' * 16)],
        settings: TimetableSettings(
          termCode: '2026-2027-1',
          termStartDate: DateTime(2026, 8, 31),
          maxWeeks: 30,
        ),
      ),
    );
    expect(c.totalWeeks, 16);
    c.setViewingWeek(28);
    expect(c.viewingWeek, 16);
    c.setViewingWeek(0);
    expect(c.viewingWeek, 1);
    // 第 6 周课程延至 24 周 → totalWeeks 24
    c.debugSetSnapshot(
      TimetableSnapshot(
        courses: [_course('b', '${'0' * 23}1')],
        settings: TimetableSettings(
          termCode: '2026-2027-1',
          termStartDate: DateTime(2026, 8, 31),
        ),
      ),
    );
    expect(c.totalWeeks, 24);
    c.setViewingWeek(30);
    expect(c.viewingWeek, 24);
    // 开学很久之后 → currentWeek 为真实教学周，可超出 totalWeeks
    TimetableController.clock = () => DateTime(2027, 6, 1);
    expect(c.currentWeek, greaterThan(24));
    expect(
      c.currentWeek,
      teachingWeekOf(DateTime(2026, 8, 31), DateTime(2027, 6, 1)),
    );
    c.setViewingWeek(c.currentWeek);
    expect(c.viewingWeek, 24);
    // ignore: deprecated_member_use_from_same_package
    expect(c.maxWeeks, c.totalWeeks);
  });
}
