import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/auth/portal_exceptions.dart';
import 'package:nuist_sta_app/core/logging/app_log.dart';
import 'package:nuist_sta_app/core/refresh/silent_refresh.dart';

void main() {
  group('刷新诊断保留真实结果', () {
    late List<Map<String, Object?>> records;
    setUp(() {
      records = [];
      AppLog.recordListenerForTesting = records.add;
    });
    tearDown(() => AppLog.recordListenerForTesting = null);

    test('共享刷新重试恢复后不会保留早期子阶段的失败结果', () async {
      var attempt = 0;
      final shared = SilentRefresh.track(() async {
        await SilentRefresh.run(
          'test.recovered',
          action: () async {
            if (++attempt == 1) {
              await AppLog.logger('test.stage')
                  .operation<void>('request', () async {
                    throw TimeoutException('合成第一次超时');
                  });
            }
          },
          delays: const [Duration.zero],
        );
      });
      final succeeded = await SilentRefresh.runAll('test.batch', {
        'shared': () => SilentRefresh.join(shared),
      });
      expect(succeeded, isTrue);
      final completed = records.singleWhere(
        (record) => record['event'] == 'refresh.batch_completed',
      );
      expect((completed['attrs'] as Map)['success_count'], 1);
      expect((completed['attrs'] as Map)['failure_count'], 0);
    });

    for (final outcome in ['skipped', 'degraded']) {
      test('共享 operation 的 $outcome 结果可跨 Zone 回传到批次', () async {
        final started = Completer<void>();
        final gate = Completer<void>();
        final shared = SilentRefresh.track(
          () => AppLog.logger('test.shared').operation<void>('load', () async {
            started.complete();
            await gate.future;
            AppLog.reportOutcome(outcome, reason: 'synthetic_outcome');
          }),
        );
        await started.future;
        final batch = SilentRefresh.runAll('test.batch', {
          'shared': () => SilentRefresh.join(shared),
        });
        gate.complete();
        expect(await batch, outcome == 'degraded');
        final completed = records.singleWhere(
          (record) => record['event'] == 'refresh.batch_completed',
        );
        expect(
          (completed['attrs'] as Map)[outcome == 'skipped'
              ? 'skipped_count'
              : 'partial_failure_count'],
          1,
        );
        expect((completed['attrs'] as Map)['success_count'], 0);
      });
    }

    test('重试共享业务 Trace，最终耗时包含退避并保留重试原因', () async {
      var calls = 0;
      final spans = <String?>[];
      final succeeded = await SilentRefresh.run(
        'test.retry_diagnostics',
        action: () async {
          spans.add(AppLog.currentSpanId);
          calls++;
          if (calls == 1) throw TimeoutException('合成超时');
        },
        delays: const [Duration(milliseconds: 20)],
      );
      expect(succeeded, isTrue);
      final retry = records.singleWhere(
        (r) => r['event'] == 'refresh.retrying',
      );
      final completed = records.singleWhere(
        (r) => r['event'] == 'refresh.completed',
      );
      final retryAttrs = retry['attrs'] as Map;
      final completedAttrs = completed['attrs'] as Map;
      expect(retry['trace_id'], isNotNull);
      expect(completed['trace_id'], retry['trace_id']);
      expect(spans.toSet(), hasLength(2));
      expect(spans, everyElement(isNotNull));
      expect(retryAttrs['wait_ms'], 20);
      expect(retryAttrs['retryable'], isTrue);
      expect(retryAttrs['error_type'], 'TimeoutException');
      expect(completedAttrs['retry_count'], 1);
      expect(completedAttrs['duration_ms'], greaterThanOrEqualTo(20));
    });

    test('模块吞掉已记录的失败时，批次仍汇总为失败', () async {
      final succeeded = await SilentRefresh.runAll('test.batch', {
        'scores': () async {
          await SilentRefresh.run(
            'test.module',
            action: () async => throw const PortalNetworkError('合成断网'),
            delays: const [],
          );
        },
      });
      expect(succeeded, isFalse);
      final batch = records.singleWhere(
        (r) => r['event'] == 'refresh.batch_completed',
      );
      expect((batch['attrs'] as Map)['failure_count'], 1);
      expect((batch['attrs'] as Map)['outcome'], 'failure');
      expect(
        records.where(
          (r) =>
              r['scope'] == 'test.batch' && r['event'] == 'refresh.completed',
        ),
        isEmpty,
      );
    });

    test('失效结果不记成功，不发已更新提示', () async {
      final before = SilentRefresh.updated.value;
      final succeeded = await SilentRefresh.run(
        'test.stale',
        action: () async {
          SilentRefresh.skipCurrent();
        },
        userInitiated: true,
      );
      expect(succeeded, isFalse);
      expect(SilentRefresh.updated.value, before);
      expect(records.where((r) => r['event'] == 'refresh.completed'), isEmpty);
      expect(records.last['event'], 'refresh.skipped');
    });

    test('缓存保存降级仍可用，但完成事件明确标注降级', () async {
      final succeeded = await SilentRefresh.run(
        'test.degraded',
        action: () async {
          SilentRefresh.degradeCurrent();
        },
      );
      expect(succeeded, isTrue);
      expect(records.last['level'], 'WARNING');
      expect((records.last['attrs'] as Map)['outcome'], 'degraded');
    });
  });

  group('网络失败判定', () {
    test('门户网络错误与超时可重试，业务异常不可重试', () {
      expect(
        SilentRefresh.isNetworkFailure(const PortalNetworkError('断网')),
        isTrue,
      );
      expect(SilentRefresh.isNetworkFailure(TimeoutException('超时')), isTrue);
      expect(SilentRefresh.isNetworkFailure(StateError('合成刷新失败')), isFalse);
      expect(
        SilentRefresh.isNetworkFailure(const PortalCredentialError('凭据失效')),
        isFalse,
      );
      expect(
        SilentRefresh.isNetworkFailure(
          PortalCredentialError('凭据失效', cause: TimeoutException('合成底层错误')),
        ),
        isFalse,
        reason: '明确的凭据判定优先，不能因保留了底层错误而自动重试',
      );
    });

    test('DioException 按类型区分，unknown 会看 inner error', () {
      final options = RequestOptions(path: '/synthetic');
      expect(
        SilentRefresh.isNetworkFailure(
          DioException(
            requestOptions: options,
            type: DioExceptionType.connectionTimeout,
          ),
        ),
        isTrue,
      );
      expect(
        SilentRefresh.isNetworkFailure(
          DioException(
            requestOptions: options,
            type: DioExceptionType.badResponse,
          ),
        ),
        isFalse,
      );
      expect(
        SilentRefresh.isNetworkFailure(
          DioException(
            requestOptions: options,
            type: DioExceptionType.unknown,
            error: TimeoutException('超时'),
          ),
        ),
        isTrue,
      );
    });
  });

  group('静默刷新', () {
    test('成功时按用户主动刷新触发一次「已更新」', () async {
      final before = SilentRefresh.updated.value;
      var calls = 0;
      final ok = await SilentRefresh.run(
        'test.silent_refresh',
        action: () async => calls++,
        userInitiated: true,
      );
      expect(ok, isTrue);
      expect(calls, 1);
      expect(SilentRefresh.updated.value, before + 1);
    });

    test('自动刷新成功不触发提示计数', () async {
      final before = SilentRefresh.updated.value;
      final ok = await SilentRefresh.run(
        'test.silent_refresh',
        action: () async {},
      );
      expect(ok, isTrue);
      expect(SilentRefresh.updated.value, before);
    });

    test('网络类失败重试耗尽后返回 false 且不抛出', () async {
      var calls = 0;
      final ok = await SilentRefresh.run(
        'test.silent_refresh',
        action: () async {
          calls++;
          throw const PortalNetworkError('合成网络失败');
        },
        delays: const [Duration.zero, Duration.zero],
      );
      expect(ok, isFalse);
      expect(calls, 3, reason: '首次 + 两次重试');
    });

    test('重试成功后返回 true，不把失败抛给调用方', () async {
      var calls = 0;
      final ok = await SilentRefresh.run(
        'test.silent_refresh',
        action: () async {
          calls++;
          if (calls < 2) throw const PortalNetworkError('合成网络失败');
        },
        delays: const [Duration.zero],
      );
      expect(ok, isTrue);
      expect(calls, 2);
    });

    test('非网络类失败默认原样抛出，便于提示重新绑定', () async {
      var calls = 0;
      await expectLater(
        SilentRefresh.run(
          'test.silent_refresh',
          action: () async {
            calls++;
            throw const PortalCredentialError('凭据失效');
          },
          delays: const [Duration.zero],
        ),
        throwsA(isA<PortalCredentialError>()),
      );
      expect(calls, 1, reason: '凭据类失败不重试');
    });

    test('批量刷新不因单个模块抛错中断，且批量层不再统一提示', () async {
      final before = SilentRefresh.updated.value;
      var second = 0;
      final ok = await SilentRefresh.runAll('test.silent_refresh', {
        'broken': () async => throw StateError('合成刷新失败'),
        'healthy': () async => second++,
      });
      expect(ok, isTrue);
      expect(second, 1);
      // 批量层「有任一成功」不代表其他模块成功，不能据此提示「已更新」，
      // 否则失败的刷新也会被报成成功。
      expect(SilentRefresh.updated.value, before);
    });

    test('批量里各模块自己成功时各发一次提示（界面侧做去重）', () async {
      final before = SilentRefresh.updated.value;
      final ok = await SilentRefresh.runAll('test.silent_refresh', {
        'a': () => SilentRefresh.run(
          'test.silent_refresh',
          action: () async {},
          userInitiated: true,
        ),
        'b': () => SilentRefresh.run(
          'test.silent_refresh',
          action: () async {},
          userInitiated: true,
        ),
      });
      expect(ok, isTrue);
      expect(SilentRefresh.updated.value, before + 2);
    });

    test('批量刷新全部失败时返回 false 且不提示', () async {
      final before = SilentRefresh.updated.value;
      final ok = await SilentRefresh.runAll('test.silent_refresh', {
        'broken': () async => throw StateError('合成刷新失败'),
      });
      expect(ok, isFalse);
      expect(SilentRefresh.updated.value, before);
    });
  });
}
