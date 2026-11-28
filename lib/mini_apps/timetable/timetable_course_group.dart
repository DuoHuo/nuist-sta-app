// 同课程吸附分组、同时段同地点合并、全学期剩余大节统计与冲突描述。纯 Dart，不依赖 Flutter。

import 'timetable_date_edits.dart';
import 'timetable_models.dart';
import 'timetable_overrides.dart';
import 'timetable_schedule_event.dart';
import 'timetable_timing.dart';
import 'timetable_week_format.dart';

/// 课程组内的一条上课时段记录，保留其所属课程与来源索引。
class CourseGroupSlot {
  const CourseGroupSlot({
    required this.course,
    required this.slotIndex,
    required this.slot,
    this.origin,
  });

  final Course course;
  final int slotIndex;
  final CourseSlot slot;
  final SlotOrigin? origin;

  bool get isManual => course.isManual;
}

/// 课程详情中按「同一星期 + 同一起止节次 + 同一地点」合并后的一条上课安排展示项。
class MergedCourseScheduleItem {
  const MergedCourseScheduleItem({
    required this.day,
    required this.startNode,
    required this.endNode,
    required this.location,
    required this.weeks,
    required this.teachers,
    required this.members,
    required this.memberIndices,
  });

  final int day;
  final int startNode;
  final int endNode;
  final String location;

  /// 合并并排序去重后的全部上课周次。
  final List<int> weeks;

  /// 合并后的去重任课教师列表。
  final List<String> teachers;

  /// 被合并进该展示项的原始时段列表。
  final List<CourseGroupSlot> members;

  /// 对应在 [CourseGroup.slots] 中的下标列表。
  final List<int> memberIndices;

  /// 首条原始时段在 [CourseGroup.slots] 中的下标。
  int get firstSlotIndex => memberIndices.first;

  /// 是否包含指定的原始时段。
  bool containsSlot(Course course, CourseSlot slot) {
    for (final m in members) {
      if (m.course.id == course.id &&
          m.slot.day == slot.day &&
          m.slot.startNode == slot.startNode &&
          m.slot.endNode == slot.endNode &&
          m.slot.weeks == slot.weeks) {
        return true;
      }
    }
    return false;
  }
}

/// 按课程号或课程名吸附后的一门课程视角。
class CourseGroup {
  const CourseGroup({
    required this.primary,
    required this.courses,
    required this.slots,
  });

  /// 主课程：组内含教务课时优先取教务课（优先当前目标课），否则取当前目标手动课。
  final Course primary;

  /// 组内全部课程（主课在前）。
  final List<Course> courses;

  /// 组内全部固定时间上课时段（按星期、起止节次排序）。
  final List<CourseGroupSlot> slots;

  /// 组内全部课程 ID 集合，用于排除同门课自身的冲突检测与批量同步。
  Set<String> get courseIds => {for (final c in courses) c.id};

  /// 是否包含至少一门教务课。
  bool get hasJwxt => courses.any((c) => !c.isManual);

  /// 展示用课程号（取主课或组内首个非空课程号）。
  String get code {
    if (primary.code.trim().isNotEmpty) return primary.code.trim();
    for (final c in courses) {
      if (c.code.trim().isNotEmpty) return c.code.trim();
    }
    return '';
  }

  /// 整门课的全局备注（优先主课，其次组内首个非空全局备注）。
  String get globalNote {
    if (primary.note.trim().isNotEmpty) return primary.note.trim();
    for (final c in courses) {
      if (c.note.trim().isNotEmpty) return c.note.trim();
    }
    return '';
  }

  /// 组内去重后的非空任课教师列表（保持首次出现顺序）。
  List<String> get distinctTeachers {
    final seen = <String>{};
    final out = <String>[];
    for (final item in slots) {
      final t = item.slot.teacher.trim();
      if (t.isNotEmpty && seen.add(t)) out.add(t);
    }
    return out;
  }

  /// 按「同星期 + 同起止节次 + 同地点」合并后的上课安排列表（含不连续周次合并）。
  List<MergedCourseScheduleItem> get mergedSchedules =>
      mergeCourseGroupSlots(slots);
}

