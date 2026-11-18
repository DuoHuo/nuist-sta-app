// WakeUp 口令导入模型与解析器（纯 Dart，不依赖 Flutter）。

import 'dart:convert';

import '../../core/logging/diagnostic_error.dart';
import 'timetable_models.dart';
import 'timetable_schedule_event.dart';

/// 导入准备、口令解析或网络请求失败时可直接展示的提示。
class TimetableImportException implements Exception, DiagnosticError {
  const TimetableImportException(
    this.message, {
    this.cause,
    this.causeStackTrace,
    this.code = 'import_invalid_data',
    this.mockSupported = false,
  });

  final String message;
  final String code;

  /// 是否属于服务端尚未部署导致失败（UI 可提示使用示例口令体验 Mock）。
  final bool mockSupported;

  @override
  final Object? cause;
  @override
  final StackTrace? causeStackTrace;
  @override
  Map<String, Object?> get diagnosticContext => {
    'endpoint': 'timetable.import',
    'service': 'community',
    'stage': 'import.parse',
    'reason_code': code,
  };

  @override
  String toString() => message;
}

/// 从粘贴的 WakeUp 分享文案或纯口令中提取口令串。
///
/// 优先匹配 32 位十六进制口令（如 `「a02b3a50f6a74fa49ec592597cef8162」`）；
/// 也兼容测试/示例用的短标识（`demo` / `mock` 或 `8..64` 位字母数字串）。
String extractWakeupShareKey(String rawInput) {
  final text = rawInput.trim();
  if (text.isEmpty) {
    throw const TimetableImportException(
      '请先输入或粘贴分享口令',
      code: 'import_empty_input',
    );
  }
  final hex32 = RegExp(r'(?<![0-9a-fA-F])[0-9a-fA-F]{32}(?![0-9a-fA-F])')
      .firstMatch(text);
  if (hex32 != null) {
    return hex32.group(0)!.toLowerCase();
  }
  final quoted = RegExp(r'[「『"\x27]([A-Za-z0-9_-]{4,64})[」』"\x27]')
      .firstMatch(text);
  if (quoted != null) {
    return quoted.group(1)!;
  }
  final compact = text.replaceAll(RegExp(r'\s+'), '');
  if (RegExp(r'^[A-Za-z0-9_-]{4,64}$').hasMatch(compact)) {
    return compact;
  }
  throw const TimetableImportException(
    '未识别到有效的分享口令，请检查粘贴内容',
    code: 'import_invalid_share_key',
  );
}

/// 解析完成后的导入结果（供预览页命名与确认导入）。
class WakeupImportResult {
  const WakeupImportResult({
    required this.defaultName,
    required this.snapshot,
    required this.courseCount,
    required this.slotCount,
    this.exams = const [],
    this.userColors = const {},
    this.skippedCount = 0,
    this.isMock = false,
    this.warnings = const [],
  });

  final String defaultName;
  final TimetableSnapshot snapshot;
  final int courseCount;
  final int slotCount;

  /// 从分享课表中识别出的考试日程，导入后以主课表考试样式（ScheduleEvent）展示。
  final List<ScheduleEvent> exams;

  int get examCount => exams.length;

  /// 导入课程附带的自定义 ARGB 颜色（`course.id -> ARGB`）。
  final Map<String, int> userColors;
  final int skippedCount;
  final bool isMock;
  final List<String> warnings;
}

/// 将服务端返回的 WakeUp 标准化 JSON（或 Mock 数据）解析为 [WakeupImportResult]。
class WakeupImportParser {
  WakeupImportParser._();

  static const int _maxAllowedWeeks = 30;
  static const int _maxAllowedNodes = 20;

