// 拖动调课数据层（spec §13.2，timetable-jwxt.md §3.2）。纯 Dart，不依赖 Flutter。
//
// - 手动课：直接改课程的时段（同一门课拆时段，不新建课程，颜色不变）。
// - 教务课：从不改同步数据，另存覆盖记录 [SlotOverride]，每次同步/启动后用
//   [applySlotOverrides] 套到教务课上得到展示用课程。

import 'timetable_models.dart';

/// 拖动后的应用范围：只改本周 / 改以后所有周（含本周）/ 所有周（第 1 条「所有周」）。
enum MoveScope { thisWeek, fromThisWeek, allWeeks }

/// [MoveResult] 状态：已移动 / 落回原位（什么都不写）/ 出错。
enum MoveStatus { moved, noChange, error }

/// 拒绝移动的原因。
enum MoveError {
  /// 课程或 slotIndex 不存在、时段没有固定时间、或课程已不在课表里。
  invalidSlot,

  /// 该时段在第 week 周没有课。
  notInWeek,

  /// 目标星期不在 1..7 或起始节 < 1。
  invalidTarget,

  /// 保持时长后结束节超过最后一节。
  pastLastPeriod,
}

/// [TimetableController.moveSlot] 的结果。
class MoveResult {
  const MoveResult._(
    this.status, {
    this.error,
    this.conflictNames = const [],
    this.affectedWeeks = const [],
  });

  const MoveResult.moved({
    List<String> conflictNames = const [],
    List<int> affectedWeeks = const [],
  }) : this._(
         MoveStatus.moved,
         conflictNames: conflictNames,
         affectedWeeks: affectedWeeks,
       );

  const MoveResult.noChange() : this._(MoveStatus.noChange);

  const MoveResult.error(MoveError error)
    : this._(MoveStatus.error, error: error);

  final MoveStatus status;
  final MoveError? error;

  /// 落点冲突的课名：去重后按课名排序（String.compareTo）。
  /// 只改本周只查第 w 周；改以后所有周查全部受影响的周。
  final List<String> conflictNames;

  /// 实际被移动的周（升序）。
  final List<int> affectedWeeks;

  bool get ok => status == MoveStatus.moved;
  bool get hasConflict => conflictNames.isNotEmpty;
  int get conflictCount => conflictNames.length;

  /// 「与X时间冲突」/「与X等 N 门课时间冲突」（X 为课名排序第一门；课名两侧不加空格，
  /// 数字两侧保留空格）；无冲突为 null。
  String? get conflictMessage {
    if (conflictNames.isEmpty) return null;
    if (conflictNames.length == 1) return '与${conflictNames.first}时间冲突';
    return '与${conflictNames.first}等 ${conflictNames.length} 门课时间冲突';
  }
}

/// 详情页「已调课：原 周X 第 a–b 节」所需信息。
class SlotOverrideInfo {
  const SlotOverrideInfo({
    required this.originalDay,
    required this.originalStart,
    required this.originalEnd,
  });
  final int originalDay;
  final int originalStart;
  final int originalEnd;
}

/// 教务课的一条本地调课记录（存 `timetable/overrides.json`）。
///
/// 识别键：courseId（= KCH|KXH 合并键）+ 原星期/起止节 + [origWeeks]（拖动时
/// 原课的 SKZC 位串）。同步后任一项对不上即失效删除（[staleOverrideIds]）。
/// [weeks] 为这条记录移动的周（显式列表）；[scope]/[fromWeek] 仅记录拖动时的选择，
/// 不参与失效判断。
class SlotOverride {
  const SlotOverride({
    required this.id,
    required this.courseId,
    required this.origDay,
    required this.origStart,
    required this.origEnd,
    required this.origWeeks,
    required this.weeks,
    required this.scope,
    required this.fromWeek,
    required this.toDay,
    required this.toStart,
    required this.toEnd,
    this.createdAt = '',
    this.extra = const {},
  });

  final String id;
  final String courseId;
  final int origDay;
  final int origStart;
  final int origEnd;
  final String origWeeks;
  final List<int> weeks;
  final MoveScope scope;
  final int fromWeek;
  final int toDay;
  final int toStart;
  final int toEnd;
  final String createdAt;

  /// 读到的未知键，写回时原样保留。
  final Map<String, dynamic> extra;

