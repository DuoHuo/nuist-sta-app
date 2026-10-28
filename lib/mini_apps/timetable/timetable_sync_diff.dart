// 课表同步变动比对（纯 Dart）：教务源快照集合 diff + 本地变更日志。
// 口径见 docs/sync-diff-spec.md；产品决策：同 KCH+KXH 的 removed+added 归并为
// 「时间变动」（含仅周次变、仅星期/节次变、或两者皆变 → 单条）。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/digests/sha256.dart';

import 'timetable_models.dart';
import 'timetable_store.dart';
import 'timetable_week_format.dart';

/// 变动类型（UI 可用 [labelZh]）。
enum TimetableChangeType {
  /// 新增时段
  added,

  /// 删除时段
  removed,

  /// 地点变更（同 slotKey）
  locationChanged,

  /// 教师变更（同 slotKey；教师已规范化）
  teacherChanged,

  /// 时间/周次变动：同 KCH+KXH 的 removed+added 归并
  timeChanged,

  /// 调课标记 ISTK 变更（同 slotKey）
  retakeFlagChanged,
}

extension TimetableChangeTypeZh on TimetableChangeType {
  String get labelZh => switch (this) {
    TimetableChangeType.added => '新增',
    TimetableChangeType.removed => '删除',
    TimetableChangeType.locationChanged => '地点变动',
    TimetableChangeType.teacherChanged => '教师变动',
    TimetableChangeType.timeChanged => '时间变动',
    TimetableChangeType.retakeFlagChanged => '调课标记变动',
  };

  String get wireName => switch (this) {
    TimetableChangeType.added => 'added',
    TimetableChangeType.removed => 'removed',
    TimetableChangeType.locationChanged => 'location_changed',
    TimetableChangeType.teacherChanged => 'teacher_changed',
    TimetableChangeType.timeChanged => 'time_changed',
    TimetableChangeType.retakeFlagChanged => 'retake_flag_changed',
  };

  static TimetableChangeType? tryParse(String? raw) {
    final s = (raw ?? '').trim();
    for (final t in TimetableChangeType.values) {
      if (t.wireName == s || t.name == s) return t;
    }
    return null;
  }
}

/// 一条持久化变动记录。
///
/// 字段与产品约定对齐：`time` / `type` / `slotKey` / `before` / `after` /
/// `fingerprint` / `notified`；另附 `id`、`courseName`、`xnxqdm` 便于 UI。
class TimetableChangeRecord {
  const TimetableChangeRecord({
    required this.id,
    required this.time,
    required this.type,
    required this.slotKey,
    required this.fingerprint,
    this.courseName = '',
    this.courseWeeks = '',
    this.xnxqdm = '',
    this.before,
    this.after,
    this.notified = false,
  });

  final String id;

  /// 检出时间（设备本地时区）。
  final DateTime time;

  final TimetableChangeType type;

  /// 稳定 key：`KCH|KXH|SKXQ|KSJC|JSJC|SKZC`；时间变动取**新**时段 key。
  final String slotKey;

  final String courseName;

  /// 变动前后该课程全部固定时段的周次位串，仅用于判断影响范围。
  /// 旧记录为空时仍可展示快照周次，但不推断「全部周次」。
  final String courseWeeks;

  final String xnxqdm;

  /// 相关字段快照；`added` 时为 null，`removed` 时 after 为 null。
  final Map<String, dynamic>? before;
  final Map<String, dynamic>? after;

  final String fingerprint;
  final bool notified;

  TimetableChangeRecord copyWith({bool? notified}) => TimetableChangeRecord(
    id: id,
    time: time,
    type: type,
    slotKey: slotKey,
    fingerprint: fingerprint,
    courseName: courseName,
    courseWeeks: courseWeeks,
    xnxqdm: xnxqdm,
    before: before,
    after: after,
    notified: notified ?? this.notified,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'time': time.toIso8601String(),
    'type': type.wireName,
    'slotKey': slotKey,
    'courseName': courseName,
    if (courseWeeks.isNotEmpty) 'courseWeeks': courseWeeks,
    'xnxqdm': xnxqdm,
    'before': before,
    'after': after,
    'fingerprint': fingerprint,
    'notified': notified,
  };

