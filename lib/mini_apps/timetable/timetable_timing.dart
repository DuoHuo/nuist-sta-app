// 实验课 / 体育课的实际起止时刻换算（纯 Dart，不依赖 Flutter）。
//
// 规则（TJ / QA LAB，南信大 11 节作息）：
// - 连续实验或体育课：节与节之间 **< 30 分钟** 的小课间全部取消；
//   每取消一个小课间，该连续段下课时刻整体提前 10 分钟。
// - **≥ 30 分钟** 的大课间保留，前后拆成独立上课段。
// - 标准课（非实验/体育）仍用教务/默认作息表，不做压缩。
//
// 例（基于 [TimetableController.defaultPeriods]）：
// - 1–2 节 → 08:00–09:30（取消 1 个小课间）
// - 1–3 节 → 08:00–09:30，大课间，再 10:10–10:55
// - 9–11 节 → 18:45–21:00（取消 2 个小课间）

import 'timetable_models.dart';

/// 学校作息节次数上限（南信大）。
const int kNuistMaxPeriodNode = 11;

/// 小于该分钟数的课间视为「小课间」，实验/体育连续段内取消。
const int kShortBreakMaxMinutes = 30;

/// 每取消一个小课间，连续段下课时刻提前的分钟数。
const int kCancelledShortBreakMinutes = 10;

/// 课程时刻类型：决定是否启用实验/体育压缩规则。
enum CourseTimingKind { standard, lab, pe }

/// 一段连续上课（中间没有保留的大课间）。
class CourseTimingSegment {
  const CourseTimingSegment({
    required this.startNode,
    required this.endNode,
    required this.start,
    required this.end,
  });

  final int startNode;
  final int endNode;

  /// "08:00"
  final String start;
  final String end;

  String get label => '$start-$end';
}

/// 综合体育课识别与时段上的实验标记，得到换算类型。
///
/// 显式实验标记（SFSYK → [CourseSlot.isLab]）优先于体育课标记。
CourseTimingKind timingKindOf({
  required Course course,
  required CourseSlot slot,
}) {
  if (slot.isLab) return CourseTimingKind.lab;
  if (course.isPe) return CourseTimingKind.pe;
  return CourseTimingKind.standard;
}

