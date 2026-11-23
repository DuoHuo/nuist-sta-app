import 'dart:async';
import 'dart:io';

import '../logging/app_log.dart';
import 'vpn_auth.dart';
import 'vpn_http_adapter.dart';
import 'vpn_log.dart';
import 'vpn_native.dart';

/// 一次已建立的隧道及其本地代理凭据；凭据只保存在内存中。
class VpnSession {
  const VpnSession({
    required this.engineId,
    required this.proxyPort,
    required this.proxyToken,
    required this.establishedAt,
    required this.generation,
  });
  final int engineId;
  final int proxyPort;
  final String proxyToken;
  final DateTime establishedAt;
  final int generation;
}

/// 网关唯一状态源，所有迁移均由协调队列发布。
sealed class VpnState {
  const VpnState();
}

/// 尚未建立可用隧道。
class VpnDisconnected extends VpnState {
  const VpnDisconnected();
}

/// 共享同一次启动的等待任务。
class VpnConnecting extends VpnState {
  const VpnConnecting(this.pending, this.epoch);
  final Future<VpnSession> pending;
  final int epoch;
}

/// 可接受新连接的隧道。
class VpnReady extends VpnState {
  const VpnReady(this.session);
  final VpnSession session;
}

/// 仅排空已有流量，不再接收新连接。
class VpnDraining extends VpnState {
  const VpnDraining(this.session);
  final VpnSession session;
}

/// 所有校园客户端共享的 VPN 有限状态机；业务请求始终可立即单飞重建。
class VpnGateway implements VpnRecoverableConnector {
  VpnGateway({
    VpnNative? native,
    VpnAuth? auth,
    this.startTimeout = const Duration(seconds: 60),
    this.controlTimeout = const Duration(seconds: 3),
    this.failureBackoffBase = const Duration(seconds: 2),
    this.failureBackoffMax = const Duration(seconds: 30),
  }) : _native = native ?? const VpnNative(),
       _auth = auth ?? VpnAuth() {
    _events = _native.events.listen(
      (event) => unawaited(onNativeEvent(event)),
      onError: (Object error, StackTrace stack) =>
          vpnLog('native.events_failed', error: error, stackTrace: stack),
    );
  }
  static final instance = VpnGateway();
  static CampusNetworkDetector? campusNetworkDetector;
  final VpnNative _native;
  final VpnAuth _auth;
  final Duration startTimeout;
  final Duration controlTimeout;
  final Duration failureBackoffBase;
  final Duration failureBackoffMax;
  VpnState _state = const VpnDisconnected();

  /// 当前状态只读，调用方可据此决定是否需要前台探活。
  VpnState get state => _state;

  @override
  int? get sessionId => switch (_state) {
    VpnReady(:final session) || VpnDraining(:final session) => session.engineId,
    _ => null,
  };
  Future<void> _coordinator = Future.value();
  late final StreamSubscription<Map<String, dynamic>> _events;
  int _epoch = 0;
  int _generation = 0;
  final Map<int, Map<String, dynamic>> _earlyTerminalEvents = {};
  _StartAttempt? _attempt;
  int _failures = 0;
  DateTime? _backgroundAfter;
  Timer? _backgroundRetry;
  bool _foreground = true;
  Future<void>? _probePending;
  int? _probeEngine;