  factory TimetableChangeRecord.fromJson(Map<String, dynamic> json) {
    final type =
        TimetableChangeTypeZh.tryParse('${json['type'] ?? ''}') ??
        TimetableChangeType.added;
    Map<String, dynamic>? mapOrNull(Object? v) {
      if (v == null) return null;
      if (v is Map<String, dynamic>) return Map<String, dynamic>.from(v);
      if (v is Map) {
        return {for (final e in v.entries) '${e.key}': e.value};
      }
      return null;
    }

    return TimetableChangeRecord(
      id: '${json['id'] ?? ''}',
      time: DateTime.tryParse('${json['time'] ?? ''}') ?? DateTime.now(),
      type: type,
      slotKey: '${json['slotKey'] ?? ''}',
      courseName: '${json['courseName'] ?? ''}',
      courseWeeks: '${json['courseWeeks'] ?? ''}',
      xnxqdm: '${json['xnxqdm'] ?? ''}',
      before: mapOrNull(json['before']),
      after: mapOrNull(json['after']),
      fingerprint: '${json['fingerprint'] ?? ''}',
      notified: json['notified'] == true,
    );
  }
}

/// 一次 [TimetableSyncDiff.applyAfterFetch] 的结果，供提醒弹窗使用。
class TimetableSyncDiffResult {
  const TimetableSyncDiffResult({
    required this.allWritten,
    required this.toNotify,
  });

  /// 本轮写入（含已通知过、静默保留 notified=true 的 upsert）。
  final List<TimetableChangeRecord> allWritten;

  /// 需要弹窗提醒的新 fingerprint（`notified == false`）。
  final List<TimetableChangeRecord> toNotify;

  bool get hasNewChanges => toNotify.isNotEmpty;
}

/// 扁平化后的教务时段（仅固定时间、仅 jwxt）。
@visibleForTesting
class DiffSlot {
  const DiffSlot({
    required this.course,
    required this.slot,
    required this.slotKey,
  });

  final Course course;
  final CourseSlot slot;
  final String slotKey;

  String get courseClassKey => '${course.code.trim()}|${course.classId.trim()}';
}

/// 课表同步 diff 纯逻辑。
class TimetableSyncDiff {
  TimetableSyncDiff._();

  /// slotKey = KCH|KXH|SKXQ|KSJC|JSJC|SKZC（各段 trim，节次/星期转字符串）。
  static String buildSlotKey({
    required String code,
    required String classId,
    required int day,
    required int startNode,
    required int endNode,
    required String weeks,
  }) =>
      '${code.trim()}|${classId.trim()}|$day|$startNode|$endNode|${weeks.trim()}';

  static String slotKeyOf(Course course, CourseSlot slot) => buildSlotKey(
    code: course.code,
    classId: course.classId,
    day: slot.day,
    startNode: slot.startNode,
    endNode: slot.endNode,
    weeks: slot.weeks,
  );

  /// 教师规范化：trim；中英文逗号统一；分割后 trim、去空、排序再 `,` 拼接。
  static String normalizeTeachers(String raw) {
    final parts =
        raw
            .trim()
            .replaceAll('，', ',')
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList()
          ..sort();
    return parts.join(',');
  }

  static String normalizeLocation(String raw) => raw.trim();

  static int normalizeIstk(int? raw) => raw ?? 0;

  static String _allCourseWeeks(Iterable<Course> courses) {
    final weeks = {
      for (final course in courses)
        for (final slot in course.slots)
          if (slot.hasFixedTime) ...weeksFromBits(slot.weeks),
    };
    if (weeks.isEmpty) return '';
    final last = weeks.reduce((a, b) => a > b ? a : b);
    return List.generate(last, (i) => weeks.contains(i + 1) ? '1' : '0').join();
  }

