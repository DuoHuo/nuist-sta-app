import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/auth/passkey_bundle.dart';
import 'package:nuist_sta_app/core/auth/portal_exceptions.dart';
import 'package:nuist_sta_app/core/refresh/silent_refresh.dart';
import 'package:nuist_sta_app/mini_apps/academic/academic_controller.dart';
import 'package:nuist_sta_app/mini_apps/academic/academic_models.dart';
import 'package:nuist_sta_app/mini_apps/electricity/electricity_controller.dart';
import 'package:nuist_sta_app/mini_apps/electricity/electricity_models.dart';
import 'package:nuist_sta_app/mini_apps/innovation_credit/innovation_credit_controller.dart';
import 'package:nuist_sta_app/mini_apps/innovation_credit/innovation_credit_models.dart';
import 'package:nuist_sta_app/mini_apps/labor_score/labor_score_controller.dart';
import 'package:nuist_sta_app/mini_apps/labor_score/labor_score_models.dart';
import 'package:nuist_sta_app/mini_apps/score/score_controller.dart';
import 'package:nuist_sta_app/mini_apps/score/score_models.dart';
import 'package:nuist_sta_app/mini_apps/student_info/student_info_controller.dart';
import 'package:nuist_sta_app/mini_apps/student_info/student_info_models.dart';
import 'package:nuist_sta_app/shell/profile/portal_bind/portal_binding_actions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PortalBindingActions 串行排队与副作用顺序', () {
    final bundle = PasskeyBundle(
      rpId: 'portal.test',
      credentialId: 'synthetic-credential',
      privateKeyPkcs8Pem: 'synthetic-key',
      userId: '',
      anonbiometricsd: 'synthetic-device',
      deviceName: '测试设备',
      createdAt: DateTime(2026, 11, 6),
    );

    test('凭据保存与会话清理完成后只通知一次，后台刷新不阻塞绑定完成', () async {
      final events = <String>[];
      final saved = Completer<void>();
      final cleared = Completer<void>();
      final refreshed = Completer<bool>();
      final actions = PortalBindingActions.forTesting(
        saveCredential: (_) {
          events.add('save');
          return saved.future;
        },
        deleteCredential: () async => events.add('delete'),
        clearSession: (webView) {
          expect(webView, isFalse);
          events.add('clear');
          return cleared.future;
        },
        notifyApps: ({required bound}) {
          expect(bound, isTrue);
          events.add('notify');
          return refreshed.future;
        },
      );
      final binding = actions.bind(bundle);
      await pumpEventQueue();
      expect(events, ['save']);
      saved.complete();
      await pumpEventQueue();
      expect(events, ['save', 'clear']);
      cleared.complete();
      await binding;
      expect(events, ['save', 'clear', 'notify']);
      expect(refreshed.isCompleted, isFalse);
      refreshed.complete(true);
      await pumpEventQueue();
    });

    for (final failedStep in ['save', 'clear']) {
      test('$failedStep 失败时不会通知绑定成功', () async {
        final events = <String>[];
        final actions = PortalBindingActions.forTesting(
          saveCredential: (_) async {
            events.add('save');
            if (failedStep == 'save') throw StateError('合成保存失败');
          },
          deleteCredential: () async {},
          clearSession: (_) async {
            events.add('clear');
            throw StateError('合成会话清理失败');
          },
          notifyApps: ({required bound}) async {
            events.add('notify');
            return true;
          },
        );
        await expectLater(actions.bind(bundle), throwsStateError);
        expect(events, failedStep == 'save' ? ['save'] : ['save', 'clear']);
      });
    }

    test('解绑删除凭据并清 WebView，等待所有模块并反馈清理失败', () async {
      final events = <String>[];
      final cleaned = Completer<bool>();
      final actions = PortalBindingActions.forTesting(
        saveCredential: (_) async {},
        deleteCredential: () async => events.add('delete'),
        clearSession: (webView) async {
          expect(webView, isTrue);
          events.add('clear');
        },
        notifyApps: ({required bound}) {
          expect(bound, isFalse);
          events.add('notify');
          return cleaned.future;
        },
      );
      var finished = false;
      final unbinding = actions.unbind().then((result) {
        finished = true;
        return result;
      });
      await pumpEventQueue();
      expect(events, ['delete', 'clear', 'notify']);
      expect(finished, isFalse);
      cleaned.complete(false);
      expect(await unbinding, isFalse);
    });

    test('后台模块意外抛错不会变成未处理异常或把绑定判为失败', () async {
      final actions = PortalBindingActions.forTesting(
        saveCredential: (_) async {},
        deleteCredential: () async {},
        clearSession: (_) async {},
        notifyApps: ({required bound}) async => throw StateError('合成通知失败'),
      );
      await actions.bind(bundle);
      await pumpEventQueue();
    });

    test('保存过程中解绑会排队，迟到的保存不会恢复已解绑凭据', () async {
      final saved = Completer<void>();
      final events = <String>[];
      final actions = PortalBindingActions.forTesting(
        saveCredential: (_) async {
          events.add('save.started');
          await saved.future;
          events.add('save.finished');
        },
        deleteCredential: () async => events.add('delete'),
        clearSession: (webView) async => events.add('clear.$webView'),
        notifyApps: ({required bound}) async {
          events.add('notify.$bound');
          return true;
        },
      );
      final binding = actions.bind(bundle);
      await pumpEventQueue();
      final unbinding = actions.unbind();
      await pumpEventQueue();
      expect(events, ['save.started']);
      saved.complete();
      await binding;
      expect(await unbinding, isTrue);
      expect(events, [
        'save.started',
        'save.finished',
        'clear.false',
        'notify.true',
        'delete',
        'clear.true',
        'notify.false',
      ]);
    });
  });

  group('电费控制器门户绑定生命周期', () {
    const room = ElecRoom(
      campus: ElecOption(name: '测试校区', value: 'campus'),
      building: ElecOption(name: '测试楼栋', value: 'building'),
      room: ElecOption(name: '测试房间', value: 'room'),
    );
    final cached = ElecReading(time: DateTime(2026, 11, 6), kwh: 20);

    test('八小时内的自动尝试和失败均受冷却约束，手动与换绑立即刷新', () async {
      var clock = DateTime(2026, 11, 17, 12);
      DateTime? lastAttempt = clock.subtract(
        const Duration(hours: 7, minutes: 59),
      );
      _ElecHarness harness({Future<double> Function()? query}) {
        final h = _ElecHarness(storedRoom: room, cached: cached);
        h.bound = true;
        h.now = () => clock;
        h.readAttempt = () async => lastAttempt;
        h.saveAttempt = (at) async => lastAttempt = at;
        h.query = query;
        return h;
      }

      final h = harness();
      final updated = SilentRefresh.updated.value;
      await h.controller.ensureStarted();
      expect(h.queries, 0);
      expect(h.controller.portalBound, isTrue);
      await h.controller.refresh();
      expect(h.queries, 1);
      expect(SilentRefresh.updated.value, updated + 1);
      await h.controller.onPortalBindingChanged(true);
      expect(h.queries, 2);
      expect(SilentRefresh.updated.value, updated + 1);

      clock = clock.add(const Duration(minutes: 1));
      final expired = harness();
      await expired.controller.ensureStarted();
      expect(expired.queries, 1);
      expect(lastAttempt, clock);

      // 自动拉取失败同样计入八小时冷却。
      lastAttempt = null;
      final failed = harness(
        query: () async => throw StateError('synthetic offline'),
      );
      await failed.controller.ensureStarted();
      expect(failed.queries, 1);
      expect(lastAttempt, clock);
      final cooled = harness(
        query: () async => throw StateError('synthetic offline'),
      );
      await cooled.controller.ensureStarted();
      expect(cooled.queries, 0);
    });

    test('未绑定宿舍时绑定、解绑与手动刷新同步门户状态，不查询余额', () async {
      final h = _ElecHarness();
      await h.controller.ensureStarted();
      expect(h.controller.portalBound, isFalse);

      await h.controller.onPortalBindingChanged(true);
      expect(h.controller.portalBound, isTrue);
      expect(h.controller.room, isNull);

      await h.controller.onPortalBindingChanged(false);
      expect(h.controller.portalBound, isFalse);
      expect(h.queries, 0);
      expect(h.roomReads, 1);

      h.bound = true;
      await h.controller.refresh();
      expect(h.controller.portalBound, isTrue);
      expect(h.queries, 0);
    });

    test('首次挂载前绑定先恢复宿舍再刷新，解绑保留宿舍和余额，旧绑定检查不覆盖新事件', () async {
      final h = _ElecHarness(storedRoom: room, cached: cached);

      await h.controller.onPortalBindingChanged(true);
      await h.controller.ensureStarted();

      expect(h.controller.portalBound, isTrue);
      expect(h.controller.room, same(room));
      expect(h.controller.latest?.kwh, 30);
      expect(h.queries, 1);
      expect(h.roomReads, 1);

      final latest = h.controller.latest;
      await h.controller.onPortalBindingChanged(false);

      expect(h.controller.portalBound, isFalse);
      expect(h.controller.room, same(room));
      expect(h.controller.latest, same(latest));
      expect(h.readings, [latest]);

      // 初始化中的旧绑定检查晚到时不能覆盖新绑定事件。
      final racing = _ElecHarness(storedRoom: room, cached: cached);
      final checking = Completer<void>();
      final oldBinding = Completer<bool>();
      racing.checkBinding = () {
        checking.complete();
        return oldBinding.future;
      };
      final starting = racing.controller.ensureStarted();
      await checking.future;

      final binding = racing.controller.onPortalBindingChanged(true);
      expect(racing.controller.portalBound, isTrue);
      oldBinding.complete(false);
      await Future.wait([starting, binding]);

      expect(racing.controller.portalBound, isTrue);
      expect(racing.controller.latest?.kwh, 30);
      expect(racing.queries, 1);
    });

    test('解绑后忽略仍在返回的旧请求余额或错误', () async {
      for (final fails in [false, true]) {
        final h = _ElecHarness(storedRoom: room, cached: cached);
        await h.controller.ensureStarted();
        h.bound = true;
        final requested = Completer<void>();
        final response = Completer<double>();
        h.query = () {
          requested.complete();
          return response.future;
        };
        final refreshing = h.controller.refresh();
        await requested.future;

        await h.controller.onPortalBindingChanged(false);
        expect(h.controller.portalBound, isFalse);
        if (fails) {
          response.completeError(const PortalLoginError('合成旧会话错误'));
        } else {
          response.complete(10);
        }
        await refreshing;

        expect(h.controller.portalBound, isFalse);
        expect(h.controller.room, same(room));
        expect(h.controller.latest, same(cached));
        expect(h.controller.error, isNull);
        expect(h.controller.loading, isFalse);
        expect(h.readings, isEmpty);
      }
    });

    test('刷新合流，重绑等待旧请求后仅用新结果更新，等待期间解绑则不补发', () async {
      final h = _ElecHarness(storedRoom: room, cached: cached);
      await h.controller.ensureStarted();
      h.bound = true;
      final oldRequested = Completer<void>();
      final oldResponse = Completer<double>();
      final newRequested = Completer<void>();
      final newResponse = Completer<double>();
      h.query = () {
        if (h.queries == 1) {
          oldRequested.complete();
          return oldResponse.future;
        }
        newRequested.complete();
        return newResponse.future;
      };
      final refreshing = h.controller.refresh();
      expect(h.controller.refresh(), same(refreshing));
      await oldRequested.future;

      final binding = h.controller.onPortalBindingChanged(true);
      oldResponse.complete(10);
      await newRequested.future;
      expect(h.controller.latest, same(cached));
      expect(h.readings, isEmpty);
      newResponse.complete(40);
      await Future.wait([refreshing, binding]);

      expect(h.controller.portalBound, isTrue);
      expect(h.controller.latest?.kwh, 40);
      expect(h.queries, 2);
      expect(h.readings.map((reading) => reading.kwh), [40]);

      // 等待旧刷新期间再次解绑，不补发已经过时的绑定刷新。
      final cancelled = _ElecHarness(storedRoom: room, cached: cached);
      await cancelled.controller.ensureStarted();
      cancelled.bound = true;
      final requested = Completer<void>();
      final response = Completer<double>();
      cancelled.query = () {
        requested.complete();
        return response.future;
      };
      final inFlight = cancelled.controller.refresh();
      await requested.future;

      final rebinding = cancelled.controller.onPortalBindingChanged(true);
      await cancelled.controller.onPortalBindingChanged(false);
      response.complete(10);
      await Future.wait([inFlight, rebinding]);

      expect(cancelled.controller.portalBound, isFalse);
      expect(cancelled.controller.latest, same(cached));
      expect(cancelled.queries, 1);
      expect(cancelled.readings, isEmpty);
    });
  });

  _registerStudyCases<AcademicSummary>(
    'academic',
    (at) => AcademicSummary.fromJson(const {}, fetchedAt: at),
    (dependencies) {
      final controller = AcademicController.forTesting(
        readCache: dependencies.readCache,
        saveCache: dependencies.saveCache,
        fetch: dependencies.fetch,
        bindingCheck: dependencies.bindingCheck,
      );
      return _StudyController(
        notifier: controller,
        ensureCacheLoaded: controller.ensureCacheLoaded,
        ensureStarted: controller.ensureStarted,
        refresh: controller.refresh,
        bindingChanged: controller.onPortalBindingChanged,
        debugReset: controller.debugReset,
        data: () => controller.summary,
        bound: () => controller.portalBound,
        loading: () => controller.loading,
        error: () => controller.error,
      );
    },
  );
  _registerStudyCases<StudentInfo>(
    'student_info',
    (at) => StudentInfo.fromJson(const {}, fetchedAt: at),
    (dependencies) {
      final controller = StudentInfoController.forTesting(
        readCache: dependencies.readCache,
        saveCache: dependencies.saveCache,
        fetch: dependencies.fetch,
        bindingCheck: dependencies.bindingCheck,
      );
      return _StudyController(
        notifier: controller,
        ensureCacheLoaded: controller.ensureCacheLoaded,
        ensureStarted: controller.ensureStarted,
        refresh: controller.refresh,
        bindingChanged: controller.onPortalBindingChanged,
        debugReset: controller.debugReset,
        data: () => controller.info,
        bound: () => controller.portalBound,
        loading: () => controller.loading,
        error: () => controller.error,
      );
    },
  );
  _registerStudyCases<ScoreReport>(
    'score',
    (at) => ScoreReport(records: const [], fetchedAt: at),
    (dependencies) {
      final controller = ScoreController.forTesting(
        readCache: dependencies.readCache,
        saveCache: dependencies.saveCache,
        fetch: dependencies.fetch,
        bindingCheck: dependencies.bindingCheck,
      );
      return _StudyController(
        notifier: controller,
        ensureCacheLoaded: controller.ensureCacheLoaded,
        ensureStarted: controller.ensureStarted,
        refresh: controller.refresh,
        bindingChanged: controller.onPortalBindingChanged,
        debugReset: controller.debugReset,
        data: () => controller.report,
        bound: () => controller.portalBound,
        loading: () => controller.loading,
        error: () => controller.error,
      );
    },
  );
  _registerStudyCases<InnovationCredit>(
    'innovation_credit',
    (at) =>
        InnovationCredit(total: '0', grade: '', items: const [], fetchedAt: at),
    (dependencies) {
      final controller = InnovationCreditController.forTesting(
        readCache: dependencies.readCache,
        saveCache: dependencies.saveCache,
        fetch: dependencies.fetch,
        bindingCheck: dependencies.bindingCheck,
      );
      return _StudyController(
        notifier: controller,
        ensureCacheLoaded: controller.ensureCacheLoaded,
        ensureStarted: controller.ensureStarted,
        refresh: controller.refresh,
        bindingChanged: controller.onPortalBindingChanged,
        debugReset: controller.debugReset,
        data: () => controller.credit,
        bound: () => controller.portalBound,
        loading: () => controller.loading,
        error: () => controller.error,
      );
    },
  );
  _registerStudyCases<LaborScore>(
    'labor_score',
    (at) => LaborScore(
      official: null,
      liveLife: null,
      liveService: null,
      liveMajor: null,
      fetchedAt: at,
    ),
    (dependencies) {
      final controller = LaborScoreController.forTesting(
        readCache: dependencies.readCache,
        saveCache: dependencies.saveCache,
        fetch: dependencies.fetch,
        bindingCheck: dependencies.bindingCheck,
      );
      return _StudyController(
        notifier: controller,
        ensureCacheLoaded: controller.ensureCacheLoaded,
        ensureStarted: controller.ensureStarted,
        refresh: controller.refresh,
        bindingChanged: controller.onPortalBindingChanged,
        debugReset: controller.debugReset,
        data: () => controller.score,
        bound: () => controller.portalBound,
        loading: () => controller.loading,
        error: () => controller.error,
      );
    },
  );

  test(
    'student_info ensureCacheLoaded 标记 infoFromCache，远端刷新与 debugReset 后复位',
    () async {
      final stale = StudentInfo.fromJson(
        const {},
        fetchedAt: DateTime.now().subtract(const Duration(days: 1)),
      );
      final fresh = StudentInfo.fromJson(const {}, fetchedAt: DateTime.now());
      final controller = StudentInfoController.forTesting(
        readCache: () async => stale,
        saveCache: (_) async {},
        fetch: () async => fresh,
        bindingCheck: () async => true,
      );
      addTearDown(controller.dispose);

      await controller.ensureCacheLoaded();
      expect(controller.info, same(stale));
      expect(controller.infoFromCache, isTrue);

      await controller.ensureStarted();
      expect(controller.info, same(fresh));
      expect(controller.infoFromCache, isFalse);

      controller.debugReset();
      expect(controller.info, isNull);
      expect(controller.infoFromCache, isFalse);
    },
  );
}

