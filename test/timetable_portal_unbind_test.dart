import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/app_registry.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_manifest.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_exams_manifest.dart';

void main() {
  late Directory tmp;
  final c = TimetableController.instance;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tt_unbind');
    TimetableStore.debugDirectory = tmp;
    c.debugReset();
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        TimetableSnapshot(
          courses: [
            Course(
              id: 'j1',
              name: '教务课',
              source: CourseSource.jwxt,
              slots: [
                CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: '1' * 16),
              ],
            ),
          ],
          settings: baseSettings ?? const TimetableSettings(),
        );
    await c.ensureStarted();
  });

  tearDown(() async {
    TimetableStore.debugDirectory = null;
    c.debugReset();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('解绑后清掉教务课（含磁盘），手动课保留', () async {
    await c.syncFromJwxt();
    await c.addManualCourse(
      Course(
        id: '',
        name: '社团',
        slots: [CourseSlot(day: 3, startNode: 5, endNode: 6, weeks: '1' * 8)],
      ),
    );
    expect(c.jwxtCourses, isNotEmpty);
    expect(File('${tmp.path}/snapshot.json').existsSync(), isTrue);

    expect(
      await AppRegistry([timetableManifest, examScheduleManifest])
          .notifyPortalBindingChanged(bound: false),
      isTrue,
    );

    expect(c.portalBound, isFalse);
    expect(c.jwxtCourses, isEmpty);
    expect(c.manualCourses.map((e) => e.name), ['社团']);

    // 重新读盘：教务课不能回来，手动课还在
    c.debugReset();
    await c.ensureStarted();
    expect(c.jwxtCourses, isEmpty);
    expect(c.manualCourses.map((e) => e.name), ['社团']);
    expect(c.settings.termStartFromJwxt, isFalse);
    expect(File('${tmp.path}/snapshot.json').existsSync(), isFalse);
  });

  for (final failedStep in ['snapshot', 'events']) {
    test('$failedStep 清理失败仍清理其他文件，通知解绑并上抛保存异常', () async {
      await c.syncFromJwxt();
      await c.addManualCourse(
        Course(
          id: 'manual-course',
          name: '社团',
          slots: [CourseSlot(day: 3, startNode: 5, endNode: 6, weeks: '1' * 8)],
        ),
      );
      final exam = ScheduleEvent(
        id: 'jwxt-exam',
        kind: ScheduleKind.exam,
        source: ScheduleSource.jwxt,
        title: '示例考试',
        date: DateTime(2026, 11, 10),
        start: const TimeOfDayMinutes(9, 0),
        end: const TimeOfDayMinutes(11, 0),
        courseCode: 'EXAMPLE01',
      );
      await c.addScheduleEvent(
        exam.copyWith(
          id: 'manual-event',
          kind: ScheduleKind.other,
          source: ScheduleSource.manual,
          title: '社团活动',
        ),
      );
      await c.replaceJwxtExams([exam]);
      final settingsFile = File('${tmp.path}/settings.json');
      final raw = jsonDecode(settingsFile.readAsStringSync()) as Map;
      raw['futureKey'] = 'keep';
      raw['periodHeight'] = 44;
      settingsFile.writeAsStringSync(jsonEncode(raw));
      final snapshotFile = File('${tmp.path}/snapshot.json');
      if (failedStep == 'snapshot') {
        snapshotFile.deleteSync();
        Directory(snapshotFile.path).createSync();
      } else {
        Directory('${tmp.path}/schedule_events.json.tmp').createSync();
      }
      final reasons = <ScheduleChangeReason>[];
      final subscription = c.scheduleChanged.listen(reasons.add);
      addTearDown(subscription.cancel);
      var notified = false;
      void listener() {
        if (!c.portalBound && c.jwxtCourses.isEmpty) notified = true;
      }

      c.addListener(listener);
      addTearDown(() => c.removeListener(listener));

      await expectLater(
        c.handleLogout(),
        throwsA(isA<TimetablePersistenceException>()),
      );
      await pumpEventQueue();

      expect(notified, isTrue);
      expect(reasons, contains(ScheduleChangeReason.unbind));
      expect(c.portalBound, isFalse);
      expect(c.jwxtCourses, isEmpty);
      expect(c.scheduleEvents.map((event) => event.id), ['manual-event']);
      expect(c.manualCourses.map((course) => course.id), ['manual-course']);
      final remainingSettings =
          jsonDecode(settingsFile.readAsStringSync()) as Map;
      expect(
        remainingSettings.keys.any(TimetableStore.termSettingKeys.contains),
        isFalse,
      );
      expect(remainingSettings['futureKey'], 'keep');
      expect(remainingSettings['periodHeight'], 44);
      if (failedStep == 'snapshot') {
        expect((await ScheduleStore.readEvents()).map((event) => event.id), [
          'manual-event',
        ]);
      } else {
        expect(snapshotFile.existsSync(), isFalse);
      }
    });
  }
}