  bool matchesKey(String courseId, CourseSlot s) =>
      this.courseId == courseId &&
      origDay == s.day &&
      origStart == s.startNode &&
      origEnd == s.endNode;

  SlotOverride withWeeks(List<int> w) => SlotOverride(
    id: id,
    courseId: courseId,
    origDay: origDay,
    origStart: origStart,
    origEnd: origEnd,
    origWeeks: origWeeks,
    weeks: w,
    scope: scope,
    fromWeek: fromWeek,
    toDay: toDay,
    toStart: toStart,
    toEnd: toEnd,
    createdAt: createdAt,
    extra: extra,
  );

  Map<String, dynamic> toJson() => {
    ...extra,
    'id': id,
    'courseId': courseId,
    'origDay': origDay,
    'origStart': origStart,
    'origEnd': origEnd,
    'origWeeks': origWeeks,
    'weeks': weeks,
    'scope': scope.name,
    'fromWeek': fromWeek,
    'toDay': toDay,
    'toStart': toStart,
    'toEnd': toEnd,
    'createdAt': createdAt,
  };

  static const _known = {
    'id', 'courseId', 'origDay', 'origStart', 'origEnd', 'origWeeks', //
    'weeks', 'scope', 'fromWeek', 'toDay', 'toStart', 'toEnd', 'createdAt',
  };

  /// 宽松解析；关键字段缺失/类型不对返回 null（调用方原样保留该条原始数据）。
  static SlotOverride? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    int? i(String k) => m[k] is int ? m[k] as int : null;
    final id = m['id'], courseId = m['courseId'];
    final od = i('origDay'), os = i('origStart'), oe = i('origEnd');
    final td = i('toDay'), ts = i('toStart'), te = i('toEnd');
    final weeksRaw = m['weeks'];
    if (id is! String || courseId is! String || weeksRaw is! List) return null;
    if (od == null || os == null || oe == null) return null;
    if (td == null || ts == null || te == null) return null;
    if (td < 1 || td > 7 || ts < 1 || te < ts) return null;
    final weeks = <int>{
      for (final w in weeksRaw)
        if (w is int && w >= 1) w,
    }.toList()..sort();
    if (weeks.isEmpty) return null;
    return SlotOverride(
      id: id,
      courseId: courseId,
      origDay: od,
      origStart: os,
      origEnd: oe,
      origWeeks: m['origWeeks'] is String ? m['origWeeks'] as String : '',
      weeks: weeks,
      scope: switch (m['scope']) {
        'fromThisWeek' => MoveScope.fromThisWeek,
        'allWeeks' => MoveScope.allWeeks,
        _ => MoveScope.thisWeek,
      },
      fromWeek: i('fromWeek') ?? weeks.first,
      toDay: td,
      toStart: ts,
      toEnd: te,
      createdAt: m['createdAt'] is String ? m['createdAt'] as String : '',
      extra: {
        for (final e in m.entries)
          if (!_known.contains(e.key)) e.key: e.value,
      },
    );
  }
}

/// 展示用时段的来源（仅对套用过覆盖记录的教务课打标）。
class SlotOrigin {
  const SlotOrigin({
    required this.courseId,
    required this.original,
    required this.moved,
  });
  final String courseId;

  /// 教务原始时段。
  final CourseSlot original;

  /// true = 被调到新位置的时段；false = 原位置剩下的周。
  final bool moved;
}

final Expando<SlotOrigin> _origins = Expando<SlotOrigin>('slotOrigin');

/// 展示用时段的来源；未套用覆盖记录的时段返回 null（即教务原样）。
SlotOrigin? slotOriginOf(CourseSlot slot) => _origins[slot];

/// 周次集合 → 位串（长度取 [minLength] 与最大周的较大值）。
String weeksToBits(Iterable<int> weeks, int minLength) {
  final set = weeks.where((w) => w >= 1).toSet();
  var len = minLength;
  for (final w in set) {
    if (w > len) len = w;
  }
  final b = StringBuffer();
  for (var w = 1; w <= len; w++) {
    b.write(set.contains(w) ? '1' : '0');
  }
  return b.toString();
}

/// 位串里有课的周（升序）。
List<int> weeksOf(CourseSlot s) => [
  for (var w = 1; w <= s.weeks.length; w++)
    if (s.hasClassInWeek(w)) w,
];

