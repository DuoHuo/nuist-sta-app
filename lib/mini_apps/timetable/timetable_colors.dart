// 课程配色分配与学期冲突判定（纯函数，不依赖 Flutter）。
//
// 默认取课名 FNV-1a 哈希色；仅当与“相邻”课程撞色（同色号，或属于当前配色方案
// 近似对表中的一对）时才 +1 mod 16 顺延。用户手动选的 colorIndex 固定不动、不参与顺延，
// 并视为邻居的占用色。顺延只在渲染时计算，不落盘。

import 'timetable_models.dart';

/// 课程配色方案：A 柔和（spec §13.5，默认）、B 马卡龙、C 莫兰迪（§13.7）。
enum CoursePaletteScheme {
  /// A 柔和（默认）。
  soft,

  /// B 马卡龙。
  macaron,

  /// C 莫兰迪。
  morandi,
}

/// 设置里存的方案字母（'A'/'B'/'C'）→ 方案；其他值按 A。
CoursePaletteScheme coursePaletteSchemeOf(String? key) => switch (key) {
  'B' => CoursePaletteScheme.macaron,
  'C' => CoursePaletteScheme.morandi,
  _ => CoursePaletteScheme.soft,
};

/// 方案 → 设置里存的字母。
String coursePaletteSchemeKey(CoursePaletteScheme s) => switch (s) {
  CoursePaletteScheme.soft => 'A',
  CoursePaletteScheme.macaron => 'B',
  CoursePaletteScheme.morandi => 'C',
};

/// 设置页显示名。
String coursePaletteSchemeLabel(CoursePaletteScheme s) => switch (s) {
  CoursePaletteScheme.soft => 'A 柔和',
  CoursePaletteScheme.macaron => 'B 马卡龙',
  CoursePaletteScheme.morandi => 'C 莫兰迪',
};

const CoursePaletteScheme kDefaultCoursePaletteScheme =
    CoursePaletteScheme.soft;

/// 各方案的近似色对（0-based 色号，写死，不在运行时算色相）。
/// 逐对查，不合并成大组：例如 (0,3)、(0,7) 近似，但 (3,7) 不近似。
const Map<CoursePaletteScheme, List<(int, int)>> kNearColorPairs = {
  // spec §13.5：按文字色 Lab 色相角相差 ≤ 23° 预先算好的 13 对。
  CoursePaletteScheme.soft: [
    (0, 7),
    (1, 12),
    (3, 8),
    (6, 14),
    (0, 8),
    (4, 12),
    (7, 15),
    (3, 13),
    (1, 10),
    (7, 8),
    (0, 15),
    (1, 4),
    (0, 3),
  ],
  // spec §13.7：按底色 Lab 色相角相差 ≤ 23° 的 9 对（写死，不现算）。
  CoursePaletteScheme.macaron: [
    (0, 7),
    (0, 15),
    (3, 8),
    (3, 13),
    (4, 12),
    (5, 11),
    (6, 14),
    (7, 8),
    (13, 14),
  ],
  // spec §13.7：9 对；(2,7) 23.0°、(1,12) 23.3° 不算。
  CoursePaletteScheme.morandi: [
    (0, 15),
    (2, 9),
    (3, 13),
    (4, 7),
    (4, 9),
    (4, 12),
    (6, 14),
    (7, 9),
    (13, 14),
  ],
};

/// 两个 0-based 色号在 [scheme] 下是否属于近似对（对称；同色号不算近似）。
bool colorsNear(
  int a,
  int b, {
  CoursePaletteScheme scheme = kDefaultCoursePaletteScheme,
}) {
  if (a == b) return false;
  for (final (x, y) in kNearColorPairs[scheme] ?? const <(int, int)>[]) {
    if ((x == a && y == b) || (x == b && y == a)) return true;
  }
  return false;
}

/// 两个 0-based 色号是否“撞色”：相等，或在 [scheme] 的近似对表中。
bool colorsClash(
  int a,
  int b, {
  CoursePaletteScheme scheme = kDefaultCoursePaletteScheme,
}) => a == b || colorsNear(a, b, scheme: scheme);

/// 两个周次位串是否有交集（等价于周掩码按位与非空）。
bool weeksIntersect(String a, String b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a.codeUnitAt(i) == 0x31 && b.codeUnitAt(i) == 0x31) return true;
  }
  return false;
}