/// 将 [slots] 按「同星期 + 同起止节次 + 同归一化地点」合并为紧凑展示列表。
List<MergedCourseScheduleItem> mergeCourseGroupSlots(
  List<CourseGroupSlot> slots,
) {
  final buckets = <String, _MergedScheduleBuilder>{};
  final order = <String>[];
  for (var i = 0; i < slots.length; i++) {
    final item = slots[i];
    final s = item.slot;
    final loc = s.location.trim();
    final key = '${s.day}|${s.startNode}|${s.endNode}|$loc';
    final bucket = buckets.putIfAbsent(key, () {
      order.add(key);
      return _MergedScheduleBuilder(
        day: s.day,
        startNode: s.startNode,
        endNode: s.endNode,
        location: loc,
      );
    });
    bucket.add(item, i);
  }
  final out = [for (final k in order) buckets[k]!.build()];
  out.sort((a, b) {
    final byDay = a.day.compareTo(b.day);
    if (byDay != 0) return byDay;
    final byStart = a.startNode.compareTo(b.startNode);
    if (byStart != 0) return byStart;
    final byEnd = a.endNode.compareTo(b.endNode);
    if (byEnd != 0) return byEnd;
    final wa = a.weeks.firstOrNull ?? 0;
    final wb = b.weeks.firstOrNull ?? 0;
    return wa.compareTo(wb);
  });
  return List.unmodifiable(out);
}

class _MergedScheduleBuilder {
  _MergedScheduleBuilder({
    required this.day,
    required this.startNode,
    required this.endNode,
    required this.location,
  });

  final int day;
  final int startNode;
  final int endNode;
  final String location;
  final Set<int> _weeks = <int>{};
  final Set<String> _teacherSeen = <String>{};
  final List<String> _teachers = <String>[];
  final List<CourseGroupSlot> _members = <CourseGroupSlot>[];
  final List<int> _indices = <int>[];

  void add(CourseGroupSlot item, int index) {
    _members.add(item);
    _indices.add(index);
    _weeks.addAll(weeksFromBits(item.slot.weeks));
    final t = item.slot.teacher.trim();
    if (t.isNotEmpty && _teacherSeen.add(t)) {
      _teachers.add(t);
    }
  }

  MergedCourseScheduleItem build() {
    final sortedWeeks = _weeks.toList()..sort();
    return MergedCourseScheduleItem(
      day: day,
      startNode: startNode,
      endNode: endNode,
      location: location,
      weeks: List.unmodifiable(sortedWeeks),
      teachers: List.unmodifiable(_teachers),
      members: List.unmodifiable(_members),
      memberIndices: List.unmodifiable(_indices),
    );
  }
}

/// 课程本学期课时进度统计（按大节计，一次完整上课时段算 1 节）。
class CourseGroupProgress {
  const CourseGroupProgress({
    required this.totalSessions,
    required this.remainingSessions,
    required this.hasTermStart,
  });

  /// 本学期总大节数（已扣除删除并计入调课/单日修改）。
  final int totalSessions;

  /// 相对当前真实时刻尚未结束的大节数；[hasTermStart] 为 false 时无剩余概念。
  final int remainingSessions;

  /// 是否已知本学期开学日期。
  final bool hasTermStart;

  /// 面向用户的简洁进度文案；无有效安排时返回空串。
  String get label {
    if (totalSessions <= 0) return '';
    if (!hasTermStart) return '共 $totalSessions 节';
    if (remainingSessions <= 0) return '已结课';
    return '还剩 $remainingSessions 节';
  }
}

/// 判断两门网格课程是否应吸附为同一门课：
/// 1. 同 [Course.id] 必吸附；
/// 2. 均有非空课程号 [Course.code] 时，仅课号相同才吸附（防止不同课程号的同名课误合）；
/// 3. 至少一方无课程号时，按归一化课名 [normalizeCourseName] 吸附。
/// 未排课（`other:` 开头或无固定时间）不参与吸附。
bool coursesBelongToSameGroup(Course a, Course b) {
  if (a.id.isNotEmpty && a.id == b.id) return true;
  if (_isUnscheduledCourse(a) || _isUnscheduledCourse(b)) return false;
  final codeA = a.code.trim();
  final codeB = b.code.trim();
  if (codeA.isNotEmpty && codeB.isNotEmpty) {
    return codeA == codeB;
  }
  final nameA = normalizeCourseName(a.name);
  final nameB = normalizeCourseName(b.name);
  return nameA.isNotEmpty && nameA == nameB;
}