  Future<T> _enqueue<T>(FutureOr<T> Function() operation) {
    final result = _coordinator.then((_) => operation());
    _coordinator = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  @override
  Future<VpnSession> prepare() => ensureReady();

  /// 同一启动共享结果，后台退避不会阻挡用户或业务主动请求。
  Future<VpnSession> ensureReady({bool userInitiated = true}) async {
    final wait = await _enqueue(() async {
      if (_state case VpnReady(:final session)) {
        return _SessionWait(Future.value(session));
      }
      if (_state case VpnConnecting(:final pending)) {
        return _SessionWait(pending);
      }
      if (!userInitiated &&
          _backgroundAfter != null &&
          DateTime.now().isBefore(_backgroundAfter!)) {
        throw const SocketException('校园 VPN 后台重连正在退避');
      }
      if (_state is VpnDraining) {
        _state = const VpnDisconnected();
        // 旧引擎自行在一秒内排空，不能截断已经交付的响应尾字节。
      }
      _backgroundRetry?.cancel();
      final attempt = _StartAttempt(++_epoch, userInitiated);
      _attempt = attempt;
      _state = VpnConnecting(attempt.result.future, attempt.epoch);
      attempt.timer = Timer(
        startTimeout,
        () => unawaited(
          _enqueue(
            () => _fail(
              attempt,
              const SocketException('校园 VPN 启动超时，请检查网络后重试'),
              StackTrace.current,
            ),
          ),
        ),
      );
      unawaited(_start(attempt));
      return _SessionWait(attempt.result.future);
    });
    return wait.pending;
  }

  bool _current(_StartAttempt attempt) =>
      identical(_attempt, attempt) &&
      !attempt.result.isCompleted &&
      _epoch == attempt.epoch;
  void _check(_StartAttempt attempt) {
    if (!_current(attempt)) throw const SocketException('VPN 会话已取消');
  }

  Future<Map<String, dynamic>> _control(Map<String, dynamic> command) =>
      _native.call(command).timeout(controlTimeout);

  Future<void> _start(_StartAttempt attempt) => attempt.span.run(() async {
    int? engineId;
    var published = false;
    try {
      vpnLog('start.started', fields: {'attempt': attempt.epoch});
      await _control({'method': 'version'});
      _check(attempt);
      final credentials = await _auth.obtain();
      _check(attempt);
      final reserved = await _control({'method': 'prepareStart'});
      attempt.startId = reserved['startId'] as int;
      _check(attempt);
      final result = await _native.call({
        'method': 'start',
        'startId': attempt.startId,
        'host': credentials.host,
        'port': credentials.port,
        'user': credentials.user,
        'token': credentials.token,
        'probeHost': Uri.parse(VpnAuth.controller).host,
      });
      engineId = result['engineId'] as int;
      final session = VpnSession(
        engineId: engineId,
        proxyPort: result['proxyPort'] as int,
        proxyToken: result['proxyToken'] as String,
        establishedAt: DateTime.now(),
        generation: _generation + 1,
      );
      final accepted = await _enqueue(() {
        if (!_current(attempt)) return false;
        final terminal = _earlyTerminalEvents.remove(engineId);
        if (terminal != null) {
          final failure = VpnNativeException.fromResponse({
            'error': 'VPN 引擎在启动完成前退出',
            'diagnostic': terminal['diagnostic'],
          }, method: 'start');
          _fail(attempt, failure, StackTrace.current);
          return false;
        }
        _earlyTerminalEvents.clear();
        _generation = session.generation;
        attempt.timer?.cancel();
        _state = VpnReady(session);
        _attempt = null;
        // TLS 握手及虚拟地址首帧已经完成，不惩罚短命会话自身的重建。
        _failures = 0;
        _backgroundAfter = null;
        attempt.result.complete(session);
        vpnLog(
          'start.completed',
          fields: {'attempt': attempt.epoch, 'vpn_session_id': engineId},
        );
        return true;
      });
      if (!accepted) {
        await _stop(engineId);
        return;
      }
      published = true;
      if (result['virtualIp'] case final String virtualIp) {
        unawaited(_auth.register(virtualIp, credentials.host));
      }
    } catch (error, stack) {
      if (engineId != null) await _stop(engineId);
      await _enqueue(() => _fail(attempt, error, stack));
    } finally {
      if (!published && !_current(attempt) && attempt.startId != null) {
        try {
          await _control({'method': 'cancelStart', 'startId': attempt.startId});
        } catch (error, stack) {
          vpnLog('start.cleanup_failed', error: error, stackTrace: stack);
        }
      }
    }
  });

  void _fail(_StartAttempt attempt, Object error, StackTrace stack) {
    if (!_current(attempt)) return;
    attempt.timer?.cancel();
    _attempt = null;
    _state = const VpnDisconnected();
    _auth.cancel();
    _failures = (_failures + 1).clamp(1, 6);
    final delay = failureBackoffBase * (1 << (_failures - 1));
    _backgroundAfter = DateTime.now().add(
      delay > failureBackoffMax ? failureBackoffMax : delay,
    );
    attempt.result.completeError(error, stack);
    vpnLog(
      'start.failed',
      error: error,
      stackTrace: stack,
      fields: {'attempt': attempt.epoch},
    );
    if (attempt.startId != null) unawaited(_cancelStart(attempt.startId!));
    if (!attempt.userInitiated) _scheduleBackground();
  }

  Future<void> _cancelStart(int startId) async {
    try {
      await _control({'method': 'cancelStart', 'startId': startId});
    } catch (error, stack) {
      vpnLog('start.cancel_failed', error: error, stackTrace: stack);
    }
  }

  Future<void> _stop(int id) async {
    try {
      await _control({'method': 'stop', 'id': id});
    } catch (error, stack) {
      vpnLog(
        'tunnel.stop_failed',
        fields: {'vpn_session_id': id},
        error: error,
        stackTrace: stack,
      );
    }
  }

  /// 仅作废失败请求实际使用的引擎，迟到异常不能掐断新隧道。
  @override
  Future<void> invalidate(int engineId, {String reason = 'transport_failed'}) =>
      _enqueue(() async {
        if (sessionId != engineId) return;
        _state = const VpnDisconnected();
        vpnLog(
          'tunnel.invalidated',
          fields: {'vpn_session_id': engineId, 'reason': reason},
        );
        await _stop(engineId);
      });

  /// 原生状态主动推送，排空与恢复健康分别处理，不进行 Dart 轮询。
  Future<void> onNativeEvent(Map<String, dynamic> event) => _enqueue(() async {
    final id = event['engineId'];
    if (id is! int) return;
    final probingAfterStall =
        event['event'] == 'unhealthy' && event['reason'] == 'scheduler_stall';
    if (_state is VpnConnecting &&
        !probingAfterStall &&
        const {'exited', 'unhealthy', 'draining'}.contains(event['event'])) {
      _earlyTerminalEvents[id] = event;
      return;
    }
    if (id != sessionId) return;
    vpnLog(
      'tunnel.status',
      fields: {
        'vpn_session_id': id,
        'reason': event['reason'],
        'event': event['event'],
        if (event['diagnostic'] case final Map diagnostic)
          'details': {'native_diagnostic': diagnostic},
      },
    );
    switch (event['event']) {
      case 'draining':
        if (_state case VpnReady(:final session)) _state = VpnDraining(session);
      case 'healthy':
        _failures = 0;
        _backgroundAfter = null;
      case 'unhealthy':
        // 原生已启动受控 DNS 探活，由 healthy/exited 决定恢复或退出。
        if (probingAfterStall) return;
        _state = const VpnDisconnected();
        await _stop(id);
        _scheduleBackground();
      case 'exited':
        _state = const VpnDisconnected();
        await _stop(id);
        _scheduleBackground();
    }
  });

  void _scheduleBackground() {
    _backgroundRetry?.cancel();
    if (!_foreground) return;
    final remaining =
        _backgroundAfter?.difference(DateTime.now()) ?? failureBackoffBase;
    _backgroundRetry = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () {
        unawaited(
          ensureReady(userInitiated: false).then<void>(
            (_) {},
            onError: (Object error, StackTrace stack) {
              vpnLog(
                'background.reconnect_failed',
                error: error,
                stackTrace: stack,
              );
            },
          ),
        );
      },
    );
  }