/// 在教务课 [course] 中找 [o] 指向的原时段下标；找不到返回 -1。
/// 要求 courseId + 星期 + 起止节 + 原 SKZC（[SlotOverride.origWeeks]）全部一致；
/// origWeeks 为空（旧记录缺该字段）视为未知，一律不匹配，免得套到错误位置。
int findOverrideSlot(Course course, SlotOverride o) {
  if (o.origWeeks.isEmpty) return -1;
  for (var i = 0; i < course.slots.length; i++) {
    final s = course.slots[i];
    if (o.matchesKey(course.id, s) && s.weeks == o.origWeeks) return i;
  }
  return -1;
}

/// 同步成功后应删除的调课记录 id（教务优先，jwxt §3.2）：
/// - 原课在 [jwxt] 里已不存在；
/// - 原课的 SKZC 与记录的 origWeeks 不同（含旧记录缺 origWeeks）；
/// - 原时段的星期/起止节变了。
/// 只应在**真正同步成功**后用最新教务课程调用；解绑不调用（记录保留）。
Set<String> staleOverrideIds(List<Course> jwxt, List<SlotOverride> overrides) {
  final byId = <String, Course>{
    for (final c in jwxt)
      if (c.source == CourseSource.jwxt) c.id: c,
  };
  return {
    for (final o in overrides)
      if (byId[o.courseId] == null ||
          findOverrideSlot(byId[o.courseId]!, o) < 0)
        o.id,
  };
}

/// [applySlotOverrides] 的结果。
class AppliedOverrides {
  const AppliedOverrides(this.courses, this.orphanIds);
  final List<Course> courses;

  /// 找不到原课/原时段（或 SKZC 对不上）的记录 id：不渲染；解绑时保留，
  /// 同步成功后由控制器按 [staleOverrideIds] 删除。
  final Set<String> orphanIds;
}

/// 把覆盖记录套到教务课上。记录按列表顺序套用，同一周后写的覆盖先写的。
/// 未受影响的课程原样返回（同一对象）。
AppliedOverrides applySlotOverrides(
  List<Course> jwxt,
  List<SlotOverride> overrides,
) {
  if (overrides.isEmpty) return AppliedOverrides(jwxt, const {});
  final byCourse = <String, List<SlotOverride>>{};
  for (final o in overrides) {
    (byCourse[o.courseId] ??= []).add(o);
  }
  final matched = <String>{};
  final out = <Course>[];
  for (final c in jwxt) {
    final recs = byCourse[c.id];
    if (recs == null || c.source != CourseSource.jwxt) {
      out.add(c);
      continue;
    }
    final perSlot = <int, List<SlotOverride>>{};
    for (final o in recs) {
      final idx = findOverrideSlot(c, o);
      if (idx < 0) continue;
      matched.add(o.id);
      (perSlot[idx] ??= []).add(o);
    }
    if (perSlot.isEmpty) {
      out.add(c);
      continue;
    }
    final slots = <CourseSlot>[];
    for (var i = 0; i < c.slots.length; i++) {
      final s = c.slots[i];
      final list = perSlot[i];
      if (list == null) {
        slots.add(s);
        continue;
      }
      final residual = <int>[];
      // 新位置 → 周次；保持首次出现顺序。
      final moved = <(int, int, int), List<int>>{};
      for (final w in weeksOf(s)) {
        SlotOverride? hit;
        for (final o in list) {
          if (o.weeks.contains(w)) hit = o;
        }
        if (hit == null) {
          residual.add(w);
        } else {
          (moved[(hit.toDay, hit.toStart, hit.toEnd)] ??= []).add(w);
        }
      }
      if (moved.isEmpty) {
        slots.add(s);
        continue;
      }
      if (residual.isNotEmpty) {
        final r = CourseSlot(
          day: s.day,
          startNode: s.startNode,
          endNode: s.endNode,
          weeks: weeksToBits(residual, s.weeks.length),
          teacher: s.teacher,
          location: s.location,
          note: s.note,
          isLab: s.isLab,
        );
        _origins[r] = SlotOrigin(courseId: c.id, original: s, moved: false);
        slots.add(r);
      }
      moved.forEach((pos, weeks) {
        final m = CourseSlot(
          day: pos.$1,
          startNode: pos.$2,
          endNode: pos.$3,
          weeks: weeksToBits(weeks, s.weeks.length),
          teacher: s.teacher,
          location: s.location,
          note: s.note,
          isLab: s.isLab,
        );
        _origins[m] = SlotOrigin(courseId: c.id, original: s, moved: true);
        slots.add(m);
      });
    }
    out.add(c.copyWith(slots: slots));
  }
  return AppliedOverrides(out, {
    for (final o in overrides)
      if (!matched.contains(o.id)) o.id,
  });
}