bool _isUnscheduledCourse(Course c) =>
    c.id.startsWith('other:') || !c.slots.any((s) => s.hasFixedTime);

/// 从全学期课程列表 [courses] 中解析 [target] 所属的同课吸附分组。
///
/// 采用传递闭包（并查集式队列扩展），保证「教务课(有课号) ↔ 手动课(无课号同名) ↔
/// 同课号实验课」能够稳定归到同一组，同时不会跨越两个不同非空课号。
CourseGroup resolveCourseGroup(List<Course> courses, Course target) {
  final pool = [
    for (final c in courses)
      if (!c.hidden && !_isUnscheduledCourse(c)) c,
  ];
  // 确保 target 自身也在候选中（即使调用方传入的是投影副本或刚构造的对象）。
  final seed = pool.where((c) => c.id == target.id).firstOrNull ?? target;
  final members = <Course>[seed];
  final visitedIds = <String>{seed.id};

  if (!_isUnscheduledCourse(seed)) {
    final targetCode = seed.code.trim();
    var cursor = 0;
    while (cursor < members.length) {
      final current = members[cursor++];
      for (final candidate in pool) {
        if (visitedIds.contains(candidate.id)) continue;
        if (!coursesBelongToSameGroup(current, candidate)) continue;
        // 避免通过无课号手动课把两个明确不同课号的教务课间接桥接在一起。
        final candCode = candidate.code.trim();
        final groupCode = targetCode.isNotEmpty
            ? targetCode
            : members
                  .map((m) => m.code.trim())
                  .firstWhere((v) => v.isNotEmpty, orElse: () => '');
        if (groupCode.isNotEmpty &&
            candCode.isNotEmpty &&
            groupCode != candCode) {
          continue;
        }
        visitedIds.add(candidate.id);
        members.add(candidate);
      }
    }
  }

  // 主课选择：优先教务课，若同级别优先当前入口课程。
  members.sort((a, b) {
    if (a.isManual != b.isManual) return a.isManual ? 1 : -1;
    if (a.id == seed.id) return -1;
    if (b.id == seed.id) return 1;
    return a.id.compareTo(b.id);
  });

  final slots = <CourseGroupSlot>[
    for (final course in members)
      for (var i = 0; i < course.slots.length; i++)
        if (course.slots[i].hasFixedTime && weeksOf(course.slots[i]).isNotEmpty)
          CourseGroupSlot(
            course: course,
            slotIndex: i,
            slot: course.slots[i],
            origin: slotOriginOf(course.slots[i]),
          ),
  ];

  slots.sort((a, b) {
    final byDay = a.slot.day.compareTo(b.slot.day);
    if (byDay != 0) return byDay;
    final byStart = a.slot.startNode.compareTo(b.slot.startNode);
    if (byStart != 0) return byStart;
    final byEnd = a.slot.endNode.compareTo(b.slot.endNode);
    if (byEnd != 0) return byEnd;
    final wa = weeksOf(a.slot).firstOrNull ?? 0;
    final wb = weeksOf(b.slot).firstOrNull ?? 0;
    return wa.compareTo(wb);
  });

  return CourseGroup(
    primary: members.first,
    courses: List.unmodifiable(members),
    slots: List.unmodifiable(slots),
  );
}

/// 查找课表中与 [name] 同名的已有课程（新建课程时用于感知重名/吸附提示）。
Course? findExistingCourseByName(List<Course> courses, String name) {
  final normalized = normalizeCourseName(name);
  if (normalized.isEmpty) return null;
  Course? manualMatch;
  for (final c in courses) {
    if (c.hidden || _isUnscheduledCourse(c)) continue;
    if (normalizeCourseName(c.name) != normalized) continue;
    if (!c.isManual) return c;
    manualMatch ??= c;
  }
  return manualMatch;
}

