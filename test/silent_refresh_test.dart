import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/auth/portal_exceptions.dart';
import 'package:nuist_sta_app/core/refresh/silent_refresh.dart';

void main() {
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

    test('批量刷新不因单个模块抛错中断，并合并成一次提示', () async {
      final before = SilentRefresh.updated.value;
      var second = 0;
      final ok = await SilentRefresh.runAll('test.silent_refresh', {
        'broken': () async => throw StateError('合成刷新失败'),
        'healthy': () async => second++,
      });
      expect(ok, isTrue);
      expect(second, 1);
      expect(SilentRefresh.updated.value, before + 1);
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
