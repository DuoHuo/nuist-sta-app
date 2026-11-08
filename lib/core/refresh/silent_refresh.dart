import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../auth/portal_exceptions.dart';
import '../logging/app_log.dart';

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
    if (error is TimeoutException || error is SocketException) return true;
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
  }) async {
    final log = AppLog.logger(scope);
    for (var attempt = 1; ; attempt++) {
      final watch = Stopwatch()..start();
      try {
        await action();
        watch.stop();
        log.info(
          'refresh.completed',
          fields: {
            ...fields,
            'attempt': attempt,
            'duration_ms': watch.elapsedMilliseconds,
          },
        );
        // 成功必须让用户看到（issue #31：不展示过程、不展示失败，只展示成功）。
        if (userInitiated) notifyUpdated();
        return true;
      } catch (error, stackTrace) {
        watch.stop();
        final network = isNetworkFailure(error);
        if (network && attempt <= delays.length) {
          final wait = delays[attempt - 1];
          log.debug(
            'refresh.retrying',
            fields: {
              ...fields,
              'attempt': attempt,
              'wait_ms': wait.inMilliseconds,
            },
          );
          await Future<void>.delayed(wait);
          continue;
        }
        log.warning(
          'refresh.failed',
          fields: {
            ...fields,
            'attempt': attempt,
            'duration_ms': watch.elapsedMilliseconds,
            'retryable': network,
          },
          error: error,
          stackTrace: stackTrace,
        );
        if (network || !rethrowNonNetwork) return false;
        rethrow;
      }
    }
  }

  /// 并发跑一批刷新任务，各自静默、互不影响，返回是否有任一模块成功。
  ///
  /// 用于首页与学习页的下拉刷新：壳只负责并发调度与日志，不感知各模块的
  /// 业务状态；「已更新」提示由各模块自己的 [run] 在成功时发出。
  /// [tasks] 的键是模块 id，进日志字段便于定位失败来源。
  static Future<bool> runAll(
    String scope,
    Map<String, Future<void> Function()> tasks,
  ) async {
    final results = await Future.wait([
      for (final entry in tasks.entries)
        run(
          scope,
          action: entry.value,
          fields: {'app_id': entry.key},
          // 壳层不承担业务失败：任何模块抛错都只记日志，不能拖垮其他卡片。
          rethrowNonNetwork: false,
        ),
    ]);
    // 成功提示由 [run] 在每次真正成功时发出：批量并发时「有任一成功」不代表
    // 其他模块也成功，这里不能再统一提示，否则会把失败的刷新也报成「已更新」。
    return results.contains(true);
  }
}
