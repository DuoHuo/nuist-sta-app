import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_colors.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_manual_course_form.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_color.dart';

String _w(int n, {bool odd = false, bool even = false}) => List.generate(
  n,
  (i) => (odd && i.isEven) || (even && i.isOdd) || (!odd && !even) ? '1' : '0',
).join();

Course _c(
  String id,
  String name,
  int day,
  int s,
  int e, {
  String? weeks,
  int? color,
  bool hidden = false,
  CourseSource src = CourseSource.jwxt,
}) => Course(
  id: id,
  name: name,
  colorIndex: color,
  source: src,
  hidden: hidden,
  slots: [
    CourseSlot(day: day, startNode: s, endNode: e, weeks: weeks ?? _w(16)),
  ],
);

const _fx = 'test/fixtures/timetable';

TimetableSnapshot _sample(String path) {
  final week =
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  return TimetableParser.parseImportJson({
    'code': '0',
    'datas': week['datas'],
  }, baseSettings: const TimetableSettings(maxWeeks: 30));
}

/// 合成课表（假数据，结构同真实样例）。
TimetableSnapshot _mockSample() => _sample('$_fx/kb_mock.json');

/// 第一个哈希到 0-based [idx] 的合成课名（确定性）。
String _nameWithHash(int idx) {
  for (var i = 0; ; i++) {
    final n = 'X课$i';
    if (courseColorIndexForName(n) == idx) return n;
  }
}

/// 第一个以 [prefix] 开头、哈希到 0-based [idx] 的合成课名（确定性；前缀决定课名排序）。
String _nm(String prefix, int idx) {
  for (var i = 0; ; i++) {
    final n = '$prefix$i';
    if (courseColorIndexForName(n) == idx) return n;
  }
}

int _of(Map<String, int> m, String name) => m[normalizeCourseName(name)]!;

/// 第 [from]–[to] 周（1-based，含两端）的 16 位周次串。
String _range(int from, int to) =>
    List.generate(16, (i) => i + 1 >= from && i + 1 <= to ? '1' : '0').join();

const _a = '测试课A-';
const _b = '测试课B-';
const _cc = '测试课C-';
const _e = '测试课E-';

/// 相邻两门（同一天上下相接）跑配色，返回 (A, B) 结果。
(int, int) _pair(int hashA, int hashB) {
  final na = _nm(_a, hashA), nb = _nm(_b, hashB);
  final m = assignCourseColors([_c('a', na, 1, 1, 2), _c('b', nb, 1, 3, 4)]);
  return (_of(m, na), _of(m, nb));
}

