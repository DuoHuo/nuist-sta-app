import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/auth/portal_exceptions.dart';
import 'package:nuist_sta_app/mini_apps/academic/academic_controller.dart';
import 'package:nuist_sta_app/mini_apps/academic/academic_models.dart';
import 'package:nuist_sta_app/mini_apps/student_info/student_info_controller.dart';
import 'package:nuist_sta_app/mini_apps/student_info/student_info_models.dart';
import 'package:nuist_sta_app/mini_apps/score/score_controller.dart';
import 'package:nuist_sta_app/mini_apps/score/score_models.dart';
import 'package:nuist_sta_app/mini_apps/innovation_credit/innovation_credit_controller.dart';
import 'package:nuist_sta_app/mini_apps/innovation_credit/innovation_credit_models.dart';
import 'package:nuist_sta_app/mini_apps/labor_score/labor_score_controller.dart';
import 'package:nuist_sta_app/mini_apps/labor_score/labor_score_models.dart';

void main() {
  _registerCases<AcademicSummary>(
    'academic',
    (at) => AcademicSummary.fromJson(const {}, fetchedAt: at),
    (dependencies) {
      final controller = AcademicController.forTesting(
        readCache: dependencies.readCache,
        saveCache: dependencies.saveCache,
        fetch: dependencies.fetch,
        bindingCheck: dependencies.bindingCheck,
      );
      return _Controller(
        notifier: controller,
        ensureStarted: controller.ensureStarted,
        refresh: controller.refresh,
        bindingChanged: controller.onPortalBindingChanged,
        data: () => controller.summary,
        bound: () => controller.portalBound,
        loading: () => controller.loading,
        error: () => controller.error,
      );
    },
  );
  _registerCases<StudentInfo>(
    'student_info',
    (at) => StudentInfo.fromJson(const {}, fetchedAt: at),
    (dependencies) {
      final controller = StudentInfoController.forTesting(
        readCache: dependencies.readCache,
        saveCache: dependencies.saveCache,
        fetch: dependencies.fetch,
        bindingCheck: dependencies.bindingCheck,
      );
      return _Controller(
        notifier: controller,
        ensureStarted: controller.ensureStarted,
        refresh: controller.refresh,
        bindingChanged: controller.onPortalBindingChanged,
        data: () => controller.info,
        bound: () => controller.portalBound,
        loading: () => controller.loading,
        error: () => controller.error,
      );
    },
  );
  _registerCases<ScoreReport>(
    'score',
    (at) => ScoreReport(records: const [], fetchedAt: at),
    (dependencies) {
      final controller = ScoreController.forTesting(
        readCache: dependencies.readCache,
        saveCache: dependencies.saveCache,
        fetch: dependencies.fetch,
        bindingCheck: dependencies.bindingCheck,
      );
      return _Controller(
        notifier: controller,
        ensureStarted: controller.ensureStarted,
        refresh: controller.refresh,
        bindingChanged: controller.onPortalBindingChanged,
        data: () => controller.report,
        bound: () => controller.portalBound,
        loading: () => controller.loading,
        error: () => controller.error,
      );
    },
  );
  _registerCases<InnovationCredit>(
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
      return _Controller(
        notifier: controller,
        ensureStarted: controller.ensureStarted,
        refresh: controller.refresh,
        bindingChanged: controller.onPortalBindingChanged,
        data: () => controller.credit,
        bound: () => controller.portalBound,
        loading: () => controller.loading,
        error: () => controller.error,
      );
    },
  );
  _registerCases<LaborScore>(
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
      return _Controller(
        notifier: controller,
        ensureStarted: controller.ensureStarted,
        refresh: controller.refresh,
        bindingChanged: controller.onPortalBindingChanged,
        data: () => controller.score,
        bound: () => controller.portalBound,
        loading: () => controller.loading,
        error: () => controller.error,
      );
    },
  );
}

void _registerCases<T>(
  String name,
  T Function(DateTime) makeData,
  _Controller<T> Function(_Dependencies<T>) create,
) {
  group('$name 门户绑定生命周期', () {
    late _Dependencies<T> dependencies;
    late _Controller<T> controller;
    late T cached;
    late T fresh;

    setUp(() {
      cached = makeData(DateTime.now());
      fresh = makeData(DateTime.now());
      dependencies = _Dependencies(cached: cached, next: fresh);
      controller = create(dependencies);
    });

    tearDown(() => controller.notifier.dispose());

    test('未挂载卡片时绑定也会初始化，并忽略当天缓存强制更新', () async {
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
    });

    test('未启动时解绑只初始化缓存，不发网络请求', () async {
      await controller.bindingChanged(false);
      await controller.ensureStarted();
      expect(controller.bound(), isFalse);
      expect(controller.loading(), isFalse);
      expect(controller.data(), same(cached));
      expect(dependencies.requests, 0);
      expect(dependencies.saved, isEmpty);
    });

    test('初始缓存晚到不能覆盖随后绑定取得的数据', () async {
      final cacheRead = Completer<T?>();
      dependencies.readOverride = () => cacheRead.future;
      final seen = <T?>[];
      controller.notifier.addListener(() => seen.add(controller.data()));
      final starting = controller.ensureStarted();
      final binding = controller.bindingChanged(true);
      cacheRead.complete(cached);
      await Future.wait([starting, binding]);
      expect(dependencies.requests, 1);
      expect(controller.data(), same(fresh));
      expect(seen, isNot(contains(same(cached))));
      expect(controller.bound(), isTrue);
    });

    test('刷新中连续重绑会合并过时通知，并丢弃旧请求结果', () async {
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

    test('解绑无需等待旧请求，旧请求失败也不会恢复绑定或显示旧错误', () async {
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
      expect(dependencies.requests, 1);
      expect(dependencies.saved, isEmpty);
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

    test('普通并发刷新连绑定检查阶段也只发一次请求', () async {
      await controller.ensureStarted();
      final binding = Completer<bool>();
      dependencies.bindingOverride = () => binding.future;
      final first = controller.refresh();
      final second = controller.refresh();
      expect(first, same(second));
      binding.complete(true);
      await Future.wait([first, second]);
      expect(dependencies.requests, 1);
      expect(dependencies.saved, [fresh]);
    });
  });
}

class _Dependencies<T> {
  _Dependencies({required this.cached, required this.next});

  T? cached;
  T next;
  int reads = 0;
  int requests = 0;
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

  Future<bool> bindingCheck() async =>
      bindingOverride == null ? true : await bindingOverride!();
}

class _Controller<T> {
  _Controller({
    required this.notifier,
    required this.ensureStarted,
    required this.refresh,
    required this.bindingChanged,
    required this.data,
    required this.bound,
    required this.loading,
    required this.error,
  });

  final ChangeNotifier notifier;
  final Future<void> Function() ensureStarted;
  final Future<void> Function() refresh;
  final Future<void> Function(bool) bindingChanged;
  final T? Function() data;
  final bool Function() bound;
  final bool Function() loading;
  final String? Function() error;
}