  /// 参与 fingerprint / 展示的字段快照（键已排序语义由 [canonicalJson] 保证）。
  static Map<String, dynamic> snapshotOf(Course course, CourseSlot slot) => {
    'KCH': course.code.trim(),
    'KXH': course.classId.trim(),
    'KCM': course.name.trim(),
    'SKXQ': slot.day,
    'KSJC': slot.startNode,
    'JSJC': slot.endNode,
    'SKZC': slot.weeks.trim(),
    'JASMC': normalizeLocation(slot.location),
    'SKJS': normalizeTeachers(slot.teacher),
    'ISTK': normalizeIstk(slot.istk),
  };

  static String canonicalJson(Map<String, dynamic>? map) {
    if (map == null) return '';
    final keys = map.keys.toList()..sort();
    final ordered = <String, dynamic>{for (final k in keys) k: map[k]};
    return jsonEncode(ordered);
  }

  static String fingerprintOf({
    required TimetableChangeType type,
    required String slotKey,
    Map<String, dynamic>? before,
    Map<String, dynamic>? after,
  }) {
    final payload =
        '${type.wireName}\n$slotKey\n${canonicalJson(before)}\n${canonicalJson(after)}';
    final digest = SHA256Digest().process(
      Uint8List.fromList(utf8.encode(payload)),
    );
    final hex = [for (final b in digest) b.toRadixString(16).padLeft(2, '0')]
        .join();
    return 'sha256:$hex';
  }

  /// 只展开教务源、有固定时间的时段；忽略手动课与「其他课程」。
  @visibleForTesting
  static List<DiffSlot> flatten(List<Course> courses) {
    final out = <DiffSlot>[];
    for (final c in courses) {
      if (c.source != CourseSource.jwxt) continue;
      for (final s in c.slots) {
        if (!s.hasFixedTime) continue;
        out.add(DiffSlot(course: c, slot: s, slotKey: slotKeyOf(c, s)));
      }
    }
    return out;
  }

  /// 计算候选变动（尚未查重 / 落盘）。
  ///
  /// [oldCourses]/[newCourses] 均为教务源缓存（可含手动课，会被忽略）。
  /// 旧列表为空时返回空（首次同步不记「全量新增」，避免打扰）。
  static List<TimetableChangeRecord> compute({
    required List<Course> oldCourses,
    required List<Course> newCourses,
    DateTime? detectedAt,
    String xnxqdm = '',
    String Function()? idFactory,
  }) {
    final oldSlots = flatten(oldCourses);
    if (oldSlots.isEmpty) return const [];

    final now = detectedAt ?? DateTime.now();
    var seq = 0;
    String nextId() {
      if (idFactory != null) return idFactory();
      seq += 1;
      return '${now.microsecondsSinceEpoch}-$seq';
    }

    final oldByKey = <String, DiffSlot>{};
    for (final s in oldSlots) {
      // 同 key 后写覆盖（教务偶发重复行）；集合 diff 不看顺序。
      oldByKey[s.slotKey] = s;
    }
    final newByKey = <String, DiffSlot>{};
    for (final s in flatten(newCourses)) {
      newByKey[s.slotKey] = s;
    }

    final removed = <DiffSlot>[];
    final added = <DiffSlot>[];
    final attributeChanges = <TimetableChangeRecord>[];

    for (final e in oldByKey.entries) {
      final neu = newByKey[e.key];
      if (neu == null) {
        removed.add(e.value);
        continue;
      }
      attributeChanges.addAll(
        _attributeDiffs(
          old: e.value,
          neu: neu,
          time: now,
          xnxqdm: xnxqdm,
          idFactory: nextId,
        ),
      );
    }
    for (final e in newByKey.entries) {
      if (!oldByKey.containsKey(e.key)) added.add(e.value);
    }

    final paired = _pairTimeChanges(
      removed: removed,
      added: added,
      time: now,
      xnxqdm: xnxqdm,
      idFactory: nextId,
    );

    return [...attributeChanges, ...paired.records];
  }

