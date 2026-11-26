import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/app_registry.dart';
import 'package:nuist_sta_app/core/logging/app_log.dart';
import 'package:nuist_sta_app/core/refresh/silent_refresh.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_change_format.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_sync_diff.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_manifest.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_exams_manifest.dart';

// 虚构数据；时钟注入，不真正等待。
Course _course(String id) => Course(
  id: id,
  name: '课程 $id',
  source: CourseSource.jwxt,
  slots: const [
    CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: '1111111111111111'),
  ],
);

void main() {
  late Directory tmp;
  final c = TimetableController.instance;
  late DateTime now;
  var fetches = 0;
  Object? failWith;
  Completer<void>? gate;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tt_sync');
    TimetableStore.debugDirectory = tmp;
    now = DateTime(2026, 9, 7, 8);
    fetches = 0;
    failWith = null;
    gate = null;
    TimetableController.clock = () => DateTime(2026, 9, 7);
    TimetableController.syncClock = () => now;
    TimetableController.bindingCheck = () async => true;
    TimetableController.fetchSnapshot = (term, {baseSettings}) async {
      fetches++;
      if (gate != null) await gate!.future;
      final err = failWith;
      if (err != null) throw err;
      return TimetableSnapshot(
        courses: [_course('j1')],
        periods: TimetableController.defaultPeriods(),
        settings: const TimetableSettings(termCode: '2026-2027-1'),
      );
    };
    c.debugReset();
  });

  tearDown(() async {
    TimetableStore.debugDirectory = null;
    TimetableController.clock = TimetableApi.shanghaiToday;
    TimetableController.syncClock = DateTime.now;
    TimetableController.fetchSnapshot = (term, {baseSettings}) =>
        TimetableApi.fetchTermSnapshot(term, baseSettings: baseSettings);
    c.debugReset();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> restart() async {
    c.debugReset();
    await c.ensureStarted();
  }

  void advance(Duration d) => now = now.add(d);

  test('AS26: first install (no timestamp) syncs on start', () async {
    expect(await c.onAppStart(), isTrue);
    expect(fetches, 1);
    expect(c.lastSyncSuccessAt, now);
  });

  test('自动同步失败后打开页面和频繁回前台遵守尝试间隔，手动与重绑可立即恢复', () async {
    failWith = const JwxtHttpError('kb', 500);
    expect(await c.onAppStart(), isTrue);
    expect(c.lastSyncSuccessAt, isNull);
    for (var index = 0; index < 5; index++) {
      await c.autoSyncIfNeeded();
      await c.onAppResumed();
      await pumpEventQueue();
      expect(await c.onAppStart(), isFalse);
    }
    expect(fetches, 1);
    advance(TimetableController.autoSyncInterval);
    expect(await c.onAppStart(), isTrue);
    expect(fetches, 2);
    failWith = null;
    expect(await c.manualSync(), isTrue);
    expect(fetches, 3);
    expect(await c.onLoginSucceeded(), isTrue);
    expect(fetches, 4);
  });

  test(
    'AS10/AS11/AS22/AS23: 90 分钟节流跨重启持久（89m59s/autoSync 不拉，90m00s/90m01s 重拉）',
    () async {
      await c.onAppStart();
      expect(fetches, 1);

      // 未满 90 分钟且缓存清空时 autoSyncIfNeeded 仍遵守节流
      c.debugSetSnapshot(const TimetableSnapshot());
      await c.autoSyncIfNeeded();
      expect(fetches, 1);

      // 5 分钟、89m59s 重启均不拉取
      advance(const Duration(minutes: 5));
      await restart();
      expect(c.lastSyncSuccessAt, DateTime(2026, 9, 7, 8));
      expect(await c.onAppStart(), isFalse);
      advance(const Duration(minutes: 84, seconds: 59));
      await restart();
      expect(await c.onAppStart(), isFalse);
      expect(fetches, 1);

      // 满 90 分钟重拉；90m01s 再次重拉
      advance(const Duration(seconds: 1));
      await restart();
      expect(await c.onAppStart(), isTrue);
      expect(fetches, 2);

      advance(const Duration(minutes: 90, seconds: 1));
      await restart();
      expect(await c.onAppStart(), isTrue);
      expect(fetches, 3);
    },
  );

  test(
    'AS17 AS24: offline failure, network restored 1 min later → one retry',
    () async {
      await c.onAppStart(); // 成功，t0
      advance(const Duration(minutes: 91));
      failWith = const SocketException('Network is unreachable');
      await c.onAppStart();
      expect(fetches, 2);
      expect(c.syncStatus, TimetableSyncStatus.failure);
      expect(c.jwxtCourses.map((e) => e.id), ['j1'], reason: 'data kept');

      advance(const Duration(minutes: 1));
      failWith = null;
      expect(await c.onNetworkRestored(), isTrue);
      expect(fetches, 3);
      expect(c.syncStatus, TimetableSyncStatus.success);
      // 只重试一次。
      expect(await c.onNetworkRestored(), isFalse);
      expect(fetches, 3);
    },
  );

  test('network restored without an offline failure does nothing', () async {
    await c.onAppStart();
    expect(await c.onNetworkRestored(), isFalse);
    advance(const Duration(minutes: 91));
    failWith = TimeoutException('t');
    await c.onAppStart();
    expect(await c.onNetworkRestored(), isFalse, reason: 'timeout ≠ offline');
    expect(fetches, 2);
  });

  test('offline retry that fails again is not retried again', () async {
    failWith = const SocketException('offline');
    await c.onAppStart();
    expect(await c.onNetworkRestored(), isTrue);
    expect(await c.onNetworkRestored(), isFalse);
    expect(fetches, 2);
  });

  for (final entry in <String, Object>{
    'timeout': TimeoutException('t'),
    '500': const JwxtHttpError('kb', 500),
  }.entries) {
    test('AS25: ${entry.key} does not reset the interval', () async {
      await c.onAppStart();
      final t0 = c.lastSyncSuccessAt;
      advance(const Duration(minutes: 91));
      failWith = entry.value;
      expect(await c.onAppStart(), isTrue);
      expect(c.syncStatus, TimetableSyncStatus.failure);
      expect(c.lastSyncSuccessAt, t0);
      await restart();
      expect(c.lastSyncSuccessAt, t0);
      // 失败时间也持久化，重启仍等待自动尝试间隔。
      failWith = null;
      expect(await c.onAppStart(), isFalse);
      expect(fetches, 2);
      advance(TimetableController.autoSyncInterval);
      expect(await c.onAppStart(), isTrue);
      expect(fetches, 3);
      expect(c.lastSyncSuccessAt, now);
    });
  }

  test('首次失败保留成功时间为空，重启90分钟内不自动重拉，手动仍可立即恢复', () async {
    failWith = const JwxtHttpError('kb', 500);
    await c.onAppStart();
    expect(c.lastSyncSuccessAt, isNull);
    await restart();
    failWith = null;
    expect(await c.onAppStart(), isFalse);
    expect(fetches, 1);
    advance(TimetableController.autoSyncInterval);
    expect(await c.onAppStart(), isTrue);
    expect(fetches, 2);
  });

  test('AS12 login and manual sync bypass the throttle', () async {
    await c.onAppStart();
    advance(const Duration(minutes: 1));
    expect(await c.onLoginSucceeded(), isTrue);
    advance(const Duration(minutes: 1));
    expect(await c.manualSync(), isTrue);
    expect(fetches, 3);
  });

  test('绑定通知立即同步，课表与考试卡片只触发一次请求', () async {
    await c.onAppStart();
    advance(const Duration(minutes: 1));
    final registry = AppRegistry([timetableManifest, examScheduleManifest]);
    expect(await registry.notifyPortalBindingChanged(bound: true), isTrue);
    expect(fetches, 2);
    expect(c.portalBound, isTrue);
  });

  test('在途同步不会吞掉换绑通知，旧请求结束后补一次同步', () async {
    await c.ensureStarted();
    gate = Completer<void>();
    final first = c.manualSync();
    await pumpEventQueue();
    final registry = AppRegistry([timetableManifest, examScheduleManifest]);
    final rebound = registry.notifyPortalBindingChanged(bound: true);
    await pumpEventQueue();
    expect(fetches, 1);
    final oldGate = gate!;
    gate = null;
    oldGate.complete();
    await first;
    expect(await rebound, isTrue);
    expect(fetches, 2);
    expect(c.syncStatus, TimetableSyncStatus.success);
  });

  test('解绑等待在途同步结束，晚到课表不会重新写回', () async {
    await c.ensureStarted();
    gate = Completer<void>();
    final first = c.manualSync();
    await pumpEventQueue();
    TimetableController.bindingCheck = () async => false;
    final registry = AppRegistry([timetableManifest, examScheduleManifest]);
    final unbound = registry.notifyPortalBindingChanged(bound: false);
    await pumpEventQueue();
    expect(c.portalBound, isFalse);
    gate!.complete();
    await first;
    expect(await unbound, isTrue);
    expect(c.jwxtCourses, isEmpty);
    expect(c.syncStatus, TimetableSyncStatus.idle);
    expect(await TimetableStore.readSnapshot(), isNull);
  });

  test('解绑忽略晚到考试，保留考试覆盖且不记录旧同步成功', () async {
    await c.ensureStarted();
    final exam = ScheduleEvent(
      id: 'old-exam',
      kind: ScheduleKind.exam,
      source: ScheduleSource.jwxt,
      title: '示例考试',
      date: DateTime(2026, 9, 8),
      start: const TimeOfDayMinutes(9, 0),
      end: const TimeOfDayMinutes(11, 0),
      courseCode: 'EXAMPLE01',
    );
    await c.replaceJwxtExams([exam]);
    await c.deleteScheduleEvent(exam.id);
    final originalFetchExams = TimetableController.fetchExams;
    addTearDown(() => TimetableController.fetchExams = originalFetchExams);
    final entered = Completer<void>();
    final examResponse = Completer<List<ScheduleEvent>>();
    TimetableController.fetchExams = (_) {
      entered.complete();
      return examResponse.future;
    };
    final outcomes = <TimetableSyncOutcome>[];
    final subscription = c.syncOutcomes.listen(outcomes.add);
    addTearDown(subscription.cancel);

    final sync = c.manualSync();
    await entered.future;
    TimetableController.bindingCheck = () async => false;
    final unbound = c.onPortalBindingChanged(false);
    // 过时响应若仍合并，空列表会删除原考试的覆盖记录。
    examResponse.complete(const []);
    await sync;
    await unbound;
    await pumpEventQueue();

    expect(c.isJwxtOverridden(examKey: exam.jwxtKey), isTrue);
    expect(await ScheduleStore.readExamOverrides(), contains(exam.jwxtKey));
    expect(c.scheduleEvents, isEmpty);
    expect(c.lastSyncSuccessAt, isNull);
    expect(outcomes, isEmpty);
    expect(c.syncStatus, TimetableSyncStatus.idle);
  });

  for (final latestBound in [true, false]) {
    test('读取绑定状态期间再次${latestBound ? '换绑' : '解绑'}，旧通知不再启动同步', () async {
      await c.ensureStarted();
      final entered = Completer<void>();
      final oldBindingRead = Completer<bool>();
      var bindingReads = 0;
      TimetableController.bindingCheck = () {
        if (bindingReads++ == 0) {
          entered.complete();
          return oldBindingRead.future;
        }
        return Future.value(latestBound);
      };

      final first = c.onPortalBindingChanged(true);
      await entered.future;
      final latest = c.onPortalBindingChanged(latestBound);
      oldBindingRead.complete(true);
      await Future.wait([first, latest]);

      expect(fetches, latestBound ? 1 : 0);
      expect(c.portalBound, latestBound);
      expect(
        c.syncStatus,
        latestBound ? TimetableSyncStatus.success : TimetableSyncStatus.idle,
      );
    });
  }

  test('AS07: unbound cold start / manual / autoSync 发送 0 请求且无失败态', () async {
    TimetableController.bindingCheck = () async => false;
    expect(await c.manualSync(), isFalse);
    expect(await c.onAppStart(), isFalse);
    await c.autoSyncIfNeeded();
    expect(fetches, 0);
    expect(c.syncStatus, TimetableSyncStatus.idle);
    expect(c.syncFailure, TimetableSyncFailure.none);
    expect(c.statusMessage, isNull);
  });

  test('AS08/AS21: 在途手动或自动同步期间，重复触发均被忽略且不排队，回前台<6h不阻塞', () async {
    await c.ensureStarted();
    gate = Completer<void>();
    final first = c.manualSync();
    await pumpEventQueue();
    expect(fetches, 1);
    expect(await c.onLoginSucceeded(), isFalse);
    expect(await c.manualSync(), isFalse);
    expect(await c.onAppResumed(), isTrue);
    expect(fetches, 1);
    gate!.complete();
    expect(await first, isTrue);
    expect(fetches, 1);

    // 自动同步在途时手动点击同步同样被忽略
    advance(const Duration(minutes: 91));
    gate = Completer<void>();
    final auto = c.onAppStart();
    await pumpEventQueue();
    expect(fetches, 2);
    expect(await c.manualSync(), isFalse);
    gate!.complete();
    expect(await auto, isTrue);
    expect(fetches, 2, reason: 'not queued, not repeated');
    expect(c.jwxtCourses.map((e) => e.id), ['j1']);
  });

  test('AS05: onAppResumed <6h 仅本地不拉网不重复读盘；显式 refreshLocal 可读回磁盘', () async {
    await c.onAppStart();
    expect(fetches, 1);
    for (final step in [
      const Duration(minutes: 30),
      const Duration(seconds: 1),
      const Duration(hours: 5, minutes: 28, seconds: 59),
    ]) {
      advance(step);
      expect(await c.onAppResumed(), isTrue);
      await pumpEventQueue();
      expect(fetches, 1, reason: '距上次成功不足 6 小时，回前台不拉网');
    }

    await TimetableStore.saveSnapshot(
      TimetableSnapshot(
        courses: [_course('j2')],
        periods: TimetableController.defaultPeriods(),
        settings: const TimetableSettings(termCode: '2026-2027-1'),
        syncedAt: now,
      ),
    );
    expect(await c.onAppResumed(), isTrue);
    expect(fetches, 1);
    expect(c.jwxtCourses.map((e) => e.id), ['j1']);

    expect(await c.refreshLocal(), isTrue);
    expect(c.jwxtCourses.map((e) => e.id), ['j2']);
  });

  test('onAppResumed >=6h（或从未同步）触发非阻塞后台静默同步', () async {
    await c.ensureStarted();
    expect(c.lastSyncSuccessAt, isNull);
    final firstDone = c.syncOutcomes.first;
    expect(await c.onAppResumed(), isTrue);
    await pumpEventQueue();
    expect(fetches, 1, reason: '从未成功同步 → 回前台补远程');
    expect((await firstDone).automatic, isTrue);
    expect(c.lastSyncSuccessAt, isNotNull);

    advance(TimetableController.resumeRemoteSyncInterval);
    gate = Completer<void>();
    final completed = c.syncOutcomes.first;
    expect(await c.onAppResumed(), isTrue);
    expect(fetches, 1, reason: '远程尚未越过 gate，onAppResumed 已返回');
    await pumpEventQueue();
    expect(fetches, 2, reason: '后台已发起');
    expect(c.syncStatus, TimetableSyncStatus.syncing);
    gate!.complete();
    expect((await completed).automatic, isTrue);
    expect(c.syncStatus, TimetableSyncStatus.success);
  });

  test(
    'AS13: unbind then re-login 1 min after success syncs at once',
    () async {
      await c.onAppStart();
      expect(fetches, 1);
      advance(const Duration(minutes: 1));
      TimetableController.bindingCheck = () async => false;
      await c.handleLogout();
      TimetableController.bindingCheck = () async => true;
      expect(await c.onLoginSucceeded(), isTrue);
      expect(fetches, 2);
      expect(c.syncStatus, TimetableSyncStatus.success);
    },
  );

  test('AS02/AS04/AS27: 首次绑定或冷启动同步一次，重复进页面/首页卡片只刷绑定不重复拉网', () async {
    TimetableController.bindingCheck = () async => false;
    expect(await c.onAppStart(), isFalse);
    expect(fetches, 0);

    // 绑定门户 / 导入通行密钥成功后，portal_status_page 都只调 onLoginSucceeded。
    TimetableController.bindingCheck = () async => true;
    expect(await c.onLoginSucceeded(), isTrue);
    expect(fetches, 1);

    // 返回课表页（autoSyncIfNeeded）、设置页 / 首页卡片（refreshPortalBound）。
    for (var i = 0; i < 3; i++) {
      expect(await c.refreshPortalBound(), isTrue);
      await c.autoSyncIfNeeded();
    }
    expect(c.portalBound, isTrue);
    expect(fetches, 1);
  });

  test(
    'AS16: resume does not retry remotely after a timeout failure',
    () async {
      await c.onAppStart();
      advance(const Duration(minutes: 91));
      failWith = TimeoutException('t');
      expect(await c.onAppStart(), isTrue);
      expect(c.syncStatus, TimetableSyncStatus.failure);
      advance(const Duration(minutes: 5));
      failWith = null;
      expect(await c.onAppResumed(), isTrue);
      expect(fetches, 2, reason: '距上次成功不足 6 小时，回前台不补远程');
      expect(c.syncStatus, TimetableSyncStatus.failure);
    },
  );

  test('AS18: after the one offline retry, a later outage is not retried until another offline failure', () async {
    await c.onAppStart();
    advance(const Duration(minutes: 91));
    failWith = const SocketException('offline');
    await c.onAppStart();
    failWith = null;
    expect(await c.onNetworkRestored(), isTrue); // AS17 重试（成功）
    expect(fetches, 3);
    // 再断网 → 恢复：不再重试。
    expect(await c.onNetworkRestored(), isFalse);
    expect(fetches, 3);
    // 再有一次自动同步因无网失败后，才重新允许一次。
    advance(const Duration(minutes: 91));
    failWith = const SocketException('offline');
    await c.onAppStart();
    expect(fetches, 4);
    failWith = null;
    expect(await c.onNetworkRestored(), isTrue);
    expect(fetches, 5);
  });

  test('AS19: timeout / 500 失败后恢复网络不触发补同步', () async {
    for (final err in <Object>[
      TimeoutException('t'),
      const JwxtHttpError('kb', 500),
    ]) {
      failWith = null;
      await c.onAppStart();
      advance(const Duration(minutes: 91));
      failWith = err;
      await c.onAppStart();
      expect(c.syncStatus, TimetableSyncStatus.failure);
      final before = fetches;
      failWith = null;
      expect(await c.onNetworkRestored(), isFalse, reason: '$err');
      expect(fetches, before);
      advance(const Duration(minutes: 91));
    }
  });

  group('AS03-ctl 自动同步失败标记与 portalSessionExpired', () {
    const expired = JwxtSessionExpiredError('重新登录后教务仍要求登录');
    File stateFile() => File('${tmp.path}/sync_state.json');

    test('AS03-ctl 自动失败置位（离线/超时/500/恢复重试/autoSync），手动失败不置位，成功或解绑清除', () async {
      final outcomes = <TimetableSyncOutcome>[];
      final sub = c.syncOutcomes.listen(outcomes.add);
      addTearDown(sub.cancel);

      failWith = const SocketException('offline');
      expect(await c.onAppStart(), isTrue);
      await pumpEventQueue();
      expect(c.lastAutoSyncFailed, isTrue);
      expect(c.syncFailure, TimetableSyncFailure.network);
      expect(c.lastSyncOutcome?.success, isFalse);
      expect(c.lastSyncOutcome?.automatic, isTrue);
      expect(c.lastSyncOutcome?.failure, TimetableSyncFailure.network);
      expect(c.lastSyncOutcome?.offline, isTrue);
      expect(outcomes.single.offline, isTrue);

      // 恢复网络后的自动重试失败也计为 automatic 且非 offline
      failWith = TimeoutException('t');
      expect(await c.onNetworkRestored(), isTrue);
      expect(c.lastAutoSyncFailed, isTrue);
      expect(c.lastSyncOutcome?.automatic, isTrue);
      expect(c.lastSyncOutcome?.offline, isFalse);

      // 手动成功清除标记
      failWith = null;
      expect(await c.manualSync(), isTrue);
      await pumpEventQueue();
      expect(c.lastAutoSyncFailed, isFalse);
      expect(c.lastSyncOutcome?.success, isTrue);
      expect(c.lastSyncOutcome?.automatic, isFalse);
      expect(c.lastSyncOutcome?.failure, TimetableSyncFailure.none);

      // 手动失败不算自动失败
      failWith = TimeoutException('t');
      expect(await c.manualSync(), isTrue);
      expect(c.syncStatus, TimetableSyncStatus.failure);
      expect(c.lastAutoSyncFailed, isFalse);
      expect(c.lastSyncOutcome?.automatic, isFalse);

      // 打开页面 autoSyncIfNeeded 各类失败置位，登录成功清除
      for (final (err, expectedFailure, expectedOffline) in [
        (TimeoutException('t'), TimetableSyncFailure.network, false),
        (const JwxtHttpError('kb', 500), TimetableSyncFailure.server, false),
        (const SocketException('offline'), TimetableSyncFailure.network, true),
      ]) {
        c.debugReset();
        await c.ensureStarted();
        c.debugSetSnapshot(const TimetableSnapshot());
        advance(const Duration(minutes: 91));
        failWith = err;
        await c.autoSyncIfNeeded();
        expect(c.lastAutoSyncFailed, isTrue, reason: '$err');
        expect(c.syncFailure, expectedFailure, reason: '$err');
        expect(c.lastSyncOutcome?.automatic, isTrue, reason: '$err');
        expect(c.lastSyncOutcome?.offline, expectedOffline, reason: '$err');
        failWith = null;
        expect(await c.onLoginSucceeded(), isTrue);
        expect(c.lastAutoSyncFailed, isFalse);
      }

      // 解绑清除标记和 lastSyncOutcome
      advance(const Duration(minutes: 91));
      failWith = const SocketException('offline');
      await c.onAppStart();
      expect(c.lastAutoSyncFailed, isTrue);
      await c.handleLogout();
      expect(c.lastAutoSyncFailed, isFalse);
      expect(c.lastSyncOutcome, isNull);
    });

    test('AS03-ctl portalSessionExpired 置位、跨重启持久与登录/成功/解绑清除', () async {
      await c.onAppStart();
      final lastOk = c.lastSyncSuccessAt;
      advance(const Duration(minutes: 91));
      failWith = expired;
      var notified = 0;
      void listener() => notified++;
      c.addListener(listener);
      expect(await c.onAppStart(), isTrue);
      c.removeListener(listener);
      expect(notified, greaterThan(0));
      expect(c.syncFailure, TimetableSyncFailure.sessionExpired);
      expect(c.lastSyncOutcome?.failure, TimetableSyncFailure.sessionExpired);
      expect(c.lastAutoSyncFailed, isTrue);
      expect(c.portalSessionExpired, isTrue);

      await restart();
      expect(c.portalSessionExpired, isTrue);
      expect(
        c.lastSyncSuccessAt,
        lastOk,
        reason: 'merge write keeps lastSuccessAt',
      );
      expect(c.lastAutoSyncFailed, isFalse, reason: 'not persisted');

      // 登录后若同步仍报过期则再次置位；若同步因其他错误失败则保持已清除
      expect(await c.onLoginSucceeded(), isTrue);
      expect(c.portalSessionExpired, isTrue);
      failWith = TimeoutException('t');
      expect(await c.onLoginSucceeded(), isTrue);
      expect(c.portalSessionExpired, isFalse);
      await restart();
      expect(c.portalSessionExpired, isFalse);

      // 手动同步 401 也置位；成功后清除并持久化
      failWith = const JwxtHttpError('kb', 401);
      await c.manualSync();
      expect(c.syncFailure, TimetableSyncFailure.sessionExpired);
      expect(c.portalSessionExpired, isTrue);
      expect(c.lastAutoSyncFailed, isFalse);
      failWith = null;
      expect(await c.manualSync(), isTrue);
      expect(c.portalSessionExpired, isFalse);
      await restart();
      expect(c.portalSessionExpired, isFalse);

      // 解绑清除并持久化
      failWith = expired;
      await c.manualSync();
      expect(c.portalSessionExpired, isTrue);
      await c.handleLogout();
      expect(c.portalSessionExpired, isFalse);
      await restart();
      expect(c.portalSessionExpired, isFalse);
    });

    test('AS03-ctl sync_state 缺字段/损坏回落 false，非会话过期错误不置位', () async {
      stateFile().writeAsStringSync('{"schemaVersion":1,"lastSuccessAt":null}');
      await restart();
      expect(c.portalSessionExpired, isFalse);
      stateFile().writeAsStringSync('{"portalSessionExpired": tru');
      await restart();
      expect(c.portalSessionExpired, isFalse);
      expect(File('${stateFile().path}.corrupt').existsSync(), isTrue);

      for (final e in <Object>[
        const SocketException('offline'),
        TimeoutException('t'),
        const JwxtHttpError('kb', 500),
        StateError('x'),
      ]) {
        failWith = e;
        await c.manualSync();
        expect(c.portalSessionExpired, isFalse, reason: '$e');
      }
    });
  });

  group('同步拆分：refreshLocal vs 远程同步', () {
    test(
      'refreshLocal 只重读本地磁盘、抛错返回 false；manualSync / syncFromRemote 写 diff',
      () async {
        TimetableChangeLogStore.debugMemory = [];
        addTearDown(() {
          TimetableChangeLogStore.debugMemory = null;
          TimetableController.debugBeforeRefreshLocal = null;
        });
        await TimetableStore.saveSnapshot(
          TimetableSnapshot(
            courses: [_course('j1')],
            periods: TimetableController.defaultPeriods(),
            settings: const TimetableSettings(termCode: '2026-2027-1'),
            syncedAt: DateTime(2026, 9, 7, 8),
          ),
        );
        await c.ensureStarted();
        expect(c.jwxtCourses.map((e) => e.id), ['j1']);

        var notified = 0;
        void listener() => notified++;
        c.addListener(listener);
        expect(await c.refreshLocal(), isTrue);
        c.removeListener(listener);
        expect(fetches, 0);
        expect(notified, greaterThan(0));
        expect(c.lastSyncDiff, isNull);

        TimetableController.debugBeforeRefreshLocal = () async {
          throw StateError('disk boom');
        };
        expect(await c.refreshLocal(), isFalse);
        TimetableController.debugBeforeRefreshLocal = null;
        expect(await c.refreshLocal(), isTrue);

        TimetableController.fetchSnapshot = (term, {baseSettings}) async {
          fetches++;
          return TimetableSnapshot(
            courses: [
              Course(
                id: 'j1',
                name: '课程 j1',
                code: 'Cj1',
                classId: '1',
                source: CourseSource.jwxt,
                slots: [
                  CourseSlot(
                    day: 1,
                    startNode: 1,
                    endNode: 2,
                    weeks: '1111111111111111',
                    location: fetches == 2 ? '测试楼 B202' : '测试楼 A101',
                  ),
                ],
              ),
            ],
            periods: TimetableController.defaultPeriods(),
            settings: const TimetableSettings(termCode: '2026-2027-1'),
          );
        };
        expect(await c.manualSync(), isTrue);
        expect(c.lastSyncDiff, isNotNull);
        await c.syncFromRemote();
        expect(c.jwxtCourses.single.slots.single.location, '测试楼 B202');
        expect(c.lastSyncDiff!.allWritten, isNotEmpty);
        expect(c.lastSyncDiff!.hasNewChanges, isTrue);
        await c.syncFromJwxt();
        expect(fetches, 3);
      },
    );
  });

  group('同步状态、浏览周与诊断降级', () {
    test('syncStatus 状态流转与成功/失败结构化日志（trace/span 一致）', () async {
      TimetableController.clock = () => DateTime(2026, 10, 11);
      await c.ensureStarted();
      final records = <Map<String, Object?>>[];
      AppLog.recordListenerForTesting = records.add;
      addTearDown(() => AppLog.recordListenerForTesting = null);

      expect(c.syncStatus, TimetableSyncStatus.idle);
      expect(c.statusIsSuccess, isFalse);
      final seen = <TimetableSyncStatus>[];
      void l() => seen.add(c.syncStatus);
      c.addListener(l);
      await c.syncFromJwxt();
      c.removeListener(l);

      expect(seen.first, TimetableSyncStatus.syncing);
      expect(c.syncStatus, TimetableSyncStatus.success);
      expect(c.statusIsSuccess, isTrue);
      final completed = records.singleWhere(
        (r) => r['event'] == 'sync.completed',
      );
      final started = records.singleWhere((r) => r['event'] == 'sync.started');
      expect(completed['level'], 'INFO');
      expect((completed['attrs'] as Map)['course_count'], 1);
      expect(completed['trace_id'], started['trace_id']);

      records.clear();
      failWith = Exception('boom');
      await c.syncFromJwxt();
      expect(c.syncStatus, TimetableSyncStatus.failure);
      final failed = records.singleWhere((r) => r['event'] == 'sync.failed');
      expect(failed['level'], 'WARNING');
      expect((failed['attrs'] as Map)['duration_ms'], isNonNegative);
    });

    test('可选元数据失败时课表仍成功，诊断明确为 degraded 且 SilentRefresh 计部分失败', () async {
      TimetableController.clock = () => DateTime(2026, 10, 11);
      await c.ensureStarted();
      final records = <Map<String, Object?>>[];
      AppLog.recordListenerForTesting = records.add;
      addTearDown(() {
        AppLog.recordListenerForTesting = null;
        TimetableApi.debugPost = null;
      });
      TimetableController.fetchSnapshot = (term, {baseSettings}) =>
          TimetableApi.fetchTermSnapshot(term, baseSettings: baseSettings);
      final started = Completer<void>();
      final response = Completer<void>();
      TimetableApi.debugPost = (uri, form) async {
        if (uri.pathSegments.last == 'cxxszhxqkb.do') {
          started.complete();
          await response.future;
          return {
            'datas': {
              'cxxszhxqkb': {'rows': <Object?>[]},
            },
          };
        }
        if (uri.pathSegments.last == 'xswpkc.do') {
          return {
            'datas': {
              'xswpkc': {'rows': <Object?>[]},
            },
          };
        }
        throw TimeoutException('合成可选接口超时');
      };
      final automatic = c.syncFromJwxt();
      await started.future;
      final batch = SilentRefresh.runAll('test.timetable_batch', {
        'timetable': c.syncFromJwxt,
      });
      response.complete();
      await automatic;
      expect(await batch, isTrue);
      expect(c.syncStatus, TimetableSyncStatus.success);
      final completed = records.singleWhere(
        (r) => r['event'] == 'sync.completed',
      );
      expect(completed['level'], 'WARNING');
      expect((completed['attrs'] as Map)['outcome'], 'degraded');
      final optional = records.firstWhere(
        (r) => r['event'] == 'optional.request_failed',
      );
      expect((optional['attrs'] as Map)['endpoint'], startsWith('timetable.'));
      expect((optional['attrs'] as Map)['error_type'], 'TimeoutException');
      final batchCompleted = records.singleWhere(
        (r) => r['event'] == 'refresh.batch_completed',
      );
      expect((batchCompleted['attrs'] as Map)['success_count'], 0);
      expect((batchCompleted['attrs'] as Map)['partial_failure_count'], 1);
    });

    test('builtin 回填开学日、weekPending 与浏览周固定钳制 1..20', () async {
      TimetableController.clock = () => DateTime(2026, 10, 11);
      await c.ensureStarted();
      expect(c.settings.termStartDate, DateTime(2026, 8, 31));
      expect(c.weekPending, isFalse);
      expect(c.currentWeek, 6);

      c.debugSetSnapshot(
        const TimetableSnapshot(
          settings: TimetableSettings(termCode: '2030-2031-1'),
        ),
      );
      expect(c.weekPending, isTrue);
      expect(c.currentWeek, 1);

      c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [
            _course('b').copyWith(
              slots: [
                CourseSlot(
                  day: 1,
                  startNode: 1,
                  endNode: 2,
                  weeks: '${'0' * 23}1',
                ),
              ],
            ),
          ],
          settings: TimetableSettings(
            termCode: '2026-2027-1',
            termStartDate: DateTime(2026, 8, 31),
          ),
        ),
      );
      expect(c.totalWeeks, 20);
      c.setViewingWeek(30);
      expect(c.viewingWeek, 20);
      c.setViewingWeek(0);
      expect(c.viewingWeek, 1);
      TimetableController.clock = () => DateTime(2027, 6, 1);
      expect(c.currentWeek, greaterThan(20));
      c.setViewingWeek(c.currentWeek);
      expect(c.viewingWeek, 20);
    });

    test('同步失败不改 course_colors.json，成功/失败与请求期间手动翻周均保留 viewingWeek', () async {
      final termStart = DateTime(2026, 8, 31);
      final monday2 = DateTime(2026, 9, 7);
      TimetableController.clock = () => monday2;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          TimetableSnapshot(
            courses: [_course('j1')],
            periods: TimetableController.defaultPeriods(),
            settings: TimetableSettings(
              termCode: '2026-2027-1',
              termStartDate: termStart,
              termStartFromJwxt: true,
            ),
          );
      await c.ensureStarted();
      await c.syncFromJwxt();
      final cf = File('${tmp.path}/${TimetableStore.courseColorsFile}');
      final before = cf.readAsStringSync();
      failWith = const JwxtHttpError('kb', 500);
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          throw failWith!;
      c.setViewingWeek(9);
      await c.syncFromJwxt();
      expect(cf.readAsStringSync(), before);
      expect(c.viewingWeek, 9);

      // 请求期间从第 2 周翻到第 9 周，完成后停留在第 9 周
      failWith = null;
      final reqGate = Completer<void>();
      TimetableController.fetchSnapshot = (term, {baseSettings}) async {
        await reqGate.future;
        return TimetableSnapshot(
          courses: [_course('j1')],
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termCode: '2026-2027-1',
            termStartDate: termStart,
            termStartFromJwxt: true,
          ),
        );
      };
      c.setViewingWeek(2);
      final outcomes = <TimetableSyncOutcome>[];
      final sub = c.syncOutcomes.listen(outcomes.add);
      addTearDown(sub.cancel);
      final future = c.manualSync();
      await pumpEventQueue();
      c.setViewingWeek(9);
      reqGate.complete();
      expect(await future, isTrue);
      await pumpEventQueue();
      expect(c.viewingWeek, 9);
      expect(outcomes.single.success, isTrue);

      // jumpToCurrentWeek 只触发 viewingWeekListenable
      var weekCalls = 0;
      var ctlCalls = 0;
      void wL() => weekCalls++;
      void cL() => ctlCalls++;
      c.viewingWeekListenable.addListener(wL);
      c.addListener(cL);
      c.jumpToCurrentWeek();
      c.viewingWeekListenable.removeListener(wL);
      c.removeListener(cL);
      expect(c.viewingWeek, 2);
      expect(weekCalls, 1);
      expect(ctlCalls, 0);
    });
  });

  group('TimetableSyncDiff 变更检测与指纹去重', () {
    CourseSlot slot({
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

    Course jwxtCourse({
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
      slots: slots ?? [slot()],
    );

    setUp(() {
      TimetableChangeLogStore.debugMemory = [];
    });

    tearDown(() {
      TimetableChangeLogStore.debugMemory = null;
    });

    test('slotKey 六元组、教师逗号与顺序归一、地点 trim 与 ISTK null→0', () {
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
      expect(
        TimetableSyncDiff.normalizeTeachers('许川川,杨宇涵'),
        TimetableSyncDiff.normalizeTeachers('杨宇涵，许川川'),
      );
      expect(
        TimetableSyncDiff.normalizeTeachers(' 许川川 , 杨宇涵 '),
        TimetableSyncDiff.normalizeTeachers('杨宇涵,许川川'),
      );
      expect(TimetableSyncDiff.normalizeLocation(' 滨江BS413 '), '滨江BS413');
      expect(TimetableSyncDiff.normalizeIstk(null), 0);
    });

    group('compute', () {
      test('忽略首次空表、手动课、未变未排课、rows 顺序、教师顺序与空白差异', () {
        expect(
          TimetableSyncDiff.compute(
            oldCourses: const [],
            newCourses: [jwxtCourse()],
          ),
          isEmpty,
        );

        final a = jwxtCourse(
          code: '1',
          classId: '1',
          name: 'A',
          slots: [slot(day: 1)],
        );
        final b = jwxtCourse(
          code: '2',
          classId: '1',
          name: 'B',
          slots: [slot(day: 2)],
        );
        expect(
          TimetableSyncDiff.compute(oldCourses: [a, b], newCourses: [b, a]),
          isEmpty,
        );

        expect(
          TimetableSyncDiff.compute(
            oldCourses: [
              jwxtCourse(
                slots: [slot(teacher: '许川川,杨宇涵', location: '滨江BS413')],
              ),
            ],
            newCourses: [
              jwxtCourse(
                slots: [slot(teacher: ' 杨宇涵 ， 许川川 ', location: ' 滨江BS413 ')],
              ),
            ],
          ),
          isEmpty,
        );

        final manual = Course(
          id: 'm1',
          name: '手动',
          source: CourseSource.manual,
          slots: [slot(location: 'A')],
        );
        final other = jwxtCourse(
          slots: [
            const CourseSlot(day: 0, startNode: 0, endNode: 0, weeks: ''),
          ],
        );
        final diffs = TimetableSyncDiff.compute(
          oldCourses: [manual, other, jwxtCourse()],
          newCourses: [
            manual,
            other,
            jwxtCourse(slots: [slot(location: '滨江BS401')]),
          ],
        );
        expect(diffs, hasLength(1));
        expect(diffs.single.type, TimetableChangeType.locationChanged);
      });

      test('地点、教师、ISTK 变更与拆周段影响范围', () {
        final loc = TimetableSyncDiff.compute(
          oldCourses: [jwxtCourse()],
          newCourses: [
            jwxtCourse(slots: [slot(location: '滨江BS401')]),
          ],
        ).single;
        expect(loc.type, TimetableChangeType.locationChanged);
        expect(loc.before!['JASMC'], '滨江BS413');
        expect(loc.after!['JASMC'], '滨江BS401');
        expect(loc.notified, isFalse);
        expect(loc.fingerprint, startsWith('sha256:'));
        expect(
          TimetableChangeFormat.scopeOf(loc),
          '影响范围：全部周次（第 1–16 周） · 周一 5–6节',
        );

        final split = TimetableSyncDiff.compute(
          oldCourses: [
            jwxtCourse(
              slots: [
                slot(weeks: '00001'),
                slot(day: 3),
              ],
            ),
          ],
          newCourses: [
            jwxtCourse(
              slots: [
                slot(weeks: '00001', location: '新教室'),
                slot(day: 3),
              ],
            ),
          ],
        ).single;
        expect(TimetableChangeFormat.scopeOf(split), '影响范围：第 5 周 · 周一 5–6节');

        final teacher = TimetableSyncDiff.compute(
          oldCourses: [
            jwxtCourse(slots: [slot(teacher: '许川川,杨宇涵')]),
          ],
          newCourses: [
            jwxtCourse(slots: [slot(teacher: '许川川')]),
          ],
        ).single;
        expect(teacher.type, TimetableChangeType.teacherChanged);
        expect(
          teacher.before!['SKJS'],
          TimetableSyncDiff.normalizeTeachers('许川川,杨宇涵'),
        );
        expect(teacher.after!['SKJS'], '许川川');

        final istk = TimetableSyncDiff.compute(
          oldCourses: [jwxtCourse()],
          newCourses: [
            jwxtCourse(slots: [slot(istk: 1)]),
          ],
        ).single;
        expect(istk.type, TimetableChangeType.retakeFlagChanged);
        expect(istk.before!['ISTK'], 0);
        expect(istk.after!['ISTK'], 1);
      });

      test('周次、星期变化与周次+地点同时变更均为单条时间变动且范围正确', () {
        const oldWeeks = '111111111111111100000000';
        const newWeeks = '101010101010101000000000';
        final weeksDiff = TimetableSyncDiff.compute(
          oldCourses: [
            jwxtCourse(slots: [slot(weeks: oldWeeks)]),
          ],
          newCourses: [
            jwxtCourse(slots: [slot(weeks: newWeeks)]),
          ],
        ).single;
        expect(weeksDiff.type, TimetableChangeType.timeChanged);
        expect(weeksDiff.type.labelZh, '时间变动');
        expect(weeksDiff.before!['SKZC'], oldWeeks);
        expect(weeksDiff.after!['SKZC'], newWeeks);
        expect(weeksDiff.slotKey, contains(newWeeks));
        expect(
          TimetableChangeFormat.scopeOf(weeksDiff),
          '影响范围：第 2–16 周（双） · 周一 5–6节',
        );
        expect(
          TimetableChangeFormat.detailOf(weeksDiff),
          '第 1–16 周 · 周一 5–6节 → 第 1–15 周（单） · 周一 5–6节',
        );

        final old4 = [
          jwxtCourse(slots: [slot(weeks: '1111')]),
        ];
        final neu3 = [
          jwxtCourse(slots: [slot(weeks: '1110')]),
        ];
        final onlyWeeks = TimetableSyncDiff.compute(
          oldCourses: old4,
          newCourses: neu3,
        ).single;
        expect(
          TimetableChangeFormat.scopeOf(onlyWeeks),
          '影响范围：第 4 周 · 周一 5–6节',
        );
        expect(
          TimetableChangeFormat.scopeOf(
            TimetableSyncDiff.compute(
              oldCourses: neu3,
              newCourses: old4,
            ).single,
          ),
          TimetableChangeFormat.scopeOf(onlyWeeks),
        );
        final withLocation = TimetableSyncDiff.compute(
          oldCourses: old4,
          newCourses: [
            jwxtCourse(
              slots: [slot(weeks: '1110', location: '新教室')],
            ),
          ],
        ).single;
        expect(
          TimetableChangeFormat.scopeOf(withLocation),
          '影响范围：全部周次（第 1–4 周） · 周一 5–6节',
        );

        final dayAndWeeks = TimetableSyncDiff.compute(
          oldCourses: [
            jwxtCourse(
              slots: [slot(day: 1, weeks: '111100000000000000000000')],
            ),
          ],
          newCourses: [
            jwxtCourse(
              slots: [slot(day: 3, weeks: '101010100000000000000000')],
            ),
          ],
        ).single;
        expect(dayAndWeeks.type, TimetableChangeType.timeChanged);
        expect(dayAndWeeks.before!['SKXQ'], 1);
        expect(dayAndWeeks.after!['SKXQ'], 3);
        expect(
          TimetableChangeFormat.scopeOf(dayAndWeeks),
          '影响范围：全部周次（第 1–5、7 周） · 周一 5–6节 → 周三 5–6节',
        );
        expect(
          TimetableChangeFormat.detailOf(dayAndWeeks),
          '第 1–4 周 · 周一 5–6节 → 第 1–7 周（单） · 周三 5–6节',
        );
      });

      test('纯新增/纯删除与离散周段展示格式', () {
        final old = [jwxtCourse()];
        final neu = [
          jwxtCourse(),
          jwxtCourse(
            code: '999',
            classId: '01',
            name: '新课',
            slots: [slot(day: 2)],
          ),
        ];
        final added = TimetableSyncDiff.compute(
          oldCourses: old,
          newCourses: neu,
        );
        expect(added.single.type, TimetableChangeType.added);
        expect(added.single.before, isNull);

        final removed = TimetableSyncDiff.compute(
          oldCourses: neu,
          newCourses: old,
        );
        expect(removed.single.type, TimetableChangeType.removed);
        expect(removed.single.after, isNull);
        expect(
          TimetableChangeFormat.scopeOf(added.single),
          '影响范围：全部周次（第 1–16 周） · 周二 5–6节',
        );
        expect(
          TimetableChangeFormat.scopeOf(removed.single),
          TimetableChangeFormat.scopeOf(added.single),
        );

        final discrete = TimetableSyncDiff.compute(
          oldCourses: old,
          newCourses: [
            jwxtCourse(),
            jwxtCourse(
              code: 'new',
              slots: [slot(weeks: '11001100010011')],
            ),
          ],
        ).single;
        expect(
          TimetableChangeFormat.scopeOf(discrete),
          '影响范围：全部周次（第 1–2、5–6、10、13–14 周） · 周一 5–6节',
        );
      });
    });

    group('fingerprint / 通知去重', () {
      test('影响范围上下文不参与指纹，不会让已通知变动重复提醒', () {
        TimetableChangeRecord change({bool withOtherSlot = false}) =>
            TimetableSyncDiff.compute(
              oldCourses: [
                jwxtCourse(
                  slots: [
                    slot(weeks: '1111'),
                    if (withOtherSlot) slot(day: 3),
                  ],
                ),
              ],
              newCourses: [
                jwxtCourse(
                  slots: [
                    slot(weeks: '1111', location: '新教室'),
                    if (withOtherSlot) slot(day: 3),
                  ],
                ),
              ],
            ).single;
        final full = change();
        final partial = change(withOtherSlot: true);
        expect(partial.fingerprint, full.fingerprint);
        expect(TimetableChangeFormat.scopeOf(full), contains('全部周次'));
        expect(
          TimetableChangeFormat.scopeOf(partial),
          '影响范围：第 1–4 周 · 周一 5–6节',
        );
      });

      test('相同实质变动同 fingerprint；再变地点则新 fingerprint', () async {
        final old = [jwxtCourse()];
        final mid = [
          jwxtCourse(slots: [slot(location: '滨江BS401')]),
        ];
        final end = [
          jwxtCourse(slots: [slot(location: '揽江楼N307')]),
        ];

        final first = TimetableSyncDiff.compute(
          oldCourses: old,
          newCourses: mid,
        );
        final again = TimetableSyncDiff.compute(
          oldCourses: old,
          newCourses: mid,
        );
        expect(first.single.fingerprint, again.single.fingerprint);

        final r1 = await TimetableChangeLogStore.upsertCandidates(first);
        expect(r1.toNotify, hasLength(1));
        await TimetableChangeLogStore.markNotified([
          r1.toNotify.single.fingerprint,
        ]);

        final r2 = await TimetableChangeLogStore.upsertCandidates(again);
        expect(r2.toNotify, isEmpty);
        expect(r2.allWritten.single.notified, isTrue);

        final next = TimetableSyncDiff.compute(
          oldCourses: mid,
          newCourses: end,
        );
        expect(next.single.fingerprint, isNot(first.single.fingerprint));
        final r3 = await TimetableChangeLogStore.upsertCandidates(next);
        expect(r3.toNotify, hasLength(1));
      });

      test('applyAfterFetch 写入内存后端', () async {
        final old = [jwxtCourse()];
        final neu = [
          jwxtCourse(slots: [slot(location: 'X')]),
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
        final old = [jwxtCourse()];
        final neu = [
          jwxtCourse(slots: [slot(location: 'X')]),
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
        expect(
          TimetableChangeFormat.scopeOf(legacy),
          '影响范围：第 1–16 周 · 周一 5–6节',
        );
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
        final base = jwxtCourse(slots: [slot(weeks: '1111')]);
        final addedSlot = TimetableSyncDiff.compute(
          oldCourses: [base],
          newCourses: [
            jwxtCourse(
              slots: [
                slot(weeks: '1111'),
                slot(day: 3, weeks: '1111'),
              ],
            ),
          ],
        );
        expect(addedSlot.single.type, TimetableChangeType.added);
        expect(addedSlot.single.after!['SKXQ'], 3);
        for (final s in [slot(end: 7, weeks: '1111'), slot(weeks: '11111')]) {
          final changes = TimetableSyncDiff.compute(
            oldCourses: [base],
            newCourses: [
              jwxtCourse(slots: [s]),
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
        final baseline = jwxtCourse();
        Course other(String id) => Course(
          id: id,
          name: id,
          source: CourseSource.jwxt,
          slots: const [],
        );
        final changes = TimetableSyncDiff.compute(
          oldCourses: [baseline],
          newCourses: [baseline, other('a'), other('a'), other('b')],
        );
        expect(changes, hasLength(2));
        expect(
          changes.every((r) => r.type == TimetableChangeType.added),
          isTrue,
        );
      });

      test('变动入库与已读确认并发时不会相互覆盖', () async {
        final first = TimetableSyncDiff.compute(
          oldCourses: [jwxtCourse()],
          newCourses: [
            jwxtCourse(slots: [slot(location: '新教室')]),
          ],
        ).single;
        final second = TimetableSyncDiff.compute(
          oldCourses: [
            jwxtCourse(slots: [slot(location: '新教室')]),
          ],
          newCourses: [
            jwxtCourse(slots: [slot(location: '另一教室')]),
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
      }) {
        final d = date ?? DateTime(2027, 1, 12);
        return ScheduleEvent(
          id: 'jwxt-exam:${ScheduleEvent.examKeyOf(code, d, start)}',
          kind: ScheduleKind.exam,
          source: ScheduleSource.jwxt,
          title: title,
          date: d,
          start: start,
          end: end,
          location: location,
          courseCode: code,
        );
      }

      test('未排课新增、删除、教师与周次文案变更均产生 diff 且格式正确', () {
        final base = jwxtCourse();
        final o1 = otherCourse();
        final added = TimetableSyncDiff.compute(
          oldCourses: [base],
          newCourses: [base, o1],
        );
        expect(added, hasLength(1));
        expect(added.single.type, TimetableChangeType.added);
        expect(
          TimetableChangeFormat.scopeOf(added.single),
          '影响范围：其他课程 · 2-17周',
        );
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
  });
}
