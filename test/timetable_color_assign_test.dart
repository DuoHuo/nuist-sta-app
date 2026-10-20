import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_colors.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_manual_course_form.dart';

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
const _realKb = '$_fx/kb_real_sample.json';

/// 真实样例 git-ignore、只在本地；不在时跳过相关测试。
bool get _realPresent => File(_realKb).existsSync();

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

TimetableSnapshot _realSample() => _sample(_realKb);

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
const _d = '测试课D-';
const _e = '测试课E-';

/// §13.5 A 柔和 (底色, 文字色)，色号 0–15。
const _softHex = <(int, int)>[
  (0xFFDCE8FB, 0xFF1F4E99),
  (0xFFFCE3D6, 0xFF9A3E1C),
  (0xFFDCF1E2, 0xFF1E6B3A),
  (0xFFE9E0FA, 0xFF5B36A8),
  (0xFFFBEBC8, 0xFF7F4A00),
  (0xFFD5EFF0, 0xFF145F66),
  (0xFFFADDE8, 0xFF9C2857),
  (0xFFE3E7EF, 0xFF3F4A60),
  (0xFFDEE2FB, 0xFF3240A8),
  (0xFFE8F0D2, 0xFF4A6214),
  (0xFFFBDCDC, 0xFFA3282A),
  (0xFFD3EEE8, 0xFF17665A),
  (0xFFF6E3D3, 0xFF82431A),
  (0xFFF1DDF5, 0xFF7D2F8F),
  (0xFFFCDCEF, 0xFFA0236C),
  (0xFFD6EAF8, 0xFF1B5B87),
];

/// §13.5 A 柔和近似对（13 对）。
const _softPairs = <(int, int)>{
  (0, 7), (1, 12), (3, 8), (6, 14), (0, 8), (4, 12), (7, 15), //
  (3, 13), (1, 10), (7, 8), (0, 15), (1, 4), (0, 3),
};

/// 相邻两门（同一天上下相接）跑配色，返回 (A, B) 结果。
(int, int) _pair(int hashA, int hashB) {
  final na = _nm(_a, hashA), nb = _nm(_b, hashB);
  final m = assignCourseColors([_c('a', na, 1, 1, 2), _c('b', nb, 1, 3, 4)]);
  return (_of(m, na), _of(m, nb));
}

