import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_notify_plan.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_notify_service.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
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

  group('显式课程类型', () {
    test('普通类型覆盖教务实验和体育识别，体育项目名也跟随类型', () {
      const course = Course(
        id: 'kind',
        name: '体育Ⅱ',
        buildingDisplay: '体育板块场地',
        projectName: '羽毛球',
      );
      final old = _slot(isLab: true, start: 1, end: 2);
      expect(
        courseDisplayName(course: course.forSlot(old), slot: old),
        '体育·羽毛球',
      );
      for (final kind in CourseKind.values) {
        final slot = CourseSlot.fromJson(old.copyWith(kind: kind).toJson());
        final displayed = course.forSlot(slot);
        expect(courseKindOf(course: displayed, slot: slot), kind);
        expect(
          resolveTimingSegments(
            periods: periods,
            startNode: 1,
            endNode: 2,
            kind: timingKindOf(course: displayed, slot: slot),
          ).single.end,
          kind == CourseKind.lab || kind == CourseKind.pe ? '09:30' : '09:40',
        );
        expect(
          courseDisplayName(course: displayed, slot: slot),
          kind == CourseKind.pe ? '体育·羽毛球' : '体育Ⅱ',
        );
      }
    });

    test('实验与普通相邻时段不合并，复制和拆分保留显式类型', () {
      const course = Course(id: 'kind', name: '测试课程');
      final first = _slot(
        start: 1,
        end: 1,
      ).copyWith(kind: CourseKind.lab, nameOverride: '实验安排', color: 0xFF123456);
      final second = _slot(
        start: 2,
        end: 2,
      ).copyWith(kind: CourseKind.standard);
      expect(mergeTimingSlots(course, [first, second]), hasLength(2));
      final copied = first.withSplitFrom(first.ref);
      expect(copied.kind, CourseKind.lab);
      expect(copied.nameOverride, '实验安排');
      expect(copied.color, 0xFF123456);
      expect(
        CourseSlot.fromJson({...first.toJson(), 'courseKind': 'unknown'}).kind,
        isNull,
      );
    });
  });

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

    test('场地、课程号与课名兜底识别体育课', () {
      final byBuilding = parse({'JXLDM_DISPLAY': '体育板块场地'});
      expect(byBuilding.isPe, isTrue);
      expect(
        timingKindOf(course: byBuilding, slot: byBuilding.slots.single),
        CourseTimingKind.pe,
      );

      final otherBuilding = parse({
        'JXLDM_DISPLAY': '测试教学楼',
        'KCH': '20000048',
        'KCM': '体育',
      });
      expect(otherBuilding.isPe, isFalse);
      expect(
        timingKindOf(course: otherBuilding, slot: otherBuilding.slots.single),
        CourseTimingKind.standard,
      );

      for (final fields in <Map<String, dynamic>>[
        {},
        {'JXLDM_DISPLAY': ''},
        {'JXLDM_DISPLAY': null},
      ]) {
        expect(parse({...fields, 'KCH': '20000048'}).isPe, isTrue);
      }

      for (final name in ['体育', '体育2', '体育（3）', '体育(三)', '体育Ⅰ', '体育①']) {
        expect(parse({'KCM': name}).isPe, isTrue, reason: name);
      }
      for (final name in ['体育概论', '体育心理学', '体育实验', '大学体育']) {
        expect(parse({'KCM': name}).isPe, isFalse, reason: name);
      }
    });

    test('体育项目名拼接、去序号显示与序列化保留', () {
      final normal = parse({'KCM': '大学英语', 'KCXMMC': '六级'});
      expect(normal.isPe, isFalse);
      expect(normal.displayName, '大学英语');

      expect(parse({'KCM': '体育（3）', 'KCXMMC': '射箭'}).displayName, '体育·射箭');
      for (final project in [null, '', '  ']) {
        expect(parse({'KCM': '体育（3）', 'KCXMMC': project}).displayName, '体育（3）');
      }

      for (final name in ['体育', '体育2', '体育（3）', '体育(三)', '体育Ⅰ', '体育①']) {
        final c = parse({'KCM': name, 'KCXMMC': '射箭'});
        expect(c.displayName, '体育·射箭', reason: name);
        expect(c.name, name);
        expect(Course.fromJson(c.toJson()).displayName, '体育·射箭');
        expect(c.copyWith(projectName: '').displayName, name);
      }

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
    test('实验/体育连续段与大课间压缩规则、标准课与单节不变', () {
      expect(periods.map((p) => p.node).toList(), [
        for (var i = 1; i <= kNuistMaxPeriodNode; i++) i,
      ]);

      for (final kind in [CourseTimingKind.lab, CourseTimingKind.pe]) {
        final segs = resolveTimingSegments(
          periods: periods,
          startNode: 1,
          endNode: 2,
          kind: kind,
        );
        expect(segs, hasLength(1), reason: '$kind');
        expect((segs.single.startNode, segs.single.endNode), (1, 2));
        expect((segs.single.start, segs.single.end), ('08:00', '09:30'));
      }

      final three = resolveTimingSegments(
        periods: periods,
        startNode: 1,
        endNode: 3,
        kind: CourseTimingKind.lab,
      );
      expect(three, hasLength(2));
      expect(
        (three[0].start, three[0].end, three[0].startNode, three[0].endNode),
        ('08:00', '09:30', 1, 2),
      );
      expect(
        (three[1].start, three[1].end, three[1].startNode, three[1].endNode),
        ('10:10', '10:55', 3, 3),
      );
      final bounds = effectiveSlotBounds(
        periods: periods,
        startNode: 1,
        endNode: 3,
        kind: CourseTimingKind.lab,
      );
      expect((bounds.start, bounds.end), ('08:00', '10:55'));

      final night = resolveTimingSegments(
        periods: periods,
        startNode: 9,
        endNode: 11,
        kind: CourseTimingKind.pe,
      );
      expect((night.single.start, night.single.end), ('18:45', '21:00'));

      final std = resolveTimingSegments(
        periods: periods,
        startNode: 1,
        endNode: 2,
        kind: CourseTimingKind.standard,
      );
      expect((std.single.start, std.single.end), ('08:00', '09:40'));

      final single = resolveTimingSegments(
        periods: periods,
        startNode: 3,
        endNode: 3,
        kind: CourseTimingKind.lab,
      );
      expect(single.single.label, '10:10-10:55');
    });
  });

  group('JSON 往返', () {
    test('isLab 持久化、旧数据缺省 false 与拆分保留实验标记', () {
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

    test('小组件数据导出：周二数据结构课程设计 payload 含四段实验时刻', () {
      final samplePath = File(
        'test/fixtures/timetable/kb_lab_tuesday_sample.json',
      );
      if (!samplePath.existsSync()) return;
      final tmp = Directory.systemTemp.createTempSync('lab_time_render_');
      final ctl = TimetableController.instance;
      TimetableStore.debugDirectory = tmp;
      ctl.debugReset();
      addTearDown(() {
        ctl.debugReset();
        TimetableStore.debugDirectory = null;
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final termStart = DateTime(2026, 8, 31);
      final tuesday = DateTime(2026, 12, 29);
      const courseName = '数据结构课程设计';
      const payloadTimes = [
        '08:00-09:30',
        '10:10-11:40',
        '13:45-15:15',
        '15:55-17:25',
      ];
      final raw =
          jsonDecode(samplePath.readAsStringSync()) as Map<String, dynamic>;
      final rows = ((raw['datas'] as Map)['cxxszhxqkb'] as Map)['rows'] as List;
      final courses = TimetableParser.parseKbRows(rows).courses;
      ctl.debugSetSnapshot(
        TimetableSnapshot(
          courses: courses,
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termStartDate: termStart,
            homeMaxItems: 4,
            widgetCourseCount: 3,
            showLocation: false,
            showTeacher: false,
          ),
          syncedAt: termStart,
        ),
        viewingWeek: 18,
      );
      final svc = TimetableNotifyService(controller: ctl);
      final classes = svc.classesOn(tuesday).where((c) => c.name == courseName);
      expect(classes.map((c) => c.timeRange), payloadTimes);

      final payload = buildWidgetPayload(
        now: DateTime(2026, 12, 29, 7),
        classesOn: svc.classesOn,
        prefs: const WidgetPrefs(courseCount: 3, showPeriod: true),
        lastSyncedAt: termStart,
      );
      expect(payload['state'], 'ok');
      final items = ((payload['days'] as List).first as Map)['items'] as List;
      final labItems = items.where((e) => (e as Map)['name'] == courseName);
      expect(labItems, hasLength(4));
      expect([
        for (final e in labItems)
          ((e as Map)['periodTime'] as String).split(' ').last,
      ], payloadTimes);

      final bare = buildWidgetPayload(
        now: DateTime(2026, 12, 29, 7),
        classesOn: svc.classesOn,
        prefs: const WidgetPrefs(courseCount: 3, showPeriod: false),
        lastSyncedAt: termStart,
      );
      final bareItems = ((bare['days'] as List).first as Map)['items'] as List;
      expect([
        for (final e in bareItems)
          if ((e as Map)['name'] == courseName) e['periodTime'],
      ], payloadTimes);
    });
  });
}