void main() {
  double lum(Color c) {
    double ch(double v) =>
        v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
  }

  double wcagContrast(Color a, Color b) {
    final la = lum(a), lb = lum(b);
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05);
  }

  test('配色方案契约：16 色不变量、无白字、WCAG>=4.5 单调递增、近似对表对称且在 0..15', () {
    expect(kDefaultCoursePaletteScheme, CoursePaletteScheme.soft);
    expect(TimetableTheme.coursePalette.length, 16);
    expect(TimetableTheme.coursePaletteText.length, 16);
    expect(kCoursePaletteSize, 16);

    final softPairs = TimetableTheme.coursePalettes[CoursePaletteScheme.soft]!;
    for (var i = 0; i < 16; i++) {
      expect(TimetableTheme.courseColor(i), softPairs[i].bg);
      expect(TimetableTheme.courseTextColor(i), softPairs[i].fg);
      expect(TimetableTheme.coursePalette[i], softPairs[i].bg);
      expect(TimetableTheme.coursePaletteText[i], softPairs[i].fg);
    }

    for (final scheme in CoursePaletteScheme.values) {
      final pairs = TimetableTheme.pairsOf(scheme);
      expect(pairs, hasLength(16), reason: '$scheme');
      for (final p in pairs) {
        expect(p.fg, isNot(Colors.white), reason: '$scheme 无白字');
        expect(p.fg.a, 1.0, reason: '$scheme 不透明');
        double? prev;
        for (var op = 100; op >= 30; op -= 10) {
          final ratio = wcagContrast(
            TimetableTheme.blendCellBg(p.bg, op),
            p.fg,
          );
          expect(ratio, greaterThanOrEqualTo(4.5), reason: '$scheme $op');
          if (prev != null) {
            expect(ratio, greaterThanOrEqualTo(prev - 1e-9));
          }
          prev = ratio;
        }
      }

      final table = kNearColorPairs[scheme]!;
      expect(table, isNotEmpty, reason: '$scheme');
      final tableSet = <(int, int)>{};
      for (final (x, y) in table) {
        expect(x, inInclusiveRange(0, 15));
        expect(y, inInclusiveRange(0, 15));
        expect(x, isNot(y));
        tableSet.add(x < y ? (x, y) : (y, x));
      }
      final found = <(int, int)>{};
      for (var a = 0; a < 16; a++) {
        for (var b = 0; b < 16; b++) {
          expect(
            colorsNear(a, b, scheme: scheme),
            colorsNear(b, a, scheme: scheme),
            reason: '$scheme ($a,$b) 对称',
          );
          if (a < b && colorsNear(a, b, scheme: scheme)) found.add((a, b));
        }
        expect(colorsNear(a, a, scheme: scheme), isFalse);
        expect(colorsClash(a, a, scheme: scheme), isTrue);
      }
      expect(found, tableSet, reason: '$scheme 逐对查不传递合并');
    }
  });

  group('C03/C04 合成课表 kb_mock.json', () {
    test('C03 前提：哈希与相邻关系符合预期（防止 fixture 被改坏）', () {
      final names = _mockSample().courses
          .map((c) => normalizeCourseName(c.name))
          .toSet();
      expect(names, hasLength(14));
      expect(courseColorIndexForName('程序设计基础'), 10);
      expect(courseColorIndexForName('高等数学A'), 10);
      expect(courseColorIndexForName('离散数学'), 8);
      expect(courseColorIndexForName('数字逻辑'), 8);
      expect(courseColorIndexForName('算法设计'), 12);
      expect(courseColorIndexForName('大学英语（3）'), 9);
      expect(courseColorIndexForName('大学物理B'), 5);
      expect(courseColorIndexForName('概率论与数理统计'), 5);
      expect(courseColorIndexForName('线性代数B'), 1);
      expect(courseColorIndexForName('大学物理实验B'), 1);
    });

    test('C03/CA15 全局防重、全表无相邻撞色且确定性可重现（含随机打乱）', () {
      final courses = _mockSample().courses;
      final a = assignCourseColors(courses);
      expect(a, hasLength(14));
      expect(a.values.toSet(), hasLength(14));

      final byName = <String, List<CourseSlot>>{};
      for (final c in courses) {
        (byName[normalizeCourseName(c.name)] ??= []).addAll(c.slots);
      }
      var adjacentPairs = 0;
      final names = byName.keys.toList();
      for (var i = 0; i < names.length; i++) {
        for (var j = i + 1; j < names.length; j++) {
          final adj = byName[names[i]]!.any(
            (x) => byName[names[j]]!.any((y) => slotsAdjacent(x, y)),
          );
          if (!adj) continue;
          adjacentPairs++;
          expect(
            colorsClash(a[names[i]]!, a[names[j]]!),
            isFalse,
            reason: '${names[i]} / ${names[j]}',
          );
        }
      }
      expect(adjacentPairs, greaterThanOrEqualTo(8));
      expect(assignCourseColors(courses), a);
      expect(assignCourseColors(List.of(courses.reversed)), a);

      // 多课程含手动色随机打乱结果一致
      final na = _nm(_a, 1), nb = _nm(_b, 10), nc = _nm(_cc, 5);
      final e = _nm(_e, 0);
      final scenario = [
        _c('a', na, 1, 1, 2),
        _c('b', nb, 1, 3, 4),
        _c('c', nc, 1, 5, 6),
        _c('e', e, 2, 3, 4),
        _c('z', '测试课Z', 3, 3, 4, color: 12, src: CourseSource.manual),
      ];
      final first = assignCourseColors(scenario);
      for (var k = 0; k < 5; k++) {
        final shuffled = List.of(scenario)..shuffle(Random(k));
        expect(assignCourseColors(shuffled), first);
      }
    });

    test('C04 colorIndexOf independent of viewing week（mock）', () {
      final ctl = TimetableController.instance..debugReset();
      final snap = _mockSample();
      final results = <int, Map<String, int>>{};
      for (final w in [1, 2, 9, 16]) {
        ctl.debugSetSnapshot(snap, viewingWeek: w, manualCourses: const []);
        results[w] = {
          for (final c in ctl.combinedCourses) c.id: ctl.colorIndexOf(c),
        };
      }
      expect(results[1], hasLength(14));
      expect(results[1]!.values.toSet(), hasLength(14));
      expect(results[2], results[1]);
      expect(results[9], results[1]);
      expect(results[16], results[1]);
      ctl.debugReset();
    });
  });

  test('C05/CA13 手动或用户自选色占用且不被改，相邻自动课避开并防近似撞色', () {
    final m = assignCourseColors([
      _c('a', '大学物理', 1, 1, 2, color: 12),
      _c('b', '数据结构', 1, 3, 4), // hash 12
    ]);
    expect(m['大学物理'], 12);
    expect(colorsClash(m['数据结构']!, 12), isFalse);
    expect(m['数据结构'], isNot(12));

    // 排序靠后的手动课也能固定色号并让排序靠前的自动课避让
    final na = _nm(_a, 1);
    final m2 = assignCourseColors([
      _c('z', '测试课Z', 1, 1, 2, color: 12, src: CourseSource.manual),
      _c('a', na, 1, 3, 4),
    ]);
    expect(m2['测试课Z'], 12);
    expect(colorsClash(_of(m2, na), 12), isFalse);
  });

  test('C06/C07/CA08 无论单双周错开、无冲突或周次交集，均优先分配不同色且相邻不撞色', () {
    final mOddEven = assignCourseColors([
      _c('a', '学术英语（1）', 2, 1, 2, weeks: _w(16, odd: true)),
      _c('b', '数据结构', 2, 3, 4, weeks: _w(16, even: true)),
    ]);
    expect(mOddEven['学术英语（1）'], isNot(mOddEven['数据结构']));

    final mDisjoint = assignCourseColors([
      _c('a', '大学物理', 1, 1, 2),
      _c('b', '数据结构', 5, 9, 10),
    ]);
    expect(mDisjoint['大学物理'], isNot(mDisjoint['数据结构']));

    final na = _nm(_a, 0), nb = _nm(_b, 8);
    final overlap = assignCourseColors([
      _c('a', na, 1, 1, 2, weeks: _range(1, 8)),
      _c('b', nb, 1, 3, 4, weeks: _range(8, 16)),
    ]);
    expect(colorsClash(_of(overlap, na), _of(overlap, nb)), isFalse);
  });

  test('C08 picked 10 and 1: 中间课避开已占用的 10 和 1 且不撞近似色', () {
    final n = _nameWithHash(10);
    final m = assignCourseColors([
      _c('p1', 'P甲', 3, 1, 2, color: 10),
      _c('p2', 'P乙', 3, 5, 6, color: 1),
      _c('x', n, 3, 3, 4),
    ]);
    final c = m[normalizeCourseName(n)]!;
    expect(colorsClash(c, 10), isFalse);
    expect(colorsClash(c, 1), isFalse);
  });

  test('C09/CA18 全撞退化：16 个都撞时选撞得最少的色号且确定性可重现', () {
    final ns16 = [
      for (var i = 0; i < 16; i++) _c('n$i', '邻$i', 3, 4, 7, color: i),
    ];
    final x = _c('x', '中心课', 3, 5, 6);
    final m1 = assignCourseColors([...ns16, x]);
    final m2 = assignCourseColors([x, ...ns16.reversed]);
    expect(m1['中心课'], inInclusiveRange(0, 15));
    expect(m2, m1);

    final z = _nm('测试课Z-', 5);
    final nsNear = [
      _c('n0', '邻0', 2, 1, 4, color: 0),
      _c('n1', '邻1', 4, 1, 4, color: 1),
      _c('n2', '邻2', 3, 5, 6, color: 2),
      _c('n5', '邻5', 3, 1, 2, color: 5),
      _c('n6', '邻6', 3, 3, 4, color: 6),
      _c('n9', '邻9', 3, 1, 4, color: 9),
      _c('n11', '邻11', 3, 2, 3, color: 11),
      _c('n13', '邻13', 3, 4, 5, color: 13),
    ];
    final zc = _c('z', z, 3, 1, 4);
    final m3 = assignCourseColors([...nsNear, zc]);
    final m4 = assignCourseColors([zc, ...nsNear.reversed]);
    expect(_of(m3, z), inInclusiveRange(0, 15));
    expect(m4, m3);
  });

  test('C10 跨天节次有交集也避让；用户自选色占用避让且不进 map', () {
    final n = _nameWithHash(0);
    final m = assignCourseColors(
      [_c('x', n, 2, 2, 3)],
      userColors: {'u': TimetableTheme.courseColor(0).toARGB32()},
      userOccupiedCourses: [_c('u', '自选课', 1, 1, 2)],
    );
    expect(m.containsKey('自选课'), isFalse);
    expect(colorsClash(m[normalizeCourseName(n)]!, 0), isFalse);
  });

  group('全局防重与分周去重', () {
    test('16 门全学期课程全员不同色（含非相邻课）', () {
      final courses = [
        for (var i = 0; i < 16; i++)
          _c('c$i', '课程$i', (i % 5) + 1, (i % 4) * 2 + 1, (i % 4) * 2 + 2),
      ];
      final m = assignCourseColors(courses);
      expect(m.values.toSet(), hasLength(16));
    });

    test('20 门跨前半学期与后半学期：任意单周内显示的课程全部不同色', () {
      final courses = [
        for (var i = 0; i < 10; i++)
          _c(
            'f$i',
            '前段课$i',
            (i % 5) + 1,
            (i ~/ 5) * 2 + 1,
            (i ~/ 5) * 2 + 2,
            weeks: _range(1, 8),
          ),
        for (var i = 0; i < 10; i++)
          _c(
            's$i',
            '后段课$i',
            (i % 5) + 1,
            (i ~/ 5) * 2 + 1,
            (i ~/ 5) * 2 + 2,
            weeks: _range(9, 16),
          ),
      ];
      final m = assignCourseColors(courses);
      final firstHalfColors = {for (var i = 0; i < 10; i++) m['前段课$i']!};
      final secondHalfColors = {for (var i = 0; i < 10; i++) m['后段课$i']!};
      expect(firstHalfColors, hasLength(10));
      expect(secondHalfColors, hasLength(10));
    });

    test('隐藏课程不挤占可见课程的唯一色号', () {
      final courses = [
        for (var i = 0; i < 16; i++)
          _c('v$i', '可见课$i', (i % 5) + 1, (i % 4) * 2 + 1, (i % 4) * 2 + 2),
        _c('h0', '隐藏课0', 1, 1, 2, hidden: true),
      ];
      final m = assignCourseColors(courses);
      final visibleColors = {for (var i = 0; i < 16; i++) m['可见课$i']!};
      expect(visibleColors, hasLength(16));
    });
  });

  group('CA 撞色顺延（晴空清透）', () {
    test('CA03 同一天相邻节次：所有近似对与同色均避开', () {
      for (final (a, b) in kNearColorPairs[CoursePaletteScheme.soft]!) {
        final (ra, rb) = _pair(a, b);
        expect(colorsClash(ra, rb), isFalse, reason: '($a,$b) -> ($ra,$rb)');
      }
      final (r0, r1) = _pair(5, 5);
      expect(r0, isNot(r1));
      expect(colorsClash(r0, r1), isFalse);
    });

    test('CA04 同一节次或节次交叠的相邻两天不撞色', () {
      final na = _nm(_a, 3), nb = _nm(_b, 8);
      final m = assignCourseColors([
        _c('a', na, 1, 1, 2),
        _c('b', nb, 2, 2, 3),
      ]);
      expect(colorsClash(_of(m, na), _of(m, nb)), isFalse);
    });

    test('CA11 课名排序靠后的那门避让，与位置、输入顺序无关', () {
      final na = _nm(_a, 0), nb = _nm(_b, 8);
      final layouts = [
        [_c('a', na, 1, 1, 2), _c('b', nb, 1, 3, 4)],
        [_c('a', na, 1, 3, 4), _c('b', nb, 1, 1, 2)],
        [_c('a', na, 1, 1, 2), _c('b', nb, 2, 1, 2)],
        [_c('a', na, 2, 1, 2), _c('b', nb, 1, 1, 2)],
      ];
      for (final l in layouts) {
        for (final input in [l, l.reversed.toList()]) {
          final m = assignCourseColors(input);
          expect(_of(m, na), 0);
          expect(colorsClash(_of(m, na), _of(m, nb)), isFalse);
        }
      }
    });

    test('CA14 两门手动近似对相邻：都保持手动色号', () {
      final m = assignCourseColors([
        _c('x', '测试课X', 1, 1, 2, color: 1, src: CourseSource.manual),
        _c('y', '测试课Y', 1, 3, 4, color: 12, src: CourseSource.manual),
      ]);
      expect(m['测试课X'], 1);
      expect(m['测试课Y'], 12);
      final ctl = TimetableController.instance..debugReset();
      ctl.debugSetSnapshot(
        const TimetableSnapshot(courses: []),
        manualCourses: [
          _c('x', '测试课X', 1, 1, 2, color: 1, src: CourseSource.manual),
          _c('y', '测试课Y', 1, 3, 4, color: 12, src: CourseSource.manual),
        ],
      );
      expect(
        {for (final c in ctl.combinedCourses) c.id: ctl.colorIndexOf(c)},
        {'x': 1, 'y': 12},
      );
      ctl.debugReset();
    });
  });

  group('conflictsFor', () {
    final courses = [
      _c('a', '甲', 1, 1, 2),
      _c('b', '乙', 1, 2, 3, weeks: _w(16, odd: true)),
      _c('c', '丙', 1, 3, 4, weeks: _w(16, even: true)),
      _c('d', '丁', 2, 1, 2),
      _c('e', '戊', 1, 1, 4, hidden: true),
      _c('f', '己', 1, 1, 1, weeks: '0000000000000001'),
    ];
    final cands = [
      CourseSlot(day: 1, startNode: 2, endNode: 3, weeks: _w(16, even: true)),
      CourseSlot(day: 1, startNode: 1, endNode: 4, weeks: _w(16)),
      CourseSlot(day: 2, startNode: 3, endNode: 4, weeks: _w(16)),
      const CourseSlot(day: 1, startNode: 1, endNode: 1, weeks: '1'),
    ];

    test('weekday + period overlap + weeks intersection; exclude', () {
      expect(courseConflicts(courses, cands[0]).map((c) => c.id), ['a', 'c']);
      expect(courseConflicts(courses, cands[1]).map((c) => c.id), [
        'a',
        'b',
        'c',
        'f',
      ]);
      expect(
        courseConflicts(courses, cands[1], excludeId: 'a').map((c) => c.id),
        ['b', 'c', 'f'],
      );
      expect(courseConflicts(courses, cands[2]), isEmpty);
    });

    test('controller.conflictsFor uses combined courses', () {
      final ctl = TimetableController.instance..debugReset();
      ctl.debugSetSnapshot(
        TimetableSnapshot(courses: courses.sublist(0, 3)),
        manualCourses: courses.sublist(3),
      );
      expect(ctl.conflictsFor(cands[1]).map((c) => c.id), ['a', 'b', 'c', 'f']);
      ctl.debugReset();
    });

    test('F01 form conflict hint reflects conflictsFor', () {
      final ctl = TimetableController.instance..debugReset();
      ctl.debugSetSnapshot(TimetableSnapshot(courses: courses));
      for (final s in cands) {
        for (final ex in [null, 'a', 'c']) {
          final found = ctl.conflictsFor(s, excludeId: ex);
          expect(
            found.map((c) => c.id).toList(),
            courseConflicts(
              courses,
              s,
              excludeId: ex,
            ).map((c) => c.id).toList(),
          );
          final hint = describeManualConflicts(s, found);
          if (found.isEmpty) {
            expect(hint, isNull);
          } else if (found.length == 1) {
            expect(hint, startsWith('与「${found.single.name}」'));
            expect(hint, endsWith('冲突'));
          } else {
            expect(hint, '与 ${found.length} 门课冲突');
          }
        }
      }
      ctl.debugReset();
    });
  });

  group('C02 课名归一化与 FNV-1a 钉死索引 & 自动文字对比度', () {
    test('normalization and pinned indices', () {
      expect(normalizeCourseName(' 学术英语(1) '), '学术英语（1）');
      expect(
        courseColorIndexForName('学术英语(1)'),
        courseColorIndexForName(' 学术英语（1） '),
      );
      expect(courseColorIndexForName('学术英语（1）'), 12);
      expect(courseColorIndexForName('高等数学A（1）'), 4);
      expect(courseColorIndexForName('数据结构'), 12);
      expect(courseColorIndexForName('大学物理'), 5);
      const a = Course(id: 'a', name: '学术英语(1)');
      final ctl = TimetableController.instance..debugReset();
      expect(courseColorIndex(ctl, a), TimetableTheme.colorIndexFor(a.name));
      expect(courseColorIndex(ctl, a.copyWith(colorIndex: 7)), 7);
    });

    double contrast(Color background, Color foreground) {
      final bg = background.computeLuminance();
      final fg = foreground.computeLuminance();
      return bg >= fg ? (bg + 0.05) / (fg + 0.05) : (fg + 0.05) / (bg + 0.05);
    }

    test('预设、自选中灰与强制黑白文字保证可读对比度', () {
      for (final (dark, index, opacity) in [
        (false, 9, 100),
        (false, 10, 30),
        (true, 3, 80),
        (true, 9, 30),
      ]) {
        final pair = TimetableTheme.autoCoursePair(index, dark: dark);
        final bg = TimetableTheme.blendCellBg(pair.bg, opacity, dark: dark);
        final fg = TimetableTheme.readableCellText(bg, pair.fg);
        expect(contrast(bg, fg), greaterThanOrEqualTo(4.5));
        expect(fg.a, 1);
      }
      const rawGray = Color(0xFF808080);
      for (final dark in [false, true]) {
        final bg = TimetableTheme.blendCellBg(rawGray, 100, dark: dark);
        final preferred = TimetableTheme.userCoursePair(bg).fg;
        final fg = TimetableTheme.readableCellText(bg, preferred);
        expect(contrast(bg, fg), greaterThanOrEqualTo(4.5));
        expect(contrast(bg, preferred), lessThan(4.5));
        expect(fg, isNot(preferred));
      }
      const whiteBg = Color(0xFFFFFFFF);
      const preferred = Color(0xFF123456);
      expect(
        TimetableTheme.readableCellText(
          whiteBg,
          preferred.withValues(alpha: 0.4),
        ),
        preferred,
      );
      expect(
        TimetableTheme.cellTextFor(preferred, CellTextColorMode.white),
        TimetableTheme.forcedWhiteText,
      );
      expect(
        TimetableTheme.cellTextFor(preferred, CellTextColorMode.black),
        TimetableTheme.forcedBlackText,
      );
    });
  });

  group('B/C 配色切换与 12 预设色板（§13.7）', () {
    String namedHash(int hash, {String after = ''}) {
      for (var i = 0; i < 100000; i++) {
        final n = '测试课$i';
        if (courseColorIndexForName(n) == hash && n.compareTo(after) > 0) {
          return n;
        }
      }
      throw StateError('no name');
    }

    test('CA16 换方案：自动色按新方案重算顺延，手动色号保留，不落盘', () async {
      final tmp = Directory.systemTemp.createTempSync('tt_scheme_sw');
      TimetableStore.debugDirectory = tmp;
      final ctl = TimetableController.instance..debugReset();
      addTearDown(() {
        TimetableStore.debugDirectory = null;
        ctl.debugReset();
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final a = namedHash(1);
      final b = namedHash(12, after: a);
      final cName = namedHash(5);
      final d = namedHash(11, after: cName);
      final n4 = namedHash(4);
      ctl.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(termStartDate: DateTime(2026, 8, 31)),
        ),
        viewingWeek: 7,
        manualCourses: [
          _c('a', a, 1, 1, 2, src: CourseSource.manual),
          _c('b', b, 1, 3, 4, src: CourseSource.manual),
          _c('c', cName, 3, 1, 2, src: CourseSource.manual),
          _c('d', d, 3, 3, 4, src: CourseSource.manual),
          _c('z', '测试课Z', 5, 1, 2, color: 12, src: CourseSource.manual),
          _c('n', n4, 5, 3, 4, src: CourseSource.manual),
        ],
      );
      Map<String, int>? first;
      for (final k in ['A', 'B', 'C', 'A']) {
        await ctl.updateSettings(ctl.settings.copyWith(paletteScheme: k));
        final m = {
          for (final x in ctl.manualCourses) x.id: ctl.colorIndexOf(x),
        };
        final scheme = coursePaletteSchemeOf(k);
        expect(m.values.toSet(), hasLength(6), reason: k);
        expect(m['z'], 12, reason: k);
        expect(colorsClash(m['a']!, m['b']!, scheme: scheme), isFalse);
        expect(colorsClash(m['c']!, m['d']!, scheme: scheme), isFalse);
        expect(colorsClash(m['z']!, m['n']!, scheme: scheme), isFalse);
        first ??= m;
      }
      expect({
        for (final x in ctl.manualCourses) x.id: ctl.colorIndexOf(x),
      }, first);
    });

    test('12 预设冷暖交错且无 userColors 时 coursePairFor 走防重分配', () {
      expect(TimetableTheme.coursePresetColors, hasLength(12));
      expect(
        TimetableTheme.hueSteppedColors(kCoursePresetCount),
        TimetableTheme.coursePresetColors,
      );
      var streak = 0;
      for (final c in TimetableTheme.coursePresetColors) {
        final hsv = HSVColor.fromColor(c);
        streak = TimetableTheme.isCoolHue(hsv.hue) ? streak + 1 : 0;
        expect(streak, lessThan(3));
        expect(hsv.saturation, greaterThanOrEqualTo(0.30));
        expect(c.computeLuminance(), inInclusiveRange(0.08, 0.90));
      }
      final ctl = TimetableController.instance..debugReset();
      addTearDown(ctl.debugReset);
      ctl.debugSetSnapshot(
        TimetableSnapshot(courses: [_c('MATH|01', '高数', 1, 1, 2)]),
        viewingWeek: 2,
      );
      final pair = coursePairFor(ctl, ctl.courses.single);
      final expected = TimetableTheme.autoCoursePair(
        ctl.colorIndexOf(ctl.courses.single),
      );
      expect(pair.bg.toARGB32(), expected.bg.toARGB32());
      expect(pair.fg.toARGB32(), expected.fg.toARGB32());
      for (final raw in TimetableTheme.coursePresetColors) {
        final light = TimetableTheme.userCoursePair(raw);
        final dark = TimetableTheme.userCoursePair(raw, dark: true);
        expect(light.bg, raw);
        expect(dark.bg, raw);
        expect(dark.fg, light.fg);
      }
      expect(coursePresetIndexForName('高数'), inInclusiveRange(0, 11));
    });
  });
}