  /// 网络切换时探测已有会话，正在建立的会话由其自身超时管理，避免重复取消。
  Future<void> networkChanged() async {
    final selected = await _enqueue(() {
      _backgroundAfter = null;
      return _state;
    });
    if (selected is VpnReady) {
      await checkHealth();
    } else if (selected is VpnConnecting) {
      try {
        final connected = await selected.pending;
        if (_state case VpnReady(:final session)
            when session.engineId == connected.engineId) {
          await checkHealth();
        }
      } catch (error, stack) {
        vpnLog('network.prepare_failed', error: error, stackTrace: stack);
      }
    }
  }

  /// 回前台仅探活已有隧道；inactive 不应调用本方法暂停后台行为。
  Future<void> setForeground(bool foreground) =>
      _enqueue(() {
        _foreground = foreground;
        if (!foreground) _backgroundRetry?.cancel();
      }).then((_) async {
        if (foreground && _state is VpnReady) await checkHealth();
      });

  /// 轻量 DNS 探活最多两秒，同一引擎的并发检查共享任务。
  Future<void> checkHealth() async {
    final selected = await _enqueue(() => _state);
    if (selected is! VpnReady) return;
    final id = selected.session.engineId;
    if (_probeEngine == id && _probePending != null) return _probePending;
    _probeEngine = id;
    late final Future<void> pending;
    pending =
        () async {
          try {
            final status = await _native
                .call({
                  'method': 'probe',
                  'id': id,
                  'host': Uri.parse(VpnAuth.controller).host,
                  'timeoutMs': 2000,
                })
                .timeout(const Duration(milliseconds: 2500));
            if (status['healthy'] == false ||
                status['alive'] == false ||
                status['draining'] == true) {
              await invalidate(id, reason: 'probe_failed');
            }
          } catch (error, stack) {
            await invalidate(id, reason: 'probe_failed');
            vpnLog(
              'tunnel.probe_failed',
              fields: {'vpn_session_id': id},
              error: error,
              stackTrace: stack,
            );
          }
        }().whenComplete(() {
          if (identical(_probePending, pending)) _probePending = null;
        });
    return _probePending = pending;
  }