  static WakeupImportResult parsePayload(
    Map<String, dynamic> rawData, {
    bool isMock = false,
  }) {
    final data = _unwrapWakeupPayload(rawData);
    final tableMap = data['table'] is Map
        ? Map<String, dynamic>.from(data['table'] as Map)
        : (data['tableBean'] is Map
              ? Map<String, dynamic>.from(data['tableBean'] as Map)
              : const <String, dynamic>{});

    T? pickMeta<T>(T? Function(Map<String, dynamic>) read) =>
        read(data) ?? (tableMap.isEmpty ? null : read(tableMap));

    final rawName = '${pickMeta((m) => m['name'] ?? m['tableName']) ?? ''}'
        .trim();
    final defaultName = rawName.isEmpty ? '导入的课表' : rawName;

    final rawMaxWeeks =
        pickMeta((m) => _asInt(m['maxWeeks'] ?? m['maxWeek'])) ?? 20;
    final maxWeeks = rawMaxWeeks.clamp(1, _maxAllowedWeeks);
    final startDate = pickMeta(
      (m) => _parseDate(
        m['startDate']?.toString() ?? m['termStartDate']?.toString(),
      ),
    );

    final rawPeriods =
        data['periods'] ??
        data['timeList'] ??
        data['timeSlots'] ??
        data['sectionTimes'] ??
        (data['timeTable'] is List ? data['timeTable'] : null);
    final periods = _parsePeriods(rawPeriods);
    final maxNode = periods.isEmpty
        ? _maxAllowedNodes
        : periods
              .map((p) => p.node)
              .reduce((a, b) => a > b ? a : b)
              .clamp(1, _maxAllowedNodes);

    final courses = <Course>[];
    final exams = <ScheduleEvent>[];
    final seenExamKeys = <String>{};
    final userColors = <String, int>{};
    var skipped = 0;
    var slotCount = 0;
    final examPeriods = periods.isEmpty ? _fallbackPeriodTimes : periods;

    bool tryConsumeAsExam({
      required String name,
      required Map<String, dynamic> slotMap,
      Map<String, dynamic>? baseMap,
      int? rawColor,
    }) {
      if (!_isExamEntry(
        name: name,
        slotMap: slotMap,
        baseMap: baseMap,
        rawColor: rawColor,
      )) {
        return false;
      }
      final extracted = _tryExtractExamEvents(
        name: name,
        slotMap: slotMap,
        baseMap: baseMap,
        startDate: startDate,
        periods: examPeriods,
        maxWeeks: maxWeeks,
        maxNode: maxNode,
        nextSeq: () => exams.length + 1,
      );
      if (extracted.isEmpty) return false;
      for (final event in extracted) {
        final dedupKey =
            '${event.title}|${event.date.year}-${event.date.month}-${event.date.day}'
            '|${event.start.totalMinutes}|${event.end.totalMinutes}|${event.location}';
        if (seenExamKeys.add(dedupKey)) {
          exams.add(event);
        }
      }
      return true;
    }

    final rawDetails =
        data['details'] ?? data['courseDetails'] ?? data['courseDetailList'];
    final rawCourses = data['courses'] ?? data['courseBaseList'];
    final rawItems = data['items'] ?? data['courseList'] ?? data['courseInfos'];

    if (rawDetails is List &&
        rawDetails.isNotEmpty &&
        rawCourses is List &&
        rawCourses.isNotEmpty) {
      // WakeUp 官方双表格式：courses（课名/色值/学分，按 id 关联）+ details（节次/周次/教室/教师）。
      final baseById = <String, Map<String, dynamic>>{};
      for (final item in rawCourses) {
        if (item is! Map) continue;
        final m = Map<String, dynamic>.from(item);
        final cid = '${m['id'] ?? m['courseId'] ?? ''}'.trim();
        if (cid.isNotEmpty) baseById[cid] = m;
      }
      final byKey = <String, _MutableImportedCourse>{};
      for (final raw in rawDetails) {
        if (raw is! Map) {
          skipped++;
          continue;
        }
        final map = Map<String, dynamic>.from(raw);
        final cid = '${map['id'] ?? map['courseId'] ?? ''}'.trim();
        final base = cid.isNotEmpty ? baseById[cid] : null;
        final name =
            '${map['courseName'] ?? map['name'] ?? map['title'] ?? base?['courseName'] ?? base?['name'] ?? ''}'
                .trim();
        if (name.isEmpty) {
          skipped++;
          continue;
        }
        final rawColor = _parseHexOrArgb(map['color'] ?? base?['color']);
        if (tryConsumeAsExam(
          name: name,
          slotMap: map,
          baseMap: base,
          rawColor: rawColor,
        )) {
          continue;
        }
        final slot = _parseSlot(
          map,
          maxWeeks: maxWeeks,
          maxNode: maxNode,
          fallbackNote: '${base?['note'] ?? ''}'.trim(),
        );
        if (slot == null) {
          skipped++;
          continue;
        }
        final key = cid.isNotEmpty ? 'cid:$cid' : 'name:$name';
        final entry = byKey.putIfAbsent(key, () {
          final id = 'wk_${byKey.length + 1}';
          return _MutableImportedCourse(
            id: id,
            name: name,
            credit: _asDouble(map['credit'] ?? base?['credit']),
            color: rawColor,
          );
        });
        entry.slots.add(slot);
      }
      for (final entry in byKey.values) {
        if (entry.slots.isEmpty) continue;
        final mergedSlots = _mergeCourseSlots(entry.slots);
        if (entry.color != null) userColors[entry.id] = entry.color!;
        courses.add(
          Course(
            id: entry.id,
            name: entry.name,
            credit: entry.credit,
            source: CourseSource.manual,
            slots: mergedSlots,
          ),
        );
        slotCount += mergedSlots.length;
      }
    } else if (rawCourses is List && rawCourses.isNotEmpty) {
      var seq = 0;
      for (final item in rawCourses) {
        if (item is! Map) {
          skipped++;
          continue;
        }
        final map = Map<String, dynamic>.from(item);
        final name = '${map['name'] ?? map['courseName'] ?? map['title'] ?? ''}'
            .trim();
        if (name.isEmpty) {
          skipped++;
          continue;
        }
        final rawColor = _parseHexOrArgb(map['color']);
        final rawSlots = map['slots'];
        final parsedSlots = <CourseSlot>[];
        if (rawSlots is List) {
          for (final rawSlot in rawSlots) {
            if (rawSlot is! Map) {
              skipped++;
              continue;
            }
            final slotMap = Map<String, dynamic>.from(rawSlot);
            if (tryConsumeAsExam(
              name: name,
              slotMap: slotMap,
              baseMap: map,
              rawColor: _parseHexOrArgb(slotMap['color']) ?? rawColor,
            )) {
              continue;
            }
            final slot = _parseSlot(
              slotMap,
              maxWeeks: maxWeeks,
              maxNode: maxNode,
            );
            if (slot == null) {
              skipped++;
            } else {
              parsedSlots.add(slot);
            }
          }
        } else {
          // 若 courses 直接是平铺时段对象（无 slots 数组），按单时段解析。
          if (tryConsumeAsExam(name: name, slotMap: map, rawColor: rawColor)) {
            continue;
          }
          final slot = _parseSlot(map, maxWeeks: maxWeeks, maxNode: maxNode);
          if (slot == null) {
            skipped++;
          } else {
            parsedSlots.add(slot);
          }
        }
        if (parsedSlots.isEmpty) continue;
        seq++;
        final id = 'wk_$seq';
        if (rawColor != null) userColors[id] = rawColor;
        courses.add(
          Course(
            id: id,
            name: name,
            credit: _asDouble(map['credit']),
            source: CourseSource.manual,
            slots: parsedSlots,
          ),
        );
        slotCount += parsedSlots.length;
      }
    } else if (rawItems is List && rawItems.isNotEmpty) {
      // 兼容按「课程时段条目」平铺返回的格式（courseList / courseInfos / items）。
      final byKey = <String, _MutableImportedCourse>{};
      for (final raw in rawItems) {
        if (raw is! Map) {
          skipped++;
          continue;
        }
        final map = Map<String, dynamic>.from(raw);
        final name = '${map['name'] ?? map['courseName'] ?? map['title'] ?? ''}'
            .trim();
        if (name.isEmpty) {
          skipped++;
          continue;
        }
        final rawColor = _parseHexOrArgb(map['color']);
        if (tryConsumeAsExam(name: name, slotMap: map, rawColor: rawColor)) {
          continue;
        }
        final slot = _parseSlot(map, maxWeeks: maxWeeks, maxNode: maxNode);
        if (slot == null) {
          skipped++;
          continue;
        }
        final key = '${map['key'] ?? map['id'] ?? map['courseId'] ?? name}';
        final entry = byKey.putIfAbsent(key, () {
          final id = 'wk_${byKey.length + 1}';
          return _MutableImportedCourse(
            id: id,
            name: name,
            credit: _asDouble(map['credit']),
            color: rawColor,
          );
        });
        entry.slots.add(slot);
      }
      for (final entry in byKey.values) {
        if (entry.slots.isEmpty) continue;
        if (entry.color != null) userColors[entry.id] = entry.color!;
        courses.add(
          Course(
            id: entry.id,
            name: entry.name,
            credit: entry.credit,
            source: CourseSource.manual,
            slots: entry.slots,
          ),
        );
        slotCount += entry.slots.length;
      }
    }

    if (courses.isEmpty && exams.isEmpty) {
      throw const TimetableImportException(
        '口令中未包含有效课程安排',
        code: 'import_no_courses',
      );
    }

    final effectiveNodesPerDay = () {
      var highest =
          pickMeta((m) => _asInt(m['nodesPerDay'] ?? m['nodes'])) ??
          periods.length;
      for (final c in courses) {
        for (final s in c.slots) {
          if (s.endNode > highest) highest = s.endNode;
        }
      }
      return highest.clamp(1, _maxAllowedNodes);
    }();

    final warnings = <String>[
      if (startDate == null) '该口令未包含开学日期，已使用默认开学周次，可在课表设置中调整。',
      if (skipped > 0) '已自动跳过 $skipped 个无效或时间超出范围的时段。',
    ];

    final settings = TimetableSettings(
      scheduleName: defaultName,
      termStartDate: startDate,
      maxWeeks: maxWeeks,
      nodesPerDay: effectiveNodesPerDay,
      termStartFromJwxt: startDate != null,
    );

    return WakeupImportResult(
      defaultName: defaultName,
      snapshot: TimetableSnapshot(
        courses: List.unmodifiable(courses),
        periods: periods,
        settings: settings,
        syncedAt: DateTime.now(),
      ),
      courseCount: courses.length,
      slotCount: slotCount,
      exams: List.unmodifiable(exams),
      userColors: Map.unmodifiable(userColors),
      skippedCount: skipped,
      isMock: isMock,
      warnings: List.unmodifiable(warnings),
    );
  }