void _registerStudyCases<T>(
  String name,
  T Function(DateTime) makeData,
  _StudyController<T> Function(_StudyDependencies<T>) create,
) {
  group('$name 门户绑定生命周期', () {
    late _StudyDependencies<T> dependencies;
    late _StudyController<T> controller;
    late T cached;
    late T fresh;

    void resetHarness({T? cachedData}) {
      controller.notifier.dispose();
      cached = cachedData ?? makeData(DateTime.now());
      fresh = makeData(DateTime.now());
      dependencies = _StudyDependencies(cached: cachedData, next: fresh);
      controller = create(dependencies);
    }

    setUp(() {
      cached = makeData(DateTime.now());
      fresh = makeData(DateTime.now());
      dependencies = _StudyDependencies(cached: cached, next: fresh);
      controller = create(dependencies);
    });

    tearDown(() => controller.notifier.dispose());

    test('缓存预热与启动：命中当天、过期、空缓存、未绑定与并发读盘去重', () async {
      // 1) 当天缓存命中：ensureCacheLoaded 读盘不发请求，后续 ensureStarted 不重复读盘也不拉取。
      await controller.ensureCacheLoaded();
      expect(dependencies.reads, 1);
      expect(dependencies.requests, 0);
      expect(controller.data(), same(cached));
      await controller.ensureStarted();
      expect(dependencies.reads, 1);
      expect(dependencies.requests, 0);
      expect(controller.data(), same(cached));

      // 2) 过期缓存：ensureCacheLoaded 仅读盘不发请求且幂等，ensureStarted 触发一次拉取且不再读盘。
      controller.debugReset();
      final stale = makeData(DateTime.now().subtract(const Duration(days: 1)));
      dependencies.cached = stale;
      var notifications = 0;
      void count() => notifications++;
      controller.notifier.addListener(count);
      await controller.ensureCacheLoaded();
      expect(dependencies.reads, 2);
      expect(dependencies.bindingChecks, 2);
      expect(dependencies.requests, 0);
      expect(controller.data(), same(stale));
      expect(controller.bound(), isTrue);
      expect(controller.loading(), isFalse);
      expect(notifications, greaterThan(0));
      controller.notifier.removeListener(count);
      await controller.ensureCacheLoaded();
      expect(dependencies.reads, 2);
      await controller.ensureStarted();
      expect(dependencies.reads, 2);
      expect(dependencies.requests, 1);
      expect(controller.data(), same(fresh));
      expect(dependencies.saved, [fresh]);
      await controller.ensureStarted();
      expect(dependencies.requests, 1);

      // 3) 空缓存首次自动刷新不发手动成功提示，手动刷新立即执行并累加提示。
      controller.debugReset();
      dependencies.cached = null;
      final updated = SilentRefresh.updated.value;
      await controller.ensureCacheLoaded();
      expect(dependencies.requests, 1);
      expect(controller.data(), isNull);
      await controller.ensureStarted();
      expect(dependencies.requests, 2);
      expect(SilentRefresh.updated.value, updated);
      await controller.refresh();
      expect(dependencies.requests, 3);
      expect(SilentRefresh.updated.value, updated + 1);

      // 4) 未绑定：ensureCacheLoaded 与 ensureStarted 均不发请求。
      controller.debugReset();
      dependencies.bindingOverride = () async => false;
      dependencies.cached = stale;
      await controller.ensureCacheLoaded();
      expect(controller.bound(), isFalse);
      expect(controller.data(), same(stale));
      await controller.ensureStarted();
      expect(dependencies.requests, 3);
      expect(controller.bound(), isFalse);

      // 5) 并发 ensureCacheLoaded + ensureStarted 共用同一次读盘；并发 refresh 绑定检查阶段即合流。
      controller.debugReset();
      dependencies.bindingOverride = null;
      final cacheRead = Completer<T?>();
      dependencies.readOverride = () => cacheRead.future;
      final readsBefore = dependencies.reads;
      final requestsBefore = dependencies.requests;
      final firstCache = controller.ensureCacheLoaded();
      final secondCache = controller.ensureCacheLoaded();
      expect(firstCache, same(secondCache));
      final starting = controller.ensureStarted();
      expect(dependencies.reads, readsBefore + 1);
      expect(dependencies.requests, requestsBefore);
      cacheRead.complete(stale);
      await Future.wait([firstCache, secondCache, starting]);
      expect(dependencies.reads, readsBefore + 1);
      expect(dependencies.requests, requestsBefore + 1);
      expect(controller.data(), same(fresh));

      dependencies.readOverride = null;
      final binding = Completer<bool>();
      dependencies.bindingOverride = () => binding.future;
      final firstRefresh = controller.refresh();
      final secondRefresh = controller.refresh();
      expect(firstRefresh, same(secondRefresh));
      binding.complete(true);
      await Future.wait([firstRefresh, secondRefresh]);
      expect(dependencies.requests, requestsBefore + 2);
    });

    test('绑定与解绑状态切换：未挂载初始化、缓存预热后解绑及解绑丢弃旧请求', () async {
      // 1) 未挂载直接绑定：初始化并忽略当天缓存强制刷新，二次绑定再刷新，解绑保留数据。
      await controller.bindingChanged(true);
      expect(dependencies.reads, 1);
      expect(dependencies.requests, 1);
      expect(controller.data(), same(fresh));
      expect(controller.bound(), isTrue);
      await controller.ensureStarted();
      expect(dependencies.reads, 1);
      expect(dependencies.requests, 1);

      final replacement = makeData(DateTime.now());
      dependencies.next = replacement;
      await controller.bindingChanged(true);
      expect(dependencies.requests, 2);
      expect(controller.data(), same(replacement));

      await controller.bindingChanged(false);
      expect(controller.bound(), isFalse);
      expect(controller.loading(), isFalse);
      expect(controller.data(), same(replacement));
      expect(dependencies.requests, 2);
      expect(dependencies.saved, [fresh, replacement]);

      // 2) 未启动时解绑只初始化缓存，不发网络请求。
      controller.debugReset();
      await controller.bindingChanged(false);
      await controller.ensureStarted();
      expect(controller.bound(), isFalse);
      expect(controller.loading(), isFalse);
      expect(controller.data(), same(cached));
      expect(dependencies.requests, 2);

      // 3) ensureCacheLoaded 读到过期缓存后解绑，再 ensureStarted 不发请求且保留缓存。
      controller.debugReset();
      final stale = makeData(DateTime.now().subtract(const Duration(days: 1)));
      dependencies.cached = stale;
      await controller.ensureCacheLoaded();
      await controller.bindingChanged(false);
      await controller.ensureStarted();
      expect(dependencies.requests, 2);
      expect(controller.bound(), isFalse);
      expect(controller.data(), same(stale));

      // 4) 解绑无需等待在途刷新，旧请求失败也不会恢复绑定或显示旧错误。
      controller.debugReset();
      dependencies.cached = cached;
      await controller.ensureStarted();
      final response = Completer<T>();
      final started = Completer<void>();
      dependencies.fetchOverride = () {
        started.complete();
        return response.future;
      };
      final refreshing = controller.refresh();
      await started.future;
      await controller.bindingChanged(false);
      expect(controller.bound(), isFalse);
      expect(controller.loading(), isFalse);
      response.completeError(const PortalCredentialError('旧凭据失效'));
      await refreshing;
      expect(controller.bound(), isFalse);
      expect(controller.error(), isNull);
      expect(controller.data(), same(cached));
      expect(dependencies.requests, 3);
      expect(dependencies.saved, [fresh, replacement]);
    });

    test('重绑竞态：初始/预热缓存晚到不覆盖新数据，连续重绑合并并丢弃旧请求', () async {
      // 1) ensureStarted 与 ensureCacheLoaded 读盘在途发生重绑，晚到旧缓存均不能覆盖新数据。
      for (final preloadOnly in [false, true]) {
        resetHarness(cachedData: makeData(DateTime.now()));
        final cacheRead = Completer<T?>();
        dependencies.readOverride = () => cacheRead.future;
        final seen = <T?>[];
        controller.notifier.addListener(() => seen.add(controller.data()));
        final loading = preloadOnly
            ? controller.ensureCacheLoaded()
            : controller.ensureStarted();
        final binding = controller.bindingChanged(true);
        cacheRead.complete(cached);
        await Future.wait([loading, binding]);
        expect(dependencies.reads, 1);
        expect(dependencies.requests, 1);
        expect(controller.data(), same(fresh));
        expect(seen, isNot(contains(same(cached))));
        expect(controller.bound(), isTrue);
        if (preloadOnly) {
          await controller.ensureStarted();
          expect(dependencies.reads, 1);
          expect(dependencies.requests, 1);
        }
      }

      // 2) 刷新中连续重绑合并过时通知，并丢弃旧请求结果。
      resetHarness(cachedData: makeData(DateTime.now()));
      await controller.ensureStarted();
      final oldResponse = Completer<T>();
      final newResponse = Completer<T>();
      final oldStarted = Completer<void>();
      final newStarted = Completer<void>();
      dependencies.fetchOverride = () {
        if (dependencies.requests == 1) {
          oldStarted.complete();
          return oldResponse.future;
        }
        newStarted.complete();
        return newResponse.future;
      };
      final refreshing = controller.refresh();
      await oldStarted.future;
      final firstBinding = controller.bindingChanged(true);
      final latestBinding = controller.bindingChanged(true);
      expect(controller.loading(), isTrue);
      oldResponse.complete(makeData(DateTime.now()));
      await newStarted.future;
      expect(controller.data(), same(cached));
      expect(dependencies.saved, isEmpty);
      newResponse.complete(fresh);
      await Future.wait([refreshing, firstBinding, latestBinding]);
      expect(dependencies.requests, 2);
      expect(dependencies.saved, [fresh]);
      expect(controller.data(), same(fresh));
      expect(controller.loading(), isFalse);
      expect(controller.error(), isNull);
    });

    test('重绑等待旧写盘完成，旧数据不会覆盖新内存或新缓存', () async {
      await controller.ensureStarted();
      final oldData = makeData(DateTime.now());
      dependencies.next = oldData;
      final saving = Completer<void>();
      final allowSave = Completer<void>();
      dependencies.saveOverride = (value) async {
        if (identical(value, oldData)) {
          saving.complete();
          await allowSave.future;
        }
      };
      final seen = <T?>[];
      controller.notifier.addListener(() => seen.add(controller.data()));
      final refreshing = controller.refresh();
      await saving.future;
      dependencies.next = fresh;
      final binding = controller.bindingChanged(true);
      expect(dependencies.requests, 1);
      allowSave.complete();
      await Future.wait([refreshing, binding]);
      expect(dependencies.saved, [oldData, fresh]);
      expect(controller.data(), same(fresh));
      expect(seen, isNot(contains(same(oldData))));
      expect(controller.loading(), isFalse);
    });

    test('debugReset 清空所有状态并使在途读盘失效，重置后可重新加载缓存与启动', () async {
      final pendingRead = Completer<T?>();
      dependencies.readOverride = () => pendingRead.future;
      final stale = makeData(DateTime.now().subtract(const Duration(days: 1)));
      final inFlight = controller.ensureCacheLoaded();
      expect(dependencies.reads, 1);

      controller.debugReset();
      pendingRead.complete(stale);
      await inFlight;
      expect(controller.data(), isNull);
      expect(controller.bound(), isTrue);
      expect(controller.loading(), isFalse);
      expect(controller.error(), isNull);

      dependencies.readOverride = null;
      dependencies.cached = stale;
      await controller.ensureCacheLoaded();
      expect(dependencies.reads, 2);
      expect(dependencies.requests, 0);
      expect(controller.data(), same(stale));

      await controller.ensureStarted();
      expect(dependencies.reads, 2);
      expect(dependencies.requests, 1);
      expect(controller.data(), same(fresh));
    });
  });
}

