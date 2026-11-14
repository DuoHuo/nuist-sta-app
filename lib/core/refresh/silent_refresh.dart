import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../auth/portal_exceptions.dart';
import '../logging/app_log.dart';
import '../logging/diagnostic_error.dart';

/// 静默刷新的统一口径（issue #31「数据更新无感化、失败自动处理」）。
///
/// 约定：
/// - 界面不出现「更新中」动画，也不展示网络类失败的文案，失败只写诊断日志；
/// - 网络类失败按 [retryDelays] 自动重试，其他失败不重试；
/// - 网络类失败重试耗尽后不向上抛，避免各页面各写一套失败 UI；
/// - 凭据类失败（[PortalCredentialError]）仍向上抛：这类失败必须让用户重新绑定，
///   静默处理会让用户永远不知道该重新绑。
class SilentRefresh {
  const SilentRefresh._();

  static final Object _executionKey = Object();
  static final Expando<_RefreshExecution> _trackedResults = Expando();

  /// 将真实刷新结果绑定到共享 Future，不依赖发起者是否位于批次 Zone。
  static Future<T> track<T>(Future<T> Function() action) {
    final execution = _RefreshExecution();
    final future = runZoned(() async {
      try {
        return await AppLog.captureOutcome<T>(
          action,
          onOutcome: (outcome, reason) =>
              execution.include(outcome, reason: reason),
        );
      } catch (_) {
        execution.include('failure');
        rethrow;
      }
    }, zoneValues: {_executionKey: execution});
    _trackedResults[future] = execution;
    return future;
  }

  /// 将在途任务最终结果回传给当前等待者，原样返回 Future 以保持刷新合流。
  static Future<T> join<T>(Future<T> future) {
    final parent = Zone.current[_executionKey] as _RefreshExecution?;
    final execution = _trackedResults[future];
    if (parent != null && execution != null && !identical(parent, execution)) {
      // 先登记结果回传，再由调用者 await；不会吞掉原 Future 的异常。
      unawaited(
        future.then<void>(
          (_) => parent.include(execution.outcome, reason: execution.reason),
          onError: (Object _, StackTrace _) => parent.include('failure'),
        ),
      );
    }
    return future;
  }

  /// 当前刷新已失效或不再需要执行；正常返回也不能再被记录为成功。
  static void skipCurrent({String reason = 'superseded'}) {
    final execution = Zone.current[_executionKey] as _RefreshExecution?;
    execution?.outcome = 'skipped';
    execution?.reason = reason;
  }

  /// 数据仍可使用，但缓存或可选步骤未完成。
  static void degradeCurrent({String reason = 'cache_write_failed'}) {
    final execution = Zone.current[_executionKey] as _RefreshExecution?;
    execution?.outcome = 'degraded';
    execution?.reason = reason;
  }

  /// 控制器已处理失败时，把真实结果回传给外层批量刷新。
  static void failCurrent({String reason = 'child_operation_failed'}) {
    final execution = Zone.current[_executionKey] as _RefreshExecution?;
    execution?.outcome = 'failure';
    execution?.reason = reason;
  }