  /// CONNECT 完成后返回原始字节流，HTTPS 校验由适配器完成。
  @override
  Future<ConnectionTask<Socket>> connect(Uri uri) async =>
      connectVpnProxy(await ensureReady(), uri);

  /// 断网立即取消共享启动并停旧引擎，保留账号和 Cookie。
  Future<void> disconnected() => _reset(clearBackoff: false);

  /// 解绑或换号停止隧道，不写回控制器空 Cookie 域。
  Future<void> reset() => _reset(clearBackoff: true);
  Future<void> _reset({required bool clearBackoff}) => _enqueue(() async {
    _epoch++;
    _backgroundRetry?.cancel();
    final id = sessionId;
    final attempt = _attempt;
    _attempt = null;
    _earlyTerminalEvents.clear();
    _state = const VpnDisconnected();
    _auth.cancel();
    if (attempt != null && !attempt.result.isCompleted) {
      attempt.timer?.cancel();
      attempt.result.completeError(const SocketException('VPN 会话已取消'));
      if (attempt.startId != null) unawaited(_cancelStart(attempt.startId!));
    }
    if (clearBackoff) {
      _failures = 0;
      _backgroundAfter = null;
    }
    if (id != null) await _stop(id);
  });

  /// 测试及独立网关销毁时释放事件订阅和后台任务。
  Future<void> dispose() async {
    await reset();
    await _events.cancel();
  }
}

class _SessionWait {
  const _SessionWait(this.pending);
  final Future<VpnSession> pending;
}

class _StartAttempt {
  _StartAttempt(this.epoch, this.userInitiated);
  final int epoch;
  final bool userInitiated;
  final result = Completer<VpnSession>();
  final span = AppLog.logger('core.network.vpn').startSpan();
  Timer? timer;
  int? startId;
}