/// 精确计算课程组 [group] 在本学期 `1..totalWeeks` 内的总大节数与剩余大节数。
///
/// 规则：
/// - 一次有效上课时段（连堂算 1 个时段）计 1 节；
/// - 结合 [cellsForDay] 走真实整天调课、单日删除、按周删除与改期，保证与课表渲染一致；
/// - 若 [hasTermStart] 为 true，以真实当前时刻 [now] 判定剩余：
///   - 上课日期在今天之后 → 计入剩余；
///   - 上课日期为今天 → 下课时刻晚于 [now] 才计入剩余（缺作息时刻时按未结束计）。
CourseGroupProgress computeCourseGroupProgress({
  required CourseGroup group,
  required int totalWeeks,
  required bool hasTermStart,
  required DateTime now,
  required List<GridCell> Function(int week, int day) cellsForDay,
  required List<PeriodTime> periods,
}) {
  final ids = group.courseIds;
  if (ids.isEmpty || totalWeeks <= 0) {
    return CourseGroupProgress(
      totalSessions: 0,
      remainingSessions: 0,
      hasTermStart: hasTermStart,
    );
  }
  final today = DateTime(now.year, now.month, now.day);
  final nowMinutes = now.hour * 60 + now.minute;
  var total = 0;
  var remaining = 0;

  for (var week = 1; week <= totalWeeks; week++) {
    for (var day = 1; day <= 7; day++) {
      for (final cell in cellsForDay(week, day)) {
        if (!cell.activeThisWeek || !ids.contains(cell.course.id)) continue;
        total++;
        if (!hasTermStart) continue;
        final date = cell.date;
        if (date == null) continue;
        final cellDay = DateTime(date.year, date.month, date.day);
        if (cellDay.isAfter(today)) {
          remaining++;
        } else if (isSameDate(cellDay, today)) {
          final endMin = _endMinutesOf(cell.course, cell.slot, periods);
          if (endMin == null || endMin > nowMinutes) {
            remaining++;
          }
        }
      }
    }
  }

  return CourseGroupProgress(
    totalSessions: total,
    remainingSessions: hasTermStart ? remaining : 0,
    hasTermStart: hasTermStart,
  );
}

int? _endMinutesOf(Course course, CourseSlot slot, List<PeriodTime> periods) {
  final bounds = effectiveSlotBounds(
    periods: periods,
    startNode: slot.startNode,
    endNode: slot.endNode,
    kind: timingKindOf(course: course, slot: slot),
  );
  return TimeOfDayMinutes.tryParse(bounds.end)?.totalMinutes;
}

/// 冲突提示文案（非阻塞）：无冲突返回 null；1 门课写明课名与冲突周次，多门课写总数。
String? describeManualConflicts(CourseSlot candidate, List<Course> conflicts) {
  if (conflicts.isEmpty) return null;
  if (conflicts.length > 1) return '与 ${conflicts.length} 门课冲突';
  final course = conflicts.single;
  final weeks = <int>{};
  for (final slot in course.slots) {
    if (!slot.hasFixedTime || slot.day != candidate.day) continue;
    if (slot.startNode > candidate.endNode ||
        candidate.startNode > slot.endNode) {
      continue;
    }
    final limit = slot.weeks.length < candidate.weeks.length
        ? slot.weeks.length
        : candidate.weeks.length;
    for (var week = 1; week <= limit; week++) {
      if (slot.occursInWeek(week) && candidate.occursInWeek(week)) {
        weeks.add(week);
      }
    }
  }
  final label = formatWeeks(weeks);
  return label.isEmpty ? '与「${course.name}」冲突' : '与「${course.name}」$label冲突';
}

/// 课程添加/编辑表单中的单条上课时段草稿。
///
/// 当同一「星期 + 起止节次 + 地点」的多个零散周次时段在编辑页合并为一张卡片时，
/// [extraSources] 持有其余被合并的原时段来源，保存时会被归并到主来源时段，避免原片段残留。
class CourseSlotDraft {
  const CourseSlotDraft({
    this.sourceCourse,
    this.sourceSlot,
    this.sourceSlotIndex,
    this.extraSources = const [],
    required this.day,
    required this.startNode,
    required this.endNode,
    required this.weeks,
    this.location = '',
    this.note = '',
    this.kind = CourseKind.standard,
    this.teacher = '',
    this.color,
    this.useDefaultColor = false,
  });

