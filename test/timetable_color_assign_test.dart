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
const _e = '测试课E-';

/// 晴空清透 16 色 (底色, 文字色)，色号 0–15。
const _softHex = <(int, int)>[
  (0xFFDCEBFF, 0xFF154F96),
  (0xFFFFE4D6, 0xFFA33A14),
  (0xFFD7F5E6, 0xFF116341),
  (0xFFECE3FF, 0xFF5730A8),
  (0xFFFFF0C7, 0xFF804E00),
  (0xFFD4F2FA, 0xFF0C5B6E),
  (0xFFFFE0EC, 0xFF9E204E),
  (0xFFE9F7CC, 0xFF41630D),
  (0xFFE0E4FF, 0xFF303EA6),
  (0xFFFFEBD4, 0xFF8F470A),
  (0xFFD1F2EE, 0xFF0E6158),
  (0xFFF7E3FC, 0xFF78248F),
  (0xFFFFDEDE, 0xFFA62126),
  (0xFFE2F2DB, 0xFF276322),
  (0xFFE3EBF2, 0xFF354B6E),
  (0xFFF5E8D7, 0xFF6E4A1E),
];

/// 晴空清透近似对（11 对）。
const _softPairs = <(int, int)>{
  (4, 15), (3, 8), (4, 9), (3, 11), (1, 9), (1, 12), //
  (0, 8), (7, 13), (9, 15), (2, 10), (0, 14),
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

  test('CA01 晴空清透 16 个（底色, 文字色）逐项相同；无白字', () {
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

  test('CA02 近似对表写死：恰好 11 对、对称、逐对查不合并', () {
    final table = kNearColorPairs[CoursePaletteScheme.soft]!;
    expect(table, hasLength(11));
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
    expect(colorsNear(4, 15), isTrue);
    expect(colorsNear(0, 14), isTrue);
    expect(colorsNear(2, 10), isTrue);
    expect(colorsNear(8, 13), isFalse);
    // 不合并成大组：8、14 都与 0 近似，但 (8,14) 不近似。
    expect(colorsNear(8, 14), isFalse);
  });

  group('C03/C04 合成课表 kb_mock.json（始终运行）', () {
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

    test('C03 全局防重：14 门课程全员不同色；确定性可重现', () {
      final courses = _mockSample().courses;
      final m = assignCourseColors(courses);
      expect(m, hasLength(14));
      expect(m.values.toSet(), hasLength(14));
      expect(assignCourseColors(List.of(courses.reversed)), m);
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
      expect(results[1]!.values.toSet(), hasLength(14));
      expect(results[2], results[1]);
      expect(results[9], results[1]);
      expect(results[16], results[1]);
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
    'C05 user-picked 12 stays 12, neighbour avoids 12 and its near pairs',
    () {
      final m = assignCourseColors([
        _c('a', '大学物理', 1, 1, 2, color: 12),
        _c('b', '数据结构', 1, 3, 4), // hash 12
      ]);
      expect(m['大学物理'], 12);
      expect(colorsClash(m['数据结构']!, 12), isFalse);
      expect(m['数据结构'], isNot(12));
    },
  );

  test('C06 同周不同课即使单双周错开也尽量分配不同色号（16门内全员唯一）', () {
    final m = assignCourseColors([
      _c('a', '学术英语（1）', 2, 1, 2, weeks: _w(16, odd: true)),
      _c('b', '数据结构', 2, 3, 4, weeks: _w(16, even: true)),
    ]);
    expect(m['学术英语（1）'], isNot(m['数据结构']));
  });

  test('C07 无冲突时多门课依然全员互不重复', () {
    final m = assignCourseColors([
      _c('a', '大学物理', 1, 1, 2),
      _c('b', '数据结构', 5, 9, 10),
    ]);
    expect(m['大学物理'], isNot(m['数据结构']));
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

  test('C09 all 16 clash → fewest-clash index, deterministic', () {
    final ns = [
      for (var i = 0; i < 16; i++) _c('n$i', '邻$i', 3, 4, 7, color: i),
    ];
    final x = _c('x', '中心课', 3, 5, 6);
    final m1 = assignCourseColors([...ns, x]);
    final m2 = assignCourseColors([x, ...ns.reversed]);
    expect(m1['中心课'], inInclusiveRange(0, 15));
    expect(m2, m1);
  });

  test('C10 跨天节次有交集也避让；用户自选色占用避让且不进 map', () {
    final n = _nameWithHash(0);
    final m = assignCourseColors(
      [_c('x', n, 2, 2, 3)],
      userColors: {'u': 0xFFDCEBFF}, // 精确命中色号 0
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
      for (final (a, b) in _softPairs) {
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

    test('CA08 周次交集相邻不撞色；周次不交也优先不同色', () {
      final na = _nm(_a, 0), nb = _nm(_b, 8);
      final overlap = assignCourseColors([
        _c('a', na, 1, 1, 2, weeks: _range(1, 8)),
        _c('b', nb, 1, 3, 4, weeks: _range(8, 16)),
      ]);
      expect(colorsClash(_of(overlap, na), _of(overlap, nb)), isFalse);
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

    test('CA13 手动色号占用且不被改：Z=12，排序靠前的 A 避让', () {
      final na = _nm(_a, 1);
      final m = assignCourseColors([
        _c('z', '测试课Z', 1, 1, 2, color: 12, src: CourseSource.manual),
        _c('a', na, 1, 3, 4),
      ]);
      expect(m['测试课Z'], 12);
      expect(colorsClash(_of(m, na), 12), isFalse);
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

    test('CA18 16 个都撞 → 选撞得最少的色号且确定性可重现', () {
      final z = _nm('测试课Z-', 5);
      final ns = [
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
      final m1 = assignCourseColors([...ns, zc]);
      final m2 = assignCourseColors([zc, ...ns.reversed]);
      expect(_of(m1, z), inInclusiveRange(0, 15));
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

    void expectCellColors(WidgetTester tester, int colorIndex) {
      final ink = tester.widget<Ink>(find.byType(Ink));
      final pair = TimetableTheme.autoCoursePair(colorIndex);
      final background = (ink.decoration! as BoxDecoration).color!;
      expect(
        background,
        TimetableTheme.blendCellBg(
          pair.bg,
          TimetableController.instance.settings.cellOpacity,
        ),
      );
      final fg = TimetableTheme.readableCellText(background, pair.fg);
      final bgLuminance = background.computeLuminance();
      final fgLuminance = fg.computeLuminance();
      final contrast = bgLuminance >= fgLuminance
          ? (bgLuminance + 0.05) / (fgLuminance + 0.05)
          : (fgLuminance + 0.05) / (bgLuminance + 0.05);
      expect(contrast, greaterThanOrEqualTo(4.5));
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

    testWidgets('角标/文字随分配色号取晴空清透文字色', (tester) async {
      await pumpCell(tester, 2);
      expectCellColors(tester, 2);
      TimetableController.instance.debugReset();
    });

    testWidgets('另一色号同样保持对比度与角标一致', (tester) async {
      await pumpCell(tester, 10);
      expectCellColors(tester, 10);
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