/// 手动课移动：返回新的时段列表（同一门课）。
/// 原时段去掉 [affected] 周，新时段只含 [affected] 周，插在原时段后；原时段周次空了就删掉。
///
/// - 新时段记 [CourseSlot.splitFrom] = 原时段位置（原时段还有剩余周时）；原时段被整段
///   移走时沿用原时段自己的 splitFrom（没有就是普通时段）。周视图据此在被移走的周
///   不画原位置的「[非本周]」虚影。
/// - 落点已有同一门课、同一位置且任课教师/地点/备注相同的时段（如拖回原位置）→
///   把 [affected] 周并回该时段（保留它自己的 splitFrom），不新建、不留重复格。
List<CourseSlot> moveManualSlots(
  List<CourseSlot> slots,
  int index,
  List<int> affected, {
  required int toDay,
  required int toStart,
  required int toEnd,
}) {
  final s = slots[index];
  final remaining = [
    for (final w in weeksOf(s))
      if (!affected.contains(w)) w,
  ];
  final keep = remaining.isNotEmpty;
  var mergeAt = -1;
  for (var i = 0; i < slots.length; i++) {
    final x = slots[i];
    if (i != index &&
        x.day == toDay &&
        x.startNode == toStart &&
        x.endNode == toEnd &&
        x.teacher == s.teacher &&
        x.location == s.location &&
        x.note == s.note) {
      mergeAt = i;
      break;
    }
  }
  CourseSlot? moved;
  CourseSlot? merged;
  if (mergeAt >= 0) {
    final t = slots[mergeAt];
    final len = t.weeks.length > s.weeks.length
        ? t.weeks.length
        : s.weeks.length;
    merged = CourseSlot(
      day: t.day,
      startNode: t.startNode,
      endNode: t.endNode,
      weeks: weeksToBits({...weeksOf(t), ...affected}.toList()..sort(), len),
      teacher: t.teacher,
      location: t.location,
      note: t.note,
      isLab: t.isLab || s.isLab,
      splitFrom: t.splitFrom,
    );
  } else {
    moved = CourseSlot(
      day: toDay,
      startNode: toStart,
      endNode: toEnd,
      weeks: weeksToBits(affected, s.weeks.length),
      teacher: s.teacher,
      location: s.location,
      note: s.note,
      isLab: s.isLab,
      splitFrom: keep ? s.ref : s.splitFrom,
    );
  }
  return [
    for (var i = 0; i < slots.length; i++) ...[
      if (i == mergeAt)
        merged!
      else if (i != index)
        slots[i]
      else ...[
        if (keep)
          CourseSlot(
            day: s.day,
            startNode: s.startNode,
            endNode: s.endNode,
            weeks: weeksToBits(remaining, s.weeks.length),
            teacher: s.teacher,
            location: s.location,
            note: s.note,
            isLab: s.isLab,
            splitFrom: s.splitFrom,
          ),
        ?moved,
      ],
    ],
  ];
}

/// 从已有记录里去掉 [weeks]（同一原时段）；周次变空的记录删除。
List<SlotOverride> subtractOverrideWeeks(
  List<SlotOverride> list,
  bool Function(SlotOverride) sameSlot,
  List<int> weeks,
) => [
  for (final o in list)
    if (!sameSlot(o))
      o
    else if (o.weeks.any((w) => !weeks.contains(w)))
      o.withWeeks([
        for (final w in o.weeks)
          if (!weeks.contains(w)) w,
      ]),
];

/// 给展示用时段打来源标（编辑覆盖层重建时段时沿用原标）。
void tagSlotOrigin(CourseSlot slot, SlotOrigin origin) =>
    _origins[slot] = origin;

// ===== 教务课编辑 / 删除覆盖层（第 4 条）=====

/// 教务课时段指纹：每个时段「星期-起-止-SKZC」排序拼接。同步后与
/// [CourseEdit.origFingerprint] 不同（周次或时间变了）→ 编辑记录失效。
String courseFingerprint(Course c) {
  final parts = [
    for (final s in c.slots) '${s.day}-${s.startNode}-${s.endNode}-${s.weeks}',
  ]..sort();
  return parts.join('|');
}