  static List<TimetableChangeRecord> _attributeDiffs({
    required DiffSlot old,
    required DiffSlot neu,
    required DateTime time,
    required String xnxqdm,
    required String Function() idFactory,
  }) {
    final before = snapshotOf(old.course, old.slot);
    final after = snapshotOf(neu.course, neu.slot);
    final out = <TimetableChangeRecord>[];

    void add(TimetableChangeType type) {
      out.add(
        TimetableChangeRecord(
          id: idFactory(),
          time: time,
          type: type,
          slotKey: neu.slotKey,
          courseName: neu.course.name,
          courseWeeks: _allCourseWeeks([old.course, neu.course]),
          xnxqdm: xnxqdm,
          before: before,
          after: after,
          fingerprint: fingerprintOf(
            type: type,
            slotKey: neu.slotKey,
            before: before,
            after: after,
          ),
        ),
      );
    }

    if (normalizeLocation(old.slot.location) !=
        normalizeLocation(neu.slot.location)) {
      add(TimetableChangeType.locationChanged);
    }
    if (normalizeTeachers(old.slot.teacher) !=
        normalizeTeachers(neu.slot.teacher)) {
      add(TimetableChangeType.teacherChanged);
    }
    if (normalizeIstk(old.slot.istk) != normalizeIstk(neu.slot.istk)) {
      add(TimetableChangeType.retakeFlagChanged);
    }
    return out;
  }

  /// 将同 KCH+KXH 的 removed/added 一对一归并为时间变动；剩余保持 added/removed。
  static _PairResult _pairTimeChanges({
    required List<DiffSlot> removed,
    required List<DiffSlot> added,
    required DateTime time,
    required String xnxqdm,
    required String Function() idFactory,
  }) {
    final remByCourse = <String, List<DiffSlot>>{};
    final addByCourse = <String, List<DiffSlot>>{};
    for (final s in removed) {
      (remByCourse[s.courseClassKey] ??= []).add(s);
    }
    for (final s in added) {
      (addByCourse[s.courseClassKey] ??= []).add(s);
    }

    final records = <TimetableChangeRecord>[];
    final usedRem = <String>{};
    final usedAdd = <String>{};

    final keys = {...remByCourse.keys, ...addByCourse.keys};
    for (final ck in keys) {
      final rs = List<DiffSlot>.from(remByCourse[ck] ?? const []);
      final as_ = List<DiffSlot>.from(addByCourse[ck] ?? const []);
      // 优先配对「同星期同节次、仅周次不同」，再任意配对。
      rs.sort((a, b) => a.slotKey.compareTo(b.slotKey));
      as_.sort((a, b) => a.slotKey.compareTo(b.slotKey));

      final pairs = <(DiffSlot, DiffSlot)>[];
      final freeAdd = List<DiffSlot>.from(as_);

      for (final r in List<DiffSlot>.from(rs)) {
        final sameTimeIdx = freeAdd.indexWhere(
          (a) =>
              a.slot.day == r.slot.day &&
              a.slot.startNode == r.slot.startNode &&
              a.slot.endNode == r.slot.endNode,
        );
        if (sameTimeIdx >= 0) {
          pairs.add((r, freeAdd.removeAt(sameTimeIdx)));
          rs.remove(r);
        }
      }
      while (rs.isNotEmpty && freeAdd.isNotEmpty) {
        pairs.add((rs.removeAt(0), freeAdd.removeAt(0)));
      }

      for (final (r, a) in pairs) {
        usedRem.add(r.slotKey);
        usedAdd.add(a.slotKey);
        final before = snapshotOf(r.course, r.slot);
        final after = snapshotOf(a.course, a.slot);
        // 时间+周次都变仍是一条时间变动；fingerprint 含前后完整快照。
        records.add(
          TimetableChangeRecord(
            id: idFactory(),
            time: time,
            type: TimetableChangeType.timeChanged,
            slotKey: a.slotKey,
            courseName: a.course.name.isNotEmpty
                ? a.course.name
                : r.course.name,
            courseWeeks: _allCourseWeeks([r.course, a.course]),
            xnxqdm: xnxqdm,
            before: before,
            after: after,
            fingerprint: fingerprintOf(
              type: TimetableChangeType.timeChanged,
              slotKey: a.slotKey,
              before: before,
              after: after,
            ),
          ),
        );
      }
    }

    for (final r in removed) {
      if (usedRem.contains(r.slotKey)) continue;
      final before = snapshotOf(r.course, r.slot);
      records.add(
        TimetableChangeRecord(
          id: idFactory(),
          time: time,
          type: TimetableChangeType.removed,
          slotKey: r.slotKey,
          courseName: r.course.name,
          courseWeeks: _allCourseWeeks([r.course]),
          xnxqdm: xnxqdm,
          before: before,
          after: null,
          fingerprint: fingerprintOf(
            type: TimetableChangeType.removed,
            slotKey: r.slotKey,
            before: before,
            after: null,
          ),
        ),
      );
    }
    for (final a in added) {
      if (usedAdd.contains(a.slotKey)) continue;
      final after = snapshotOf(a.course, a.slot);
      records.add(
        TimetableChangeRecord(
          id: idFactory(),
          time: time,
          type: TimetableChangeType.added,
          slotKey: a.slotKey,
          courseName: a.course.name,
          courseWeeks: _allCourseWeeks([a.course]),
          xnxqdm: xnxqdm,
          before: null,
          after: after,
          fingerprint: fingerprintOf(
            type: TimetableChangeType.added,
            slotKey: a.slotKey,
            before: null,
            after: after,
          ),
        ),
      );
    }

    return _PairResult(records: records);
  }

