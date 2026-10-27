import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_lifecycle.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

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

  test(
    'AS22: restart within 10 min does not sync (interval persisted)',
    () async {
      await c.onAppStart();
      expect(fetches, 1);
      advance(const Duration(minutes: 5));
      await restart();
      expect(c.lastSyncSuccessAt, DateTime(2026, 9, 7, 8));
      expect(await c.onAppStart(), isFalse);
      expect(fetches, 1);
    },
  );

  test('AS23: restart after 10 min syncs again', () async {
    await c.onAppStart();
    advance(const Duration(minutes: 10));
    await restart();
    expect(await c.onAppStart(), isTrue);
    expect(fetches, 2);
  });

  test(
    'AS17 AS24: offline failure, network restored 1 min later → one retry',
    () async {
      await c.onAppStart(); // 成功，t0
      advance(const Duration(minutes: 11));
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
    advance(const Duration(minutes: 11));
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
      advance(const Duration(minutes: 11));
      failWith = entry.value;
      expect(await c.onAppStart(), isTrue);
      expect(c.syncStatus, TimetableSyncStatus.failure);
      expect(c.lastSyncSuccessAt, t0);
      await restart();
      expect(c.lastSyncSuccessAt, t0);
      // 仍按上次成功算，未被重置 → 再次启动照样同步。
      failWith = null;
      expect(await c.onAppStart(), isTrue);
      expect(fetches, 3);
      expect(c.lastSyncSuccessAt, now);
    });
  }

  test('first-install failure keeps no timestamp; next start syncs', () async {
    failWith = const JwxtHttpError('kb', 500);
    await c.onAppStart();
    expect(c.lastSyncSuccessAt, isNull);
    await restart();
    failWith = null;
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

  test('manual sync when unbound does nothing', () async {
    TimetableController.bindingCheck = () async => false;
    expect(await c.manualSync(), isFalse);
    expect(await c.onAppStart(), isFalse);
    expect(fetches, 0);
  });

  test('AS21: trigger during an in-flight sync is ignored', () async {
    await c.ensureStarted();
    gate = Completer<void>();
    final first = c.manualSync();
    await pumpEventQueue();
    expect(fetches, 1);
    expect(await c.onLoginSucceeded(), isFalse);
    expect(await c.manualSync(), isFalse);
    // 距上次成功不足 6h：回前台只本地刷新，不参与远程同步的并发拦截。
    expect(await c.onAppResumed(), isTrue);
    expect(fetches, 1);
    gate!.complete();
    expect(await first, isTrue);
    expect(fetches, 1);
  });

  test('AS05 resume within 6h is local-only and never fetches', () async {
    await c.onAppStart();
    advance(const Duration(minutes: 30));
    expect(await c.onAppResumed(), isTrue);
    expect(fetches, 1);
    advance(const Duration(seconds: 1));
    expect(await c.onAppResumed(), isTrue);
    expect(fetches, 1, reason: '距上次成功不足 6 小时，回前台只重读本地');
  });

  test('autoSyncIfNeeded respects the 10-min throttle', () async {
    await c.onAppStart();
    c.debugSetSnapshot(const TimetableSnapshot()); // needsSync = true
    await c.autoSyncIfNeeded();
    expect(fetches, 1);
  });

  test('AS10: restart at 9m59s after success does not sync', () async {
    await c.onAppStart();
    expect(fetches, 1);
    advance(const Duration(minutes: 9, seconds: 59));
    await restart();
    expect(await c.onAppStart(), isFalse);
    expect(fetches, 1);
  });

  test('AS11: restart at 10m01s after success syncs', () async {
    await c.onAppStart();
    advance(const Duration(minutes: 10, seconds: 1));
    await restart();
    expect(await c.onAppStart(), isTrue);
    expect(fetches, 2);
  });

  test('AS14: resume at 29 min is local-only', () async {
    await c.onAppStart();
    advance(const Duration(minutes: 29));
    expect(await c.onAppResumed(), isTrue);
    expect(fetches, 1);
  });

  test('AS15: resume at 31 min is still local-only (<6h)', () async {
    await c.onAppStart();
    advance(const Duration(minutes: 31));
    expect(await c.onAppResumed(), isTrue);
    expect(fetches, 1);
  });

  test('resume at 5h59m is still local-only', () async {
    await c.onAppStart();
    advance(const Duration(hours: 5, minutes: 59));
    expect(await c.onAppResumed(), isTrue);
    await pumpEventQueue();
    expect(fetches, 1);
  });

  test('resume after 6h fires silent background remote sync', () async {
    await c.onAppStart();
    expect(fetches, 1);
    advance(TimetableController.resumeRemoteSyncInterval);
    final completed = c.syncOutcomes.first;
    expect(await c.onAppResumed(), isTrue);
    await pumpEventQueue();
    expect(fetches, 2, reason: '达到 6 小时静默补同步');
    expect((await completed).automatic, isTrue);
    expect(c.syncStatus, TimetableSyncStatus.success);
  });

  test('resume when never synced fires silent remote sync', () async {
    await c.ensureStarted();
    expect(c.lastSyncSuccessAt, isNull);
    final completed = c.syncOutcomes.first;
    expect(await c.onAppResumed(), isTrue);
    await pumpEventQueue();
    expect(fetches, 1, reason: '从未成功同步 → 回前台补远程');
    expect((await completed).automatic, isTrue);
    expect(c.lastSyncSuccessAt, isNotNull);
  });

  test('resume >6h remote does not block onAppResumed return', () async {
    await c.onAppStart();
    advance(const Duration(hours: 6, minutes: 1));
    gate = Completer<void>();
    final completed = c.syncOutcomes.first;
    final resumed = c.onAppResumed();
    expect(await resumed, isTrue);
    expect(fetches, 1, reason: '远程尚未越过 gate');
    await pumpEventQueue();
    expect(fetches, 2, reason: '后台已发起');
    expect(c.syncStatus, TimetableSyncStatus.syncing);
    gate!.complete();
    // 等真实完成事件；固定事件轮数无法保证磁盘 IO 已完成。
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

  test('AS02 AS27: login from unbound syncs once; reopening pages only refreshes binding', () async {
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
    'AS04: one launch, home card + entering the page 3 times → one sync',
    () async {
      expect(await c.onAppStart(), isTrue);
      for (var i = 0; i < 3; i++) {
        await c.refreshPortalBound(); // 首页卡片
        await c.autoSyncIfNeeded(); // 进课表页
      }
      expect(fetches, 1);
    },
  );

  test(
    'AS07: unbound cold start sends nothing and reports no failure',
    () async {
      TimetableController.bindingCheck = () async => false;
      expect(await c.onAppStart(), isFalse);
      await c.autoSyncIfNeeded();
      expect(fetches, 0);
      expect(c.syncStatus, TimetableSyncStatus.idle);
      expect(c.syncFailure, TimetableSyncFailure.none);
      expect(c.statusMessage, isNull);
    },
  );

  test('AS08: sync icon during an in-flight auto sync is ignored', () async {
    await c.ensureStarted();
    gate = Completer<void>();
    final auto = c.onAppStart();
    await pumpEventQueue();
    expect(fetches, 1);
    expect(await c.manualSync(), isFalse);
    gate!.complete();
    expect(await auto, isTrue);
    expect(fetches, 1, reason: 'not queued, not repeated');
    expect(c.jwxtCourses.map((e) => e.id), ['j1']);
  });

  test(
    'AS16: resume does not retry remotely after a timeout failure',
    () async {
      await c.onAppStart();
      advance(const Duration(minutes: 26));
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
    advance(const Duration(minutes: 11));
    failWith = const SocketException('offline');
    await c.onAppStart();
    failWith = null;
    expect(await c.onNetworkRestored(), isTrue); // AS17 重试（成功）
    expect(fetches, 3);
    // 再断网 → 恢复：不再重试。
    expect(await c.onNetworkRestored(), isFalse);
    expect(fetches, 3);
    // 再有一次自动同步因无网失败后，才重新允许一次。
    advance(const Duration(minutes: 11));
    failWith = const SocketException('offline');
    await c.onAppStart();
    expect(fetches, 4);
    failWith = null;
    expect(await c.onNetworkRestored(), isTrue);
    expect(fetches, 5);
  });

  for (final entry in <String, Object>{
    'timeout': TimeoutException('t'),
    '500': const JwxtHttpError('kb', 500),
  }.entries) {
    test(
      'AS19: ${entry.key} failure, then network restored → no retry',
      () async {
        await c.onAppStart();
        advance(const Duration(minutes: 11));
        failWith = entry.value;
        await c.onAppStart();
        expect(c.syncStatus, TimetableSyncStatus.failure);
        failWith = null;
        expect(await c.onNetworkRestored(), isFalse);
        expect(fetches, 2);
      },
    );
  }

  test('AS20: Wi-Fi ↔ mobile data switches 3 times → no sync', () async {
    await c.onAppStart();
    expect(fetches, 1);
    final detector = NetworkRestoreDetector()..seed(true);
    // wifi → 移动 → wifi … 都是「有网 → 有网」，不算恢复。
    for (var i = 0; i < 6; i++) {
      if (detector.update(true)) await c.onNetworkRestored();
    }
    expect(fetches, 1);
    // 即使连接监听多报了一次，controller 也不会补同步（上次成功）。
    expect(await c.onNetworkRestored(), isFalse);
    expect(fetches, 1);
  });

  group('AS03-ctl 自动同步失败标记与失败原因（controller）', () {
    test('AS03-ctl offline auto failure: lastAutoSyncFailed, network + offline; manual success clears', () async {
      final outcomes = <TimetableSyncOutcome>[];
      final sub = c.syncOutcomes.listen(outcomes.add);
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

      failWith = null;
      expect(await c.manualSync(), isTrue);
      await pumpEventQueue();
      expect(c.lastAutoSyncFailed, isFalse);
      expect(c.lastSyncOutcome?.success, isTrue);
      expect(c.lastSyncOutcome?.automatic, isFalse);
      expect(c.lastSyncOutcome?.failure, TimetableSyncFailure.none);
      expect(outcomes, hasLength(2));
      await sub.cancel();
    });

    for (final entry in <String, (Object, TimetableSyncFailure)>{
      'timeout': (TimeoutException('t'), TimetableSyncFailure.network),
      '500': (const JwxtHttpError('kb', 500), TimetableSyncFailure.server),
    }.entries) {
      test(
        'AS03-ctl ${entry.key} on page open: lastAutoSyncFailed, not offline',
        () async {
          await c.ensureStarted();
          c.debugSetSnapshot(const TimetableSnapshot()); // needsSync = true
          failWith = entry.value.$1;
          await c.autoSyncIfNeeded();
          expect(fetches, 1);
          expect(c.lastAutoSyncFailed, isTrue);
          expect(c.syncFailure, entry.value.$2);
          expect(c.lastSyncOutcome?.failure, entry.value.$2);
          expect(c.lastSyncOutcome?.offline, isFalse);
          // 下一次任意成功（这里是登录后同步）清除。
          failWith = null;
          expect(await c.onLoginSucceeded(), isTrue);
          expect(c.lastAutoSyncFailed, isFalse);
        },
      );
    }

    test('AS03-ctl a failed manual sync is not an auto failure', () async {
      failWith = TimeoutException('t');
      expect(await c.manualSync(), isTrue);
      expect(c.syncStatus, TimetableSyncStatus.failure);
      expect(c.lastAutoSyncFailed, isFalse);
      expect(c.lastSyncOutcome?.automatic, isFalse);
      expect(c.lastSyncOutcome?.failure, TimetableSyncFailure.network);
      expect(c.lastSyncOutcome?.offline, isFalse);
    });

    test(
      'AS03-ctl network-restored retry failure counts as automatic',
      () async {
        failWith = const SocketException('offline');
        await c.onAppStart();
        failWith = TimeoutException('t');
        expect(await c.onNetworkRestored(), isTrue);
        expect(c.lastAutoSyncFailed, isTrue);
        expect(c.lastSyncOutcome?.automatic, isTrue);
        expect(c.lastSyncOutcome?.offline, isFalse);
      },
    );

    test(
      'AS03-ctl page-open autoSyncIfNeeded failure counts as automatic',
      () async {
        await c.ensureStarted();
        failWith = const SocketException('offline');
        await c.autoSyncIfNeeded();
        expect(fetches, 1);
        expect(c.lastAutoSyncFailed, isTrue);
        expect(c.lastSyncOutcome?.automatic, isTrue);
      },
    );

    test('AS03-ctl unbind clears the flag and the last outcome', () async {
      failWith = const SocketException('offline');
      await c.onAppStart();
      expect(c.lastAutoSyncFailed, isTrue);
      await c.handleLogout();
      expect(c.lastAutoSyncFailed, isFalse);
      expect(c.lastSyncOutcome, isNull);
    });
  });

  group('AS03-ctl portalSessionExpired（持久化）', () {
    const expired = JwxtSessionExpiredError('重新登录后教务仍要求登录');
    File stateFile() => File('${tmp.path}/sync_state.json');

    test(
      'AS03-ctl auto sync session expiry sets it, persisted across restart',
      () async {
        await c.onAppStart(); // 成功，写 lastSuccessAt
        final lastOk = c.lastSyncSuccessAt;
        advance(const Duration(minutes: 11));
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
      },
    );

    test('AS03-ctl manual sync session expiry (401) also sets it', () async {
      failWith = const JwxtHttpError('kb', 401);
      await c.manualSync();
      expect(c.syncFailure, TimetableSyncFailure.sessionExpired);
      expect(c.portalSessionExpired, isTrue);
      expect(c.lastAutoSyncFailed, isFalse);
    });

    test('AS03-ctl cleared by login even if the following sync fails for another reason', () async {
      failWith = expired;
      await c.onAppStart();
      expect(c.portalSessionExpired, isTrue);
      failWith = TimeoutException('t');
      expect(await c.onLoginSucceeded(), isTrue);
      expect(c.portalSessionExpired, isFalse);
      await restart();
      expect(c.portalSessionExpired, isFalse);
    });

    test(
      'AS03-ctl login whose sync still reports expiry sets it again',
      () async {
        failWith = expired;
        await c.onAppStart();
        expect(await c.onLoginSucceeded(), isTrue);
        expect(c.portalSessionExpired, isTrue);
      },
    );

    test('AS03-ctl cleared by unbind (persisted)', () async {
      failWith = expired;
      await c.onAppStart();
      await c.handleLogout();
      expect(c.portalSessionExpired, isFalse);
      await restart();
      expect(c.portalSessionExpired, isFalse);
    });

    test('AS03-ctl cleared by any successful sync (persisted)', () async {
      failWith = expired;
      await c.onAppStart();
      failWith = null;
      expect(await c.manualSync(), isTrue);
      expect(c.portalSessionExpired, isFalse);
      await restart();
      expect(c.portalSessionExpired, isFalse);
    });

    test(
      'AS03-ctl missing field = false; corrupt sync_state backed up, false',
      () async {
        stateFile().writeAsStringSync(
          '{"schemaVersion":1,"lastSuccessAt":null}',
        );
        await restart();
        expect(c.portalSessionExpired, isFalse);
        stateFile().writeAsStringSync('{"portalSessionExpired": tru');
        await restart();
        expect(c.portalSessionExpired, isFalse);
        expect(File('${stateFile().path}.corrupt').existsSync(), isTrue);
      },
    );

    test('AS03-ctl other failures do not set it', () async {
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
}
