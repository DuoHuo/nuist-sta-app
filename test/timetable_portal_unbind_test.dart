import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/shell/profile/portal_bind/portal_status_page.dart';

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

    await clearTimetableOnUnbind();

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
}
