import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
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

    test('忽略手动课与无固定时间时段', () {
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
}