  /// 每次重试前的等待时间，长度即最多重试次数（1s、3s 指数退避）。
  static const List<Duration> retryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 3),
  ];

  /// 「用户主动刷新成功」的计数，壳层监听后弹一次「已更新」轻提示。
  ///
  /// 只有用户主动触发的刷新（点卡片刷新、下拉刷新）才会加一；自动刷新（首次
  /// 进入、门户绑定变化、回到前台）全程静默，不加计数。
  static final ValueNotifier<int> updated = ValueNotifier<int>(0);

  /// 记一次用户主动刷新的成功，供壳层提示。
  static void notifyUpdated() => updated.value++;

  /// 判断失败是否属于「可安全重试」的网络层失败：超时、连不上、连接被重置。
  ///
  /// 只看错误类型不看文案；[DioException] 会带上 inner error，逐层判断（最多 3 层）。
  static bool isNetworkFailure(Object error, [int depth = 0]) {
    if (error is PortalNetworkError) return true;
    if (error is PortalCredentialError || error is PortalLoginError) {
      return false;
    }
    if (error is TimeoutException || error is SocketException) return true;
    if (error is DiagnosticError && depth < 3 && error.cause != null) {
      return isNetworkFailure(error.cause!, depth + 1);
    }
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.connectionError:
          return true;
        case DioExceptionType.unknown:
          final inner = error.error;
          return depth < 3 &&
              inner != null &&
              isNetworkFailure(inner, depth + 1);
        default:
          return false;
      }
    }
    return false;
  }

  /// 在 [scope] 下静默执行一次刷新 [action]。
  ///
  /// 网络类失败按 [delays]（默认 [retryDelays]）自动重试并在每次重试前记 DEBUG；重试耗尽返回
  /// false 并记 WARNING。非网络类失败记 WARNING 后原样抛出，由调用方决定是否
  /// 提示用户（例如凭据失效）。成功记 INFO，带尝试次数与耗时。
  static Future<bool> run(
    String scope, {
    required Future<void> Function() action,
    Map<String, Object?> fields = const {},
    bool userInitiated = false,
    bool rethrowNonNetwork = true,
    List<Duration> delays = retryDelays,
    String? trigger,
  }) => AppLog.logger(scope).startSpan().run(() async {
    final log = AppLog.logger(scope);
    final parent = Zone.current[_executionKey] as _RefreshExecution?;
    final totalWatch = Stopwatch()..start();
    final common = <String, Object?>{
      ...fields,
      'trigger': trigger ?? (userInitiated ? 'manual' : 'automatic'),
    };
    log.debug('refresh.started', fields: common);
    for (var attempt = 1; ; attempt++) {
      final watch = Stopwatch()..start();
      final execution = _RefreshExecution();
      try {
        await log.startSpan().run(
          () => runZoned(action, zoneValues: {_executionKey: execution}),
        );
        watch.stop();
        final outcome = execution.outcome;
        AppLog.reportOutcome(outcome, reason: execution.reason);
        parent?.include(outcome);
        final resultFields = {
          ...common,
          'attempt': attempt,
          'retry_count': attempt - 1,
          'duration_ms': totalWatch.elapsedMilliseconds,
          'attempt_duration_ms': watch.elapsedMilliseconds,
          'outcome': outcome,
          if (execution.reason != null) 'reason': execution.reason,
        };
        if (outcome == 'failure' || outcome == 'degraded') {
          log.warning(
            outcome == 'failure' ? 'refresh.failed' : 'refresh.completed',
            fields: resultFields,
          );
        } else if (outcome == 'skipped') {
          log.debug('refresh.skipped', fields: resultFields);
        } else {
          log.info('refresh.completed', fields: resultFields);
        }
        // 成功必须让用户看到（issue #31：不展示过程、不展示失败，只展示成功）。
        final succeeded = outcome == 'success' || outcome == 'degraded';
        if (userInitiated && succeeded) notifyUpdated();
        return succeeded;
      } catch (error, stackTrace) {
        watch.stop();
        final network = isNetworkFailure(error);
        if (network && attempt <= delays.length) {
          final wait = delays[attempt - 1];
          log.debug(
            'refresh.retrying',
            fields: {
              ...common,
              'attempt': attempt,
              'wait_ms': wait.inMilliseconds,
              'attempt_duration_ms': watch.elapsedMilliseconds,
              'duration_ms': totalWatch.elapsedMilliseconds,
              'retryable': true,
            },
            error: error,
            stackTrace: stackTrace,
          );
          await Future<void>.delayed(wait);
          continue;
        }
        parent?.include('failure');
        AppLog.reportOutcome('failure');
        log.warning(
          'refresh.failed',
          fields: {
            ...common,
            'attempt': attempt,
            'retry_count': attempt - 1,
            'duration_ms': totalWatch.elapsedMilliseconds,
            'attempt_duration_ms': watch.elapsedMilliseconds,
            'retryable': network,
            'outcome': 'failure',
          },
          error: error,
          stackTrace: stackTrace,
        );
        if (network || !rethrowNonNetwork) return false;
        rethrow;
      }
    }
  });

  /// 并发跑一批刷新任务，各自静默、互不影响，返回是否有任一模块成功。
  ///
  /// 用于首页与学习页的下拉刷新：壳只负责并发调度与日志，不感知各模块的
  /// 业务状态；「已更新」提示由各模块自己的 [run] 在成功时发出。
  /// [tasks] 的键是模块 id，进日志字段便于定位失败来源。
  static Future<bool> runAll(
    String scope,
    Map<String, Future<void> Function()> tasks,
  ) => AppLog.logger(scope).startSpan().run(() async {
    final log = AppLog.logger(scope);
    final watch = Stopwatch()..start();
    final results = await Future.wait([
      for (final entry in tasks.entries)
        log.startSpan().run(() async {
          final execution = _RefreshExecution();
          for (var attempt = 1; ; attempt++) {
            try {
              await runZoned(
                () => AppLog.captureOutcome<void>(
                  entry.value,
                  onOutcome: (outcome, reason) =>
                      execution.include(outcome, reason: reason),
                ),
                zoneValues: {_executionKey: execution},
              );
              break;
            } catch (error, stackTrace) {
              // 未使用模块刷新包装的回调仍保留原有网络重试。
              if (isNetworkFailure(error) && attempt <= retryDelays.length) {
                final wait = retryDelays[attempt - 1];
                log.debug(
                  'refresh.dispatch_retrying',
                  fields: {
                    'app_id': entry.key,
                    'attempt': attempt,
                    'wait_ms': wait.inMilliseconds,
                    'retryable': true,
                  },
                  error: error,
                  stackTrace: stackTrace,
                );
                await Future<void>.delayed(wait);
                execution.outcome = 'success';
                execution.reason = null;
                continue;
              }
              // 内层刷新已经记录根因时，壳仅汇总，避免重复异常。
              if (execution.outcome != 'failure') {
                log.warning(
                  'refresh.dispatch_failed',
                  fields: {
                    'app_id': entry.key,
                    'attempt': attempt,
                    'outcome': 'failure',
                  },
                  error: error,
                  stackTrace: stackTrace,
                );
              }
              execution.outcome = 'failure';
              break;
            }
          }
          return execution.outcome;
        }),
    ]);
    final successCount = results.where((value) => value == 'success').length;
    final degradedCount = results.where((value) => value == 'degraded').length;
    final failureCount = results.where((value) => value == 'failure').length;
    final fields = {
      'count': tasks.length,
      'success_count': successCount,
      'failure_count': failureCount,
      'partial_failure_count': degradedCount,
      'skipped_count': results.where((value) => value == 'skipped').length,
      'duration_ms': watch.elapsedMilliseconds,
      'outcome': failureCount == tasks.length && failureCount > 0
          ? 'failure'
          : failureCount > 0 || degradedCount > 0
          ? 'partial'
          : successCount == 0
          ? 'skipped'
          : 'success',
    };
    if (failureCount > 0 || degradedCount > 0) {
      log.warning('refresh.batch_completed', fields: fields);
    } else {
      log.info('refresh.batch_completed', fields: fields);
    }
    // 成功提示由 [run] 在每次真正成功时发出：批量并发时「有任一成功」不代表
    // 其他模块也成功，这里不能再统一提示，否则会把失败的刷新也报成「已更新」。
    return successCount + degradedCount > 0;
  });
}

class _RefreshExecution {
  String outcome = 'success';
  String? reason;

  void include(String child, {String? reason}) {
    child = switch (child) {
      'failed' || 'error' || 'rejected' => 'failure',
      'partial' => 'degraded',
      'cancelled' || 'stale' => 'skipped',
      _ => child,
    };
    if (child == 'failure' || outcome == 'failure') {
      outcome = 'failure';
      this.reason = reason ?? 'child_operation_failed';
    } else if (child == 'degraded' || outcome == 'degraded') {
      outcome = 'degraded';
      this.reason = reason ?? this.reason;
    } else if (child == 'skipped') {
      outcome = 'skipped';
      this.reason = reason ?? this.reason;
    }
  }
}
