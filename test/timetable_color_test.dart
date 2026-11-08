import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';

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

  group('自动文字按实际背景保证对比度', () {
    double contrast(Color background, Color foreground) {
      final bg = background.computeLuminance();
      final fg = foreground.computeLuminance();
      return bg >= fg ? (bg + 0.05) / (fg + 0.05) : (fg + 0.05) / (bg + 0.05);
    }

    test('青、琥珀、青绿预设：明暗主题及不同透明度均可读', () {
      for (final index in [9, 10, 3]) {
        for (final dark in [false, true]) {
          final pair = TimetableTheme.autoCoursePair(index, dark: dark);
          for (final opacity in [30, 80, 100]) {
            final background = TimetableTheme.blendCellBg(
              pair.bg,
              opacity,
              dark: dark,
            );
            final foreground = TimetableTheme.readableCellText(
              background,
              pair.fg,
            );
            expect(contrast(background, foreground), greaterThanOrEqualTo(4.5));
            expect(foreground.a, 1);
            if (contrast(background, pair.fg) >= 4.5) {
              expect(foreground, pair.fg);
            }
          }
        }
      }
    });

    test('自选中灰：原先黑白候选均不足时修正文字，明暗混合后重新计算', () {
      const raw = Color(0xFF808080);
      for (final dark in [false, true]) {
        for (final opacity in [30, 80, 100]) {
          final background = TimetableTheme.blendCellBg(
            raw,
            opacity,
            dark: dark,
          );
          final preferred = TimetableTheme.userCoursePair(background).fg;
          final foreground = TimetableTheme.readableCellText(
            background,
            preferred,
          );
          expect(contrast(background, foreground), greaterThanOrEqualTo(4.5));
          expect(foreground.a, 1);
          if (opacity == 100) {
            expect(contrast(background, preferred), lessThan(4.5));
            expect(foreground, isNot(preferred));
          }
        }
      }
    });

    test('已可读颜色保留，透明文字转为不透明，强制黑白设置仍有效', () {
      const background = Color(0xFFFFFFFF);
      const preferred = Color(0xFF123456);
      expect(TimetableTheme.readableCellText(background, preferred), preferred);
      final foreground = TimetableTheme.readableCellText(
        background,
        preferred.withValues(alpha: 0.4),
      );
      expect(foreground, preferred);
      expect(foreground.a, 1);
      expect(
        TimetableTheme.cellTextFor(foreground, CellTextColorMode.white),
        TimetableTheme.forcedWhiteText,
      );
      expect(
        TimetableTheme.cellTextFor(foreground, CellTextColorMode.black),
        TimetableTheme.forcedBlackText,
      );
    });
  });
}
