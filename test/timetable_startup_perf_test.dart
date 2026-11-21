import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_appearance_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_colors.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_date_edits.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_multi_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_notify_bridge.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_notify_service.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_overrides.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_sync_diff.dart';

class _RecordingBridge extends TimetableNotifyBridge {
  final scheduled = <List<Map<String, Object?>>>[];
  final widgets = <Map<String, Object?>>[];
  bool failNextSchedule = false;
  bool failNextWidget = false;
  Completer<void>? scheduleGate;
  Completer<void>? scheduleEntered;

  @override
  Future<void> scheduleReminders(List<Map<String, Object?>> alarms) async {
    scheduleEntered?.complete();
    if (scheduleGate case final gate?) {
      await gate.future;
    }
    if (failNextSchedule) {
      failNextSchedule = false;
      throw PlatformException(code: 'schedule_error', message: '合成排程失败');
    }
    scheduled.add(alarms);
  }

  @override
  Future<void> updateWidget(Map<String, Object?> payload) async {
    if (failNextWidget) {
      failNextWidget = false;
      throw PlatformException(code: 'widget_error', message: '合成小组件更新失败');
    }
    widgets.add(payload);
  }

  @override
  Future<bool> openExactAlarmSettings() async => true;

  @override
  Future<bool> openNotificationSettings() async => true;
}

