// 课表同步拆分（local refresh vs remote sync）：
// - refreshLocal 只重读本地磁盘，不拉教务、不写同步 diff；失败返回 false。
// - onAppResumed 始终 refreshLocal；距上次成功远程同步 >6h（或从未成功）才静默补远程。
// - manualSync / syncFromJwxt / syncFromRemote 仍走远程全量同步。
// 全部为构造数据，不读真实样例。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_sync_diff.dart';

Course _course(String id, {String location = '测试楼 A101'}) => Course(
  id: id,
  name: '课程 $id',
  code: 'C$id',
  classId: '1',
  source: CourseSource.jwxt,
  slots: [
    CourseSlot(
      day: 1,
      startNode: 1,
      endNode: 2,
      weeks: '1111111111111111',
      location: location,
    ),
  ],
);

TimetableSnapshot _snapshot(List<Course> courses, {DateTime? syncedAt}) =>
    TimetableSnapshot(
      courses: courses,
      periods: TimetableController.defaultPeriods(),
      settings: const TimetableSettings(termCode: '2026-2027-1'),
      syncedAt: syncedAt ?? DateTime(2026, 9, 7, 8),
    );

void main() {
  late Directory tmp;
  final c = TimetableController.instance;
  late DateTime now;
  var fetches = 0;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tt_sync_split');
    TimetableStore.debugDirectory = tmp;
    TimetableChangeLogStore.debugMemory = [];
    now = DateTime(2026, 9, 7, 8);
    fetches = 0;
    TimetableController.clock = () => DateTime(2026, 9, 7);
    TimetableController.syncClock = () => now;
    TimetableController.bindingCheck = () async => true;
    c.debugReset();
  });

  tearDown(() async {
    TimetableStore.debugDirectory = null;
    TimetableChangeLogStore.debugMemory = null;
    TimetableController.clock = TimetableApi.shanghaiToday;
    TimetableController.syncClock = DateTime.now;
    TimetableController.fetchSnapshot = (term, {baseSettings}) =>
        TimetableApi.fetchTermSnapshot(term, baseSettings: baseSettings);
    c.debugReset();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('refreshLocal 只重读本地磁盘：不 fetch、会 notifyListeners', () async {
    TimetableController.fetchSnapshot = (term, {baseSettings}) async {
      fetches++;
      return _snapshot([_course('j1')]);
    };
    await TimetableStore.saveSnapshot(_snapshot([_course('j1')]));
    await c.ensureStarted();
    expect(c.jwxtCourses.map((e) => e.id), ['j1']);

    var notified = 0;
    void listener() => notified++;
    c.addListener(listener);
    await c.refreshLocal();
    c.removeListener(listener);

    expect(fetches, 0);
    expect(notified, greaterThan(0));
    expect(c.lastSyncDiff, isNull, reason: '本地刷新不套用远程同步 diff');
  });

  test('onAppResumed 未满 6 小时只本地刷新，磁盘改动可读回', () async {
    TimetableController.fetchSnapshot = (term, {baseSettings}) async {
      fetches++;
      return _snapshot([_course('j1')]);
    };
    await c.ensureStarted();
    expect(await c.manualSync(), isTrue);
    expect(fetches, 1);

    now = now.add(const Duration(minutes: 31));
    await TimetableStore.saveSnapshot(
      _snapshot([_course('j2')], syncedAt: now),
    );

    expect(await c.onAppResumed(), isTrue);
    expect(fetches, 1, reason: '距上次成功不足 6 小时，回前台不拉教务');
    expect(c.jwxtCourses.map((e) => e.id), ['j2'], reason: '重新读盘');
  });

  test('refreshLocal 成功返回 true，钩子抛错返回 false', () async {
    await TimetableStore.saveSnapshot(_snapshot([_course('j1')]));
    await c.ensureStarted();
    expect(await c.refreshLocal(), isTrue);

    TimetableController.debugBeforeRefreshLocal = () async {
      throw StateError('disk boom');
    };
    expect(await c.refreshLocal(), isFalse);
    TimetableController.debugBeforeRefreshLocal = null;
    expect(await c.refreshLocal(), isTrue);
  });

  test('manualSync / syncFromRemote / syncFromJwxt 仍走远程，成功路径写 diff', () async {
    TimetableController.fetchSnapshot = (term, {baseSettings}) async {
      fetches++;
      return _snapshot([
        _course('j1', location: fetches == 1 ? '测试楼 A101' : '测试楼 B202'),
      ]);
    };
    await c.ensureStarted();

    expect(await c.manualSync(), isTrue);
    expect(fetches, 1);
    expect(c.lastSyncDiff, isNotNull);

    await c.syncFromRemote();
    expect(fetches, 2);
    expect(c.jwxtCourses.single.slots.single.location, '测试楼 B202');
    expect(c.lastSyncDiff, isNotNull);
    expect(c.lastSyncDiff!.allWritten, isNotEmpty);
    expect(c.lastSyncDiff!.hasNewChanges, isTrue);

    await c.syncFromJwxt();
    expect(fetches, 3);
  });
}