  static const List<PeriodTime> _fallbackPeriodTimes = [
    PeriodTime(node: 1, start: '08:00', end: '08:45'),
    PeriodTime(node: 2, start: '08:55', end: '09:40'),
    PeriodTime(node: 3, start: '10:10', end: '10:55'),
    PeriodTime(node: 4, start: '11:05', end: '11:50'),
    PeriodTime(node: 5, start: '13:45', end: '14:30'),
    PeriodTime(node: 6, start: '14:40', end: '15:25'),
    PeriodTime(node: 7, start: '15:55', end: '16:40'),
    PeriodTime(node: 8, start: '16:50', end: '17:35'),
    PeriodTime(node: 9, start: '18:45', end: '19:30'),
    PeriodTime(node: 10, start: '19:40', end: '20:25'),
    PeriodTime(node: 11, start: '20:35', end: '21:20'),
  ];

  static bool _isExamEntry({
    required String name,
    required Map<String, dynamic> slotMap,
    Map<String, dynamic>? baseMap,
    int? rawColor,
  }) {
    final kind = '${slotMap['kind'] ?? baseMap?['kind'] ?? ''}'
        .trim()
        .toLowerCase();
    if (kind == 'exam') return true;
    final trimmedName = name.trim();
    if (trimmedName.startsWith('【考试】') || trimmedName.startsWith('[考试]')) {
      return true;
    }
    final note =
        '${slotMap['note'] ?? slotMap['courseNote'] ?? baseMap?['note'] ?? ''}'
            .trim();
    final hasStartTime = _hhmm(slotMap['startTime']) != null;
    final hasEndTime = _hhmm(slotMap['endTime']) != null;
    final hasCustomTime =
        slotMap['ownTime'] == true || (hasStartTime && hasEndTime);
    if (rawColor == 0xFFC62828 && (hasCustomTime || note.contains('考试'))) {
      return true;
    }
    if (note.contains('考试') && slotMap['ownTime'] == true) {
      return true;
    }
    return false;
  }

