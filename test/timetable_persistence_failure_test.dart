import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_colors.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_date_edits.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_overrides.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

void main() {
  final c = TimetableController.instance;
  final originalBinding = TimetableController.bindingCheck;
  late Directory directory;
  const oldSlotColor = 0xFF336699;
  const newGlobalColor = 0xFF996633;
  final settings = TimetableSettings(
    termCode: '2026-2027-1',
    termStartDate: DateTime(2026, 8, 31),
  );

  Course course(String id, {bool manual = false, bool assigned = true}) =>
      Course(
        id: id,
        name: manual ? '手动测试课' : '教务测试课',
        source: manual ? CourseSource.manual : CourseSource.jwxt,
        assignedColorIndex: manual && assigned ? 3 : null,
        slots: [
          CourseSlot(
            day: 1,
            startNode: 1,
            endNode: 2,
            weeks: '1111',
            color: manual ? oldSlotColor : null,
          ),
        ],
      );

  Future<void> seed() async {
    await TimetableStore.saveSettings(settings);
    await TimetableStore.saveSnapshot(
      TimetableSnapshot(settings: settings, courses: [course('jwxt')]),
    );
    await TimetableStore.saveManualCourses([course('manual', manual: true)]);
    await ScheduleStore.saveCourseDateEdits([
      CourseDateEdit(
        id: 'day-color',
        courseId: 'manual',
        date: DateTime(2026, 8, 31),
        origStart: 1,
        origEnd: 2,
        color: oldSlotColor,
        note: '保留备注',
      ),
    ]);
    await c.ensureStarted();
  }

  Map<String, String> savedFiles() => {
    for (final name in [
      'settings.json',
      'snapshot.json',
      'course_colors.json',
      'manual_courses.json',
      'course_edits.json',
    ])
      if (File('${directory.path}/$name').existsSync())
        name: File('${directory.path}/$name').readAsStringSync(),
  };

  Future<void> restart() async {
    c.debugReset();
    await c.ensureStarted();
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tt_persistence_failure');
    TimetableStore.debugDirectory = directory;
    TimetableStore.debugBeforeBatchReplace = null;
    TimetableController.bindingCheck = () async => false;
    c.debugReset();
  });

  tearDown(() async {
    TimetableStore.debugBeforeBatchReplace = null;
    TimetableStore.debugDirectory = null;
    TimetableController.bindingCheck = originalBinding;
    c.debugReset();
    await directory.delete(recursive: true);
  });

  test('设置后一个文件替换失败，原文件和内存均恢复，重启也保持原值', () async {
    await seed();
    final before = savedFiles();
    final changes = <ScheduleChangeReason>[];
    final subscription = c.scheduleChanged.listen(changes.add);
    addTearDown(subscription.cancel);
    TimetableStore.debugBeforeBatchReplace = (index) {
      if (index == 1) throw const FileSystemException('合成替换失败');
    };
    await expectLater(
      c.updateSettings(c.settings.copyWith(showSaturday: false)),
      throwsA(isA<TimetablePersistenceException>()),
    );
    expect(c.settings.showSaturday, isTrue);
    expect(savedFiles(), before);
    await pumpEventQueue();
    expect(changes, isEmpty);
    TimetableStore.debugBeforeBatchReplace = null;
    await restart();
    expect(c.settings.showSaturday, isTrue);
  });

  test('换配色方案的最后一份文件失败，不残留新方案或新手动课色号', () async {
    await seed();
    final before = savedFiles();
    final oldColors = Map<String, int>.of(c.courseColorMap);
    final oldManual = c.manualCourses.single.toJson();
    TimetableStore.debugBeforeBatchReplace = (index) {
      if (index == 3) throw const FileSystemException('合成末段失败');
    };
    await expectLater(
      c.updateSettings(c.settings.copyWith(paletteScheme: 'B')),
      throwsA(isA<TimetablePersistenceException>()),
    );
    expect(savedFiles(), before);
    expect(c.settings.paletteScheme, 'A');
    expect(c.courseColorMap, oldColors);
    expect(c.manualCourses.single.toJson(), oldManual);
    TimetableStore.debugBeforeBatchReplace = null;
    await restart();
    expect(c.settings.paletteScheme, 'A');
    expect(c.courseColorMap, oldColors);
    expect(c.manualCourses.single.toJson(), oldManual);
  });

  test('目录不可用时设置保存反馈失败，恢复目录后可再次保存', () async {
    await seed();
    final blocked = File('${directory.path}/blocked')..writeAsStringSync('占位');
    TimetableStore.debugDirectory = Directory(blocked.path);
    await expectLater(
      c.updateSettings(c.settings.copyWith(showSaturday: false)),
      throwsA(isA<TimetablePersistenceException>()),
    );
    expect(c.settings.showSaturday, isTrue);
    TimetableStore.debugDirectory = directory;
    await c.updateSettings(c.settings.copyWith(showSaturday: false));
    expect(c.settings.showSaturday, isFalse);
    await restart();
    expect(c.settings.showSaturday, isFalse);
  });

  test('连续设置保留不同字段，并允许待保存字段恢复到原值', () async {
    await seed();
    final saturdayOff = c.updateSettings(
      c.settingsForEditing.copyWith(showSaturday: false),
    );
    final sundayOff = c.updateSettings(
      c.settingsForEditing.copyWith(showSunday: false),
    );
    final saturdayOn = c.updateSettings(
      c.settingsForEditing.copyWith(showSaturday: true),
    );
    await Future.wait([saturdayOff, sundayOff, saturdayOn]);
    expect(c.settings.showSaturday, isTrue);
    expect(c.settings.showSunday, isFalse);
    await restart();
    expect(c.settings.showSaturday, isTrue);
    expect(c.settings.showSunday, isFalse);
  });

  test('全局色保存后段失败，不清掉局部颜色、单日颜色或备注', () async {
    await seed();
    final before = savedFiles();
    final originalDateEdit = c.courseDateEdits.single.toJson();
    TimetableStore.debugBeforeBatchReplace = (index) {
      if (index == 2) throw const FileSystemException('合成覆盖写入失败');
    };
    await expectLater(
      c.setUserCourseColor('manual', newGlobalColor),
      throwsA(isA<TimetablePersistenceException>()),
    );
    expect(c.userColorOf(c.manualCourses.single), oldSlotColor);
    expect(c.courseDateEdits.single.toJson(), originalDateEdit);
    expect(savedFiles(), before);
    TimetableStore.debugBeforeBatchReplace = null;
    await restart();
    expect(c.userColorOf(c.manualCourses.single), oldSlotColor);
    await c.setUserCourseColor('manual', newGlobalColor);
    expect(c.userColorOf(c.manualCourses.single), newGlobalColor);
    expect(c.courseDateEdits.single.color, isNull);
    expect(c.courseDateEdits.single.note, '保留备注');
  });

  test('前项成功后项失败时，变更订阅者只读取已保存的提醒设置', () async {
    await seed();
    final observed = <bool>[];
    final subscription = c.scheduleChanged.listen((_) {
      observed.add(c.settings.nextDayReminderEnabled);
    });
    addTearDown(subscription.cancel);
    var batches = 0;
    TimetableStore.debugBeforeBatchReplace = (index) {
      if (index == 0) batches++;
      if (batches == 2 && index == 1) {
        throw const FileSystemException('合成第二次保存失败');
      }
    };
    final first = c.updateSettings(
      c.settingsForEditing.copyWith(showSaturday: false),
    );
    final failed = c.updateSettings(
      c.settingsForEditing.copyWith(nextDayReminderEnabled: false),
    );
    final failure = expectLater(
      failed,
      throwsA(isA<TimetablePersistenceException>()),
    );
    await first;
    await failure;
    await pumpEventQueue();
    expect(c.settings.showSaturday, isFalse);
    expect(c.settings.nextDayReminderEnabled, isTrue);
    expect(observed, [true]);
  });

  test('待保存配色不会污染已保存的稳定颜色映射', () async {
    await seed();
    const stableColors = {'教务测试课': 10, '手动测试课': 12};
    await TimetableStore.saveCourseColors(
      coursePaletteSchemeOf('A'),
      stableColors,
    );
    await restart();
    expect(c.courseColorMap, stableColors);
    TimetableStore.debugBeforeBatchReplace = (_) {
      throw const FileSystemException('合成方案保存失败');
    };
    final failed = c.updateSettings(
      c.settingsForEditing.copyWith(paletteScheme: 'B'),
    );
    expect(c.settingsForEditing.paletteScheme, 'B');
    expect(c.settings.paletteScheme, 'A');
    expect(c.courseColorMap, stableColors);
    await expectLater(failed, throwsA(isA<TimetablePersistenceException>()));
    expect(c.settingsForEditing.paletteScheme, 'A');
    expect(c.courseColorMap, stableColors);
  });

  test('旧手动课和日程回填写入失败不阻断启动，原文件不损坏', () async {
    await TimetableStore.saveManualCourses([
      course('manual', manual: true, assigned: false),
    ]);
    await ScheduleStore.saveEvents([
      ScheduleEvent(
        id: 'old-event',
        kind: ScheduleKind.other,
        source: ScheduleSource.manual,
        title: '测试日程',
        date: DateTime(2026, 8, 31),
        start: const TimeOfDayMinutes(18, 0),
        end: const TimeOfDayMinutes(19, 0),
      ),
    ]);
    final manualFile = File('${directory.path}/manual_courses.json');
    final eventFile = File('${directory.path}/schedule_events.json');
    final manualBefore = manualFile.readAsStringSync();
    final eventsBefore = eventFile.readAsStringSync();
    Directory('${manualFile.path}.tmp').createSync();
    Directory('${eventFile.path}.tmp').createSync();
    await c.ensureStarted();
    await c.ensureStarted();
    expect(c.manualCourses, hasLength(1));
    expect(c.scheduleEvents, hasLength(1));
    expect(c.manualCourses.single.assignedColorIndex, isNotNull);
    expect(manualFile.readAsStringSync(), manualBefore);
    expect(eventFile.readAsStringSync(), eventsBefore);
  });

  test('真正启动失败后可以重试，不永久缓存失败 Future', () async {
    TimetableController.bindingCheck = () async => throw StateError('合成启动失败');
    await expectLater(c.ensureStarted(), throwsStateError);
    TimetableController.bindingCheck = () async => false;
    await c.ensureStarted();
    expect(c.portalBound, isFalse);
  });

  test('恢复旧调课记录写盘失败时，内存和磁盘都保留原记录', () async {
    await TimetableStore.saveOverrides([
      const SlotOverride(
        id: 'old-move',
        courseId: 'jwxt',
        origDay: 1,
        origStart: 1,
        origEnd: 2,
        origWeeks: '1111',
        weeks: [1],
        scope: MoveScope.thisWeek,
        fromWeek: 1,
        toDay: 2,
        toStart: 3,
        toEnd: 4,
      ),
    ]);
    await seed();
    Directory('${directory.path}/overrides.json.tmp').createSync();
    await expectLater(
      c.restoreOverride(c.jwxtCourses.single, 0),
      throwsA(isA<TimetablePersistenceException>()),
    );
    expect(c.slotOverrides.single.id, 'old-move');
    expect((await TimetableStore.readOverrides()).single.id, 'old-move');
  });
}