int? _hhmmToMinutes(String hhmm) {
  final parts = hhmm.split(':');
  if (parts.length < 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  return h * 60 + m;
}

String _minutesToHhmm(int total) {
  final h = total ~/ 60;
  final m = total % 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

PeriodTime? _periodOf(List<PeriodTime> periods, int node) {
  for (final p in periods) {
    if (p.node == node) return p;
  }
  return null;
}

/// 两节之间的课间分钟数；缺作息或顺序异常时返回 null。
int? breakMinutesBetween(PeriodTime earlier, PeriodTime later) {
  final a = _hhmmToMinutes(earlier.end);
  final b = _hhmmToMinutes(later.start);
  if (a == null || b == null) return null;
  return b - a;
}

/// 将 [startNode]..=[endNode] 按大课间拆成连续段，并对实验/体育取消小课间。
///
/// [periods] 为标准作息（教务或 [TimetableController.defaultPeriods]）。
/// [kind] 为 [CourseTimingKind.standard] 时返回单段标准起止，不压缩。
List<CourseTimingSegment> resolveTimingSegments({
  required List<PeriodTime> periods,
  required int startNode,
  required int endNode,
  required CourseTimingKind kind,
}) {
  if (startNode < 1 || endNode < startNode) return const [];

  final first = _periodOf(periods, startNode);
  final last = _periodOf(periods, endNode);
  if (first == null || last == null) return const [];

  if (kind == CourseTimingKind.standard || startNode == endNode) {
    // 单节或标准课：整段标准起止（多节标准课也不压缩小课间）。
    if (kind == CourseTimingKind.standard) {
      return [
        CourseTimingSegment(
          startNode: startNode,
          endNode: endNode,
          start: first.start,
          end: last.end,
        ),
      ];
    }
    // lab/pe 单节：与标准相同。
    return [
      CourseTimingSegment(
        startNode: startNode,
        endNode: endNode,
        start: first.start,
        end: last.end,
      ),
    ];
  }

  // lab / pe：按大课间拆段，段内取消小课间。
  final blocks = <(int, int)>[];
  var blockStart = startNode;
  for (var n = startNode; n < endNode; n++) {
    final cur = _periodOf(periods, n);
    final nxt = _periodOf(periods, n + 1);
    if (cur == null || nxt == null) {
      // 缺作息：无法可靠判断课间，退回整段标准起止。
      return [
        CourseTimingSegment(
          startNode: startNode,
          endNode: endNode,
          start: first.start,
          end: last.end,
        ),
      ];
    }
    final gap = breakMinutesBetween(cur, nxt);
    if (gap == null) {
      return [
        CourseTimingSegment(
          startNode: startNode,
          endNode: endNode,
          start: first.start,
          end: last.end,
        ),
      ];
    }
    if (gap >= kShortBreakMaxMinutes) {
      blocks.add((blockStart, n));
      blockStart = n + 1;
    }
  }
  blocks.add((blockStart, endNode));

  final out = <CourseTimingSegment>[];
  for (final (a, b) in blocks) {
    final aP = _periodOf(periods, a);
    final bP = _periodOf(periods, b);
    if (aP == null || bP == null) continue;
    final endMinutes = _hhmmToMinutes(bP.end);
    if (endMinutes == null) continue;
    final cancelled = b - a; // 段内相邻节对数 = 取消的小课间数
    final adjusted = endMinutes - kCancelledShortBreakMinutes * cancelled;
    out.add(
      CourseTimingSegment(
        startNode: a,
        endNode: b,
        start: aP.start,
        end: _minutesToHhmm(adjusted),
      ),
    );
  }
  return out;
}

/// 时段在给定类型下的整体起止（首段开始、末段结束）；无法解析时 null。
({String? start, String? end}) effectiveSlotBounds({
  required List<PeriodTime> periods,
  required int startNode,
  required int endNode,
  required CourseTimingKind kind,
}) {
  final segs = resolveTimingSegments(
    periods: periods,
    startNode: startNode,
    endNode: endNode,
    kind: kind,
  );
  if (segs.isEmpty) return (start: null, end: null);
  return (start: segs.first.start, end: segs.last.end);
}

/// 兼容旧调用：单节换算。实验/体育单节与标准相同；多节请用
/// [resolveTimingSegments] / [effectiveSlotBounds]。
PeriodTime resolvePeriodTime({
  required PeriodTime standard,
  required CourseTimingKind kind,
  int? node,
  List<PeriodTime>? periods,
}) {
  final n = node ?? standard.node;
  if (kind == CourseTimingKind.standard || periods == null) {
    return standard;
  }
  final segs = resolveTimingSegments(
    periods: periods,
    startNode: n,
    endNode: n,
    kind: kind,
  );
  if (segs.isEmpty) return standard;
  return PeriodTime(node: n, start: segs.first.start, end: segs.first.end);
}

String? effectiveStart({
  required List<PeriodTime> periods,
  required int startNode,
  required int endNode,
  required CourseTimingKind kind,
}) => effectiveSlotBounds(
  periods: periods,
  startNode: startNode,
  endNode: endNode,
  kind: kind,
).start;

String? effectiveEnd({
  required List<PeriodTime> periods,
  required int startNode,
  required int endNode,
  required CourseTimingKind kind,
}) => effectiveSlotBounds(
  periods: periods,
  startNode: startNode,
  endNode: endNode,
  kind: kind,
).end;

/// 合并地点：按「 / 」拆开、trim，按出现顺序去重并去掉空串，再拼回。
String _mergeLocations(String a, String b) {
  final seen = <String>{};
  final parts = <String>[];
  for (final raw in [a, b]) {
    for (final piece in raw.split(' / ')) {
      final t = piece.trim();
      if (t.isEmpty || !seen.add(t)) continue;
      parts.add(t);
    }
  }
  return parts.join(' / ');
}

/// 按实际教学周合并同课同日首尾相接的实验/体育记录。
/// 保留原始课程与时段供编辑寻址；仅用于已套用调课、单日修改的展示候选。
List<CourseSlot> mergeTimingSlots(Course course, List<CourseSlot> slots) {
  final sorted = [...slots]..sort((a, b) => a.startNode.compareTo(b.startNode));
  final out = <CourseSlot>[];
  for (final s in sorted) {
    final prev = out.lastOrNull;
    if (prev == null ||
        prev.day != s.day ||
        prev.endNode + 1 != s.startNode ||
        timingKindOf(course: course, slot: prev) == CourseTimingKind.standard ||
        timingKindOf(course: course, slot: s) == CourseTimingKind.standard) {
      out.add(s);
      continue;
    }
    out[out.length - 1] = CourseSlot(
      day: prev.day,
      startNode: prev.startNode,
      endNode: s.endNode,
      weeks: prev.weeks,
      weeksLabel: prev.weeksLabel,
      teacher: {prev.teacher, s.teacher}.where((v) => v.isNotEmpty).join('，'),
      location: _mergeLocations(prev.location, s.location),
      note: {prev.note, s.note}.where((v) => v.isNotEmpty).join('；'),
      istk: prev.istk,
      isLab: prev.isLab || s.isLab,
    );
  }
  return out;
}
