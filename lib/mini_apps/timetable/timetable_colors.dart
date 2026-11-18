// 课程配色分配与学期冲突判定（纯函数，不依赖 Flutter）。
//
// 默认优先保证所有可见课程颜色互不重复（先保证同周不同色，再保证全学期不同色，
// 16 色以上时再兜底避开相邻与近似色对）。用户手动选的 colorIndex 与 userColors
// 固定不动，并作为其他自动课的占用参考色。

import 'dart:math' as math;

import 'timetable_models.dart';

/// 课程配色方案：A 晴空清透（默认）、B 马卡龙、C 莫兰迪（§13.7）。
enum CoursePaletteScheme {
  /// A 晴空清透（默认）。
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
  CoursePaletteScheme.soft => 'A 晴空清透',
  CoursePaletteScheme.macaron => 'B 马卡龙',
  CoursePaletteScheme.morandi => 'C 莫兰迪',
};

const CoursePaletteScheme kDefaultCoursePaletteScheme =
    CoursePaletteScheme.soft;

/// 各方案的 16 个浅色底色 ARGB，供纯 Dart 层将用户自选色映射到最近似色号。
const Map<CoursePaletteScheme, List<int>> kPaletteLightBgArgb = {
  CoursePaletteScheme.soft: [
    0xFFDCEBFF, // 0 晴空蓝
    0xFFFFE4D6, // 1 珊瑚橙
    0xFFD7F5E6, // 2 薄荷绿
    0xFFECE3FF, // 3 薰衣紫
    0xFFFFF0C7, // 4 蜜柚黄
    0xFFD4F2FA, // 5 冰川青
    0xFFFFE0EC, // 6 蔷薇粉
    0xFFE9F7CC, // 7 青柠绿
    0xFFE0E4FF, // 8 矢车菊
    0xFFFFEBD4, // 9 蜜桃杏
    0xFFD1F2EE, // 10 翡翠青
    0xFFF7E3FC, // 11 丁香紫
    0xFFFFDEDE, // 12 莓果红
    0xFFE2F2DB, // 13 森林绿
    0xFFE3EBF2, // 14 雾霾蓝
    0xFFF5E8D7, // 15 焦糖沙
  ],
  CoursePaletteScheme.macaron: [
    0xFFA8D8FF,
    0xFFFFC2A8,
    0xFFB5E5B9,
    0xFFD5C2FF,
    0xFFFFE29A,
    0xFF9FE3DD,
    0xFFFFB8D1,
    0xFFC9D3E6,
    0xFFB3BEFF,
    0xFFD6EBA0,
    0xFFFFB3B3,
    0xFFA3E6CF,
    0xFFF2CFA8,
    0xFFE8BFF2,
    0xFFFFBDE6,
    0xFFAEE0F5,
  ],
  CoursePaletteScheme.morandi: [
    0xFFB7C9D6,
    0xFFD8B9A8,
    0xFFB9C8B0,
    0xFFC6B8D0,
    0xFFD9CBA6,
    0xFFA9C6C1,
    0xFFD4AFB9,
    0xFFC2C2BA,
    0xFFB3B8D3,
    0xFFC8CDA6,
    0xFFD6ADA8,
    0xFFA8C4B4,
    0xFFD2BFA6,
    0xFFCDB4C9,
    0xFFD9B3C3,
    0xFFADC3D3,
  ],
};

/// 将任意 ARGB 颜色映射到 [scheme] 下视觉最接近的 0..15 色号（加权 sRGB 距离）。
int nearestPaletteIndexForArgb(
  int argb, {
  CoursePaletteScheme scheme = kDefaultCoursePaletteScheme,
}) {
  final list =
      kPaletteLightBgArgb[scheme] ??
      kPaletteLightBgArgb[kDefaultCoursePaletteScheme]!;
  final r1 = (argb >> 16) & 0xFF;
  final g1 = (argb >> 8) & 0xFF;
  final b1 = argb & 0xFF;
  var best = 0;
  var bestDist = 1 << 30;
  for (var i = 0; i < list.length; i++) {
    final c = list[i];
    final dr = r1 - ((c >> 16) & 0xFF);
    final dg = g1 - ((c >> 8) & 0xFF);
    final db = b1 - (c & 0xFF);
    final dist = 2 * dr * dr + 4 * dg * dg + 3 * db * db;
    if (dist < bestDist) {
      bestDist = dist;
      best = i;
    }
  }
  return best;
}