  static String _stripExamPrefix(String name) {
    final stripped = name
        .trim()
        .replaceFirst(RegExp(r'^(?:【考试】|\[考试\])\s*'), '')
        .trim();
    return stripped.isEmpty ? name.trim() : stripped;
  }

  static List<ScheduleEvent> _tryExtractExamEvents({
    required String name,
    required Map<String, dynamic> slotMap,
    Map<String, dynamic>? baseMap,
    required DateTime? startDate,
    required List<PeriodTime> periods,
    required int maxWeeks,
    required int maxNode,
    required int Function() nextSeq,
  }) {
    final title = _stripExamPrefix(name);
    if (title.isEmpty) return const [];

    TimeOfDayMinutes? start = TimeOfDayMinutes.tryParse(
      _hhmm(slotMap['startTime']),
    );
    TimeOfDayMinutes? end = TimeOfDayMinutes.tryParse(
      _hhmm(slotMap['endTime']),
    );
    if (start == null || end == null) {
      final startNode = _asInt(
        slotMap['startNode'] ?? slotMap['node'] ?? slotMap['startSection'],
      );
      final step = _asInt(slotMap['step']);
      var endNode =
          _asInt(slotMap['endNode'] ?? slotMap['endSection']) ??
          (startNode != null && step != null && step > 0
              ? startNode + step - 1
              : startNode);
      if (startNode != null &&
          endNode != null &&
          startNode >= 1 &&
          startNode <= maxNode &&
          endNode >= startNode) {
        if (endNode > maxNode) endNode = maxNode;
        final startPeriod = periods
            .where((p) => p.node == startNode)
            .firstOrNull;
        final endPeriod = periods.where((p) => p.node == endNode).firstOrNull;
        start ??= TimeOfDayMinutes.tryParse(startPeriod?.start);
        end ??= TimeOfDayMinutes.tryParse(endPeriod?.end);
      }
    }
    if (start == null || end == null || end.compareTo(start) <= 0) {
      return const [];
    }

    final dates = <DateTime>[];
    final explicitDate = _parseDate(slotMap['date']?.toString());
    if (explicitDate != null) {
      dates.add(explicitDate);
    } else if (startDate != null) {
      final day = _asInt(slotMap['day']);
      final weeks = _parseWeeks(slotMap, maxWeeks: maxWeeks);
      if (day == null || day < 1 || day > 7 || weeks == null) {
        return const [];
      }
      for (var i = 0; i < weeks.length; i++) {
        if (weeks[i] == '1') {
          dates.add(startDate.add(Duration(days: i * 7 + (day - 1))));
        }
      }
    }
    if (dates.isEmpty) return const [];

    final location =
        '${slotMap['location'] ?? slotMap['room'] ?? slotMap['position'] ?? ''}'
            .trim();
    final rawNote =
        '${slotMap['note'] ?? slotMap['courseNote'] ?? baseMap?['note'] ?? ''}'
            .trim();
    return [
      for (final date in dates)
        ScheduleEvent(
          id: 'wk_exam_${nextSeq()}',
          kind: ScheduleKind.exam,
          source: ScheduleSource.manual,
          title: title,
          date: date,
          start: start,
          end: end,
          location: location,
          note: rawNote,
        ),
    ];
  }

