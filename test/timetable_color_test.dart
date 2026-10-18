import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

void main() {
  group('C01 colorIndex', () {
    late Directory tmp;
    final c = TimetableController.instance;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tt_color');
      TimetableStore.debugDirectory = tmp;
      c.debugReset();
    });
    tearDown(() async {
      TimetableStore.debugDirectory = null;
      c.debugReset();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test(
      'old v1 JSON loads; assigned color persisted once; set color persists',
      () async {
        final f = File('${tmp.path}/manual_courses.json');
        const v1 =
            '{"schemaVersion":1,"courses":[{"id":"m1","name":"社团",'
            '"source":"manual","slots":[{"day":1,"startNode":1,"endNode":2,'
            '"weeks":"1111"}]}]}';
        f.writeAsStringSync(v1);
        final mtime = f.lastModifiedSync();
        await c.ensureStarted();
        var m = c.manualCourses.single;
        expect(m.colorIndex, isNull);
        expect(m.resolvedColorIndex, courseColorIndexForName('社团'));
        // 颜色稳定：旧数据缺 assignedColorIndex → 启动时算一次并落盘（未知结构保留）。
        expect(m.assignedColorIndex, courseColorIndexForName('社团'));
        final once = f.readAsStringSync();
        expect(once, contains('"assignedColorIndex"'));
        expect(mtime, isNotNull);
        c.debugReset();
        await c.ensureStarted();
        expect(f.readAsStringSync(), once); // 第二次启动不再写
        m = c.manualCourses.single;

        await c.updateManualCourse(m.copyWith(colorIndex: 7));
        expect(f.readAsStringSync(), contains('"schemaVersion":2'));
        c.debugReset();
        await c.ensureStarted();
        expect(c.manualCourses.single.colorIndex, 7);
        expect(c.manualCourses.single.resolvedColorIndex, 7);
      },
    );

    test('out-of-range colorIndex reads as null', () {
      final course = Course.fromJson({
        'id': 'x',
        'name': 'a',
        'colorIndex': 99,
      });
      expect(course.colorIndex, isNull);
    });

    test('same-name JWXT and manual share default color', () {
      const jw = Course(id: 'j', name: '学术英语（1）', source: CourseSource.jwxt);
      const ma = Course(id: 'm', name: '学术英语（1）', source: CourseSource.manual);
      expect(jw.resolvedColorIndex, ma.resolvedColorIndex);
    });
  });

  group('C02 pinned FNV-1a indices', () {
    test('normalization', () {
      expect(normalizeCourseName(' 学术英语(1) '), '学术英语（1）');
      expect(
        courseColorIndexForName('学术英语(1)'),
        courseColorIndexForName(' 学术英语（1） '),
      );
    });
    test('pins', () {
      expect(courseColorIndexForName('学术英语（1）'), 12);
      expect(courseColorIndexForName('高等数学A（1）'), 4);
      expect(courseColorIndexForName('数据结构'), 12);
      expect(courseColorIndexForName('大学物理'), 5);
    });
  });
}