/// 两个时段是否“相邻”：同一天节次相接/重叠，或同节次范围左右相邻两天；
/// 且周次有交集。
bool slotsAdjacent(CourseSlot a, CourseSlot b) {
  if (!a.hasFixedTime || !b.hasFixedTime) return false;
  var spatial = false;
  if (a.day == b.day) {
    spatial = a.startNode <= b.endNode + 1 && b.startNode <= a.endNode + 1;
  } else if ((a.day - b.day).abs() == 1) {
    spatial = a.startNode == b.startNode && a.endNode == b.endNode;
  }
  return spatial && weeksIntersect(a.weeks, b.weeks);
}

/// 两个时段是否冲突：同星期 + 节次重叠 + 周次相交。
bool slotsConflict(CourseSlot a, CourseSlot b) =>
    a.hasFixedTime &&
    b.hasFixedTime &&
    a.day == b.day &&
    a.startNode <= b.endNode &&
    b.startNode <= a.endNode &&
    weeksIntersect(a.weeks, b.weeks);

/// 学期级冲突：[courses] 中与 [candidate] 任一时段冲突的课程（保持输入顺序）。
/// 跳过隐藏课程与 id == [excludeId] 的课程（编辑自身时传入）。
List<Course> courseConflicts(
  Iterable<Course> courses,
  CourseSlot candidate, {
  String? excludeId,
}) => [
  for (final c in courses)
    if (!c.hidden &&
        (excludeId == null || c.id != excludeId) &&
        c.slots.any((s) => slotsConflict(s, candidate)))
      c,
];

/// 全学期配色：key 为 [normalizeCourseName] 后的课名，value 为 0-based 色号。
///
/// 按课名排序依次分配；与已定色的相邻课（含手动色号的课）撞色时，排序靠后的那门
/// 从哈希色号起 +1 顺延，跳过所有与相邻课相同或近似（[scheme] 近似对表）的色号；
/// 16 个都撞时取撞得最少的色号（同数取最小）。手动色号的课保持原样。
Map<String, int> assignCourseColors(
  List<Course> courses, {
  CoursePaletteScheme scheme = kDefaultCoursePaletteScheme,
}) {
  final slotsByName = <String, List<CourseSlot>>{};
  final fixed = <String, int>{};
  for (final c in courses) {
    final key = normalizeCourseName(c.name);
    (slotsByName[key] ??= []).addAll(c.slots);
    final ci = c.colorIndex;
    if (ci != null && ci >= 0 && ci < kCoursePaletteSize) {
      fixed.putIfAbsent(key, () => ci);
    }
  }
  final names = slotsByName.keys.toList()..sort();

  final neighbours = <String, Set<String>>{for (final n in names) n: {}};
  for (var i = 0; i < names.length; i++) {
    for (var j = i + 1; j < names.length; j++) {
      final a = names[i], b = names[j];
      final adjacent = slotsByName[a]!.any(
        (sa) => slotsByName[b]!.any((sb) => slotsAdjacent(sa, sb)),
      );
      if (adjacent) {
        neighbours[a]!.add(b);
        neighbours[b]!.add(a);
      }
    }
  }

  final result = <String, int>{...fixed};
  for (final name in names) {
    if (result.containsKey(name)) continue;
    final used = [
      for (final n in neighbours[name]!)
        if (result[n] != null) result[n]!,
    ];
    int clashCount(int c) =>
        used.where((u) => colorsClash(c, u, scheme: scheme)).length;
    final start = courseColorIndexForName(name);
    int? chosen;
    for (var k = 0; k < kCoursePaletteSize; k++) {
      final c = (start + k) % kCoursePaletteSize;
      if (clashCount(c) == 0) {
        chosen = c;
        break;
      }
    }
    if (chosen == null) {
      // 16 个都撞：取撞色邻居最少的色号，平局取最小色号（确定性）。
      var best = 0, bestCount = clashCount(0);
      for (var c = 1; c < kCoursePaletteSize; c++) {
        final n = clashCount(c);
        if (n < bestCount) {
          best = c;
          bestCount = n;
        }
      }
      chosen = best;
    }
    result[name] = chosen;
  }
  return result;
}