void main() {
  test('palette is 0-based, 16 entries; pair table within 0..15', () {
    expect(TimetableTheme.coursePalette.length, 16);
    expect(TimetableTheme.coursePaletteText.length, 16);
    expect(kCoursePaletteSize, 16);
    for (final (x, y) in kNearColorPairs[CoursePaletteScheme.soft]!) {
      expect(x, inInclusiveRange(0, 15));
      expect(y, inInclusiveRange(0, 15));
    }
  });

  test('CA01 A 柔和 16 个（底色, 文字色）与 §13.5 逐项相同；无白字', () {
    expect(kDefaultCoursePaletteScheme, CoursePaletteScheme.soft);
    final pairs = TimetableTheme.coursePalettes[CoursePaletteScheme.soft]!;
    expect(pairs, hasLength(16));
    for (var i = 0; i < 16; i++) {
      expect(pairs[i].bg, Color(_softHex[i].$1), reason: '色号 $i 底色');
      expect(pairs[i].fg, Color(_softHex[i].$2), reason: '色号 $i 文字色');
      expect(TimetableTheme.courseColor(i), pairs[i].bg);
      expect(TimetableTheme.courseTextColor(i), pairs[i].fg);
      expect(TimetableTheme.coursePalette[i], pairs[i].bg);
      expect(TimetableTheme.coursePaletteText[i], pairs[i].fg);
      expect(pairs[i].fg, isNot(Colors.white));
      expect(pairs[i].fg.a, 1.0);
    }
    expect(TimetableTheme.pageBg, const Color(0xFFF5F6F8));
  });

  test('CA02 近似对表写死：恰好 13 对、对称、逐对查不合并', () {
    final table = kNearColorPairs[CoursePaletteScheme.soft]!;
    expect(table, hasLength(13));
    expect(table.toSet(), _softPairs);
    final found = <(int, int)>{};
    for (var a = 0; a < 16; a++) {
      for (var b = 0; b < 16; b++) {
        expect(colorsNear(a, b), colorsNear(b, a), reason: '($a,$b) 对称');
        if (a < b && colorsNear(a, b)) found.add((a, b));
      }
      expect(colorsNear(a, a), isFalse);
      expect(colorsClash(a, a), isTrue);
    }
    expect(found, _softPairs);
    // 边界对
    expect(colorsNear(0, 3), isTrue);
    expect(colorsNear(0, 15), isTrue);
    expect(colorsNear(1, 4), isTrue);
    expect(colorsNear(8, 13), isFalse);
    expect(colorsNear(2, 11), isFalse);
    // 不合并成大组：3、7 都与 0 近似，但 (3,7) 不近似。
    expect(colorsNear(3, 7), isFalse);
    // 旧分组 {1,11}、{0,8,14}、{3,9}、{5,12}、{6,15} 作废。
    expect(colorsClash(1, 11), isFalse);
    expect(colorsClash(0, 14), isFalse);
    expect(colorsClash(6, 15), isFalse);
  });

  group('C03/C04 合成课表 kb_mock.json（始终运行）', () {
    test('C03 前提：哈希与相邻关系符合预期（防止 fixture 被改坏）', () {
      final names = _mockSample().courses
          .map((c) => normalizeCourseName(c.name))
          .toSet();
      expect(names, hasLength(14));
      // 撞同色：程序设计基础 / 高等数学A 都哈希到 10，周一 1-2 与 3-4 相接
      expect(courseColorIndexForName('程序设计基础'), 10);
      expect(courseColorIndexForName('高等数学A'), 10);
      // 链式顺延：离散数学 8，邻居 数字逻辑 8、大学英语（3） 9、数字电路 7
      expect(courseColorIndexForName('离散数学'), 8);
      expect(courseColorIndexForName('数字逻辑'), 8);
      expect(courseColorIndexForName('算法设计'), 12);
      expect(courseColorIndexForName('大学英语（3）'), 9);
      // 左右相邻同节次且撞色：大学物理B / 概率论与数理统计 都是 5
      expect(courseColorIndexForName('大学物理B'), 5);
      expect(courseColorIndexForName('概率论与数理统计'), 5);
      // 同色但周次不相交（单周 vs 双周）→ 不算相邻
      expect(courseColorIndexForName('线性代数B'), 1);
      expect(courseColorIndexForName('大学物理实验B'), 1);
    });

    test('C03 撞色顺延：排序靠后者顺延，含多步顺延；周次不交不顺延', () {
      final courses = _mockSample().courses;
      final m = assignCourseColors(courses);
      // 「程」< 「高」：程序设计基础保留 10，高等数学A 顺延到 11
      expect(m['程序设计基础'], 10);
      expect(m['高等数学A'], 11);
      // 大学物理B 保留 5，概率论与数理统计顺延到 6
      expect(m['大学物理B'], 5);
      expect(m['概率论与数理统计'], 6);
      // 离散数学：8 撞 数字逻辑(8)，9 撞 大学英语（3）(9) → 10（两步）
      expect(m['数字逻辑'], 8);
      expect(m['算法设计'], 12);
      expect(m['大学英语（3）'], 9);
      expect(m['离散数学'], 10);
      // 单周 vs 双周不相交：都保留哈希色 1
      expect(m['线性代数B'], 1);
      expect(m['大学物理实验B'], 1);
      // 其余课保持哈希色
      for (final n in ['数字电路', '电路分析', '大学化学', '形势与政策']) {
        expect(m[n], courseColorIndexForName(n), reason: n);
      }
    });

    test('C03 全表无相邻撞色；结果确定、与输入顺序无关', () {
      final courses = _mockSample().courses;
      final a = assignCourseColors(courses);
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
      expect(results[2], results[1]);
      expect(results[9], results[1]);
      expect(results[16], results[1]);
      expect(results[1]!['MK000101|01'], 11); // 高等数学A 顺延后的色号
      ctl.debugReset();
    });
  });

  group('C03/C04 真实样例（仅本地存在时运行）', () {
    test('C03 real sample: 学术英语（1） vs 数据结构 do not clash; deterministic', () {
      final courses = _realSample().courses;
      final names = courses.map((c) => normalizeCourseName(c.name)).toSet();
      expect(names, containsAll(['学术英语（1）', '数据结构']));
      final a = assignCourseColors(courses);
      final b = assignCourseColors(List.of(courses.reversed));
      expect(colorsClash(a['学术英语（1）']!, a['数据结构']!), isFalse);
      expect(assignCourseColors(courses), a);
      expect(b, a);
    });

    test('C04 colorIndexOf independent of viewing week', () {
      final ctl = TimetableController.instance..debugReset();
      final snap = _realSample();
      final results = <int, Map<String, int>>{};
      for (final w in [1, 5, 12]) {
        ctl.debugSetSnapshot(snap, viewingWeek: w, manualCourses: const []);
        results[w] = {
          for (final c in ctl.combinedCourses) c.id: ctl.colorIndexOf(c),
        };
      }
      expect(results[5], results[1]);
      expect(results[12], results[1]);
      ctl.debugReset();
    });
  }, skip: _realPresent ? false : 'real sample not present');

  test(
    'C05 user-picked 12 stays 12, neighbour avoids 12 and its pairs (1,4)',
    () {
      final m = assignCourseColors([
        _c('a', '大学物理', 1, 1, 2, color: 12),
        _c('b', '数据结构', 1, 3, 4), // hash 12
      ]);
      expect(m['大学物理'], 12);
      expect(colorsClash(m['数据结构']!, 12), isFalse);
      // 12 同色 → 13：与 12 不同也不近似。
      expect(m['数据结构'], 13);
    },
  );

  test('C06 odd-only vs even-only adjacent same-hash keep same color', () {
    final m = assignCourseColors([
      _c('a', '学术英语（1）', 2, 1, 2, weeks: _w(16, odd: true)),
      _c('b', '数据结构', 2, 3, 4, weeks: _w(16, even: true)),
    ]);
    expect(m['学术英语（1）'], 12);
    expect(m['数据结构'], 12);
  });

  test('C07 non-colliding courses keep hash color', () {
    final m = assignCourseColors([
      _c('a', '大学物理', 1, 1, 2),
      _c('b', '数据结构', 5, 9, 10),
    ]);
    expect(m['大学物理'], courseColorIndexForName('大学物理'));
    expect(m['数据结构'], courseColorIndexForName('数据结构'));
  });

  test('C08 hash 10 between picked 10 and 1: 10 同色 → 11 合法', () {
    final n = _nameWithHash(10);
    final m = assignCourseColors([
      _c('p1', 'P甲', 3, 1, 2, color: 10),
      _c('p2', 'P乙', 3, 5, 6, color: 1),
      _c('x', n, 3, 3, 4),
    ]);
    // 10 与邻居同色；11 与 10、1 都不同也不在近似对表里（旧分组 {1,11} 已作废）。
    expect(m[normalizeCourseName(n)], 11);
  });

  test('C09 all 16 clash → fewest-clash index, lowest tie, deterministic', () {
    final ns = [
      for (var i = 0; i < 16; i++) _c('n$i', '邻$i', 3, 4, 7, color: i),
    ];
    final x = _c('x', '中心课', 3, 5, 6);
    final m1 = assignCourseColors([...ns, x]);
    final m2 = assignCourseColors([x, ...ns.reversed]);
    // 不在任何近似对里的最小色号 2 只撞 1 个邻居（同色）。
    expect(m1['中心课'], 2);
    expect(m2, m1);
  });

  test('C10 default 0 next to picked 14 keeps 0; next to picked 7 → 1', () {
    final n = _nameWithHash(0);
    final m1 = assignCourseColors([
      _c('p', 'P丙', 2, 1, 2, color: 14),
      _c('x', n, 2, 3, 4),
    ]);
    // (0,14) 不在 A 柔和近似对表里（旧分组 {0,8,14} 已作废）。
    expect(m1[normalizeCourseName(n)], 0);
    final m2 = assignCourseColors([
      _c('p', 'P丙', 2, 1, 2, color: 7),
      _c('x', n, 2, 3, 4),
    ]);
    expect(m2[normalizeCourseName(n)], 1);
  });

  group('CA 撞色顺延（A 柔和 §13.5，测试文档 23.5.1）', () {
    test('CA03 同一天相邻节次：0 与 7 → 7 近似 → 8 近似 → 9', () {
      expect(_pair(0, 7), (0, 9));
    });

    test('CA04 同一节次相邻两天：(3,13) 近似 → B 为 14', () {
      final na = _nm(_a, 3), nb = _nm(_b, 13);
      final m = assignCourseColors([
        _c('a', na, 1, 1, 2),
        _c('b', nb, 2, 1, 2),
      ]);
      expect(_of(m, na), 3);
      expect(_of(m, nb), 14);
    });

    test('CA05 同色号相邻：B 改为 6，A 保持 5', () {
      expect(_pair(5, 5), (5, 6));
    });

    test('CA06 非近似对相邻不顺延：(2,11)、(8,13)', () {
      expect(_pair(2, 11), (2, 11));
      expect(_pair(11, 2), (11, 2));
      expect(_pair(8, 13), (8, 13));
      expect(_pair(13, 8), (13, 8));
    });

    test('边界近似对相邻要顺延：(0,3)、(0,15)、(1,4)', () {
      // 3 与 0 近似 → 4 合法。
      expect(_pair(0, 3), (0, 4));
      // 15 与 0 近似 → 绕回 0 同色 → 1 合法。
      expect(_pair(0, 15), (0, 1));
      // 4 与 1 近似 → 5 合法。
      expect(_pair(1, 4), (1, 5));
    });

    test('CA07 不挨着不算相邻（中间空节次 / 对角）', () {
      final na = _nm(_a, 0), nb = _nm(_b, 7);
      final gap = assignCourseColors([
        _c('a', na, 1, 1, 2),
        _c('b', nb, 1, 5, 6),
      ]);
      expect(_of(gap, nb), 7);
      final diag = assignCourseColors([
        _c('a', na, 1, 1, 2),
        _c('b', nb, 2, 3, 4),
      ]);
      expect(_of(diag, nb), 7);
    });

    test('CA08 周次不重叠不算相邻；有交集则按近似对顺延', () {
      final na = _nm(_a, 0), nb = _nm(_b, 7);
      final oddEven = assignCourseColors([
        _c('a', na, 1, 1, 2, weeks: _w(16, odd: true)),
        _c('b', nb, 1, 3, 4, weeks: _w(16, even: true)),
      ]);
      expect(_of(oddEven, nb), 7);
      final overlap = assignCourseColors([
        _c('a', na, 1, 1, 2, weeks: _range(1, 8)),
        _c('b', nb, 1, 3, 4, weeks: _range(8, 16)),
      ]);
      expect(_of(overlap, na), 0);
      expect(_of(overlap, nb), 9);
    });

    test('CA09 色号 0 与多个色号近似时仍能找到合法颜色', () {
      final up = _nm(_a, 3), down = _nm(_b, 1);
      final left = _nm(_cc, 8), right = _nm(_d, 15);
      final e = _nm(_e, 0);
      final m = assignCourseColors([
        _c('e', e, 3, 3, 4),
        _c('u', up, 3, 1, 2),
        _c('dn', down, 3, 5, 6),
        _c('l', left, 2, 3, 4),
        _c('r', right, 4, 3, 4),
      ]);
      // 0 与 3/8/15 近似 → 1 与下邻居相同 → 2 合法。
      expect(_of(m, e), 2);
      expect(_of(m, up), 3);
      expect(_of(m, down), 1);
      expect(_of(m, left), 8);
      expect(_of(m, right), 15);
    });

    test('CA10 顺延过 15 绕回：7 与 15 → 0 近似 → 1', () {
      expect(_pair(7, 15), (7, 1));
    });

    test('CA11 课名排序靠后的那门移动，与位置、输入顺序无关', () {
      final na = _nm(_a, 0), nb = _nm(_b, 3);
      final layouts = [
        [_c('a', na, 1, 1, 2), _c('b', nb, 1, 3, 4)], // A 上 B 下
        [_c('a', na, 1, 3, 4), _c('b', nb, 1, 1, 2)], // B 上 A 下
        [_c('a', na, 1, 1, 2), _c('b', nb, 2, 1, 2)], // A 左 B 右
        [_c('a', na, 2, 1, 2), _c('b', nb, 1, 1, 2)], // B 左 A 右
      ];
      for (final l in layouts) {
        for (final input in [l, l.reversed.toList()]) {
          final m = assignCourseColors(input);
          expect(_of(m, na), 0);
          expect(_of(m, nb), 4);
        }
      }
    });

    test('CA12 只移动真正撞色的课', () {
      final na = _nm(_a, 1), nb = _nm(_b, 10), nc = _nm(_cc, 5);
      final m = assignCourseColors([
        _c('a', na, 1, 1, 2),
        _c('b', nb, 1, 3, 4),
        _c('c', nc, 1, 5, 6),
      ]);
      expect(_of(m, na), 1);
      expect(_of(m, nb), 11);
      expect(_of(m, nc), 5);
    });

    test('CA13 手动色号占用且不被改：Z=12，排序靠前的 A 也要避让 → 5', () {
      final na = _nm(_a, 4);
      final m = assignCourseColors([
        _c('z', '测试课Z', 1, 1, 2, color: 12, src: CourseSource.manual),
        _c('a', na, 1, 3, 4),
      ]);
      expect(m['测试课Z'], 12);
      expect(_of(m, na), 5);
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

    test('CA15 确定性：多次运行、打乱输入顺序结果相同', () {
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
      expect(assignCourseColors(scenario), first);
    });

    test('CA18 16 个都撞 → 选撞得最少的色号（同数取最小）', () {
      final z = _nm('测试课Z-', 5);
      // 周围 8 个手动邻居：0、1、2、5、6、9、11、13。
      final ns = [
        _c('n0', '邻0', 2, 1, 4, color: 0), // 左
        _c('n1', '邻1', 4, 1, 4, color: 1), // 右
        _c('n2', '邻2', 3, 5, 6, color: 2), // 下
        _c('n5', '邻5', 3, 1, 2, color: 5),
        _c('n6', '邻6', 3, 3, 4, color: 6),
        _c('n9', '邻9', 3, 1, 4, color: 9),
        _c('n11', '邻11', 3, 2, 3, color: 11),
        _c('n13', '邻13', 3, 4, 5, color: 13),
      ];
      final zc = _c('z', z, 3, 1, 4);
      final m1 = assignCourseColors([...ns, zc]);
      final m2 = assignCourseColors([zc, ...ns.reversed]);
      // 色号 3 撞 2 个（13 同组、0 近似），其余都只撞 1 个 → 取最小 0。
      expect(_of(m1, z), 0);
      expect(m2, m1);
    });
  });

  group('CA17 角标用该课文字色（不透明）', () {
    Future<void> pumpCell(WidgetTester tester, int colorIndex) async {
      final ctl = TimetableController.instance..debugReset();
      final course = _c('k', '测试课K', 1, 1, 2, color: colorIndex);
      ctl.debugSetSnapshot(TimetableSnapshot(courses: [course]));
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: CourseCell(
              controller: ctl,
              cell: GridCell(
                course: course,
                slot: course.slots.first,
                conflictCount: 1,
                activeThisWeek: true,
              ),
              stackCount: 2,
              width: 60,
              height: TimetableTheme.periodHeight * 2,
              radius: TimetableTheme.cellRadius,
            ),
          ),
        ),
      );
    }

    void expectCellColors(WidgetTester tester, Color fg) {
      final ink = tester.widget<Ink>(find.byType(Ink));
      final pair = TimetableTheme.autoCoursePair(
        coursePresetIndexForCourse(
          Course(id: 'k', name: '测试课K', slots: const []),
        ),
      );
      expect((ink.decoration! as BoxDecoration).color, pair.bg);
      final dot = tester.widget<Container>(
        find.byKey(const Key('course_cell_conflict_dot')),
      );
      expect((dot.decoration! as BoxDecoration).color, fg);
      final badge = tester.widget<Container>(
        find.byKey(const Key('course_cell_stack_badge')),
      );
      final border = (badge.decoration! as BoxDecoration).border! as Border;
      expect(border.top.color, fg);
      final badgeText = tester.widget<Text>(find.text('2 门'));
      expect(badgeText.style!.color, fg);
      final name = tester.widget<Text>(
        find.descendant(
          of: find.byType(CourseNameText),
          matching: find.byType(Text),
        ),
      );
      expect(name.style!.color, fg);
      expect(fg.a, 1.0);
      expect(find.byType(Opacity), findsNothing);
    }

    testWidgets('角标/文字用 id 哈希自动色（忽略旧 colorIndex）', (tester) async {
      await pumpCell(tester, 2);
      expectCellColors(
        tester,
        TimetableTheme.autoCoursePair(
          coursePresetIndexForCourse(
            Course(id: 'k', name: '测试课K', slots: const []),
          ),
        ).fg,
      );
      TimetableController.instance.debugReset();
    });

    testWidgets('另一旧色号仍同 id 同色', (tester) async {
      await pumpCell(tester, 10);
      expectCellColors(
        tester,
        TimetableTheme.autoCoursePair(
          coursePresetIndexForCourse(
            Course(id: 'k', name: '测试课K', slots: const []),
          ),
        ).fg,
      );
      TimetableController.instance.debugReset();
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
}