class _ElecHarness {
  _ElecHarness({this.storedRoom, this.cached}) {
    addTearDown(controller.dispose);
  }

  bool bound = false;
  ElecRoom? storedRoom;
  ElecReading? cached;
  Future<bool> Function()? checkBinding;
  Future<double> Function()? query;
  DateTime Function()? now;
  Future<DateTime?> Function()? readAttempt;
  Future<void> Function(DateTime at)? saveAttempt;
  int roomReads = 0;
  int queries = 0;
  final readings = <ElecReading>[];

  late final controller = ElectricityController.forTesting(
    bindingCheck: () async =>
        checkBinding == null ? bound : await checkBinding!(),
    readRoom: () async {
      roomReads++;
      return storedRoom;
    },
    readLatest: (_) async => cached,
    queryBalance: (_) async {
      queries++;
      return query == null ? 30 : await query!();
    },
    appendReading: (_, reading) async => readings.add(reading),
    readLastAutomaticAttempt: () async => await readAttempt?.call(),
    saveLastAutomaticAttempt: (at) async => await saveAttempt?.call(at),
    now: () => now == null ? DateTime.now() : now!(),
  );
}

class _StudyDependencies<T> {
  _StudyDependencies({required this.cached, required this.next});

  T? cached;
  T next;
  int reads = 0;
  int requests = 0;
  int bindingChecks = 0;
  final List<T> saved = [];
  Future<T?> Function()? readOverride;
  Future<T> Function()? fetchOverride;
  Future<void> Function(T)? saveOverride;
  Future<bool> Function()? bindingOverride;

  Future<T?> readCache() async {
    reads++;
    return readOverride == null ? cached : await readOverride!();
  }

  Future<T> fetch() async {
    requests++;
    return fetchOverride == null ? next : await fetchOverride!();
  }

  Future<void> saveCache(T value) async {
    await saveOverride?.call(value);
    saved.add(value);
  }

  Future<bool> bindingCheck() async {
    bindingChecks++;
    return bindingOverride == null ? true : await bindingOverride!();
  }
}

class _StudyController<T> {
  _StudyController({
    required this.notifier,
    required this.ensureCacheLoaded,
    required this.ensureStarted,
    required this.refresh,
    required this.bindingChanged,
    required this.debugReset,
    required this.data,
    required this.bound,
    required this.loading,
    required this.error,
  });

  final ChangeNotifier notifier;
  final Future<void> Function() ensureCacheLoaded;
  final Future<void> Function() ensureStarted;
  final Future<void> Function() refresh;
  final Future<void> Function(bool) bindingChanged;
  final void Function() debugReset;
  final T? Function() data;
  final bool Function() bound;
  final bool Function() loading;
  final String? Function() error;
}