  /// 来源课程（新建时段为 null）。
  final Course? sourceCourse;

  /// 来源时段（新建时段为 null）。
  final CourseSlot? sourceSlot;

  /// 在 [sourceCourse.slots] 中的下标（新建时段为 null）。
  final int? sourceSlotIndex;

  /// 合并进同一张时段卡的其余原始时段引用（保存时清空其原位并合并至主时段）。
  final List<CourseGroupSlot> extraSources;

  final int day;
  final int startNode;
  final int endNode;
  final List<int> weeks;
  final String location;
  final String note;
  final CourseKind kind;

  /// 原时段自带的任课教师；编辑页用户未主动改全局教师时保持各时段原有教师。
  final String teacher;

  /// 原时段的局部自选色（如未重设整门课颜色则原样保留）。
  final int? color;
  final bool useDefaultColor;

  CourseSlotDraft copyWith({
    List<CourseGroupSlot>? extraSources,
    int? day,
    int? startNode,
    int? endNode,
    List<int>? weeks,
    String? location,
    String? note,
    CourseKind? kind,
    String? teacher,
    int? color,
    bool clearColor = false,
    bool? useDefaultColor,
  }) => CourseSlotDraft(
    sourceCourse: sourceCourse,
    sourceSlot: sourceSlot,
    sourceSlotIndex: sourceSlotIndex,
    extraSources: extraSources ?? this.extraSources,
    day: day ?? this.day,
    startNode: startNode ?? this.startNode,
    endNode: endNode ?? this.endNode,
    weeks: weeks ?? this.weeks,
    location: location ?? this.location,
    note: note ?? this.note,
    kind: kind ?? this.kind,
    teacher: teacher ?? this.teacher,
    color: clearColor ? null : (color ?? this.color),
    useDefaultColor: useDefaultColor ?? this.useDefaultColor,
  );

  /// 转为用于冲突检测的临时 [CourseSlot]。
  CourseSlot toPreviewSlot(int totalWeeks) => CourseSlot(
    day: day,
    startNode: startNode,
    endNode: endNode,
    weeks: weeksToBits(weeks, totalWeeks),
    teacher: teacher,
    location: location,
    note: note,
    kind: kind,
  );
}

/// 将表单中的时段草稿列表按「同一星期 + 起止节次 + 地点」自动合并（周次求并集）。
///
/// 用于新建/编辑时段后若落在已有同时段同地点，自动收拢为一张卡片。
List<CourseSlotDraft> mergeCourseSlotDrafts(List<CourseSlotDraft> drafts) {
  final result = <CourseSlotDraft>[];
  for (final draft in drafts) {
    final loc = draft.location.trim();
    final idx = result.indexWhere(
      (other) =>
          other.day == draft.day &&
          other.startNode == draft.startNode &&
          other.endNode == draft.endNode &&
          other.location.trim() == loc &&
          other.kind == draft.kind,
    );
    if (idx < 0) {
      final sorted = draft.weeks.toSet().toList()..sort();
      result.add(draft.copyWith(weeks: sorted, location: loc));
    } else {
      final existing = result[idx];
      final mergedWeeks = {...existing.weeks, ...draft.weeks}.toList()..sort();
      final extras = <CourseGroupSlot>[
        ...existing.extraSources,
        if (draft.sourceCourse != null && draft.sourceSlot != null)
          CourseGroupSlot(
            course: draft.sourceCourse!,
            slotIndex: draft.sourceSlotIndex ?? -1,
            slot: draft.sourceSlot!,
          ),
        ...draft.extraSources,
      ];
      final mergedNote = combineCourseNotes(existing.note, draft.note);
      result[idx] = existing.copyWith(
        weeks: mergedWeeks,
        extraSources: extras,
        note: mergedNote,
      );
    }
  }
  return result;
}
