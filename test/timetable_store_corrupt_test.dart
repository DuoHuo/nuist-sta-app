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
import 'package:nuist_sta_app/mini_apps/timetable/timetable_overrides.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

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
