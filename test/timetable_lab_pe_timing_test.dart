import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_timing.dart';

Map<String, dynamic> _row({
  required String name,
  required String code,
  Object? sfsyk,
  bool includeSfsyk = true,
  int day = 1,
  int start = 1,
  int end = 2,
}) => {
  'KCM': name,
  'KCH': code,
  'KXH': '01',
  'SKXQ': day,
  'KSJC': start,
  'JSJC': end,
  'SKZC': '1' * 16,
  if (includeSfsyk) 'SFSYK': sfsyk,
};

CourseSlot _slot({bool isLab = false, int start = 5, int end = 6}) =>
    CourseSlot(
      day: 1,
      startNode: start,
      endNode: end,
      weeks: '1' * 16,
      isLab: isLab,
    );

void main() {
  final periods = TimetableController.defaultPeriods();

  group('SFSYK 解析', () {
    test('"1" / 1 / true 都解析为实验课', () {
      for (final (i, raw) in <Object>['1', 1, true].indexed) {
        final result = TimetableParser.parseKbRows([
          _row(name: '大学物理实验', code: 'L$i', sfsyk: raw),
        ]);
        expect(
          result.courses.single.slots.single.isLab,
          isTrue,
          reason: 'SFSYK=$raw',
        );
      }
    });

    test('"0" / 0 / false / 缺省 / null 为普通课', () {
      for (final (i, raw) in <Object>['0', 0, false].indexed) {
        final result = TimetableParser.parseKbRows([
          _row(name: '高等数学', code: 'N$i', sfsyk: raw),
        ]);
        expect(
          result.courses.single.slots.single.isLab,
          isFalse,
          reason: 'SFSYK=$raw',
        );
      }
      final missing = TimetableParser.parseKbRows([
        _row(name: '高等数学', code: 'N9', includeSfsyk: false),
      ]);
      expect(missing.courses.single.slots.single.isLab, isFalse);
      final nullValue = TimetableParser.parseKbRows([
        _row(name: '高等数学', code: 'N10', sfsyk: null),
      ]);
      expect(nullValue.courses.single.slots.single.isLab, isFalse);
    });
  });

  group('体育课启发式', () {
    test('体育序号课名识别为体育课', () {
      expect(looksLikePeCourse('体育Ⅰ'), isTrue);
      expect(looksLikePeCourse(' 大学体育（三） '), isFalse);
      expect(
        timingKindOf(
          course: const Course(id: 'p', name: '体育Ⅱ'),
          slot: _slot(),
        ),
        CourseTimingKind.pe,
      );
    });

    test('理论课不误判，实验标记优先于课名', () {
      expect(looksLikePeCourse('大学物理实验'), isFalse);
      expect(looksLikePeCourse('高等数学A'), isFalse);
      expect(
        timingKindOf(
          course: const Course(id: 'x', name: '体育实验'),
          slot: _slot(isLab: true),
        ),
        CourseTimingKind.lab,
      );
    });
  });

  group('体育课场地优先与显示名', () {
    Course parse(Map<String, dynamic> fields) => TimetableParser.parseKbRows([
      {..._row(name: '测试课程', code: 'TEST'), ...fields},
    ]).courses.single;

    test('体育板块场地是主判断，无需体育课名或课程号', () {
      final c = parse({'JXLDM_DISPLAY': '体育板块场地'});
      expect(c.isPe, isTrue);
      expect(
        timingKindOf(course: c, slot: c.slots.single),
        CourseTimingKind.pe,
      );
    });

    test('非空其他场地禁止课程号和课名兜底', () {
      final c = parse({
        'JXLDM_DISPLAY': '测试教学楼',
        'KCH': '20000048',
        'KCM': '体育',
      });
      expect(c.isPe, isFalse);
      expect(
        timingKindOf(course: c, slot: c.slots.single),
        CourseTimingKind.standard,
      );
    });

    test('场地为空、null 或缺失才按课程号兜底', () {
      for (final fields in <Map<String, dynamic>>[
        {},
        {'JXLDM_DISPLAY': ''},
        {'JXLDM_DISPLAY': null},
      ]) {
        expect(parse({...fields, 'KCH': '20000048'}).isPe, isTrue);
      }
    });

    test('体育原名和只含数字括号序号的后缀可兜底', () {
      for (final name in ['体育', '体育2', '体育（3）', '体育(三)', '体育Ⅰ', '体育①']) {
        expect(parse({'KCM': name}).isPe, isTrue, reason: name);
      }
    });

    test('体育概论不命中', () {
      expect(parse({'KCM': '体育概论'}).isPe, isFalse);
    });

    test('体育心理学、体育实验、大学体育均不命中', () {
      for (final name in ['体育心理学', '体育实验', '大学体育']) {
        expect(parse({'KCM': name}).isPe, isFalse, reason: name);
      }
    });

    test('KCXMMC 不能识别体育课，普通课不拼接项目名', () {
      final c = parse({'KCM': '大学英语', 'KCXMMC': '六级'});
      expect(c.isPe, isFalse);
      expect(c.displayName, '大学英语');
    });

    test('体育课项目非空才拼接，空项目不带分隔符', () {
      expect(parse({'KCM': '体育（3）', 'KCXMMC': '射箭'}).displayName, '体育·射箭');
      for (final project in [null, '', '  ']) {
        expect(parse({'KCM': '体育（3）', 'KCXMMC': project}).displayName, '体育（3）');
      }
    });

    test('所有允许的序号均从体育项目显示名移除，原课名保留', () {
      for (final name in ['体育', '体育2', '体育（3）', '体育(三)', '体育Ⅰ', '体育①']) {
        final c = parse({'KCM': name, 'KCXMMC': '射箭'});
        expect(c.displayName, '体育·射箭', reason: name);
        expect(c.name, name);
        expect(Course.fromJson(c.toJson()).displayName, '体育·射箭');
        expect(c.copyWith(projectName: '').displayName, name);
      }
    });

    test('原始字段经过缓存和 copyWith 后保留主判断与显示名', () {
      final c = parse({'KCM': '体育', 'JXLDM_DISPLAY': '测试教学楼', 'KCXMMC': '六级'});
      final restored = Course.fromJson(jsonDecode(jsonEncode(c.toJson())))
          .copyWith(hidden: true);
      expect(restored.buildingDisplay, '测试教学楼');
      expect(restored.projectName, '六级');
      expect(restored.isPe, isFalse);
      expect(restored.displayName, '体育');
    });
  });

  group('QA LAB：实验/体育连续段取消小课间', () {
    test('学校作息共 11 节', () {
      expect(periods.map((p) => p.node).toList(), [
        for (var i = 1; i <= kNuistMaxPeriodNode; i++) i,
      ]);
    });

    test('1–2 节 → 08:00–09:30', () {
      for (final kind in [CourseTimingKind.lab, CourseTimingKind.pe]) {
        final segs = resolveTimingSegments(
          periods: periods,
          startNode: 1,
          endNode: 2,
          kind: kind,
        );
        expect(segs, hasLength(1), reason: '$kind');
        expect(segs.single.startNode, 1);
        expect(segs.single.endNode, 2);
        expect(segs.single.start, '08:00');
        expect(segs.single.end, '09:30');
      }
    });

    test('1–3 节 → 08:00–09:30 + 大课间 + 10:10–10:55', () {
      final segs = resolveTimingSegments(
        periods: periods,
        startNode: 1,
        endNode: 3,
        kind: CourseTimingKind.lab,
      );
      expect(segs, hasLength(2));
      expect((segs[0].start, segs[0].end), ('08:00', '09:30'));
      expect((segs[0].startNode, segs[0].endNode), (1, 2));
      expect((segs[1].start, segs[1].end), ('10:10', '10:55'));
      expect((segs[1].startNode, segs[1].endNode), (3, 3));
      final bounds = effectiveSlotBounds(
        periods: periods,
        startNode: 1,
        endNode: 3,
        kind: CourseTimingKind.lab,
      );
      expect((bounds.start, bounds.end), ('08:00', '10:55'));
    });

    test('9–11 节 → 18:45–21:00', () {
      final segs = resolveTimingSegments(
        periods: periods,
        startNode: 9,
        endNode: 11,
        kind: CourseTimingKind.pe,
      );
      expect(segs, hasLength(1));
      expect(segs.single.start, '18:45');
      expect(segs.single.end, '21:00');
    });

    test('标准课不压缩小课间', () {
      final segs = resolveTimingSegments(
        periods: periods,
        startNode: 1,
        endNode: 2,
        kind: CourseTimingKind.standard,
      );
      expect(segs, hasLength(1));
      expect((segs.single.start, segs.single.end), ('08:00', '09:40'));
    });

    test('单节实验/体育与标准相同', () {
      final segs = resolveTimingSegments(
        periods: periods,
        startNode: 3,
        endNode: 3,
        kind: CourseTimingKind.lab,
      );
      expect(segs.single.label, '10:10-10:55');
    });
  });

  group('JSON 往返', () {
    test('isLab 为 true 时持久化并可还原', () {
      final snap = TimetableSnapshot(
        courses: [
          Course(
            id: 'MK000401|17',
            name: '大学物理实验B',
            source: CourseSource.jwxt,
            slots: [_slot(isLab: true)],
          ),
        ],
        periods: const [PeriodTime(node: 5, start: '13:45', end: '14:30')],
      );
      final json =
          jsonDecode(jsonEncode(snap.toJson())) as Map<String, dynamic>;
      final restored = TimetableSnapshot.fromJson(json);
      expect(restored.courses.single.slots.single.isLab, isTrue);
    });

    test('旧数据没有 isLab 时缺省 false', () {
      final slot = CourseSlot.fromJson({
        'day': 1,
        'startNode': 5,
        'endNode': 6,
        'weeks': '1' * 16,
      });
      expect(slot.isLab, isFalse);
      expect(slot.toJson().containsKey('isLab'), isFalse);
      expect(
        CourseSlot.fromJson({
          'day': 1,
          'startNode': 5,
          'endNode': 6,
          'weeks': '1' * 16,
          'isLab': 1,
        }).isLab,
        isTrue,
      );
    });

    test('拆分时段保留实验标记', () {
      final split = _slot(isLab: true)
          .withSplitFrom(const SlotRef(day: 1, startNode: 5, endNode: 6));
      expect(split.isLab, isTrue);
      expect(split.splitFrom, isNotNull);
    });
  });

  group('mergeTimingSlots 地点去重', () {
    test('实验课连堂地点按 / 拆开后按出现顺序去重', () {
      const course = Course(id: 'lab', name: '数据结构课程设计');
      final slots = [
        CourseSlot(
          day: 2,
          startNode: 1,
          endNode: 2,
          weeks: '1',
          location: '长望楼S508',
          isLab: true,
        ),
        CourseSlot(
          day: 2,
          startNode: 3,
          endNode: 4,
          weeks: '1',
          location: '长望楼S302',
          isLab: true,
        ),
        CourseSlot(
          day: 2,
          startNode: 5,
          endNode: 6,
          weeks: '1',
          location: '长望楼S508',
          isLab: true,
        ),
        CourseSlot(
          day: 2,
          startNode: 7,
          endNode: 8,
          weeks: '1',
          location: '长望楼S508',
          isLab: true,
        ),
      ];
      final merged = mergeTimingSlots(course, slots);
      expect(merged, hasLength(1));
      expect(merged.single.startNode, 1);
      expect(merged.single.endNode, 8);
      expect(merged.single.location, '长望楼S508 / 长望楼S302');
    });
  });
}
