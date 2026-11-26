import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_colors.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_date_edits.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_multi_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_overrides.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_sync_diff.dart';

// 全部为虚构数据。
const _settings = TimetableSettings(termCode: '2026-2027-1');
final _termStart = DateTime(2026, 8, 31); // 周一，第 1 周
final _monday = DateTime(2026, 9, 7); // 第 2 周周一

Course _jwxt(
  String id,
  String name, {
  int day = 1,
  int start = 1,
  int end = 2,
  String weeks = '1111111111111111',
}) => Course(
  id: id,
  name: name,
  source: CourseSource.jwxt,
  slots: [
    CourseSlot(
      day: day,
      startNode: start,
      endNode: end,
      weeks: weeks,
      teacher: '张老师',
      location: '教一-101',
    ),
  ],
);

TimetableSnapshot _snap(List<Course> courses) => TimetableSnapshot(
  courses: courses,
  periods: TimetableController.defaultPeriods(),
  settings: _settings.copyWith(
    termStartDate: _termStart,
    termStartFromJwxt: true,
  ),
);

ScheduleEvent _exam(
  String id,
  String code, {
  DateTime? date,
  int startH = 9,
  int endH = 11,
  String title = '高等数学考试',
}) => ScheduleEvent(
  id: id,
  kind: ScheduleKind.exam,
  source: ScheduleSource.jwxt,
  title: title,
  date: date ?? _monday,
  start: TimeOfDayMinutes(startH, 0),
  end: TimeOfDayMinutes(endH, 0),
  location: '教二-201',
  courseCode: code,
);

ScheduleEvent _other(String id, {int endH = 21}) => ScheduleEvent(
  id: id,
  kind: ScheduleKind.other,
  source: ScheduleSource.manual,
  title: '社团活动',
  date: _monday,
  start: TimeOfDayMinutes(endH - 1, 0),
  end: TimeOfDayMinutes(endH, 0),
);

