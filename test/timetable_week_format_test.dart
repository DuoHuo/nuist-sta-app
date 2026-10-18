import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_detail_sheet.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_manual_course_form.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_format.dart';

const _fx = 'test/fixtures/timetable';

void main() {
  group('formatWeeks (W01)', () {
    test('空 / 单周 / 两周', () {
      expect(formatWeeks(const []), '');
      expect(formatWeeks(const [5]), '第 5 周');
      expect(formatWeeks(const [2, 4]), '第 2、4 周');
    });

    test('连续段', () {
      expect(formatWeeks(const [2, 3, 4, 5, 6]), '第 2–6 周');
      expect(
        formatWeeks(const [1, 2, 3, 4, 7, 9, 10, 11, 12]),
        '第 1–4、7、9–12 周',
      );
    });

    test('单双周', () {
      expect(formatWeeks(const [2, 4, 6, 8, 10]), '第 2–10 周（双）');
      expect(formatWeeks(const [1, 3, 5, 7, 9]), '第 1–9 周（单）');
      // 全单但有缺口 → 不用（单），逐个列出（>3 段截断）。
      expect(formatWeeks(const [1, 3, 7]), '第 1、3、7 周');
    });

    test('超过 3 段：只取前 3 段，「周」后加「等」', () {
      final s = formatWeeks(const [1, 2, 4, 6, 9, 12]);
      expect(s, '第 1–2、4、6 周等');
      expect(s, endsWith('等'));
    });

    test('乱序 / 重复输入', () {
      expect(formatWeeks(const [6, 2, 4, 2, 3, 5, 6]), '第 2–6 周');
      expect(formatWeeks(const [9, 1, 5, 3, 7, 7]), '第 1–9 周（单）');
      expect(formatWeeks(const [5, 5]), '第 5 周');
    });

    test('从不输出半角 - 或 (单)', () {
      for (final w in const [
        [1, 2, 3],
        [1, 3, 5],
        [2, 4, 6],
        [1, 2, 5, 6, 9, 10, 13],
      ]) {
        final s = formatWeeks(w);
        expect(s, isNot(contains('-')));
        expect(s, isNot(contains('(')));
      }
    });

    test('weeksFromBits', () {
      expect(weeksFromBits('0101010000'), [2, 4, 6]);
      expect(formatWeekBits('0000'), '');
    });
  });

  group('合成课表 kb_mock.json（始终运行）：按 SKZC 格式化，不用 ZCMC', () {
    late Map<String, Course> byName;
    setUpAll(() {
      final raw = jsonDecode(
        File('$_fx/kb_mock.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final snap = TimetableParser.parseImportJson({
        'code': '0',
        'datas': raw['datas'],
      }, baseSettings: const TimetableSettings(maxWeeks: 30));
      byName = {for (final c in snap.courses) normalizeCourseName(c.name): c};
    });

    String fmt(String name, [int slot = 0]) =>
        formatWeekBits(byName[name]!.slots[slot].weeks);

    test('双周 2–16（SKZC 24 位）→「第 2–16 周（双）」，不是 ZCMC', () {
      final slot = byName['大学物理B']!.slots.single;
      expect(slot.weeks.length, 30); // 24 位按 maxWeeks 补齐
      final text = formatWeekBits(slot.weeks);
      expect(text, '第 2–16 周（双）');
      expect(text, isNot(contains('-')));
      expect(text, isNot(contains('(双)')));
      expect(slot.weeksLabel, '2-16周(双)');
      expect(text, isNot(slot.weeksLabel));
    });

    test('单周 1–15 / 1–17', () {
      expect(fmt('线性代数B'), '第 1–15 周（单）');
      expect(fmt('大学化学'), '第 1–17 周（单）');
    });

    test('连续段与多段（SKZC 30 位）', () {
      expect(fmt('高等数学A'), '第 1–16 周');
      expect(fmt('高等数学A', 1), '第 1–16 周');
      expect(fmt('概率论与数理统计'), '第 1–8 周');
      expect(fmt('数字逻辑'), '第 3–14 周');
      expect(fmt('电路分析'), '第 1–4、7、9–12 周');
      expect(byName['电路分析']!.slots.single.weeksLabel, '1-4周,7周,9-12周');
    });

    test('单个周 / 短双周', () {
      expect(fmt('形势与政策'), '第 9 周');
      expect(fmt('大学物理实验B'), '第 2–8 周（双）');
    });
  });

  group(
    '真实样例（仅本地存在时运行）',
    () {
      test('真实样例：大学物理Ⅱ（2）按 SKZC →「第 2–16 周（双）」，不用 ZCMC', () {
        final raw = jsonDecode(
          File('test/fixtures/timetable/kb_real_sample.json')
              .readAsStringSync(),
        ) as Map<String, dynamic>;
        final snap = TimetableParser.parseImportJson({
          'code': '0',
          'datas': raw['datas'],
        }, baseSettings: const TimetableSettings(maxWeeks: 30));
        final physics = snap.courses.firstWhere(
          (c) => normalizeCourseName(c.name) == '大学物理Ⅱ（2）',
        );
        final slot = physics.slots.firstWhere((s) => s.weeks.contains('1'));
        final text = formatWeekBits(slot.weeks);
        expect(text, '第 2–16 周（双）');
        expect(text, isNot(contains('-')));
        expect(text, isNot(contains('(双)')));
        expect(text, isNot(slot.weeksLabel)); // ZCMC「2-16周(双)」
      });
    },
    skip: File('$_fx/kb_real_sample.json').existsSync()
        ? false
        : 'real sample not present',
  );

  test('mock 样例：大学英语Ⅰ 单周 →「第 1–15 周（单）」', () {
    final json = jsonDecode(
      File('test/fixtures/timetable/kb_mock_2026-1.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final rows = (json['datas'] as Map)['cxxszhxqkb']['rows'] as List;
    final result = TimetableParser.parseKbRows(rows);
    final english = result.courses.firstWhere((c) => c.name == '大学英语Ⅰ');
    final slot = english.slots.firstWhere((s) => s.weeks.contains('1'));
    final text = formatWeekBits(slot.weeks);
    expect(text, '第 1–15 周（单）');
    expect(text, isNot(contains('(单)')));
    expect(text, isNot(slot.weeksLabel));
  });

  testWidgets('表单冲突提示与详情弹层的周次文案一致', (tester) async {
    const bits = '01010101010000000000'; // 2,4,6,8,10
    final slot = CourseSlot(
      day: 1,
      startNode: 1,
      endNode: 2,
      weeks: bits,
      weeksLabel: '2-10周(双)',
    );
    final course = Course(
      id: 'p',
      name: '大学物理',
      source: CourseSource.jwxt,
      slots: [slot],
    );
    final hint = describeManualConflicts(
      const CourseSlot(
        day: 1,
        startNode: 1,
        endNode: 1,
        weeks: '11111111111111111111',
      ),
      [course],
    );
    const expected = '第 2–10 周（双）';
    expect(hint, '与「大学物理」$expected冲突');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CourseDetailSheet(
            cell: GridCell(
              course: course,
              slot: slot,
              conflictCount: 0,
              activeThisWeek: true,
            ),
            controller: TimetableController.instance,
          ),
        ),
      ),
    );
    expect(find.text(expected), findsOneWidget);
    expect(find.text('2-10周(双)'), findsNothing);
    expect(hint, contains(expected));
  });
}