  /// 全量拉取成功后的钩子：比对旧/新教务源、按 fingerprint 去重后写入本地变更日志。
  ///
  /// 不改变同步成功/失败语义；调用方在写快照前后均可调用。
  /// 返回本轮应弹窗的新变动（[TimetableSyncDiffResult.toNotify]）。
  static Future<TimetableSyncDiffResult> applyAfterFetch({
    required List<Course> previousJwxtCourses,
    required List<Course> newJwxtCourses,
    String xnxqdm = '',
    DateTime? detectedAt,
  }) async {
    final candidates = compute(
      oldCourses: previousJwxtCourses,
      newCourses: newJwxtCourses,
      detectedAt: detectedAt,
      xnxqdm: xnxqdm,
    );
    if (candidates.isEmpty) {
      return const TimetableSyncDiffResult(allWritten: [], toNotify: []);
    }
    return TimetableChangeLogStore.upsertCandidates(candidates);
  }
}

class _PairResult {
  const _PairResult({required this.records});
  final List<TimetableChangeRecord> records;
}

/// 变更日志本地存储：`ApplicationDocuments/timetable/sync_changes.json`。
///
/// 约定与 [TimetableStore] / [ScheduleStore] 一致：schemaVersion、坏文件改名备份、
/// 原子写；`try/catch` 失败时退化为无存储。
class TimetableChangeLogStore {
  TimetableChangeLogStore._();

  static const fileName = 'sync_changes.json';
  static const schemaVersion = 1;

  /// 测试可注入的内存后端（非 null 时不碰磁盘）。
  @visibleForTesting
  static List<TimetableChangeRecord>? debugMemory;