void main() {
  late Directory tmp;
  final c = TimetableController.instance;
  final originalBinding = TimetableController.bindingCheck;
  final originalClock = TimetableController.clock;
  final originalSyncClock = TimetableController.syncClock;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tt_startup_perf');
    TimetableStore.debugDirectory = tmp;
    TimetableStore.debugReadBatchInBackground = false;
    TimetableStore.debugPrepareBatchInBackground = false;
    TimetableStore.debugOnBatchRead = null;
    TimetableStore.debugBeforeBatchReplace = null;
    TimetableController.debugBuildNextDayReminderInBackground = false;
    TimetableController.bindingCheck = () async => false;
    TimetableController.clock = () => DateTime(2026, 9, 7);
    TimetableController.syncClock = () => DateTime(2026, 9, 7, 8);
    TimetableChangeLogStore.debugMemory = null;
    c.debugReset();
  });

  tearDown(() async {
    TimetableStore.debugReadBatchInBackground = false;
    TimetableStore.debugPrepareBatchInBackground = false;
    TimetableStore.debugOnBatchRead = null;
    TimetableStore.debugBeforeBatchReplace = null;
    TimetableController.debugBuildNextDayReminderInBackground = false;
    TimetableController.bindingCheck = originalBinding;
    TimetableController.clock = originalClock;
    TimetableController.syncClock = originalSyncClock;
    TimetableChangeLogStore.debugMemory = null;
    c.debugReset();
    TimetableStore.debugDirectory = null;
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Course jwxtCourse(String id, String name) => Course(
    id: id,
    name: name,
    source: CourseSource.jwxt,
    slots: const [
      CourseSlot(
        day: 1,
        startNode: 1,
        endNode: 2,
        weeks: '1111111111111111',
        location: '教1-101',
      ),
    ],
  );

  Course manualCourse(String id, String name) => Course(
    id: id,
    name: name,
    source: CourseSource.manual,
    assignedColorIndex: 2,
    slots: const [
      CourseSlot(
        day: 2,
        startNode: 3,
        endNode: 4,
        weeks: '1111111111111111',
        location: '教2-202',
      ),
    ],
  );

  Future<void> seedAllFiles({
    String primaryScheduleId = kDefaultScheduleId,
  }) async {
    final settings = TimetableSettings(
      termCode: '2026-2027-1',
      termStartDate: DateTime(2026, 8, 31),
      termStartFromJwxt: true,
    );
    await TimetableStore.saveSchedulesIndex(
      SchedulesIndex(
        primaryScheduleId: primaryScheduleId,
        currentTermCode: '2026-2027-1',
        schedules: [
          const ScheduleMetadata(
            id: kDefaultScheduleId,
            name: '默认学期',
            sourceKind: TimetableSourceKind.jwxt,
            termCode: '2026-2027-1',
            courseCount: 1,
          ),
          if (primaryScheduleId != kDefaultScheduleId)
            ScheduleMetadata(
              id: primaryScheduleId,
              name: '好友课表',
              sourceKind: TimetableSourceKind.wakeupImport,
              termCode: '2026-2027-1',
              courseCount: 1,
            ),
        ],
      ),
    );
    await TimetableStore.saveSettings(settings);
    await ScheduleStore.saveLastSyncSuccess(DateTime(2026, 9, 7, 8));
    await ScheduleStore.saveLastAutomaticAttempt(DateTime(2026, 9, 7, 8));
    await ScheduleStore.savePortalSessionExpired(false);

    await TimetableStore.withScheduleScope(primaryScheduleId, () async {
      await TimetableStore.saveSnapshot(
        TimetableSnapshot(
          courses: [jwxtCourse('j1', '高等数学')],
          periods: TimetableController.defaultPeriods(),
          settings: settings,
          syncedAt: DateTime(2026, 9, 7, 8),
        ),
      );
      await TimetableStore.saveManualCourses([manualCourse('m1', '线性代数')]);
      await TimetableStore.saveOverrides([
        const SlotOverride(
          id: 'ov1',
          courseId: 'j1',
          origDay: 1,
          origStart: 1,
          origEnd: 2,
          origWeeks: '1111111111111111',
          weeks: [1],
          scope: MoveScope.thisWeek,
          fromWeek: 1,
          toDay: 3,
          toStart: 1,
          toEnd: 2,
        ),
      ]);
      await TimetableStore.saveCourseColors(CoursePaletteScheme.soft, const {
        '高等数学': 1,
      });
      await TimetableStore.saveUserCourseColors(const {'j1': 0xFF336699});
      await ScheduleStore.saveEventsAndOtherColors(
        [
          ScheduleEvent(
            id: 'ev1',
            kind: ScheduleKind.other,
            source: ScheduleSource.manual,
            title: '班会',
            date: DateTime(2026, 9, 7),
            start: const TimeOfDayMinutes(18, 0),
            end: const TimeOfDayMinutes(19, 0),
          ),
        ],
        const {'班会': 4},
      );
      await ScheduleStore.saveCourseEdits(const {
        'j1': CourseEdit(courseId: 'j1', origFingerprint: 'fp'),
      });
      await ScheduleStore.saveCourseDateEdits([
        CourseDateEdit(
          id: 'de1',
          courseId: 'm1',
          date: DateTime(2026, 9, 8),
          origStart: 3,
          origEnd: 4,
          note: '带教材',
        ),
      ]);
      await ScheduleStore.saveDaySwaps([
        DaySwap(
          id: 'sw1',
          dateA: DateTime(2026, 9, 9),
          dateB: DateTime(2026, 9, 10),
        ),
      ]);
      await ScheduleStore.saveExamOverrides(const {
        'ex1': ExamOverride(key: 'ex1', deleted: true),
      });
      await TimetableChangeLogStore.upsertCandidates([
        TimetableChangeRecord(
          id: 'chg1',
          slotKey: 'C1|1|1|1|2|1111111111111111',
          fingerprint: 'fp1',
          xnxqdm: '2026-2027-1',
          courseName: '高等数学',
          type: TimetableChangeType.added,
          time: DateTime(2026, 9, 7, 8),
        ),
      ]);
    });
  }

  group('单次批量读盘', () {
    test('冷启动只触发一次批量读取且每个文件仅读一次（含后台 Isolate 与多课表隔离）', () async {
      await seedAllFiles();

      final batchCalls = <List<String>>[];
      TimetableStore.debugOnBatchRead = (files) => batchCalls.add(files);
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
      // 在默认根目录放一门不同的课，确认非默认主课表不会混读。
      await TimetableStore.saveSnapshot(
        TimetableSnapshot(courses: [jwxtCourse('def1', '默认根目录课')]),
      );
      // 损坏 friend_1 作用域内的 day_swaps.json。
      final badSwaps = File('${tmp.path}/schedules/friend_1/day_swaps.json')
        ..writeAsStringSync('{not valid json');

      TimetableStore.debugReadBatchInBackground = true;
      await c.ensureStarted();

      expect(c.primaryScheduleId, 'friend_1');
      expect(c.jwxtCourses.single.name, '高等数学');
      expect(c.daySwaps, isEmpty);
      expect(File('${badSwaps.path}.corrupt').existsSync(), isTrue);
    });
  });

  group('外观滑杆拖动不写盘、松手写一次且不重写 snapshot', () {
    Future<void> settleIo(WidgetTester tester) async {
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets(
      '拖动不透明度/表头字号/格子高度滑杆仅更新预览，松手写一次 settings.json 且不改 snapshot.json',
      (tester) async {
        await tester.runAsync(() async {
          await seedAllFiles();
          await c.ensureStarted();
        });

        final snapshotFile = File('${tmp.path}/snapshot.json');
        final settingsFile = File('${tmp.path}/settings.json');
        final snapshotBytesBefore = snapshotFile.readAsBytesSync();
        final settingsBefore =
            jsonDecode(settingsFile.readAsStringSync()) as Map<String, dynamic>;

        var batchReplaceCount = 0;
        TimetableStore.debugBeforeBatchReplace = (_) => batchReplaceCount++;
        final changes = <ScheduleChangeReason>[];
        final sub = c.scheduleChanged.listen(changes.add);
        addTearDown(sub.cancel);

        tester.view.physicalSize = const Size(1080, 6000);
        tester.view.devicePixelRatio = 2.625;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(home: TimetableAppearancePage(controller: c)),
        );
        await tester.pump();

        // 1) 拖动过程中多次触发 onChanged：预览文案变化，但不写盘、不改 controller.settings。
        final opacitySliderFinder = find.byKey(
          const Key('tt_settings_opacity'),
        );
        await tester.ensureVisible(opacitySliderFinder);
        await tester.pump();
        final opacitySlider = tester.widget<Slider>(opacitySliderFinder);
        opacitySlider.onChanged!(80);
        await tester.pump();
        opacitySlider.onChanged!(60);
        await tester.pump();
        opacitySlider.onChanged!(50);
        await tester.pump();

        expect(
          tester
              .widget<Text>(find.byKey(const Key('tt_settings_opacity_value')))
              .data,
          '50%',
        );
        expect(c.settings.cellOpacity, 100);
        expect(batchReplaceCount, 0, reason: '拖动过程不能触发写盘');
        expect(jsonDecode(settingsFile.readAsStringSync()), settingsBefore);

        // 2) 松手触发 onChangeEnd：只写一次 settings.json，不重写 snapshot.json，不发 settings 变更事件。
        opacitySlider.onChangeEnd!(50);
        await tester.pump();
        await settleIo(tester);

        expect(c.settings.cellOpacity, 50);
        expect(batchReplaceCount, 1, reason: '松手后只提交写 settings.json 一个文件');
        expect(snapshotFile.readAsBytesSync(), snapshotBytesBefore);
        expect(
          (jsonDecode(settingsFile.readAsStringSync()) as Map)['cellOpacity'],
          50,
        );
        expect(
          changes,
          isEmpty,
          reason: '纯外观偏好不触发 ScheduleChangeReason.settings',
        );

        // 3) 表头字号与格子高度同理。
        final headerSliderFinder = find.byKey(
          const Key('tt_settings_header_text_size'),
        );
        await tester.ensureVisible(headerSliderFinder);
        await tester.pump();
        final headerSlider = tester.widget<Slider>(headerSliderFinder);
        headerSlider.onChanged!(13);
        await tester.pump();
        expect(batchReplaceCount, 1);
        headerSlider.onChangeEnd!(13);
        await tester.pump();
        await settleIo(tester);
        expect(batchReplaceCount, 2);
        expect(c.settings.headerTextSize, 13);

        final heightSliderFinder = find.byKey(
          const Key('tt_settings_period_height'),
        );
        await tester.ensureVisible(heightSliderFinder);
        await tester.pump();
        final heightSlider = tester.widget<Slider>(heightSliderFinder);
        heightSlider.onChanged!(72);
        await tester.pump();
        expect(batchReplaceCount, 2);
        heightSlider.onChangeEnd!(72);
        await tester.pump();
        await settleIo(tester);
        expect(batchReplaceCount, 3);
        expect(c.settings.periodHeight, 72);
        expect(snapshotFile.readAsBytesSync(), snapshotBytesBefore);
        expect(changes, isEmpty);

        // 4) 修改影响小组件/配色的设置时仍按需同步通知。
        await tester.runAsync(
          () => c.updateSettings(c.settings.copyWith(examColor: 0xFF123456)),
        );
        await tester.runAsync(
          () => c.updateSettings(c.settings.copyWith(paletteScheme: 'B')),
        );
        await tester.pump();
        expect(changes, [
          ScheduleChangeReason.settings,
          ScheduleChangeReason.settings,
        ]);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  });

  group('TimetableNotifyService.reschedule 指纹去重', () {
    test('相同输入跳过重复 MethodChannel 与小组件更新，变化或失败后重跑', () async {
      c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [jwxtCourse('j1', '高等数学')],
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termCode: '2026-2027-1',
            termStartDate: DateTime(2026, 8, 31),
          ),
          syncedAt: DateTime(2026, 9, 7, 8),
        ),
      );

      var now = DateTime(2026, 9, 7, 8);
      final bridge = _RecordingBridge();
      final service = TimetableNotifyService(
        controller: c,
        bridge: bridge,
        clock: () => now,
      );
      addTearDown(service.dispose);

      await service.reschedule();
      await service.reschedule();
      expect(bridge.scheduled, hasLength(1));
      expect(bridge.widgets, hasLength(1));

      // 跨自然日 → 触发重新排程。
      now = DateTime(2026, 9, 8, 8);
      await service.reschedule();
      expect(bridge.scheduled, hasLength(2));
      expect(bridge.widgets, hasLength(2));

      // 课表或设置变化 → 触发重新排程。
      await c.updateSettings(
        c.settingsForEditing.copyWith(reminderEnabled: true),
      );
      await service.reschedule();
      expect(bridge.scheduled, hasLength(3));
      expect(bridge.widgets, hasLength(3));

      // 桥调用失败时不记录指纹，下次相同输入可重试。
      now = DateTime(2026, 9, 9, 8);
      bridge.failNextWidget = true;
      await service.reschedule();
      expect(bridge.scheduled, hasLength(4));
      expect(bridge.widgets, hasLength(3));

      await service.reschedule();
      expect(bridge.scheduled, hasLength(5));
      expect(bridge.widgets, hasLength(4));

      // 再次相同输入则继续命中去重。
      await service.reschedule();
      expect(bridge.scheduled, hasLength(5));
      expect(bridge.widgets, hasLength(4));
    });

    test('同日权限跳转后清空指纹缓存，允许升级为精确闹钟并刷新小组件', () async {
      c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [jwxtCourse('j1', '高等数学')],
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termCode: '2026-2027-1',
            termStartDate: DateTime(2026, 8, 31),
          ),
          syncedAt: DateTime(2026, 9, 7, 8),
        ),
      );

      final bridge = _RecordingBridge();
      final service = TimetableNotifyService(
        controller: c,
        bridge: bridge,
        clock: () => DateTime(2026, 9, 7, 9),
      );
      addTearDown(service.dispose);

      await service.reschedule();
      expect(bridge.scheduled, hasLength(1));
      expect(bridge.widgets, hasLength(1));

      await service.openExactAlarmSettings();
      await service.reschedule();
      expect(bridge.scheduled, hasLength(2));
      expect(bridge.widgets, hasLength(2));

      await service.openNotificationSettings();
      await service.reschedule();
      expect(bridge.scheduled, hasLength(3));
      expect(bridge.widgets, hasLength(3));
    });

    test('同日跨过 syncedAt + 7 天过期边界时，触发重排并更新小组件为 needsUpdate', () async {
      final syncedAt = DateTime(2026, 9, 7, 8);
      TimetableController.bindingCheck = () async => true;
      c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [jwxtCourse('j1', '高等数学')],
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termCode: '2026-2027-1',
            termStartDate: DateTime(2026, 8, 31),
          ),
          syncedAt: syncedAt,
        ),
      );
      await c.refreshPortalBound();

      var now = DateTime(2026, 9, 14, 7, 59);
      final bridge = _RecordingBridge();
      final service = TimetableNotifyService(
        controller: c,
        bridge: bridge,
        clock: () => now,
      );
      addTearDown(service.dispose);

      await service.reschedule();
      expect(bridge.widgets, hasLength(1));
      expect(bridge.widgets.last['state'], 'ok');

      now = DateTime(2026, 9, 14, 8, 1);
      await service.reschedule();
      expect(bridge.scheduled, hasLength(2));
      expect(bridge.widgets, hasLength(2));
      expect(bridge.widgets.last['state'], 'needsUpdate');
    });

    test('并发 reschedule 在途发生设置变更时，不会写入过时指纹覆盖新状态', () async {
      c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [jwxtCourse('j1', '高等数学')],
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termCode: '2026-2027-1',
            termStartDate: DateTime(2026, 8, 31),
          ),
          syncedAt: DateTime(2026, 9, 7, 8),
        ),
      );

      final bridge = _RecordingBridge();
      final gate = Completer<void>();
      final entered = Completer<void>();
      bridge.scheduleGate = gate;
      bridge.scheduleEntered = entered;

      final service = TimetableNotifyService(
        controller: c,
        bridge: bridge,
        clock: () => DateTime(2026, 9, 7, 8),
      );
      addTearDown(service.dispose);

      final first = service.reschedule();
      await entered.future;

      await c.updateSettings(
        c.settingsForEditing.copyWith(reminderEnabled: true),
      );
      gate.complete();
      bridge.scheduleGate = null;
      bridge.scheduleEntered = null;
      await first;

      // 早启动的 first 使用的是旧设置快照，不能把旧指纹当成当前已缓存指纹。
      await service.reschedule();
      expect(bridge.scheduled, hasLength(2));
      expect(bridge.widgets, hasLength(2));
    });
  });

  group('后台读写串行与 writeBatch / modifyJsonFile 并发保护', () {
    test('后台写后立即调用 readScopeBundle 不会读到旧文件', () async {
      await seedAllFiles();
      TimetableStore.debugPrepareBatchInBackground = true;
      TimetableStore.debugReadBatchInBackground = true;

      final writeFuture = TimetableStore.writeBatch(() async {
        await TimetableStore.saveManualCourses([
          manualCourse('m_new', '后台新手动课'),
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

      // 1) 先发起独立异步 modifyJsonFile（saveUserCourseColors），紧接并发 writeBatch（saveCourseColors）。
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

      // 2) 反向顺序：先发起 writeBatch（stageWrites 内部包含异步断点），并发触发 modifyJsonFile。
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

  group('明日提醒后台 Isolate 计算', () {
    test(
      '开启 debugBuildNextDayReminderInBackground 时在后台 Isolate 计算 400 天且不扰动缓存',
      () async {
        const channel = MethodChannel('nuist/timetable_next_day');
        Map<Object?, Object?>? sent;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'update') {
                sent = call.arguments as Map<Object?, Object?>;
              }
              return {'diagnostics': <Object?>[]};
            });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });

        TimetableController.bindingCheck = () async => true;
        TimetableController.debugBuildNextDayReminderInBackground = true;
        c.debugSetSnapshot(
          TimetableSnapshot(
            courses: [jwxtCourse('j1', '高等数学')],
            periods: TimetableController.defaultPeriods(),
            settings: TimetableSettings(termStartDate: DateTime(2026, 8, 31)),
            syncedAt: DateTime(2026, 9, 7, 8),
          ),
        );
        await c.refreshPortalBound();
        final dayCells = c.cellsForDay(2, 1);

        await c.updateNextDayReminder();
        expect(sent?['enabled'], isTrue);
        final payloads = sent?['payloads'] as Map<Object?, Object?>;
        expect(payloads, hasLength(400));
        expect(c.cellsForDay(2, 1), same(dayCells));
      },
    );
  });
}