  /// 兼容 WakeUp 官方 `share_schedule/getv2` 的 `shareData` 多行 JSON 字符串格式。
  static Map<String, dynamic> _unwrapWakeupPayload(Map<String, dynamic> raw) {
    var root = raw;
    if (root['data'] is Map &&
        root['shareData'] == null &&
        root['share_data'] == null &&
        root['courses'] == null &&
        root['details'] == null &&
        root['items'] == null &&
        root['courseList'] == null &&
        root['table'] == null &&
        root['tableBean'] == null) {
      root = Map<String, dynamic>.from(root['data'] as Map);
    }

    final rawShareData = root['shareData'] ?? root['share_data'];
    if (rawShareData is! String || rawShareData.trim().isEmpty) {
      return root;
    }

    final decodedBlocks = <Object?>[];
    for (final line in rawShareData.split(RegExp(r'\r?\n'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        decodedBlocks.add(jsonDecode(trimmed));
      } catch (_) {}
    }
    if (decodedBlocks.isEmpty) return root;

    Map<String, dynamic>? tableMeta;
    List<Object?>? periods;
    List<Object?>? courses;
    List<Object?>? details;

    for (final block in decodedBlocks) {
      if (block is Map) {
        final m = Map<String, dynamic>.from(block);
        if (m.containsKey('tableName') ||
            m.containsKey('maxWeek') ||
            m.containsKey('maxWeeks') ||
            m.containsKey('startDate') ||
            m.containsKey('nodes')) {
          tableMeta = m;
        }
      } else if (block is List && block.isNotEmpty) {
        final first = block.first;
        if (first is Map) {
          if ((first.containsKey('startTime') || first.containsKey('start')) &&
              (first.containsKey('endTime') || first.containsKey('end')) &&
              !first.containsKey('day') &&
              !first.containsKey('startNode')) {
            periods ??= block;
          } else if (first.containsKey('day') ||
              first.containsKey('startNode') ||
              first.containsKey('step') ||
              first.containsKey('startWeek')) {
            details ??= block;
          } else if (first.containsKey('courseName') ||
              first.containsKey('name') ||
              first.containsKey('id')) {
            courses ??= block;
          }
        }
      }
    }

    // WakeUp 标准 5 行顺序兜底：[timeConfig, timeSlots, table, courses, details]。
    if (decodedBlocks.length >= 5) {
      periods ??= decodedBlocks[1] is List
          ? decodedBlocks[1] as List<Object?>
          : null;
      tableMeta ??= decodedBlocks[2] is Map
          ? Map<String, dynamic>.from(decodedBlocks[2] as Map)
          : null;
      courses ??= decodedBlocks[3] is List
          ? decodedBlocks[3] as List<Object?>
          : null;
      details ??= decodedBlocks[4] is List
          ? decodedBlocks[4] as List<Object?>
          : null;
    }

    return <String, dynamic>{
      ...root,
      'table': ?tableMeta,
      'periods': ?periods,
      'courses': ?courses,
      'details': ?details,
    };
  }

  /// 将同一课程下星期、节次、地点、教师、备注完全一致的拆分周次条合并为一个时段。
  static List<CourseSlot> _mergeCourseSlots(List<CourseSlot> slots) {
    if (slots.length <= 1) return slots;
    final bySignature = <String, CourseSlot>{};
    for (final slot in slots) {
      final sig =
          '${slot.day}|${slot.startNode}|${slot.endNode}|'
          '${slot.teacher}|${slot.location}|${slot.note}';
      final prev = bySignature[sig];
      if (prev == null) {
        bySignature[sig] = slot;
        continue;
      }
      final maxLen = prev.weeks.length > slot.weeks.length
          ? prev.weeks.length
          : slot.weeks.length;
      final bits = List<String>.generate(maxLen, (i) {
        final a = i < prev.weeks.length && prev.weeks[i] == '1';
        final b = i < slot.weeks.length && slot.weeks[i] == '1';
        return (a || b) ? '1' : '0';
      });
      bySignature[sig] = CourseSlot(
        day: prev.day,
        startNode: prev.startNode,
        endNode: prev.endNode,
        weeks: bits.join(),
        teacher: prev.teacher,
        location: prev.location,
        note: prev.note,
      );
    }
    return List<CourseSlot>.unmodifiable(bySignature.values);
  }

  static List<PeriodTime> _parsePeriods(Object? raw) {
    if (raw is! List) return const [];
    final out = <PeriodTime>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final node = _asInt(
        item['node'] ?? item['n'] ?? item['section'] ?? item['DM'],
      );
      final start = _hhmm(item['start'] ?? item['startTime'] ?? item['KSSJ']);
      final end = _hhmm(item['end'] ?? item['endTime'] ?? item['JSSJ']);
      if (node == null || node < 1 || start == null || end == null) continue;
      out.add(PeriodTime(node: node, start: start, end: end));
    }
    out.sort((a, b) => a.node.compareTo(b.node));
    return out;
  }