  static Future<List<TimetableChangeRecord>> readAll() async {
    final mem = debugMemory;
    if (mem != null) return List.unmodifiable(mem);

    final file = await TimetableStore.fileFor(fileName);
    if (file == null || !await file.exists()) return const [];
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return const [];
      final list = decoded['changes'];
      if (list is! List) return const [];
      return [
        for (final item in list)
          if (item is Map<String, dynamic>)
            TimetableChangeRecord.fromJson(item)
          else if (item is Map)
            TimetableChangeRecord.fromJson({
              for (final e in item.entries) '${e.key}': e.value,
            }),
      ];
    } catch (_) {
      try {
        var target = File('${file.path}.corrupt');
        if (await target.exists()) {
          target = File(
            '${file.path}.corrupt.${DateTime.now().millisecondsSinceEpoch}',
          );
        }
        await file.rename(target.path);
      } catch (_) {}
      return const [];
    }
  }

  static Future<void> _writeAll(List<TimetableChangeRecord> changes) async {
    final mem = debugMemory;
    if (mem != null) {
      debugMemory = List.of(changes);
      return;
    }
    final file = await TimetableStore.fileFor(fileName);
    if (file == null) return;
    try {
      Map<String, dynamic> raw = {};
      if (await file.exists()) {
        try {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is Map<String, dynamic>) {
            raw = Map<String, dynamic>.from(decoded);
          } else if (decoded is Map) {
            raw = {for (final e in decoded.entries) '${e.key}': e.value};
          }
        } catch (_) {}
      }
      raw['schemaVersion'] = schemaVersion;
      raw['changes'] = [for (final c in changes) c.toJson()];
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(raw), flush: true);
      await tmp.rename(file.path);
    } catch (_) {}
  }

  /// 按 fingerprint upsert：已存在且 notified=true → 保持 notified，不进入 toNotify；
  /// 新 fingerprint → notified=false，进入 toNotify。
  static Future<TimetableSyncDiffResult> upsertCandidates(
    List<TimetableChangeRecord> candidates,
  ) async {
    final existing = await readAll();
    final byFp = <String, TimetableChangeRecord>{
      for (final c in existing) c.fingerprint: c,
    };
    final written = <TimetableChangeRecord>[];
    final toNotify = <TimetableChangeRecord>[];

    for (final c in candidates) {
      final prev = byFp[c.fingerprint];
      if (prev != null && prev.notified) {
        // 静默：保留已通知状态（可刷新 time/id 以外字段，但保持 notified）。
        final kept = c.copyWith(notified: true);
        byFp[c.fingerprint] = kept;
        written.add(kept);
        continue;
      }
      byFp[c.fingerprint] = c;
      written.add(c);
      toNotify.add(c);
    }

    // 保留历史：按 time 升序；同 fingerprint 以最新 upsert 为准。
    final merged = byFp.values.toList()
      ..sort((a, b) => a.time.compareTo(b.time));
    await _writeAll(merged);
    return TimetableSyncDiffResult(allWritten: written, toNotify: toNotify);
  }

  /// 将给定 fingerprint 标为已通知（弹窗确认后调用）。
  static Future<void> markNotified(Iterable<String> fingerprints) async {
    final set = fingerprints.toSet();
    if (set.isEmpty) return;
    final all = await readAll();
    var changed = false;
    final next = <TimetableChangeRecord>[];
    for (final c in all) {
      if (set.contains(c.fingerprint) && !c.notified) {
        changed = true;
        next.add(c.copyWith(notified: true));
      } else {
        next.add(c);
      }
    }
    if (changed) await _writeAll(next);
  }

  /// 未通知记录（变更日志页 / 弹窗）。
  static Future<List<TimetableChangeRecord>> readUnnotified() async {
    final all = await readAll();
    return [
      for (final c in all)
        if (!c.notified) c,
    ];
  }

  /// 按时间倒序的全部记录（变更日志页）。
  static Future<List<TimetableChangeRecord>> readNewestFirst() async {
    final all = await readAll();
    return all.reversed.toList();
  }

  static Future<void> clear() async {
    if (debugMemory != null) {
      debugMemory = [];
      return;
    }
    final file = await TimetableStore.fileFor(fileName);
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