/// 一门教务课的本地编辑 / 删除记录（与调课记录 [SlotOverride] 分开存）。
/// 字段为 null 表示该项未改。课时间与周次不可编辑（调课只靠拖动）。
class CourseEdit {
  const CourseEdit({
    required this.courseId,
    required this.origFingerprint,
    this.origName = '',
    this.name,
    this.teacher,
    this.location,
    this.note,
    this.deleted = false,
    this.updatedAt = '',
  });

  final String courseId;

  /// 记录创建时教务原课的 [courseFingerprint]。
  final String origFingerprint;

  /// 教务原课名（仅供参考；配色始终查当前教务快照里的原名）。
  final String origName;
  final String? name;
  final String? teacher;
  final String? location;
  final String? note;
  final bool deleted;
  final String updatedAt;

  bool get hasFieldEdits =>
      name != null || teacher != null || location != null || note != null;

  bool get isEmpty => !deleted && !hasFieldEdits;

  CourseEdit copyWith({
    String? name,
    String? teacher,
    String? location,
    String? note,
    bool? deleted,
    String? updatedAt,
  }) => CourseEdit(
    courseId: courseId,
    origFingerprint: origFingerprint,
    origName: origName,
    name: name ?? this.name,
    teacher: teacher ?? this.teacher,
    location: location ?? this.location,
    note: note ?? this.note,
    deleted: deleted ?? this.deleted,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'courseId': courseId,
    'origFingerprint': origFingerprint,
    'origName': origName,
    if (name != null) 'name': name,
    if (teacher != null) 'teacher': teacher,
    if (location != null) 'location': location,
    if (note != null) 'note': note,
    'deleted': deleted,
    'updatedAt': updatedAt,
  };

  static CourseEdit? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['courseId'];
    final fp = raw['origFingerprint'];
    if (id is! String || id.isEmpty || fp is! String) return null;
    String? s(String k) => raw[k] is String ? raw[k] as String : null;
    return CourseEdit(
      courseId: id,
      origFingerprint: fp,
      origName: s('origName') ?? '',
      name: s('name'),
      teacher: s('teacher'),
      location: s('location'),
      note: s('note'),
      deleted: raw['deleted'] == true,
      updatedAt: s('updatedAt') ?? '',
    );
  }
}

/// 同步成功后应删除的编辑记录：原课不在了，或时段指纹（SKZC / 星期节次）变了。
Set<String> staleCourseEditIds(
  List<Course> jwxt,
  Map<String, CourseEdit> edits,
) {
  final byId = <String, Course>{
    for (final c in jwxt)
      if (c.source == CourseSource.jwxt) c.id: c,
  };
  return {
    for (final e in edits.values)
      if (byId[e.courseId] == null ||
          courseFingerprint(byId[e.courseId]!) != e.origFingerprint)
        e.courseId,
  };
}

/// 套用编辑覆盖层：删除的课隐藏；改过的名字 / 老师 / 地点 / 备注替换显示。
/// 指纹对不上的记录（待同步失效）不套用。时段保留来源标。
List<Course> applyCourseEdits(
  List<Course> applied,
  List<Course> jwxtOriginal,
  Map<String, CourseEdit> edits,
) {
  if (edits.isEmpty) return applied;
  final fpById = <String, String>{
    for (final c in jwxtOriginal) c.id: courseFingerprint(c),
  };
  final out = <Course>[];
  for (final c in applied) {
    final e = edits[c.id];
    if (e == null || c.isManual || fpById[c.id] != e.origFingerprint) {
      out.add(c);
      continue;
    }
    if (e.deleted) continue;
    if (!e.hasFieldEdits) {
      out.add(c);
      continue;
    }
    final slots = <CourseSlot>[];
    for (final s in c.slots) {
      final n = CourseSlot(
        day: s.day,
        startNode: s.startNode,
        endNode: s.endNode,
        weeks: s.weeks,
        weeksLabel: s.weeksLabel,
        teacher: e.teacher ?? s.teacher,
        location: e.location ?? s.location,
        note: e.note ?? s.note,
        isLab: s.isLab,
        splitFrom: s.splitFrom,
      );
      tagSlotOrigin(
        n,
        slotOriginOf(s) ??
            SlotOrigin(courseId: c.id, original: s, moved: false),
      );
      slots.add(n);
    }
    out.add(c.copyWith(name: e.name, slots: slots));
  }
  return out;
}