  static CourseSlot? _parseSlot(
    Map<String, dynamic> map, {
    required int maxWeeks,
    required int maxNode,
    String fallbackNote = '',
  }) {
    final day = _asInt(map['day']);
    final startNode = _asInt(
      map['startNode'] ?? map['node'] ?? map['startSection'],
    );
    final step = _asInt(map['step']);
    var endNode =
        _asInt(map['endNode'] ?? map['endSection']) ??
        (startNode != null && step != null && step > 0
            ? startNode + step - 1
            : startNode);
    if (day == null || day < 1 || day > 7) return null;
    if (startNode == null || startNode < 1 || startNode > maxNode) return null;
    if (endNode == null || endNode < startNode) return null;
    if (endNode > maxNode) endNode = maxNode;

    final weeks = _parseWeeks(map, maxWeeks: maxWeeks);
    if (weeks == null || !weeks.contains('1')) return null;

    final rawNote = '${map['note'] ?? map['courseNote'] ?? ''}'.trim();
    return CourseSlot(
      day: day,
      startNode: startNode,
      endNode: endNode,
      weeks: weeks,
      teacher: '${map['teacher'] ?? ''}'.trim(),
      location: '${map['location'] ?? map['room'] ?? map['position'] ?? ''}'
          .trim(),
      note: rawNote.isNotEmpty ? rawNote : fallbackNote,
    );
  }