void main() {
  late Directory tmp;
  final c = TimetableController.instance;
  List<Course> nextFetch = const [];
  List<ScheduleEvent>? nextExams;
  final origFetchExams = TimetableController.fetchExams;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tt_data');
    TimetableStore.debugDirectory = tmp;
    TimetableController.clock = () => _monday;
    TimetableController.bindingCheck = () async => true;
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        _snap(nextFetch);
    // 默认返回 null（本次不拉考试，与替换了 fetchSnapshot 时的默认钩子一致）。
    nextExams = null;
    TimetableController.fetchExams = (term) async => nextExams;
    c.debugReset();
  });

  tearDown(() async {
    TimetableStore.debugDirectory = null;
    TimetableStore.debugBeforeBatchReplace = null;
    TimetableController.clock = TimetableApi.shanghaiToday;
    TimetableController.syncClock = DateTime.now;
    TimetableController.fetchSnapshot = (term, {baseSettings}) =>
        TimetableApi.fetchTermSnapshot(term, baseSettings: baseSettings);
    TimetableController.fetchExams = origFetchExams;
    c.debugReset();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// 模拟重启：清内存，按同一目录重新读盘。
  Future<void> restart() async {
    c.debugReset();
    await c.ensureStarted();
  }

  Future<void> seed(List<Course> jwxt, {List<Course> manual = const []}) async {
    nextFetch = jwxt;
    await c.ensureStarted();
    for (final m in manual) {
      await c.addManualCourse(m);
    }
    await c.syncFromJwxt();
    expect(c.syncStatus, TimetableSyncStatus.success);
  }

  Course shown(String id) => c.courses.firstWhere((x) => x.id == id);

  // ===== §24 补充用例（FC / JE / EV / EX / SW01）=====

  ScheduleEvent eventById(String id) =>
      c.scheduleEvents.firstWhere((e) => e.id == id);

  Map<String, Future<void> Function()> criticalWrites() => {
    '快照': () => TimetableStore.saveSnapshot(_snap([])),
    '设置': () => TimetableStore.saveSettings(_settings),
    '原始设置': () => TimetableStore.writeRawSettings({'custom': true}),
    '设置合并': () => TimetableStore.mergeSettingsChanges(
      _settings,
      _settings.copyWith(showTeacher: !_settings.showTeacher),
    ),
    '学期设置': () => TimetableStore.mergeTermSettings(_settings),
    '清除学期键': TimetableStore.removeTermSettingKeys,
    '手动课': () => TimetableStore.saveManualCourses([]),
    '课程覆盖': () => TimetableStore.saveOverrides([]),
    '自动配色': () =>
        TimetableStore.saveCourseColors(CoursePaletteScheme.values.first, {}),
    '用户配色': () => TimetableStore.saveUserCourseColors({}),
    '最近配色': () => TimetableStore.pushRecentCustomColor(0xFF336699),
    '日程': () => ScheduleStore.saveEvents([]),
    '日程及配色': () => ScheduleStore.saveEventsAndOtherColors([], {}),
    '课程编辑': () => ScheduleStore.saveCourseEdits({}),
    '单日编辑': () => ScheduleStore.saveCourseDateEdits([]),
    '整天调课': () => ScheduleStore.saveDaySwaps([]),
    '考试覆盖': () => ScheduleStore.saveExamOverrides({}),
    '同步时间': () => ScheduleStore.saveLastSyncSuccess(_monday),
    '登录过期': () => ScheduleStore.savePortalSessionExpired(true),
    '清除快照': TimetableStore.clearJwxtSnapshot,
    '清空课表': TimetableStore.clearAll,
  };

  Future<void> expectEmptyReads() async {
    expect(await TimetableStore.readSnapshot(), isNull);
    expect(
      (await TimetableStore.readSettings()).toJson(),
      const TimetableSettings().toJson(),
    );
    expect(await TimetableStore.readRawSettings(), isEmpty);
    expect(await TimetableStore.readManualCourses(), isEmpty);
    expect(await TimetableStore.readOverrides(), isEmpty);
    expect(await TimetableStore.readCourseColors(), isNull);
    expect(await TimetableStore.readUserCourseColors(), isEmpty);
    expect(await TimetableStore.readRecentCustomColors(), isEmpty);
    expect(await TimetableStore.readReminderIntroSeen(), isFalse);
    expect(await ScheduleStore.readEvents(), isEmpty);
    expect(await ScheduleStore.readOtherColors(), isEmpty);
    expect(await ScheduleStore.readCourseEdits(), isEmpty);
    expect(await ScheduleStore.readCourseDateEdits(), isEmpty);
    expect(await ScheduleStore.readDaySwaps(), isEmpty);
    expect(await ScheduleStore.readExamOverrides(), isEmpty);
    expect(await ScheduleStore.readLastSyncSuccess(), isNull);
    expect(await ScheduleStore.readPortalSessionExpired(), isFalse);
  }

  group('存储 I/O 边界', () {
    test('目录被文件占用时读取降级，全部关键写入和删除反馈安全错误', () async {
      final blocker = File('${tmp.path}/blocked')..writeAsStringSync('保留');
      TimetableStore.debugDirectory = Directory(blocker.path);
      await expectEmptyReads();
      for (final entry in criticalWrites().entries) {
        await expectLater(
          entry.value(),
          throwsA(isA<TimetablePersistenceException>()),
          reason: entry.key,
        );
      }
      await TimetableStore.saveReminderIntroSeen();
      expect(blocker.readAsStringSync(), '保留');
    });

    test('无平台存储的默认 widget 测试仍可降级', () async {
      TimetableStore.debugDirectory = null;
      await expectEmptyReads();
      for (final entry in criticalWrites().entries) {
        await entry.value();
      }
      await TimetableStore.writeBatch(() async {
        await TimetableStore.saveSettings(_settings);
        await ScheduleStore.saveEvents([]);
      });
    });

    test('文件存在性检查抛错时，各类读取仍按空降级', () async {
      await IOOverrides.runZoned(
        expectEmptyReads,
        createFile: (path) => _UnavailableFile(path),
      );
    });

    test('删除快照遇到同名目录会报错，不误删目录内容', () async {
      final directory = Directory('${tmp.path}/snapshot.json')..createSync();
      final kept = File('${directory.path}/keep')..writeAsStringSync('保留');
      await expectLater(
        TimetableStore.clearJwxtSnapshot(),
        throwsA(isA<TimetablePersistenceException>()),
      );
      expect(kept.readAsStringSync(), '保留');
    });

    for (final entry in <String, Future<void> Function()>{
      'snapshot.json': () => TimetableStore.saveSnapshot(_snap([])),
      'settings.json': () => TimetableStore.saveSettings(_settings),
      'manual_courses.json': () => TimetableStore.saveManualCourses([]),
      'overrides.json': () => TimetableStore.saveOverrides([]),
      'course_colors.json': () => TimetableStore.saveUserCourseColors({}),
      'schedule_events.json': () => ScheduleStore.saveEvents([]),
    }.entries) {
      test('${entry.key} 写入临时文件失败时原文件逐字保持不变', () async {
        final original = File('${tmp.path}/${entry.key}');
        original.writeAsStringSync('{"keep": {"value": "原值"}}');
        final before = original.readAsBytesSync();
        Directory('${original.path}.tmp').createSync();
        await expectLater(
          entry.value(),
          throwsA(isA<TimetablePersistenceException>()),
        );
        expect(original.readAsBytesSync(), before);
      });
    }

    test('损坏文件无法备份时读取降级，保存拒绝覆盖原内容', () async {
      final file = File('${tmp.path}/course_edits.json')
        ..writeAsStringSync('{broken');
      Directory('${file.path}.corrupt').createSync();
      expect(await ScheduleStore.readCourseEdits(), isEmpty);
      await expectLater(
        ScheduleStore.saveCourseEdits({}),
        throwsA(isA<TimetablePersistenceException>()),
      );
      expect(file.readAsStringSync(), '{broken');
    });
  });

  group('设置与编辑批次提交', () {
    Future<Map<String, List<int>>> seedFiles() async {
      await TimetableStore.saveSettings(_settings);
      await TimetableStore.saveSnapshot(_snap([]));
      return {
        for (final name in ['settings.json', 'snapshot.json'])
          name: File('${tmp.path}/$name').readAsBytesSync(),
      };
    }

    void expectOriginals(Map<String, List<int>> originals) {
      for (final entry in originals.entries) {
        expect(File('${tmp.path}/${entry.key}').readAsBytesSync(), entry.value);
      }
    }

    Future<void> stageSettings() async {
      await TimetableStore.mergeSettingsChanges(
        _settings,
        _settings.copyWith(showTeacher: !_settings.showTeacher),
      );
      await TimetableStore.saveSnapshot(
        _snap([]).copyWith(
          settings: _settings.copyWith(showTeacher: !_settings.showTeacher),
        ),
      );
    }

    test('后一个准备步骤失败时，前面暂存的数据完全不落盘', () async {
      final originals = await seedFiles();
      await expectLater(
        TimetableStore.writeBatch(() async {
          await stageSettings();
          throw const FormatException('模拟准备失败');
        }),
        throwsA(isA<TimetablePersistenceException>()),
      );
      expectOriginals(originals);
      expect(tmp.listSync().length, 2);
    });

    test('批次刷盘让出事件循环，重叠批次拒绝过时内容且不共用临时文件', () async {
      TimetableStore.debugPrepareBatchInBackground = true;
      addTearDown(() => TimetableStore.debugPrepareBatchInBackground = false);
      await seedFiles();
      var completed = false;
      var eventRanBeforeCompletion = false;
      await TimetableStore.writeBatch(() async {
        await stageSettings();
        Timer.run(() => eventRanBeforeCompletion = !completed);
      });
      completed = true;
      await pumpEventQueue();
      expect(eventRanBeforeCompletion, isTrue, reason: '临时文件和备份刷盘不阻塞 UI');

      final staged = [Completer<void>(), Completer<void>()];
      final proceed = Completer<void>();
      Future<void> batch(int index) => TimetableStore.writeBatch(() async {
        await TimetableStore.writeRawSettings({'winner': index});
        staged[index].complete();
        await proceed.future;
      });
      final first = batch(0);
      final second = batch(1);
      final results = Future.wait(
        [first, second].map((work) async {
          try {
            await work;
            return true;
          } on TimetablePersistenceException {
            return false;
          }
        }),
      );
      await Future.wait(staged.map((gate) => gate.future));
      proceed.complete();
      expect(await results, [true, false]);
      expect((await TimetableStore.readRawSettings())['winner'], 0);
      expect(
        tmp.listSync().where((file) => file.path.contains('.tmp')),
        isEmpty,
      );
      expect(
        tmp.listSync().where((file) => file.path.contains('.rollback')),
        isEmpty,
      );
    });

    test('后一个临时文件准备失败时，所有原文件仍保持不变', () async {
      final originals = await seedFiles();
      Directory('${tmp.path}/snapshot.json.tmp').createSync();
      await expectLater(
        TimetableStore.writeBatch(stageSettings),
        throwsA(isA<TimetablePersistenceException>()),
      );
      expectOriginals(originals);
      expect(File('${tmp.path}/settings.json.tmp').existsSync(), isFalse);
    });

    test('后一个文件替换失败时，恢复已替换文件并移除本批新建文件', () async {
      final originals = await seedFiles();
      TimetableStore.debugBeforeBatchReplace = (index) {
        if (index == 2) throw const FileSystemException('模拟替换失败');
      };
      await expectLater(
        TimetableStore.writeBatch(() async {
          await TimetableStore.saveManualCourses([]);
          await stageSettings();
        }),
        throwsA(isA<TimetablePersistenceException>()),
      );
      expectOriginals(originals);
      expect(File('${tmp.path}/manual_courses.json').existsSync(), isFalse);
      expect(tmp.listSync().length, 2);
    });

    test('同文件多次合并能读到本批暂存值，未知键与两种编辑都保留', () async {
      final colors = File('${tmp.path}/course_colors.json')
        ..writeAsStringSync('{"unknown": true}');
      final edits = File('${tmp.path}/course_edits.json')
        ..writeAsStringSync('{"unknown": true}');
      final dateEdit = CourseDateEdit(
        id: 'edit-1',
        courseId: 'j1',
        date: _monday,
        origStart: 1,
        origEnd: 2,
        note: '测试备注',
      );
      await TimetableStore.writeBatch(() async {
        await TimetableStore.saveCourseColors(
          CoursePaletteScheme.values.first,
          {'测试课程': 1},
        );
        await TimetableStore.saveUserCourseColors({'j1': 0xFF336699});
        await TimetableStore.pushRecentCustomColor(0xFF336699);
        await ScheduleStore.saveCourseEdits({
          'j1': const CourseEdit(courseId: 'j1', origFingerprint: 'fp'),
        });
        await ScheduleStore.saveCourseDateEdits([dateEdit]);
        expect((await ScheduleStore.readCourseEdits()).keys, ['j1']);
        expect((await ScheduleStore.readCourseDateEdits()).single.id, 'edit-1');
        expect(colors.readAsStringSync(), '{"unknown": true}');
        expect(edits.readAsStringSync(), '{"unknown": true}');
      });
      final colorJson = jsonDecode(colors.readAsStringSync()) as Map;
      expect(colorJson['unknown'], isTrue);
      expect(colorJson['map'], {'测试课程': 1});
      expect(colorJson['userColors'], contains('j1'));
      expect(colorJson['recentCustomColors'], [0xFF336699]);
      expect((jsonDecode(edits.readAsStringSync()) as Map)['unknown'], isTrue);
      expect((await ScheduleStore.readCourseEdits()).keys, ['j1']);
      expect((await ScheduleStore.readCourseDateEdits()).single.id, 'edit-1');
    });

    test('恢复原文件也失败时保留旧内容备份，并反馈安全错误', () async {
      final originals = await seedFiles();
      TimetableStore.debugBeforeBatchReplace = (index) {
        if (index != 1) return;
        // 首个新文件已提交后，模拟文件系统不再允许用旧文件替换这个路径。
        final first = File('${tmp.path}/settings.json');
        first.deleteSync();
        Directory(first.path).createSync();
        throw const FileSystemException('模拟替换失败');
      };
      await expectLater(
        TimetableStore.writeBatch(stageSettings),
        throwsA(isA<TimetablePersistenceException>()),
      );
      expect(
        File('${tmp.path}/settings.json.rollback').readAsBytesSync(),
        originals['settings.json'],
      );
      expect(
        File('${tmp.path}/snapshot.json').readAsBytesSync(),
        originals['snapshot.json'],
      );
    });

    test('损坏文件在批次准备失败时原样保留，提交成功才留下备份', () async {
      final file = File('${tmp.path}/manual_courses.json')
        ..writeAsStringSync('{broken');
      await expectLater(
        TimetableStore.writeBatch(() async {
          await TimetableStore.saveManualCourses([]);
          throw const TimetablePersistenceException();
        }),
        throwsA(isA<TimetablePersistenceException>()),
      );
      expect(file.readAsStringSync(), '{broken');
      expect(File('${file.path}.corrupt').existsSync(), isFalse);
      await TimetableStore.writeBatch(
        () => TimetableStore.saveManualCourses([]),
      );
      expect(File('${file.path}.corrupt').readAsStringSync(), '{broken');
      expect(await TimetableStore.readManualCourses(), isEmpty);
    });

    test('批次暂存期间外部已更新原文件时拒绝覆盖', () async {
      await seedFiles();
      final staged = Completer<void>();
      final proceed = Completer<void>();
      final batch = TimetableStore.writeBatch(() async {
        await stageSettings();
        staged.complete();
        await proceed.future;
      });
      final rejected = expectLater(
        batch,
        throwsA(isA<TimetablePersistenceException>()),
      );
      await staged.future;
      final file = File('${tmp.path}/settings.json')
        ..writeAsStringSync('{"outside": true}');
      proceed.complete();
      await rejected;
      expect(file.readAsStringSync(), '{"outside": true}');
    });
  });

  group('corrupt user-edit files are backed up before overwrite', () {
    Future<void> check(String name, Future<void> Function() save) async {
      final f = File('${tmp.path}/$name');
      f.writeAsStringSync('{broken user edits');
      await save();
      final backup = File('${tmp.path}/$name.corrupt');
      expect(backup.existsSync(), isTrue);
      expect(backup.readAsStringSync(), '{broken user edits');
      expect(f.existsSync(), isTrue);
      expect(f.readAsStringSync(), isNot('{broken user edits'));
    }

    test('course_edits.json: corrupt, then save, backup survives', () async {
      await check(
        ScheduleStore.courseEditsFile,
        () => ScheduleStore.saveCourseEdits({
          'j1': const CourseEdit(courseId: 'j1', origFingerprint: 'fp'),
        }),
      );
    });

    test('exam_overrides.json: corrupt, then save, backup survives', () async {
      await check(
        ScheduleStore.examOverridesFile,
        () => ScheduleStore.saveExamOverrides({
          'k1': const ExamOverride(key: 'k1', deleted: true),
        }),
      );
    });

    test('a second corruption does not overwrite the first backup', () async {
      final name = ScheduleStore.courseEditsFile;
      File('${tmp.path}/$name').writeAsStringSync('first');
      await ScheduleStore.readCourseEdits();
      File('${tmp.path}/$name').writeAsStringSync('second');
      await ScheduleStore.readCourseEdits();
      expect(File('${tmp.path}/$name.corrupt').readAsStringSync(), 'first');
      final extra = tmp
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('$name.corrupt.'))
          .toList();
      expect(extra, hasLength(1));
      expect(extra.single.readAsStringSync(), 'second');
    });
  });

  group('FC 本地存储文件损坏', () {
    final names = [
      ScheduleStore.scheduleEventsFile,
      ScheduleStore.courseEditsFile,
      ScheduleStore.examOverridesFile,
      ScheduleStore.syncStateFile,
    ];
    File f(String n) => File('${tmp.path}/$n');
    List<File> stamped(String n) => tmp
        .listSync()
        .whereType<File>()
        .where((x) => x.path.contains('$n.corrupt.'))
        .toList();

    test(
      'FC01 corrupt schedule_events.json → .corrupt, empty, new event saved',
      () async {
        final n = ScheduleStore.scheduleEventsFile;
        f(n).writeAsStringSync('{not json');
        await c.ensureStarted();
        expect(f('$n.corrupt').readAsStringSync(), '{not json');
        expect(f(n).existsSync(), isFalse);
        expect(c.scheduleEvents, isEmpty);
        await c.addScheduleEvent(_other('o1'));
        expect((await ScheduleStore.readEvents()).map((e) => e.id), ['o1']);
        await restart();
        expect(c.scheduleEvents.map((e) => e.id), ['o1']);
        expect(f('$n.corrupt').readAsStringSync(), '{not json');
      },
    );

    test(
      'FC02 corrupt course_edits.json → .corrupt; jwxt course shown as-is',
      () async {
        final n = ScheduleStore.courseEditsFile;
        await seed([_jwxt('j1', '高等数学')]);
        await c.editJwxtCourse('j1', name: 'A');
        f(n).writeAsStringSync('{"edits": [');
        await restart();
        expect(f('$n.corrupt').readAsStringSync(), '{"edits": [');
        expect(c.courseEditOf('j1'), isNull);
        expect(c.isJwxtOverridden(courseId: 'j1'), isFalse);
        expect(shown('j1').name, '高等数学');
      },
    );

    test(
      'FC03 corrupt exam_overrides.json → .corrupt; jwxt exam shown as-is',
      () async {
        final n = ScheduleStore.examOverridesFile;
        await seed([_jwxt('j1', '高等数学')]);
        await c.replaceJwxtExams([_exam('e1', 'MATH01')]);
        await c.updateScheduleEvent(
          _exam('e1', 'MATH01').copyWith(location: '体育馆'),
        );
        expect(eventById('e1').location, '体育馆');
        f(n).writeAsStringSync('oops');
        await restart();
        expect(f('$n.corrupt').readAsStringSync(), 'oops');
        expect(c.isJwxtOverridden(examKey: c.jwxtExamKeyOf('e1')), isFalse);
        expect(eventById('e1').location, '教二-201');
      },
    );

    test('FC04 corrupt sync_state.json → .corrupt; no last success, start syncs once', () async {
      final n = ScheduleStore.syncStateFile;
      await seed([_jwxt('j1', '高等数学')]);
      var fetches = 0;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async {
        fetches++;
        return _snap(nextFetch);
      };
      f(n).writeAsStringSync('{"lastSuccessAt":');
      await restart();
      expect(f('$n.corrupt').readAsStringSync(), '{"lastSuccessAt":');
      expect(c.lastSyncSuccessAt, isNull);
      expect(await c.onAppStart(), isTrue);
      expect(fetches, 1);
      expect(c.lastSyncSuccessAt, isNotNull);
    });

    test(
      'FC05 existing .corrupt kept; new backup gets a timestamp (all 4 files)',
      () async {
        for (final n in names) {
          f('$n.corrupt').writeAsStringSync('old-$n');
          f(n).writeAsStringSync('new-$n');
        }
        await c.ensureStarted();
        for (final n in names) {
          expect(f('$n.corrupt').readAsStringSync(), 'old-$n', reason: n);
          final s = stamped(n);
          expect(s, hasLength(1), reason: n);
          expect(s.single.readAsStringSync(), 'new-$n');
          expect(RegExp(r'\.corrupt\.\d+$').hasMatch(s.single.path), isTrue);
        }
      },
    );

    test(
      'FC07 truncated file or wrong top-level type is treated as corrupt',
      () async {
        const variants = {
          'truncated': '{"schemaVersion": 1, "events": [{"id": "x"',
          'array': '[]',
          'array of objects': '[{"schemaVersion": 1}]',
          'string': '"text"',
        };
        for (final v in variants.entries) {
          for (final n in names) {
            for (final x in tmp.listSync().whereType<File>()) {
              if (x.path.contains('.corrupt')) x.deleteSync();
            }
            f(n).writeAsStringSync(v.value);
            await restart();
            expect(f('$n.corrupt').existsSync(), isTrue, reason: '${v.key} $n');
            expect(f('$n.corrupt').readAsStringSync(), v.value);
          }
        }
        expect(c.scheduleEvents, isEmpty);
        expect(c.lastSyncSuccessAt, isNull);
        expect(await ScheduleStore.readCourseEdits(), isEmpty);
        expect(await ScheduleStore.readExamOverrides(), isEmpty);
      },
    );

    test(
      'FC08 only the corrupt file is backed up; others read normally',
      () async {
        await seed([_jwxt('j1', '高等数学')]);
        await c.editJwxtCourse('j1', name: 'A');
        await c.addScheduleEvent(_other('o1'));
        await c.replaceJwxtExams([_exam('e1', 'MATH01')]);
        final lastOk = c.lastSyncSuccessAt;
        expect(lastOk, isNotNull);
        f(ScheduleStore.examOverridesFile).writeAsStringSync('{broken');
        await restart();
        expect(
          f('${ScheduleStore.examOverridesFile}.corrupt').existsSync(),
          isTrue,
        );
        for (final n in names) {
          if (n == ScheduleStore.examOverridesFile) continue;
          expect(f('$n.corrupt').existsSync(), isFalse, reason: n);
          expect(stamped(n), isEmpty, reason: n);
        }
        expect(shown('j1').name, 'A');
        expect(c.scheduleEvents.map((e) => e.id).toSet(), {'o1', 'e1'});
        expect(c.lastSyncSuccessAt, lastOk);
      },
    );
  });

  group('冷启动批量读盘与后台读写并发', () {
    Future<void> seedAllFiles({
      String primaryScheduleId = kDefaultScheduleId,
    }) async {
      final scope = primaryScheduleId;
      await TimetableStore.saveSchedulesIndex(
        SchedulesIndex(
          primaryScheduleId: primaryScheduleId,
          currentTermCode: _settings.termCode,
          schedules: [
            ScheduleMetadata(
              id: primaryScheduleId,
              name: scope == kDefaultScheduleId ? '我的课表' : '导入课表',
              sourceKind: scope == kDefaultScheduleId
                  ? TimetableSourceKind.jwxt
                  : TimetableSourceKind.wakeupImport,
              termCode: _settings.termCode,
            ),
          ],
        ),
      );
      await TimetableStore.saveSettings(_settings);
      await ScheduleStore.saveLastSyncSuccess(_monday);
      await TimetableStore.withScheduleScope(scope, () async {
        await TimetableStore.saveSnapshot(_snap([_jwxt('j1', '高等数学')]));
        await TimetableStore.saveManualCourses([
          Course(
            id: 'm1',
            name: '线性代数',
            source: CourseSource.manual,
            slots: const [
              CourseSlot(day: 2, startNode: 3, endNode: 4, weeks: '1111'),
            ],
          ),
        ]);
        await TimetableStore.saveOverrides(const [
          SlotOverride(
            id: 'ov1',
            courseId: 'j1',
            origDay: 1,
            origStart: 1,
            origEnd: 2,
            origWeeks: '1111111111111111',
            weeks: [2],
            scope: MoveScope.thisWeek,
            fromWeek: 2,
            toDay: 2,
            toStart: 1,
            toEnd: 2,
          ),
        ]);
        await TimetableStore.saveCourseColors(CoursePaletteScheme.soft, const {
          '高等数学': 1,
        });
        await TimetableStore.saveUserCourseColors(const {'j1': 0xFF336699});
        await ScheduleStore.saveEvents([
          ScheduleEvent(
            id: 'ev1',
            kind: ScheduleKind.other,
            source: ScheduleSource.manual,
            title: '班会',
            date: _monday,
            start: const TimeOfDayMinutes(19, 0),
            end: const TimeOfDayMinutes(20, 0),
          ),
        ]);
        await ScheduleStore.saveCourseDateEdits([
          CourseDateEdit(
            id: 'de1',
            courseId: 'j1',
            date: _monday,
            origStart: 1,
            origEnd: 2,
            note: '带教材',
          ),
        ]);
        await ScheduleStore.saveDaySwaps([
          DaySwap(
            id: 'sw1',
            dateA: _monday,
            dateB: _monday.add(const Duration(days: 1)),
          ),
        ]);
        await ScheduleStore.saveExamOverrides({
          'e1': const ExamOverride(key: 'e1', deleted: true),
        });
        await TimetableChangeLogStore.upsertCandidates([
          TimetableChangeRecord(
            id: 'chg1',
            time: _monday,
            type: TimetableChangeType.added,
            slotKey: 'k1',
            fingerprint: 'fp1',
            courseName: '高等数学',
            xnxqdm: _settings.termCode,
          ),
        ]);
      });
    }

    tearDown(() {
      TimetableStore.debugOnBatchRead = null;
      TimetableStore.debugReadBatchInBackground = false;
      TimetableStore.debugPrepareBatchInBackground = false;
    });

    test('冷启动只触发一次批量读取且每个文件仅读一次（含后台 Isolate 与多课表隔离）', () async {
      await seedAllFiles();
      final batchCalls = <List<String>>[];
      TimetableStore.debugOnBatchRead = batchCalls.add;
      TimetableStore.debugReadBatchInBackground = true;

      await c.ensureStarted();

      expect(batchCalls, hasLength(1), reason: '冷启动应合并为单次批量读取');
      final files = batchCalls.single;
      expect(files.toSet().length, files.length, reason: '每个 JSON 文件最多读取一次');
      expect(
        files,
        containsAll([
          'schedules_index.json',
          'settings.json',
          'sync_state.json',
          'snapshot.json',
          'manual_courses.json',
          'overrides.json',
          'course_colors.json',
          'schedule_events.json',
          'course_edits.json',
          'day_swaps.json',
          'exam_overrides.json',
          'sync_changes.json',
        ]),
      );

      expect(c.jwxtCourses.single.name, '高等数学');
      expect(c.manualCourses.single.name, '线性代数');
      expect(c.slotOverrides.single.id, 'ov1');
      expect(c.courseColorMap['高等数学'], 1);
      expect(c.userColorOf(c.jwxtCourses.single), 0xFF336699);
      expect(c.scheduleEvents.single.title, '班会');
      expect(c.courseDateEdits.single.note, '带教材');
      expect(c.daySwaps.single.id, 'sw1');
      expect(c.pendingChangeAlerts.single.id, 'chg1');
    });

    test('后台 Isolate 批量读盘正确处理 .corrupt 备份与非默认课表作用域隔离', () async {
      await seedAllFiles(primaryScheduleId: 'friend_1');
      await TimetableStore.saveSnapshot(
        TimetableSnapshot(courses: [_jwxt('def1', '默认根目录课')]),
      );
      final badSwaps = File('${tmp.path}/schedules/friend_1/day_swaps.json')
        ..writeAsStringSync('{not valid json');

      TimetableStore.debugReadBatchInBackground = true;
      await c.ensureStarted();

      expect(c.primaryScheduleId, 'friend_1');
      expect(c.snapshot.courses.single.name, '高等数学');
      expect(c.jwxtCourses, isEmpty);
      expect(c.daySwaps, isEmpty);
      expect(File('${badSwaps.path}.corrupt').existsSync(), isTrue);
    });

    test('后台写后立即调用 readScopeBundle 不会读到旧文件', () async {
      await seedAllFiles();
      TimetableStore.debugPrepareBatchInBackground = true;
      TimetableStore.debugReadBatchInBackground = true;

      final writeFuture = TimetableStore.writeBatch(() async {
        await TimetableStore.saveManualCourses([
          Course(
            id: 'm_new',
            name: '后台新手动课',
            source: CourseSource.manual,
            slots: const [
              CourseSlot(day: 2, startNode: 3, endNode: 4, weeks: '1111'),
            ],
          ),
        ]);
      });
      final bundle = await TimetableStore.readScopeBundle(
        initialScheduleId: kDefaultScheduleId,
        resolvePrimaryFromIndex: true,
      );
      await writeFuture;

      final courses = TimetableStore.parseManualCourses(bundle.manualCourses);
      expect(courses.map((e) => e.name), ['后台新手动课']);
    });

    test('并发执行异步 modifyJsonFile 与 writeBatch 修改同一文件不丢键且不误抛异常', () async {
      await seedAllFiles();
      TimetableStore.debugPrepareBatchInBackground = true;
      TimetableStore.debugReadBatchInBackground = true;

      await Future.wait([
        TimetableStore.saveUserCourseColors(const {'j1': 0xFF112233}),
        TimetableStore.writeBatch(() async {
          await TimetableStore.saveCourseColors(
            CoursePaletteScheme.soft,
            const {'高等数学': 5},
          );
        }),
      ]);

      expect(await TimetableStore.readUserCourseColors(), {'j1': 0xFF112233});
      expect((await TimetableStore.readCourseColors())?.map, {'高等数学': 5});

      final stageReady = Completer<void>();
      final stageContinue = Completer<void>();
      final batchFuture = TimetableStore.writeBatch(() async {
        await TimetableStore.saveCourseColors(CoursePaletteScheme.soft, const {
          '高等数学': 9,
        });
        stageReady.complete();
        await stageContinue.future;
      });
      await stageReady.future;
      final modifyFuture = TimetableStore.saveUserCourseColors(const {
        'j1': 0xFF445566,
      });
      stageContinue.complete();
      await Future.wait([batchFuture, modifyFuture]);

      expect(await TimetableStore.readUserCourseColors(), {'j1': 0xFF445566});
      expect((await TimetableStore.readCourseColors())?.map, {'高等数学': 9});
    });
  });

  group('schedule events store & EV 配色 persistence', () {
    late Directory tmp;
    final c = TimetableController.instance;
    final origClock = TimetableController.clock;
    final origSyncClock = TimetableController.syncClock;
    final origBinding = TimetableController.bindingCheck;
    final origFetch = TimetableController.fetchSnapshot;
    final origFetchExams = TimetableController.fetchExams;
    List<Course> nextFetch = const [];
    List<ScheduleEvent>? nextExams;

    ScheduleEvent named(String id, String title, {DateTime? date}) =>
        ScheduleEvent(
          id: id,
          kind: ScheduleKind.other,
          source: ScheduleSource.manual,
          title: title,
          date: date ?? _monday,
          start: const TimeOfDayMinutes(19, 0),
          end: const TimeOfDayMinutes(20, 0),
        );

    ScheduleEvent manualExam() => ScheduleEvent(
      id: 'm1',
      kind: ScheduleKind.exam,
      source: ScheduleSource.manual,
      title: '测试手动考试',
      date: _monday,
      start: const TimeOfDayMinutes(8, 0),
      end: const TimeOfDayMinutes(9, 0),
    );

    ScheduleEvent otherEvent(String id, {int endH = 21}) => ScheduleEvent(
      id: id,
      kind: ScheduleKind.other,
      source: ScheduleSource.manual,
      title: '社团活动',
      date: _monday,
      start: TimeOfDayMinutes(endH - 1, 0),
      end: TimeOfDayMinutes(endH, 0),
    );

    ScheduleEvent eventById(String id) =>
        c.scheduleEvents.firstWhere((e) => e.id == id);

    String manualEventsJson() => jsonEncode([
      for (final e in c.scheduleEvents)
        if (!e.isFromJwxt) e.toJson(),
    ]);

    Future<void> restart() async {
      c.debugReset();
      await c.ensureStarted();
    }

    Future<void> seed(List<Course> jwxt) async {
      nextFetch = jwxt;
      await c.ensureStarted();
      await c.syncFromJwxt();
      expect(c.syncStatus, TimetableSyncStatus.success);
    }

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tt_sched_store');
      TimetableStore.debugDirectory = tmp;
      TimetableController.clock = () => _monday;
      TimetableController.bindingCheck = () async => true;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          _snap(nextFetch);
      nextExams = null;
      TimetableController.fetchExams = (term) async => nextExams;
      c.debugReset();
    });

    tearDown(() async {
      TimetableStore.debugDirectory = null;
      TimetableController.clock = origClock;
      TimetableController.syncClock = origSyncClock;
      TimetableController.fetchSnapshot = origFetch;
      TimetableController.fetchExams = origFetchExams;
      TimetableController.bindingCheck = origBinding;
      c.debugReset();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('旧版教务备注在读取时清理，手动备注和用户覆盖仍保留', () async {
      const oldNote = '座位号 12\n考试审核通过生成考试安排\n请携带学生证';
      final original = _exam('legacy', 'MATH01').copyWith(note: oldNote);
      final overridden = _exam('edited', 'PHY01').copyWith(note: oldNote);
      final manual = manualExam().copyWith(note: oldNote);
      await ScheduleStore.saveEvents([original, overridden, manual]);
      await ScheduleStore.saveExamOverrides({
        overridden.jwxtKey!: ExamOverride(
          key: overridden.jwxtKey!,
          note: oldNote,
        ),
      });

      await restart();
      expect(eventById(original.id).note, '请携带学生证');
      expect(eventById(original.id).id, original.id);
      expect(c.jwxtExamKeyOf(original.id), original.jwxtKey);
      expect(eventById(overridden.id).note, oldNote);
      expect(eventById(manual.id).note, oldNote);

      await c.updateScheduleEvent(
        eventById(original.id).copyWith(location: '测试楼 A101'),
      );
      final overrides = await ScheduleStore.readExamOverrides();
      expect(overrides[original.jwxtKey]?.note, isNull);

      await c.replaceJwxtExams([original, overridden]);
      expect(eventById(original.id).note, '请携带学生证');
      expect(eventById(overridden.id).note, oldNote);
      expect(eventById(manual.id).note, oldNote);
      await restart();
      expect(eventById(original.id).note, '请携带学生证');
      expect(eventById(overridden.id).note, oldNote);
      expect(eventById(manual.id).note, oldNote);
    });

    test('round trip: manual + jwxt events survive restart', () async {
      await seed([_jwxt('j1', '高等数学')]);
      await c.addScheduleEvent(otherEvent('o1'));
      await c.replaceJwxtExams([_exam('e1', 'MATH01')]);
      final f = File('${tmp.path}/${ScheduleStore.scheduleEventsFile}');
      expect(f.existsSync(), isTrue);
      await restart();
      expect(c.scheduleEvents.map((e) => e.id).toSet(), {'o1', 'e1'});
      final e1 = c.scheduleEvents.firstWhere((e) => e.id == 'e1');
      expect(e1.isFromJwxt, isTrue);
      expect(e1.isExam, isTrue);
      expect(e1.courseCode, 'MATH01');
    });

    test('corrupt files read as empty, no throw', () async {
      for (final n in [
        ScheduleStore.scheduleEventsFile,
        ScheduleStore.courseEditsFile,
        ScheduleStore.examOverridesFile,
        ScheduleStore.syncStateFile,
      ]) {
        File('${tmp.path}/$n').writeAsStringSync('{not json');
      }
      await c.ensureStarted();
      expect(c.scheduleEvents, isEmpty);
      expect(c.lastSyncSuccessAt, isNull);
      expect(await ScheduleStore.readCourseEdits(), isEmpty);
      expect(await ScheduleStore.readExamOverrides(), isEmpty);
    });

    test('manual add / update / delete change the event directly', () async {
      await c.ensureStarted();
      final saved = await c.addScheduleEvent(otherEvent(''));
      expect(saved.id, isNotEmpty);
      expect(
        await c.updateScheduleEvent(saved.copyWith(title: '改过的活动')),
        isTrue,
      );
      expect(c.scheduleEvents.single.title, '改过的活动');
      expect(await c.deleteScheduleEvent(saved.id), isTrue);
      expect(c.scheduleEvents, isEmpty);
      await restart();
      expect(c.scheduleEvents, isEmpty);
    });

    test('日程写入失败会反馈错误并恢复最后一次保存的状态', () async {
      await c.ensureStarted();
      await c.addScheduleEvent(otherEvent('existing'));
      await Directory('${tmp.path}/schedule_events.json.tmp').create();
      await expectLater(
        c.addScheduleEvent(otherEvent('new')),
        throwsA(isA<TimetablePersistenceException>()),
      );
      expect(c.scheduleEvents.map((e) => e.id), ['existing']);
      await restart();
      expect(c.scheduleEvents.map((e) => e.id), ['existing']);
    });

    test(
      'scheduleEventsOn hides exams only; last-item helper follows',
      () async {
        await seed([_jwxt('j1', '高等数学', start: 1, end: 2)]);
        await c.replaceJwxtExams([_exam('e1', 'MATH01', startH: 18, endH: 22)]);
        await c.addScheduleEvent(otherEvent('o1', endH: 21));
        final now = DateTime(2026, 9, 7, 7);

        expect(c.scheduleEventsOn(_monday).map((e) => e.id), ['e1', 'o1']);
        expect(
          c.lastVisibleItemEndToday(now: now),
          const TimeOfDayMinutes(22, 0),
        );

        await c.updateSettings(c.settings.copyWith(showExams: false));
        expect(c.scheduleEventsOn(_monday).map((e) => e.id), ['o1']);
        expect(c.scheduleEvents.length, 2);
        expect(
          c.lastVisibleItemEndToday(now: now),
          const TimeOfDayMinutes(21, 0),
        );

        await c.deleteScheduleEvent('o1');
        expect(
          c.lastVisibleItemEndToday(now: now),
          const TimeOfDayMinutes(9, 40),
        );
        expect(c.lastVisibleItemEndToday(now: DateTime(2026, 9, 9, 7)), isNull);
      },
    );

    test('EV19 manual exam / other unchanged by exam sync, restore all, unbind and re-sync', () async {
      await seed([_jwxt('j1', '高等数学')]);
      await c.addScheduleEvent(manualExam());
      await c.addScheduleEvent(otherEvent('o1'));
      final before = manualEventsJson();

      nextExams = [_exam('e1', 'MATH01')];
      await c.syncFromJwxt();
      expect(c.scheduleEvents.where((e) => e.isFromJwxt), hasLength(1));
      expect(manualEventsJson(), before);

      await c.deleteScheduleEvent('e1');
      expect(await c.restoreAllJwxt(), isTrue);
      expect(manualEventsJson(), before);

      await c.handleLogout();
      expect(manualEventsJson(), before);
      expect(c.scheduleEventsOn(_monday).map((e) => e.id).toSet(), {
        'm1',
        'o1',
      });
      await restart();
      expect(manualEventsJson(), before);

      await c.syncFromJwxt();
      expect(manualEventsJson(), before);
    });

    test('EV24 same name → same colour; map in schedule_events.json, fixed after restart; course_colors.json untouched', () async {
      await seed([_jwxt('j1', '高等数学'), _jwxt('j2', '大学物理', day: 2)]);
      final colorsFile = File('${tmp.path}/${TimetableStore.courseColorsFile}');
      final colorsBefore = colorsFile.readAsStringSync();
      await c.addScheduleEvent(named('a', '测试日程甲'));
      await c.addScheduleEvent(named('b', '测试日程甲', date: DateTime(2026, 9, 9)));
      await c.addScheduleEvent(named('x', '测试日程乙'));
      int idx(String id) => c.otherColorIndexOf(eventById(id));
      final ia = idx('a');
      final ix = idx('x');
      expect(idx('b'), ia);
      final stored = await ScheduleStore.readOtherColors();
      expect(stored, {'测试日程甲': ia, '测试日程乙': ix});
      expect(colorsFile.readAsStringSync(), colorsBefore);
      expect(colorsFile.readAsStringSync(), isNot(contains('测试日程')));

      await restart();
      expect(idx('a'), ia);
      expect(idx('b'), ia);
      expect(idx('x'), ix);
      expect(await ScheduleStore.readOtherColors(), stored);
      expect(colorsFile.readAsStringSync(), isNot(contains('测试日程')));
    });

    test('EV25 名称哈希位被课程占用 → 改用课程没用的色号', () async {
      await seed([_jwxt('j1', '高等数学')]);
      final courseIdx = c.colorIndexOf(c.courses.single);
      String? clash;
      for (var i = 0; i < 500 && clash == null; i++) {
        final n = '测试日程$i';
        if (courseColorIndexForName(n) % kCoursePaletteSize == courseIdx) {
          clash = n;
        }
      }
      expect(clash, isNotNull);
      final e = await c.addScheduleEvent(named('o1', clash!));
      final idx = c.otherColorIndexOf(e);
      expect(idx, isNot(courseIdx));
      expect(idx, inInclusiveRange(0, kCoursePaletteSize - 1));
    });

    test('EV26 adding/deleting 3 「其他」 events leaves course colours and course_colors.json unchanged', () async {
      await seed([
        _jwxt('j1', '高等数学'),
        _jwxt('j2', '大学物理', day: 2),
        _jwxt('j3', '线性代数', day: 3),
      ]);
      final file = File('${tmp.path}/${TimetableStore.courseColorsFile}');
      final bytes = file.readAsBytesSync();
      final before = {for (final x in c.courses) x.id: c.colorIndexOf(x)};
      for (var i = 0; i < 3; i++) {
        final e = await c.addScheduleEvent(named('o$i', '测试日程$i'));
        expect(await c.deleteScheduleEvent(e.id), isTrue);
      }
      expect({for (final x in c.courses) x.id: c.colorIndexOf(x)}, before);
      expect(file.readAsBytesSync(), bytes);
    });

    test(
      'EV27 courses use all 16 colours → 「其他」 falls back to the name hash',
      () async {
        await c.ensureStarted();
        for (var i = 0; i < kCoursePaletteSize; i++) {
          await c.addManualCourse(
            Course(
              id: 'm$i',
              name: '测试课$i',
              source: CourseSource.manual,
              colorIndex: i,
              slots: [
                CourseSlot(
                  day: i % 7 + 1,
                  startNode: i ~/ 7 * 2 + 1,
                  endNode: i ~/ 7 * 2 + 2,
                  weeks: '1' * 16,
                ),
              ],
            ),
          );
        }
        expect(
          {for (final x in c.courses) c.colorIndexOf(x)},
          {for (var i = 0; i < kCoursePaletteSize; i++) i},
        );
        final e = await c.addScheduleEvent(named('o1', '测试日程丙'));
        final idx = c.otherColorIndexOf(e);
        expect(idx, courseColorIndexForName('测试日程丙'));
        expect(idx, inInclusiveRange(0, kCoursePaletteSize - 1));
      },
    );

    test('EV29 renaming to an existing name takes that colour; no new map entry (restart)', () async {
      await c.ensureStarted();
      await c.addScheduleEvent(named('a', '测试日程甲'));
      await c.addScheduleEvent(named('b', '测试日程乙'));
      final ca = c.otherColorIndexOf(eventById('a'));
      expect(c.otherColorIndexOf(eventById('b')), isNot(ca));
      await c.updateScheduleEvent(eventById('b').copyWith(title: '测试日程甲'));
      expect(c.otherColorIndexOf(eventById('b')), ca);
      expect((await ScheduleStore.readOtherColors()).keys.toSet(), {
        '测试日程甲',
        '测试日程乙',
      });
      await restart();
      expect(c.otherColorIndexOf(eventById('b')), ca);
      expect(await ScheduleStore.readOtherColors(), hasLength(2));
    });

    test('EV30 renaming to a brand-new name keeps the colour; new name maps to it (restart)', () async {
      await c.ensureStarted();
      await c.addScheduleEvent(named('b', '测试日程乙'));
      final cb = c.otherColorIndexOf(eventById('b'));
      await c.updateScheduleEvent(eventById('b').copyWith(title: '测试日程丁'));
      expect(c.otherColorIndexOf(eventById('b')), cb);
      expect((await ScheduleStore.readOtherColors())['测试日程丁'], cb);
      await restart();
      expect(eventById('b').title, '测试日程丁');
      expect(c.otherColorIndexOf(eventById('b')), cb);
    });
  });

  group('批量写盘失败原子回滚与异常保护', () {
    final c = TimetableController.instance;
    final originalBinding = TimetableController.bindingCheck;
    late Directory directory;
    const oldSlotColor = 0xFF336699;
    const newGlobalColor = 0xFF996633;
    final pfSettings = TimetableSettings(
      termCode: '2026-2027-1',
      termStartDate: DateTime(2026, 8, 31),
    );

    Course pfCourse(String id, {bool manual = false, bool assigned = true}) =>
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

    Future<void> seedPf() async {
      await TimetableStore.saveSettings(pfSettings);
      await TimetableStore.saveSnapshot(
        TimetableSnapshot(settings: pfSettings, courses: [pfCourse('jwxt')]),
      );
      await TimetableStore.saveManualCourses([
        pfCourse('manual', manual: true),
      ]);
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
        'schedule_events.json',
      ])
        if (File('${directory.path}/$name').existsSync())
          name: File('${directory.path}/$name').readAsStringSync(),
    };

    Future<void> restart() async {
      c.debugReset();
      await c.ensureStarted();
    }

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('tt_persistence_fail');
      TimetableStore.debugDirectory = directory;
      TimetableStore.debugBeforeBatchReplace = null;
      TimetableStore.debugPrepareBatchInBackground = true;
      TimetableController.bindingCheck = () async => false;
      c.debugReset();
    });

    tearDown(() async {
      TimetableStore.debugBeforeBatchReplace = null;
      TimetableStore.debugPrepareBatchInBackground = false;
      TimetableStore.debugDirectory = null;
      TimetableController.bindingCheck = originalBinding;
      c.debugReset();
      await directory.delete(recursive: true);
    });

    test('设置后一个文件替换失败，原文件和内存均恢复，重启也保持原值', () async {
      await seedPf();
      final before = savedFiles();
      final changes = <ScheduleChangeReason>[];
      final subscription = c.scheduleChanged.listen(changes.add);
      addTearDown(subscription.cancel);
      TimetableStore.debugBeforeBatchReplace = (index) {
        if (index == 1) throw const FileSystemException('合成替换失败');
      };
      await expectLater(
        c.updateSettings(c.settings.copyWith(maxWeeks: 18)),
        throwsA(isA<TimetablePersistenceException>()),
      );
      expect(c.settings.maxWeeks, 30);
      expect(savedFiles(), before);
      await pumpEventQueue();
      expect(changes, isEmpty);
      TimetableStore.debugBeforeBatchReplace = null;
      await restart();
      expect(c.settings.maxWeeks, 30);
    });

    test('课程转换考试最后文件失败时全部存储与内存均不变，重试仅通知一次', () async {
      await seedPf();
      await c.addScheduleEvent(
        ScheduleEvent(
          id: 'existing-exam',
          kind: ScheduleKind.exam,
          source: ScheduleSource.manual,
          title: '已有考试',
          date: DateTime(2026, 9, 1),
          start: const TimeOfDayMinutes(10, 0),
          end: const TimeOfDayMinutes(11, 0),
        ),
      );
      await pumpEventQueue();
      final before = savedFiles();
      final originalManual = c.manualCourses.single.toJson();
      final originalEdits = c.courseDateEdits
          .map((edit) => edit.toJson())
          .toList();
      final originalEvents = c.scheduleEvents
          .map((event) => event.toJson())
          .toList();
      GridCell opening() => c
          .cellsForDay(1, 1)
          .firstWhere(
            (cell) => cell.activeThisWeek && cell.course.id == 'manual',
          );
      Future<ScheduleEvent?> convert() => c.convertCourseOccurrenceToExam(
        cell: opening(),
        title: '转换考试',
        location: '',
        note: '',
        day: 1,
        startNode: 1,
        endNode: 2,
      );
      final changes = <ScheduleChangeReason>[];
      final subscription = c.scheduleChanged.listen(changes.add);
      addTearDown(subscription.cancel);
      TimetableStore.debugBeforeBatchReplace = (index) {
        if (index == 2) throw const FileSystemException('合成考试保存失败');
      };
      await expectLater(
        convert(),
        throwsA(isA<TimetablePersistenceException>()),
      );
      expect(savedFiles(), before);
      expect(c.manualCourses.single.toJson(), originalManual);
      expect(
        c.courseDateEdits.map((edit) => edit.toJson()).toList(),
        originalEdits,
      );
      expect(
        c.scheduleEvents.map((event) => event.toJson()).toList(),
        originalEvents,
      );
      expect(opening().slot.note, '保留备注');
      await pumpEventQueue();
      expect(changes, isEmpty);
      TimetableStore.debugBeforeBatchReplace = null;
      await restart();
      expect(opening().slot.note, '保留备注');
      expect(
        c.scheduleEvents.map((event) => event.toJson()).toList(),
        originalEvents,
      );
      expect(await convert(), isNotNull);
      await pumpEventQueue();
      expect(changes, [ScheduleChangeReason.scheduleEvent]);
      expect(c.scheduleEvents, hasLength(2));
      expect(c.courseDateEdits, isEmpty);
      expect(c.manualCourses.single.slots.single.weeks, '0111');
      expect(c.manualCourses.single.slots.single.color, oldSlotColor);
    });

    test('换配色方案的最后一份文件失败，不残留新方案或新手动课色号', () async {
      await seedPf();
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
      await seedPf();
      final blocked = File('${directory.path}/blocked')
        ..writeAsStringSync('占位');
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
      await seedPf();
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
      await seedPf();
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
      await seedPf();
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
        c.settingsForEditing.copyWith(reminderLeadMinutes: 10),
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
      expect(c.settings.reminderLeadMinutes, 10);
      expect(c.settings.nextDayReminderEnabled, isTrue);
      expect(observed, [true]);
    });

    test('待保存配色不会污染已保存的稳定颜色映射', () async {
      await seedPf();
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
        pfCourse('manual', manual: true, assigned: false),
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
      await seedPf();
      Directory('${directory.path}/overrides.json.tmp').createSync();
      await expectLater(
        c.restoreOverride(c.jwxtCourses.single, 0),
        throwsA(isA<TimetablePersistenceException>()),
      );
      expect(c.slotOverrides.single.id, 'old-move');
      expect((await TimetableStore.readOverrides()).single.id, 'old-move');
    });
  });
}

class _UnavailableFile implements File {
  _UnavailableFile(this.path);

  @override
  final String path;

  @override
  bool existsSync() => throw const FileSystemException('模拟读取失败');

  @override
  Future<bool> exists() async => throw const FileSystemException('模拟读取失败');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
