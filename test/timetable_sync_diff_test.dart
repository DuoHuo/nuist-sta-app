import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_change_format.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_sync_diff.dart';

CourseSlot _slot({
  int day = 1,
  int start = 5,
  int end = 6,
  String weeks = '111111111111111100000000',
  String teacher = '黄晓燕',
  String location = '滨江BS413',
  int istk = 0,
}) => CourseSlot(
  day: day,
  startNode: start,
  endNode: end,
  weeks: weeks,
  teacher: teacher,
  location: location,
  istk: istk,
);

Course _jwxt({
  String code = '18001299',
  String classId = '70',
  String name = '学术英语（1）',
  List<CourseSlot>? slots,
}) => Course(
  id: '$code|$classId',
  name: name,
  code: code,
  classId: classId,
  source: CourseSource.jwxt,
  slots: slots ?? [_slot()],
);

void main() {
  setUp(() {
    TimetableChangeLogStore.debugMemory = [];
  });
  tearDown(() {
    TimetableChangeLogStore.debugMemory = null;
  });

  group('slotKey / normalize', () {
    test('buildSlotKey 六元组', () {
      expect(
        TimetableSyncDiff.buildSlotKey(
          code: '18001299',
          classId: '70',
          day: 1,
          startNode: 5,
          endNode: 6,
          weeks: '111111111111111100000000',
        ),
        '18001299|70|1|5|6|111111111111111100000000',
      );
    });

    test('教师中英文逗号与顺序不影响相等', () {
      expect(
        TimetableSyncDiff.normalizeTeachers('许川川,杨宇涵'),
        TimetableSyncDiff.normalizeTeachers('杨宇涵，许川川'),
      );
      expect(
        TimetableSyncDiff.normalizeTeachers(' 许川川 , 杨宇涵 '),
        TimetableSyncDiff.normalizeTeachers('杨宇涵,许川川'),
      );
    });

    test('地点 trim；ISTK null→0', () {
      expect(TimetableSyncDiff.normalizeLocation(' 滨江BS413 '), '滨江BS413');
      expect(TimetableSyncDiff.normalizeIstk(null), 0);
    });
  });

  group('compute', () {
    test('首次同步（旧为空）不记变动', () {
      final neu = [_jwxt()];
      expect(
        TimetableSyncDiff.compute(oldCourses: const [], newCourses: neu),
        isEmpty,
      );
    });

    test('忽略手动课，未排课未变时不重复记录', () {
      final manual = Course(
        id: 'm1',
        name: '手动',
        source: CourseSource.manual,
        slots: [_slot(location: 'A')],
      );
      final other = _jwxt(
        slots: [const CourseSlot(day: 0, startNode: 0, endNode: 0, weeks: '')],
      );
      final old = [manual, other, _jwxt()];
      final neu = [
        manual,
        other,
        _jwxt(slots: [_slot(location: '滨江BS401')]),
      ];
      final diffs = TimetableSyncDiff.compute(oldCourses: old, newCourses: neu);
      expect(diffs, hasLength(1));
      expect(diffs.single.type, TimetableChangeType.locationChanged);
    });

    test('地点变更', () {
      final old = [_jwxt()];
      final neu = [
        _jwxt(slots: [_slot(location: '滨江BS401')]),
      ];
      final diffs = TimetableSyncDiff.compute(oldCourses: old, newCourses: neu);
      expect(diffs.single.type, TimetableChangeType.locationChanged);
      expect(diffs.single.before!['JASMC'], '滨江BS413');
      expect(diffs.single.after!['JASMC'], '滨江BS401');
      expect(diffs.single.notified, isFalse);
      expect(diffs.single.fingerprint, startsWith('sha256:'));
      expect(
        TimetableChangeFormat.scopeOf(diffs.single),
        '影响范围：全部周次（第 1–16 周） · 周一 5–6节',
      );
    });

    test('同课拆周段变动只标出受影响周，不把其他时段的周次算进去', () {
      final old = [
        _jwxt(
          slots: [
            _slot(weeks: '00001'),
            _slot(day: 3),
          ],
        ),
      ];
      final neu = [
        _jwxt(
          slots: [
            _slot(weeks: '00001', location: '新教室'),
            _slot(day: 3),
          ],
        ),
      ];
      final record = TimetableSyncDiff.compute(
        oldCourses: old,
        newCourses: neu,
      ).single;
      expect(TimetableChangeFormat.scopeOf(record), '影响范围：第 5 周 · 周一 5–6节');
    });

    test('教师仅顺序变化 → 忽略', () {
      final old = [
        _jwxt(slots: [_slot(teacher: '许川川,杨宇涵')]),
      ];
      final neu = [
        _jwxt(slots: [_slot(teacher: '杨宇涵，许川川')]),
      ];
      expect(
        TimetableSyncDiff.compute(oldCourses: old, newCourses: neu),
        isEmpty,
      );
    });

    test('教师更换', () {
      final old = [
        _jwxt(slots: [_slot(teacher: '许川川,杨宇涵')]),
      ];
      final neu = [
        _jwxt(slots: [_slot(teacher: '许川川')]),
      ];
      final diffs = TimetableSyncDiff.compute(oldCourses: old, newCourses: neu);
      expect(diffs.single.type, TimetableChangeType.teacherChanged);
      expect(
        diffs.single.before!['SKJS'],
        TimetableSyncDiff.normalizeTeachers('许川川,杨宇涵'),
      );
      expect(diffs.single.after!['SKJS'], '许川川');
    });

    test('ISTK 变更', () {
      final old = [_jwxt()];
      final neu = [
        _jwxt(slots: [_slot(istk: 1)]),
      ];
      final diffs = TimetableSyncDiff.compute(oldCourses: old, newCourses: neu);
      expect(diffs.single.type, TimetableChangeType.retakeFlagChanged);
      expect(diffs.single.before!['ISTK'], 0);
      expect(diffs.single.after!['ISTK'], 1);
    });

    test('周次变化 → 单条时间变动', () {
      const oldWeeks = '111111111111111100000000';
      const newWeeks = '101010101010101000000000';
      final old = [
        _jwxt(slots: [_slot(weeks: oldWeeks)]),
      ];
      final neu = [
        _jwxt(slots: [_slot(weeks: newWeeks)]),
      ];
      final diffs = TimetableSyncDiff.compute(oldCourses: old, newCourses: neu);
      expect(diffs, hasLength(1));
      expect(diffs.single.type, TimetableChangeType.timeChanged);
      expect(diffs.single.type.labelZh, '时间变动');
      expect(diffs.single.before!['SKZC'], oldWeeks);
      expect(diffs.single.after!['SKZC'], newWeeks);
      expect(diffs.single.slotKey, contains(newWeeks));
      expect(
        TimetableChangeFormat.scopeOf(diffs.single),
        '影响范围：第 2–16 周（双） · 周一 5–6节',
      );
      expect(
        TimetableChangeFormat.detailOf(diffs.single),
        '第 1–16 周 · 周一 5–6节 → 第 1–15 周（单） · 周一 5–6节',
      );
    });

    test('周次增减只影响增减的周，地点同时变更则包含保留周', () {
      final old = [
        _jwxt(slots: [_slot(weeks: '1111')]),
      ];
      final neu = [
        _jwxt(slots: [_slot(weeks: '1110')]),
      ];
      final onlyWeeks = TimetableSyncDiff.compute(
        oldCourses: old,
        newCourses: neu,
      ).single;
      expect(TimetableChangeFormat.scopeOf(onlyWeeks), '影响范围：第 4 周 · 周一 5–6节');
      final reverse = TimetableSyncDiff.compute(
        oldCourses: neu,
        newCourses: old,
      ).single;
      expect(
        TimetableChangeFormat.scopeOf(reverse),
        TimetableChangeFormat.scopeOf(onlyWeeks),
      );

      final withLocation = TimetableSyncDiff.compute(
        oldCourses: old,
        newCourses: [
          _jwxt(
            slots: [_slot(weeks: '1110', location: '新教室')],
          ),
        ],
      ).single;
      expect(
        TimetableChangeFormat.scopeOf(withLocation),
        '影响范围：全部周次（第 1–4 周） · 周一 5–6节',
      );
    });

    test('星期与周次都变 → 仍单条时间变动', () {
      final old = [
        _jwxt(slots: [_slot(day: 1, weeks: '111100000000000000000000')]),
      ];
      final neu = [
        _jwxt(slots: [_slot(day: 3, weeks: '101010100000000000000000')]),
      ];
      final diffs = TimetableSyncDiff.compute(oldCourses: old, newCourses: neu);
      expect(diffs, hasLength(1));
      expect(diffs.single.type, TimetableChangeType.timeChanged);
      expect(diffs.single.before!['SKXQ'], 1);
      expect(diffs.single.after!['SKXQ'], 3);
      expect(
        TimetableChangeFormat.scopeOf(diffs.single),
        '影响范围：全部周次（第 1–5、7 周） · 周一 5–6节 → 周三 5–6节',
      );
      expect(
        TimetableChangeFormat.detailOf(diffs.single),
        '第 1–4 周 · 周一 5–6节 → 第 1–7 周（单） · 周三 5–6节',
      );
    });

    test('纯新增 / 纯删除（不同课程号，无法配对）', () {
      final old = [_jwxt()];
      final neu = [
        _jwxt(),
        _jwxt(code: '999', classId: '01', name: '新课', slots: [_slot(day: 2)]),
      ];
      final added = TimetableSyncDiff.compute(oldCourses: old, newCourses: neu);
      expect(added.single.type, TimetableChangeType.added);

      final removed = TimetableSyncDiff.compute(
        oldCourses: neu,
        newCourses: old,
      );
      expect(removed.single.type, TimetableChangeType.removed);
      expect(removed.single.after, isNull);
      expect(added.single.before, isNull);
      expect(
        TimetableChangeFormat.scopeOf(added.single),
        '影响范围：全部周次（第 1–16 周） · 周二 5–6节',
      );
      expect(
        TimetableChangeFormat.scopeOf(removed.single),
        TimetableChangeFormat.scopeOf(added.single),
      );
    });

    test('忽略 rows 顺序', () {
      final a = _jwxt(
        code: '1',
        classId: '1',
        name: 'A',
        slots: [_slot(day: 1)],
      );
      final b = _jwxt(
        code: '2',
        classId: '1',
        name: 'B',
        slots: [_slot(day: 2)],
      );
      expect(
        TimetableSyncDiff.compute(oldCourses: [a, b], newCourses: [b, a]),
        isEmpty,
      );
    });

    test('影响范围完整展示多个离散周段，保留具体节次', () {
      final record = TimetableSyncDiff.compute(
        oldCourses: [_jwxt()],
        newCourses: [
          _jwxt(),
          _jwxt(
            code: 'new',
            slots: [_slot(weeks: '11001100010011')],
          ),
        ],
      ).single;
      expect(
        TimetableChangeFormat.scopeOf(record),
        '影响范围：全部周次（第 1–2、5–6、10、13–14 周） · 周一 5–6节',
      );
    });

    test('空白差异忽略', () {
      final old = [
        _jwxt(
          slots: [_slot(location: '滨江BS413', teacher: '黄晓燕')],
        ),
      ];
      final neu = [
        _jwxt(
          slots: [_slot(location: ' 滨江BS413 ', teacher: ' 黄晓燕 ')],
        ),
      ];
      expect(
        TimetableSyncDiff.compute(oldCourses: old, newCourses: neu),
        isEmpty,
      );
    });
  });

  group('fingerprint / 通知去重', () {
    test('影响范围上下文不参与指纹，不会让已通知变动重复提醒', () {
      TimetableChangeRecord change({bool withOtherSlot = false}) =>
          TimetableSyncDiff.compute(
            oldCourses: [
              _jwxt(
                slots: [
                  _slot(weeks: '1111'),
                  if (withOtherSlot) _slot(day: 3),
                ],
              ),
            ],
            newCourses: [
              _jwxt(
                slots: [
                  _slot(weeks: '1111', location: '新教室'),
                  if (withOtherSlot) _slot(day: 3),
                ],
              ),
            ],
          ).single;
      final full = change();
      final partial = change(withOtherSlot: true);
      expect(partial.fingerprint, full.fingerprint);
      expect(TimetableChangeFormat.scopeOf(full), contains('全部周次'));
      expect(TimetableChangeFormat.scopeOf(partial), '影响范围：第 1–4 周 · 周一 5–6节');
    });

    test('相同实质变动同 fingerprint；再变地点则新 fingerprint', () async {
      final old = [_jwxt()];
      final mid = [
        _jwxt(slots: [_slot(location: '滨江BS401')]),
      ];
      final end = [
        _jwxt(slots: [_slot(location: '揽江楼N307')]),
      ];

      final first = TimetableSyncDiff.compute(oldCourses: old, newCourses: mid);
      final again = TimetableSyncDiff.compute(oldCourses: old, newCourses: mid);
      expect(first.single.fingerprint, again.single.fingerprint);

      final r1 = await TimetableChangeLogStore.upsertCandidates(first);
      expect(r1.toNotify, hasLength(1));
      await TimetableChangeLogStore.markNotified([
        r1.toNotify.single.fingerprint,
      ]);

      final r2 = await TimetableChangeLogStore.upsertCandidates(again);
      expect(r2.toNotify, isEmpty);
      expect(r2.allWritten.single.notified, isTrue);

      final next = TimetableSyncDiff.compute(oldCourses: mid, newCourses: end);
      expect(next.single.fingerprint, isNot(first.single.fingerprint));
      final r3 = await TimetableChangeLogStore.upsertCandidates(next);
      expect(r3.toNotify, hasLength(1));
    });

    test('applyAfterFetch 写入内存后端', () async {
      final old = [_jwxt()];
      final neu = [
        _jwxt(slots: [_slot(location: 'X')]),
      ];
      final result = await TimetableSyncDiff.applyAfterFetch(
        previousJwxtCourses: old,
        newJwxtCourses: neu,
        xnxqdm: '2026-2027-1',
      );
      expect(result.hasNewChanges, isTrue);
      expect(result.toNotify.single.xnxqdm, '2026-2027-1');
      final all = await TimetableChangeLogStore.readAll();
      expect(all, hasLength(1));
    });
  });

  group('JSON roundtrip', () {
    test('record toJson/fromJson', () {
      final old = [_jwxt()];
      final neu = [
        _jwxt(slots: [_slot(location: 'X')]),
      ];
      final rec = TimetableSyncDiff.compute(
        oldCourses: old,
        newCourses: neu,
        detectedAt: DateTime.parse('2026-10-27T09:00:00+08:00'),
        xnxqdm: '2026-2027-1',
        idFactory: () => 'id-1',
      ).single;
      final back = TimetableChangeRecord.fromJson(rec.toJson());
      expect(back.id, 'id-1');
      expect(back.type, TimetableChangeType.locationChanged);
      expect(back.slotKey, rec.slotKey);
      expect(back.fingerprint, rec.fingerprint);
      expect(back.xnxqdm, '2026-2027-1');
      expect(back.before!['JASMC'], '滨江BS413');
      expect(back.after!['JASMC'], 'X');
      expect(back.courseWeeks, '1111111111111111');
      expect(back.copyWith(notified: true).courseWeeks, back.courseWeeks);
      final legacyJson = rec.toJson()..remove('courseWeeks');
      final legacy = TimetableChangeRecord.fromJson(legacyJson);
      expect(legacy.courseWeeks, isEmpty);
      expect(TimetableChangeFormat.scopeOf(legacy), '影响范围：第 1–16 周 · 周一 5–6节');
      legacyJson['before'] = {'SKXQ': 1, 'KSJC': 5, 'JSJC': 6};
      legacyJson['after'] = {'SKXQ': 1, 'KSJC': 5, 'JSJC': 6};
      expect(
        TimetableChangeFormat.scopeOf(
          TimetableChangeRecord.fromJson(legacyJson),
        ),
        '影响范围：周次未知 · 周一 5–6节',
      );
    });
  });

  group('ISTK 解析入模型', () {
    test('parseKbRows 读取 ISTK 与地点回退', () {
      final rows = [
        {
          'KCM': '学术英语（1）',
          'KCH': '18001299',
          'KXH': '70',
          'SKXQ': 1,
          'KSJC': 5,
          'JSJC': 6,
          'SKZC': '111111111111111100000000',
          'SKJS': '黄晓燕',
          'JASMC': null,
          'JXLDM_DISPLAY': '滨江楼',
          'ISTK': '1',
        },
      ];
      final parsed = TimetableParser.parseKbRows(rows);
      expect(parsed.courses, hasLength(1));
      final slot = parsed.courses.single.slots.single;
      expect(slot.istk, 1);
      expect(slot.location, '滨江楼');
    });
  });

  group('未排课与考试 diff', () {
    test('已有课程新增独立时段、延长节次和增加周次均产生 diff', () {
      final base = _jwxt(slots: [_slot(weeks: '1111')]);
      final addedSlot = TimetableSyncDiff.compute(
        oldCourses: [base],
        newCourses: [
          _jwxt(
            slots: [
              _slot(weeks: '1111'),
              _slot(day: 3, weeks: '1111'),
            ],
          ),
        ],
      );
      expect(addedSlot.single.type, TimetableChangeType.added);
      expect(addedSlot.single.after!['SKXQ'], 3);
      for (final slot in [
        _slot(end: 7, weeks: '1111'),
        _slot(weeks: '11111'),
      ]) {
        final changes = TimetableSyncDiff.compute(
          oldCourses: [base],
          newCourses: [
            _jwxt(slots: [slot]),
          ],
        );
        expect(changes.single.type, TimetableChangeType.timeChanged);
      }
    });

    test('未排课补齐教学班 ID 只报告实际属性变化；不同教学班不强配对', () {
      Course other(
        String jxb, {
        String teacher = '甲老师',
        String weeks = '2-17周',
      }) => TimetableParser.parseKbRows([
        {
          'KCM': '测试实践课',
          'KCH': '9001',
          'KXH': '01',
          'JXBID': jxb,
          'SKZC': weeks,
          'SKJS': teacher,
        },
      ]).courses.single;
      expect(
        TimetableSyncDiff.compute(
          oldCourses: [other('')],
          newCourses: [other('a')],
        ),
        isEmpty,
      );
      final teacher = TimetableSyncDiff.compute(
        oldCourses: [other('')],
        newCourses: [other('a', teacher: '乙老师')],
      );
      expect(teacher.single.type, TimetableChangeType.teacherChanged);
      expect(
        TimetableChangeFormat.alertBody(teacher.single),
        '测试实践课 甲老师 → 乙老师',
      );
      final moved = TimetableSyncDiff.compute(
        oldCourses: [other('a')],
        newCourses: [other('b')],
      );
      expect(moved.map((r) => r.type), [
        TimetableChangeType.removed,
        TimetableChangeType.added,
      ]);
      final ambiguous = TimetableSyncDiff.compute(
        oldCourses: [other('')],
        newCourses: [other('a'), other('b')],
      );
      expect(
        ambiguous.where((r) => r.type == TimetableChangeType.added),
        hasLength(2),
      );
      expect(
        ambiguous.where((r) => r.type == TimetableChangeType.timeChanged),
        isEmpty,
      );
    });

    test('重复未排课行不重复记录，空课程号按课程隔离', () {
      final baseline = _jwxt();
      Course other(String id) =>
          Course(id: id, name: id, source: CourseSource.jwxt, slots: const []);
      final changes = TimetableSyncDiff.compute(
        oldCourses: [baseline],
        newCourses: [baseline, other('a'), other('a'), other('b')],
      );
      expect(changes, hasLength(2));
      expect(changes.every((r) => r.type == TimetableChangeType.added), isTrue);
    });

    test('变动入库与已读确认并发时不会相互覆盖', () async {
      final first = TimetableSyncDiff.compute(
        oldCourses: [_jwxt()],
        newCourses: [
          _jwxt(slots: [_slot(location: '新教室')]),
        ],
      ).single;
      final second = TimetableSyncDiff.compute(
        oldCourses: [
          _jwxt(slots: [_slot(location: '新教室')]),
        ],
        newCourses: [
          _jwxt(slots: [_slot(location: '另一教室')]),
        ],
      ).single;
      await TimetableChangeLogStore.upsertCandidates([first]);
      await Future.wait([
        TimetableChangeLogStore.upsertCandidates([second]),
        TimetableChangeLogStore.markNotified([first.fingerprint]),
      ]);
      final pending = await TimetableChangeLogStore.readUnnotified();
      expect(pending.single.fingerprint, second.fingerprint);
      expect(await TimetableChangeLogStore.readAll(), hasLength(2));
    });

    Course otherCourse({
      String id = 'other:o1',
      String code = '88001',
      String classId = '01',
      String name = '创新创业实践',
      String weeksLabel = '2-17周',
      String teacher = '李老师',
      String location = '',
    }) => Course(
      id: id,
      name: name,
      code: code,
      classId: classId,
      source: CourseSource.jwxt,
      slots: [
        CourseSlot(
          day: 0,
          startNode: 0,
          endNode: 0,
          weeks: '',
          weeksLabel: weeksLabel,
          teacher: teacher,
          location: location,
        ),
      ],
    );

    ScheduleEvent jwxtExam({
      String code = '18001299',
      String title = '学术英语（1）',
      DateTime? date,
      TimeOfDayMinutes start = const TimeOfDayMinutes(9, 0),
      TimeOfDayMinutes end = const TimeOfDayMinutes(11, 0),
      String location = '明德楼N201',
      ScheduleSource source = ScheduleSource.jwxt,
    }) {
      final d = date ?? DateTime(2027, 1, 12);
      return ScheduleEvent(
        id: 'jwxt-exam:${ScheduleEvent.examKeyOf(code, d, start)}',
        kind: ScheduleKind.exam,
        source: source,
        title: title,
        date: d,
        start: start,
        end: end,
        location: location,
        courseCode: code,
      );
    }

    test('未排课新增、删除、教师与周次文案变更均产生 diff 且格式正确', () {
      final base = _jwxt();
      final o1 = otherCourse();
      final added = TimetableSyncDiff.compute(
        oldCourses: [base],
        newCourses: [base, o1],
      );
      expect(added, hasLength(1));
      expect(added.single.type, TimetableChangeType.added);
      expect(TimetableChangeFormat.scopeOf(added.single), '影响范围：其他课程 · 2-17周');
      expect(
        TimetableChangeFormat.alertBody(added.single),
        '创新创业实践 · 2-17周 · 李老师',
      );
      expect(TimetableChangeFormat.detailOf(added.single), '2-17周 · 李老师');

      final teacherChanged = TimetableSyncDiff.compute(
        oldCourses: [base, o1],
        newCourses: [
          base,
          otherCourse(teacher: '王老师'),
        ],
      );
      expect(teacherChanged.single.type, TimetableChangeType.teacherChanged);
      expect(
        TimetableChangeFormat.alertBody(teacherChanged.single),
        '创新创业实践 李老师 → 王老师',
      );

      final weeksLabelChanged = TimetableSyncDiff.compute(
        oldCourses: [base, o1],
        newCourses: [
          base,
          otherCourse(weeksLabel: '3-16周'),
        ],
      );
      expect(weeksLabelChanged.single.type, TimetableChangeType.timeChanged);
      expect(
        TimetableChangeFormat.scopeOf(weeksLabelChanged.single),
        '影响范围：其他课程 · 2-17周 → 3-16周',
      );
      expect(
        TimetableChangeFormat.alertBody(weeksLabelChanged.single),
        '创新创业实践 2-17周 → 3-16周',
      );

      final removed = TimetableSyncDiff.compute(
        oldCourses: [base, o1],
        newCourses: [base],
      );
      expect(removed.single.type, TimetableChangeType.removed);
    });

    test('教务考试支持首次空列表后续新增、时间变动、地点变动与删除', () {
      final e1 = jwxtExam();
      expect(
        TimetableSyncDiff.computeExams(oldExams: const [], newExams: [e1]),
        isEmpty,
      );

      final newlyPublished = TimetableSyncDiff.computeExams(
        oldExams: const [],
        newExams: [e1],
        allowWhenOldEmpty: true,
      );
      expect(newlyPublished, hasLength(1));
      expect(newlyPublished.single.type, TimetableChangeType.added);
      expect(
        TimetableChangeFormat.scopeOf(newlyPublished.single),
        '影响范围：考试 · 1月12日 09:00–11:00',
      );
      expect(
        TimetableChangeFormat.alertBody(newlyPublished.single),
        '学术英语（1）（考试） · 1月12日 09:00–11:00 · 明德楼N201',
      );

      final timeMoved = TimetableSyncDiff.computeExams(
        oldExams: [e1],
        newExams: [
          jwxtExam(
            date: DateTime(2027, 1, 13),
            start: const TimeOfDayMinutes(14, 0),
            end: const TimeOfDayMinutes(16, 0),
          ),
        ],
      );
      expect(timeMoved, hasLength(1));
      expect(timeMoved.single.type, TimetableChangeType.timeChanged);
      expect(
        TimetableChangeFormat.alertBody(timeMoved.single),
        '学术英语（1）（考试） 1月12日 09:00–11:00 → 1月13日 14:00–16:00',
      );

      final roomMoved = TimetableSyncDiff.computeExams(
        oldExams: [e1],
        newExams: [jwxtExam(location: '逸夫楼S102')],
      );
      expect(roomMoved, hasLength(1));
      expect(roomMoved.single.type, TimetableChangeType.locationChanged);
      expect(
        TimetableChangeFormat.alertBody(roomMoved.single),
        '学术英语（1）（考试） 明德楼N201 → 逸夫楼S102',
      );

      final dropped = TimetableSyncDiff.computeExams(
        oldExams: [e1],
        newExams: const [],
      );
      expect(dropped.single.type, TimetableChangeType.removed);
    });
  });
}
