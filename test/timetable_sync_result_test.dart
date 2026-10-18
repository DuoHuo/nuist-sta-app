import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

// 全部为虚构数据。
const _settings = TimetableSettings(termCode: '2026-2027-1');
final _termStart = DateTime(2026, 8, 31); // 周一，第 1 周
final _monday = DateTime(2026, 9, 7); // 第 2 周周一

Course _jwxt(
  String id,
  String name, {
  int day = 1,
  int start = 1,
  int end = 2,
  String weeks = '1111111111111111',
}) => Course(
  id: id,
  name: name,
  source: CourseSource.jwxt,
  slots: [
    CourseSlot(
      day: day,
      startNode: start,
      endNode: end,
      weeks: weeks,
      teacher: '张老师',
      location: '教一-101',
    ),
  ],
);

TimetableSnapshot _snap(List<Course> courses) => TimetableSnapshot(
  courses: courses,
  periods: TimetableController.defaultPeriods(),
  settings: _settings.copyWith(
    termStartDate: _termStart,
    termStartFromJwxt: true,
  ),
);

void main() {
  late Directory tmp;
  final c = TimetableController.instance;
  List<Course> nextFetch = const [];
  List<ScheduleEvent>? nextExams;
  final origFetchExams = TimetableController.fetchExams;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tt_data');
    TimetableStore.debugDirectory = tmp;
    TimetableController.clock = () => _monday;
    TimetableController.bindingCheck = () async => true;
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        _snap(nextFetch);
    // 默认返回 null（本次不拉考试，与替换了 fetchSnapshot 时的默认钩子一致）。
    nextExams = null;
    TimetableController.fetchExams = (term) async => nextExams;
    c.debugReset();
  });

  tearDown(() async {
    TimetableStore.debugDirectory = null;
    TimetableController.clock = TimetableApi.shanghaiToday;
    TimetableController.syncClock = DateTime.now;
    TimetableController.fetchSnapshot = (term, {baseSettings}) =>
        TimetableApi.fetchTermSnapshot(term, baseSettings: baseSettings);
    TimetableController.fetchExams = origFetchExams;
    c.debugReset();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> seed(List<Course> jwxt, {List<Course> manual = const []}) async {
    nextFetch = jwxt;
    await c.ensureStarted();
    for (final m in manual) {
      await c.addManualCourse(m);
    }
    await c.syncFromJwxt();
    expect(c.syncStatus, TimetableSyncStatus.success);
  }

  // ===== §24 补充用例（FC / JE / EV / EX / SW01）=====

  test('failed sync does not change course_colors.json', () async {
    await seed([_jwxt('j1', '高等数学'), _jwxt('j2', '大学物理', day: 2)]);
    final f = File('${tmp.path}/${TimetableStore.courseColorsFile}');
    final before = f.readAsStringSync();
    final mtime = f.lastModifiedSync();
    for (final err in <Object>[
      const SocketException('offline'),
      const JwxtHttpError('kb', 500),
      StateError('x'),
    ]) {
      TimetableController.fetchSnapshot = (t, {baseSettings}) async =>
          throw err;
      await c.syncFromJwxt();
      expect(c.syncStatus, TimetableSyncStatus.failure);
    }
    expect(f.readAsStringSync(), before);
    expect(f.lastModifiedSync(), mtime);
  });

  group('SW01 同步成功后的浏览周（controller）', () {
    test('SW01 viewing week 9 (current 2): successful sync stays on 9; jumpToCurrentWeek returns', () async {
      await seed([_jwxt('j1', '高等数学')]);
      expect(c.currentWeek, 2);
      expect(c.viewingWeek, 2);
      c.setViewingWeek(9);
      final outcomes = <TimetableSyncOutcome>[];
      final sub = c.syncOutcomes.listen(outcomes.add);
      expect(await c.manualSync(), isTrue);
      await pumpEventQueue();
      expect(c.syncStatus, TimetableSyncStatus.success);
      expect(c.viewingWeek, 9);
      expect(c.isViewingCurrentWeek, isFalse);
      expect(outcomes, hasLength(1));
      expect(outcomes.single.success, isTrue);
      expect(outcomes.single.automatic, isFalse);
      expect(c.lastSyncOutcome?.success, isTrue);

      var notified = 0;
      void listener() => notified++;
      c.addListener(listener);
      c.jumpToCurrentWeek();
      c.removeListener(listener);
      expect(c.viewingWeek, 2);
      expect(c.isViewingCurrentWeek, isTrue);
      expect(notified, 1);
      await sub.cancel();
    });

    test('SW01 viewing the current week: stays on the current week', () async {
      await seed([_jwxt('j1', '高等数学')]);
      expect(c.isViewingCurrentWeek, isTrue);
      await c.syncFromJwxt();
      expect(c.viewingWeek, 2);
      expect(c.isViewingCurrentWeek, isTrue);
    });

    test(
      'SW01 term shrinks below the viewed week: clamped to the last week',
      () async {
        await seed([_jwxt('j1', '高等数学')]); // 16 周
        c.setViewingWeek(14);
        nextFetch = [_jwxt('j1', '高等数学', weeks: '1' * 10)];
        await c.syncFromJwxt();
        expect(c.syncStatus, TimetableSyncStatus.success);
        expect(c.totalWeeks, 10);
        expect(c.viewingWeek, 10);
      },
    );

    test('SW01 failed sync also keeps the viewed week', () async {
      await seed([_jwxt('j1', '高等数学')]);
      c.setViewingWeek(9);
      TimetableController.fetchSnapshot = (t, {baseSettings}) async =>
          throw const SocketException('offline');
      await c.syncFromJwxt();
      expect(c.syncStatus, TimetableSyncStatus.failure);
      expect(c.viewingWeek, 9);
    });
  });
}