/// 将导入课表的任意 ARGB 原色自动适配到 [scheme] 下最接近的 0..15 配色色号。
///
/// 若原色已是相近浅色底则优先按加权 sRGB 距离精确命中；
/// 对高饱和或深色原色（如 WakeUp 默认色板）按 HSL 色相与饱和度匹配同色系。
int adaptedPaletteIndexForArgb(
  int argb, {
  CoursePaletteScheme scheme = kDefaultCoursePaletteScheme,
}) {
  final list =
      kPaletteLightBgArgb[scheme] ??
      kPaletteLightBgArgb[kDefaultCoursePaletteScheme]!;
  final r1 = (argb >> 16) & 0xFF;
  final g1 = (argb >> 8) & 0xFF;
  final b1 = argb & 0xFF;

  var bestRgb = 0;
  var bestRgbDist = 1 << 30;
  for (var i = 0; i < list.length; i++) {
    final c = list[i];
    final dr = r1 - ((c >> 16) & 0xFF);
    final dg = g1 - ((c >> 8) & 0xFF);
    final db = b1 - (c & 0xFF);
    final dist = 2 * dr * dr + 4 * dg * dg + 3 * db * db;
    if (dist < bestRgbDist) {
      bestRgbDist = dist;
      bestRgb = i;
    }
  }
  if (bestRgbDist <= 4000) return bestRgb;

  final (h1, s1, l1) = _rgbToHsl(r1, g1, b1);
  if (s1 < 0.12) return bestRgb;

  var bestIdx = bestRgb;
  var bestScore = double.infinity;
  for (var i = 0; i < list.length; i++) {
    final c = list[i];
    final (h2, s2, l2) = _rgbToHsl((c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF);
    final rawDiff = (h1 - h2).abs();
    final hueDiff = math.min(rawDiff, 360.0 - rawDiff);
    final satDiff = (s1 - s2).abs();
    final lightDiff = (l1 - l2).abs();
    final score = hueDiff * 1.5 + satDiff * 18.0 + lightDiff * 10.0;
    if (score < bestScore) {
      bestScore = score;
      bestIdx = i;
    }
  }
  return bestIdx;
}

(double, double, double) _rgbToHsl(int rInt, int gInt, int bInt) {
  final r = rInt / 255.0;
  final g = gInt / 255.0;
  final b = bInt / 255.0;
  final maxC = math.max(r, math.max(g, b));
  final minC = math.min(r, math.min(g, b));
  final l = (maxC + minC) / 2.0;
  final d = maxC - minC;
  if (d == 0) return (0.0, 0.0, l);
  final s = l > 0.5 ? d / (2.0 - maxC - minC) : d / (maxC + minC);
  double h;
  if (maxC == r) {
    h = (g - b) / d + (g < b ? 6.0 : 0.0);
  } else if (maxC == g) {
    h = (b - r) / d + 2.0;
  } else {
    h = (r - g) / d + 4.0;
  }
  return (h * 60.0, s, l);
}

/// 各方案的近似色对（0-based 色号，写死，不在运行时算色相）。
/// 逐对查，不合并成大组：例如 (0,8)、(0,14) 近似，但 (8,14) 不近似。
const Map<CoursePaletteScheme, List<(int, int)>> kNearColorPairs = {
  // 晴空清透 16 色：按文字色 CIE Lab 色相角相差 ≤ 23° 预先算好的 11 对。
  CoursePaletteScheme.soft: [
    (4, 15),
    (3, 8),
    (4, 9),
    (3, 11),
    (1, 9),
    (1, 12),
    (0, 8),
    (7, 13),
    (9, 15),
    (2, 10),
    (0, 14),
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

/// 两个时段是否“相邻”：同一天节次相接/重叠，或左右相邻两天节次有交集；
/// 且周次有交集。
bool slotsAdjacent(CourseSlot a, CourseSlot b) {
  if (!a.hasFixedTime || !b.hasFixedTime) return false;
  var spatial = false;
  if (a.day == b.day) {
    spatial = a.startNode <= b.endNode + 1 && b.startNode <= a.endNode + 1;
  } else if ((a.day - b.day).abs() == 1) {
    spatial = a.startNode <= b.endNode && b.startNode <= a.endNode;
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
/// 分配优先级（从高到低，保证所有可见课程尽量不同色且不撞近似色）：
/// 1. 相邻课程（[slotsAdjacent]）不同色号；
/// 2. 同周显示的课程（周次有交集）不同色号；
/// 3. 全学期所有可见课程尽量不重复使用同一色号（≤ 16 门全员唯一）；
/// 4. 相邻课程尽量不为近似对（[kNearColorPairs]）；
/// 5. 同周课程尽量不为近似对（课程较少时拉开色相差距）。
///
/// 用户手动色号 [Course.colorIndex] 固定不动；[userOccupiedCourses]（通常为
/// 用户自选色课程）不写入返回值，但作为占用色参与邻接与去重避让。
/// 仅隐藏课程在可见课程之后分配，避免挤占可见课程的唯一色号。
Map<String, int> assignCourseColors(
  List<Course> courses, {
  CoursePaletteScheme scheme = kDefaultCoursePaletteScheme,
  Map<String, int> userColors = const {},
  List<Course> userOccupiedCourses = const [],
}) {
  final visibleSlots = <String, List<CourseSlot>>{};
  final hiddenSlots = <String, List<CourseSlot>>{};
  final fixed = <String, int>{};

  for (final c in courses) {
    final key = normalizeCourseName(c.name);
    if (c.hidden) {
      (hiddenSlots[key] ??= []).addAll(c.slots);
    } else {
      (visibleSlots[key] ??= []).addAll(c.slots);
    }
    final ci = c.colorIndex;
    if (ci != null && ci >= 0 && ci < kCoursePaletteSize) {
      fixed.putIfAbsent(key, () => ci);
    }
  }

  // 用户自选色课程：按最接近的色板槽位登记占用，不写入返回的 result。
  final occupiedSlots = <String, List<CourseSlot>>{};
  final occupiedColor = <String, int>{};
  void addOccupied(Course c, int argb) {
    if (c.hidden) return;
    final key = 'user:${normalizeCourseName(c.name)}#${c.id}';
    (occupiedSlots[key] ??= []).addAll(c.slots);
    occupiedColor[key] = nearestPaletteIndexForArgb(argb, scheme: scheme);
  }

  for (final c in userOccupiedCourses) {
    final argb = userColors[c.id];
    if (argb != null) addOccupied(c, argb);
  }
  for (final c in courses) {
    final argb = userColors[c.id];
    if (argb != null) addOccupied(c, argb);
  }

  final visibleNames = visibleSlots.keys.toList()..sort();
  final hiddenOnlyNames = [
    for (final k in hiddenSlots.keys)
      if (!visibleSlots.containsKey(k)) k,
  ]..sort();

  // 合并所有参与图关系判断的节点（可见课 + 仅隐藏课 + 用户自选色占位）。
  final allSlots = <String, List<CourseSlot>>{
    for (final n in hiddenOnlyNames) n: hiddenSlots[n]!,
    ...visibleSlots,
    ...occupiedSlots,
  };
  final allNodes = allSlots.keys.toList();

  final neighbours = <String, Set<String>>{for (final n in allNodes) n: {}};
  final sameWeekPeers = <String, Set<String>>{for (final n in allNodes) n: {}};

  for (var i = 0; i < allNodes.length; i++) {
    for (var j = i + 1; j < allNodes.length; j++) {
      final a = allNodes[i], b = allNodes[j];
      final saList = allSlots[a]!;
      final sbList = allSlots[b]!;
      var adj = false;
      var sameWeek = false;
      for (final sa in saList) {
        for (final sb in sbList) {
          if (!sameWeek && weeksIntersect(sa.weeks, sb.weeks)) {
            sameWeek = true;
          }
          if (!adj && slotsAdjacent(sa, sb)) {
            adj = true;
          }
          if (adj && sameWeek) break;
        }
        if (adj && sameWeek) break;
      }
      if (adj) {
        neighbours[a]!.add(b);
        neighbours[b]!.add(a);
      }
      if (sameWeek) {
        sameWeekPeers[a]!.add(b);
        sameWeekPeers[b]!.add(a);
      }
    }
  }

  final result = <String, int>{...fixed};
  final globalCounts = List<int>.filled(kCoursePaletteSize, 0);
  for (final color in fixed.values) {
    globalCounts[color % kCoursePaletteSize]++;
  }
  for (final color in occupiedColor.values) {
    globalCounts[color % kCoursePaletteSize]++;
  }

  int? colorOfNode(String node) => result[node] ?? occupiedColor[node];

  int pickColor(String name, {required bool countGlobal}) {
    final adjColors = [for (final n in neighbours[name]!) ?colorOfNode(n)];
    final weekColors = [for (final n in sameWeekPeers[name]!) ?colorOfNode(n)];

    (int, int, int, int, int) score(int c) {
      var adjSame = 0;
      var adjNear = 0;
      for (final u in adjColors) {
        if (u == c) {
          adjSame++;
        } else if (colorsNear(c, u, scheme: scheme)) {
          adjNear++;
        }
      }
      var weekSame = 0;
      var weekNear = 0;
      for (final u in weekColors) {
        if (u == c) {
          weekSame++;
        } else if (colorsNear(c, u, scheme: scheme)) {
          weekNear++;
        }
      }
      final global = countGlobal ? globalCounts[c] : 0;
      return (adjSame, weekSame, global, adjNear, weekNear);
    }

    bool better((int, int, int, int, int) a, (int, int, int, int, int) b) {
      if (a.$1 != b.$1) return a.$1 < b.$1;
      if (a.$2 != b.$2) return a.$2 < b.$2;
      if (a.$3 != b.$3) return a.$3 < b.$3;
      if (a.$4 != b.$4) return a.$4 < b.$4;
      return a.$5 < b.$5;
    }

    final start = courseColorIndexForName(name);
    var best = start;
    var bestScore = score(start);
    // 以与 16 互质的步长 5 遍历，碰撞顺延时自动拉开色相跨越。
    for (var k = 1; k < kCoursePaletteSize; k++) {
      final candidate = (start + k * 5) % kCoursePaletteSize;
      final s = score(candidate);
      if (better(s, bestScore)) {
        best = candidate;
        bestScore = s;
      }
    }
    return best;
  }

  for (final name in visibleNames) {
    if (result.containsKey(name)) continue;
    final chosen = pickColor(name, countGlobal: true);
    result[name] = chosen;
    globalCounts[chosen]++;
  }

  for (final name in hiddenOnlyNames) {
    if (result.containsKey(name)) continue;
    result[name] = pickColor(name, countGlobal: true);
  }

  return result;
}