  static String? _parseWeeks(
    Map<String, dynamic> map, {
    required int maxWeeks,
  }) {
    final rawWeeks = map['weeks'] ?? map['stepWeekList'];
    if (rawWeeks is String && RegExp(r'^[01]+$').hasMatch(rawWeeks)) {
      if (rawWeeks.length >= maxWeeks) return rawWeeks.substring(0, maxWeeks);
      return rawWeeks.padRight(maxWeeks, '0');
    }
    if (rawWeeks is List) {
      final bits = List.filled(maxWeeks, '0');
      for (final w in rawWeeks) {
        final idx = _asInt(w);
        if (idx != null && idx >= 1 && idx <= maxWeeks) {
          bits[idx - 1] = '1';
        }
      }
      return bits.join();
    }
    final startWeek = _asInt(map['startWeek']);
    final endWeek = _asInt(map['endWeek']);
    if (startWeek != null && endWeek != null && endWeek >= startWeek) {
      final type = _asInt(map['type']) ?? 0; // 0=全周, 1=单周, 2=双周
      final bits = List.filled(maxWeeks, '0');
      for (var w = startWeek; w <= endWeek && w <= maxWeeks; w++) {
        if (w < 1) continue;
        if (type == 1 && w.isEven) continue;
        if (type == 2 && w.isOdd) continue;
        bits[w - 1] = '1';
      }
      return bits.join();
    }
    return null;
  }

  static int? _parseHexOrArgb(Object? raw) {
    if (raw is int) return raw | 0xFF000000;
    if (raw is String) {
      final s = raw.trim();
      final hex = s.startsWith('#') ? s.substring(1) : s;
      if (RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) {
        final v = int.tryParse(hex, radix: 16);
        return v == null ? null : (0xFF000000 | v);
      }
      if (RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(hex)) {
        return int.tryParse(hex, radix: 16);
      }
    }
    return null;
  }

  static int? _asInt(Object? v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse('${v ?? ''}'));

  static double? _asDouble(Object? v) => v is double
      ? v
      : (v is num ? v.toDouble() : double.tryParse('${v ?? ''}'));

  static DateTime? _parseDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final parsed = DateTime.tryParse(raw.trim().split(' ').first);
    return parsed == null
        ? null
        : DateTime(parsed.year, parsed.month, parsed.day);
  }

  static String? _hhmm(Object? v) {
    if (v == null) return null;
    final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch('$v'.trim());
    if (m == null) return null;
    final h = int.tryParse(m.group(1)!);
    final min = int.tryParse(m.group(2)!);
    if (h == null || min == null || h < 0 || h > 23 || min < 0 || min > 59) {
      return null;
    }
    return '${h.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}';
  }
}

class _MutableImportedCourse {
  _MutableImportedCourse({
    required this.id,
    required this.name,
    this.credit,
    this.color,
  });

  final String id;
  final String name;
  final double? credit;
  final int? color;
  final List<CourseSlot> slots = [];
}
