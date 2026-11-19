import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import '../logging/app_log.dart';
import 'vpn_auth.dart';
import 'vpn_http_adapter.dart';
import 'vpn_log.dart';
import 'vpn_native.dart';

/// 所有 vpnDio 共享的校园 VPN 会话；首次请求才加载原生库和登录。
class VpnGateway implements VpnPreparedConnector {
  static final _log = AppLog.logger('core.network.vpn');
  VpnGateway({
    VpnNative? native,
    VpnAuth? auth,
    this.startTimeout = const Duration(seconds: 60),
    this.controlTimeout = const Duration(seconds: 3),
    this.recoveryTimeout = const Duration(seconds: 12),
    this.recoveryPollInterval = const Duration(milliseconds: 200),
    this.failureBackoffBase = const Duration(seconds: 2),
    this.failureBackoffMax = const Duration(seconds: 30),
    this.stableSessionDuration = const Duration(seconds: 30),
  }) : _native = native ?? const VpnNative(),
       _auth = auth ?? VpnAuth();

  static final instance = VpnGateway();

  /// 后续接入校园网检测；未配置时 unknown 按 VPN 处理。
  static CampusNetworkDetector? campusNetworkDetector;

  final VpnNative _native;
  final VpnAuth _auth;

  /// 包含凭据、认证与原生握手的整体期限。
  final Duration startTimeout;

  /// 状态查询和清理不能阻塞恢复流程。
  final Duration controlTimeout;

  /// 原生线程恢复探测期间复用同一等待任务，避免每位请求立即重建隧道。
  final Duration recoveryTimeout;
  final Duration recoveryPollInterval;

  /// 连续失败采用有上限的退避，网络变化、解绑与成功后重新计数。
  final Duration failureBackoffBase;
  final Duration failureBackoffMax;

  /// 连续正常存活达到此期限后，清除不稳定连接的退避计数。
  final Duration stableSessionDuration;
  int? _id;
  @override
  int? get sessionId => _id;
  int _generation = 0;
  int _attemptSequence = 0;
  _VpnAttempt? _pending;
  Future<void>? _resetting;
  Timer? _monitor;
  bool _foreground = true;
  bool _observing = false;
  Future<Map<String, dynamic>>? _probing;
  int? _probingId;
  Object? _lastFailure;
  StackTrace? _lastFailureStack;
  DateTime? _retryAfter;
  DateTime? _preparedAt;
  int _consecutiveFailures = 0;
  int _unstableSessions = 0;
  DateTime? _sessionStartedAt;
  final Queue<_OpenWaiter> _openQueue = Queue<_OpenWaiter>();
  int _openingConnections = 0;
  String? _statusSignature;
  DateTime? _statusLoggedAt;

  /// 在装入业务 Cookie 前准备隧道，避免首次请求带着 VPN 登录前的旧状态。
  @override
  Future<void> prepare() async {
    await _ensureConnected();
  }

  Future<int> _ensureConnected({bool useRecentPreparation = false}) async {
    if (_resetting case final resetting?) await resetting;
    if (_pending case final pending?) {
      pending.waiters++;
      return pending.result.future;
    }
    // 适配器已在取连接池前 prepare；随后新连接工厂可复用刚完成的检查，
    // 独立的 prepare 调用仍检查当前状态，不让缓存隐藏恢复或失败。
    if (useRecentPreparation &&
        _id != null &&
        _preparedAt != null &&
        DateTime.now().difference(_preparedAt!) <
            const Duration(milliseconds: 250)) {
      return _id!;
    }
    if (_retryAfter case final retryAfter?) {
      if (DateTime.now().isBefore(retryAfter)) {
        Error.throwWithStackTrace(
          _lastFailure!,
          _lastFailureStack ?? StackTrace.current,
        );
      }
    }
    final attempt = _VpnAttempt(_generation);
    _pending = attempt;
    attempt.timer = Timer(startTimeout, () {
      _failAttempt(
        attempt,
        const SocketException('校园 VPN 启动超时，请检查网络后重试'),
        StackTrace.current,
      );
    });
    unawaited(_runAttempt(attempt));
    return attempt.result.future;
  }

  bool _isCurrent(_VpnAttempt attempt) =>
      !attempt.result.isCompleted && attempt.generation == _generation;

  void _checkAttempt(_VpnAttempt attempt) {
    if (!_isCurrent(attempt)) throw const SocketException('VPN 会话已取消');
  }

  Future<void> _runAttempt(_VpnAttempt attempt) => attempt.span.run(() async {
    try {
      final id = await _connect(attempt);
      _checkAttempt(attempt);
      attempt.timer?.cancel();
      _lastFailure = null;
      _lastFailureStack = null;
      _retryAfter = null;
      // 刚握手成功不等于稳定；短命隧道不能每次启动都清空重建退避。
      if (_sessionStartedAt != null &&
          DateTime.now().difference(_sessionStartedAt!) >=
              stableSessionDuration) {
        _consecutiveFailures = 0;
        _unstableSessions = 0;
      }
      _preparedAt = DateTime.now();
      if (identical(_pending, attempt)) _pending = null;
      attempt.result.complete(id);
      if (attempt.number case final number?) {
        vpnLog(
          'start.completed',
          fields: {
            'attempt': number,
            'vpn_session_id': id,
            'duration_ms': attempt.watch.elapsedMilliseconds,
            'waiters': attempt.waiters,
          },
        );
      }
    } catch (error, stack) {
      _failAttempt(attempt, error, stack);
    }
  });

  void _failAttempt(_VpnAttempt attempt, Object error, StackTrace stack) =>
      attempt.span.run(() {
        if (attempt.result.isCompleted) return;
        attempt.timer?.cancel();
        if (identical(_pending, attempt)) {
          _pending = null;
          _preparedAt = null;
          _lastFailure = error;
          _lastFailureStack = stack;
          _consecutiveFailures = (_consecutiveFailures + 1).clamp(1, 6);
          final delay = failureBackoffBase * (1 << (_consecutiveFailures - 1));
          final nextRetry = DateTime.now().add(
            delay > failureBackoffMax ? failureBackoffMax : delay,
          );
          if (_retryAfter == null || nextRetry.isAfter(_retryAfter!)) {
            _retryAfter = nextRetry;
          }
          _auth.cancel();
        }
        attempt.result.completeError(error, stack);
        vpnLog(
          'start.failed',
          fields: {
            'attempt': attempt.number,
            'duration_ms': attempt.watch.elapsedMilliseconds,
            'waiters': attempt.waiters,
            'cancelled': attempt.generation != _generation,
          },
          error: error,
          stackTrace: stack,
        );
        if (attempt.nativeStartId case final startId?) {
          unawaited(_discardStart(startId));
        }
      });

  Future<Map<String, dynamic>> _control(Map<String, dynamic> request) =>
      _native.call(request).timeout(controlTimeout);

  Future<void> _discardStart(int startId) async {
    try {
      await _control({'method': 'cancelStart', 'startId': startId});
    } catch (error) {
      vpnLog(
        'start.cancel_failed',
        fields: {'native_start_id': startId},
        error: error,
      );
    }
  }

  Future<void> _stop(int id) async {
    try {
      await _control({'method': 'stop', 'id': id});
    } catch (error) {
      vpnLog(
        'tunnel.stop_failed',
        fields: {'vpn_session_id': id},
        error: error,
      );
    }
  }

  void _logStatus(int id, Map<String, dynamic> status, {bool force = false}) {
    if (_id == id && !_usable(status)) _preparedAt = null;
    final signature = [
      id,
      for (final field in [
        'alive',
        'healthy',
        'exitReason',
        'recovering',
        'dnsTimeouts',
        'tcpTimeouts',
      ])
        status[field],
    ].join('/');
    final changed = _statusSignature != null && _statusSignature != signature;
    final now = DateTime.now();
    final elapsed =
        _statusLoggedAt == null ||
        now.difference(_statusLoggedAt!) >= const Duration(minutes: 1);
    final firstAbnormal =
        _statusSignature == null &&
        (!_usable(status) || status['recovering'] == true);
    _statusSignature = signature;
    if (!force && !changed && !elapsed && !firstAbnormal) return;
    _statusLoggedAt = now;
    // 字段由原生层生成，仅包含状态、计数、耗时和错误类别。
    vpnLog(
      'tunnel.status',
      fields: {
        'vpn_session_id': id,
        'alive': status['alive'],
        'healthy': status['healthy'],
        'reason': status['exitReason'],
        'loop_idle_ms': status['loopIdleMs'],
        'rx_idle_ms': status['rxIdleMs'],
        'heartbeats': status['heartbeats'],
        'received_bytes': status['receivedBytes'],
        'recovering': status['recovering'],
        'dns_timeouts': status['dnsTimeouts'],
        'tcp_timeouts': status['tcpTimeouts'],
      },
    );
  }

  bool _usable(Map<String, dynamic> status) =>
      status['alive'] == true && status['healthy'] != false;

  bool _recovering(Map<String, dynamic> status) =>
      status['alive'] == true &&
      (status['recovering'] == true ||
          status['loopIdleMs'] is num && status['loopIdleMs'] >= 5000);

  Future<Map<String, dynamic>> _probe(int id) {
    if (_probingId == id && _probing != null) return _probing!;
    late final Future<Map<String, dynamic>> probing;
    probing = _native
        .call({
          'method': 'probe',
          'id': id,
          // 配置中已有且必需可达的校园主机，用 DNS 请求验证数据通路。
          'host': Uri.parse(VpnAuth.controller).host,
        })
        .timeout(const Duration(seconds: 5))
        .whenComplete(() {
          if (identical(_probing, probing)) _probing = null;
        });
    _probingId = id;
    return _probing = probing;
  }

  void _invalidate(int id) {
    if (_id != id) return;
    _id = null;
    _preparedAt = null;
    _monitor?.cancel();
    _statusSignature = null;
    final started = _sessionStartedAt;
    _sessionStartedAt = null;
    if (started != null &&
        DateTime.now().difference(started) < stableSessionDuration) {
      _unstableSessions = (_unstableSessions + 1).clamp(1, 6);
      if (_unstableSessions >= 2) {
        final delay = failureBackoffBase * (1 << (_unstableSessions - 2));
        _lastFailure = const SocketException('校园 VPN 连接反复中断，请稍后重试');
        _lastFailureStack = StackTrace.current;
        _retryAfter = DateTime.now().add(
          delay > failureBackoffMax ? failureBackoffMax : delay,
        );
      }
    } else if (started != null) {
      _unstableSessions = 0;
      _consecutiveFailures = 0;
    }
  }

  void _startMonitor() {
    _monitor?.cancel();
    if (!_foreground || _id == null) return;
    _monitor = Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(checkHealth());
    });
  }

  /// 后台暂停 Dart 周期查询，回前台只恢复已有隧道，不主动登录。
  Future<void> setForeground(bool foreground) async {
    _foreground = foreground;
    _startMonitor();
    if (foreground) await checkHealth();
  }

  /// 回前台及定期检查已有隧道；不主动登录，也不让诊断失败冒泡到 UI。
  Future<void> checkHealth() => _log.startSpan().run(() async {
    final id = _id;
    if (id == null || _observing) return;
    final generation = _generation;
    _observing = true;
    try {
      var status = await _control({'method': 'status', 'id': id});
      if (status['needsProbe'] == true) {
        try {
          status = await _probe(id);
        } catch (error) {
          if (_id == id && generation == _generation) {
            _invalidate(id);
            await _stop(id);
          }
          rethrow;
        }
      }
      final recovering = Stopwatch()..start();
      while (_foreground &&
          _id == id &&
          generation == _generation &&
          _recovering(status) &&
          recovering.elapsed < recoveryTimeout) {
        _logStatus(id, status);
        await Future<void>.delayed(recoveryPollInterval);
        if (!_foreground || _id != id || generation != _generation) return;
        status = await _control({'method': 'status', 'id': id});
      }
      if (_id == id && generation == _generation) {
        _logStatus(id, status);
        // 先同步发布失效标识，下一请求才能在取连接池之前丢弃旧隧道。
        // 原生恢复探测超时才释放旧隧道，下一实际请求负责合流重建。
        if (!_usable(status) &&
            (!_recovering(status) || recovering.elapsed >= recoveryTimeout)) {
          _invalidate(id);
          await _stop(id);
        }
      }
    } catch (error) {
      vpnLog(
        'tunnel.health_failed',
        fields: {'vpn_session_id': id},
        error: error,
      );
    } finally {
      _observing = false;
    }
  });

  /// 网络出口变化时作废隧道，保留门户 Cookie，下一请求重新建连。
  Future<void> networkChanged() async {
    vpnLog('tunnel.network_changed', fields: {'reason': 'network_changed'});
    _generation++;
    _cancelQueuedOpens();
    _lastFailure = null;
    _lastFailureStack = null;
    _retryAfter = null;
    _consecutiveFailures = 0;
    _unstableSessions = 0;
    _sessionStartedAt = null;
    _preparedAt = null;
    final pending = _pending;
    if (pending != null) {
      _failAttempt(
        pending,
        const SocketException('网络已变化，请重试'),
        StackTrace.current,
      );
      _lastFailure = null;
      _lastFailureStack = null;
      _retryAfter = null;
      _consecutiveFailures = 0;
      _unstableSessions = 0;
    }
    final id = _id;
    _id = null;
    _monitor?.cancel();
    if (id != null) await _stop(id);
  }

  Future<int> _connect(_VpnAttempt attempt) async {
    _checkAttempt(attempt);
    if (_id case final id?) {
      Map<String, dynamic>? status;
      try {
        status = await _control({'method': 'status', 'id': id});
        _logStatus(id, status);
      } catch (error) {
        vpnLog(
          'tunnel.status_failed',
          fields: {'vpn_session_id': id},
          error: error,
        );
      }
      _checkAttempt(attempt);
      if (status?['needsProbe'] == true) {
        try {
          status = await _probe(id);
        } catch (error) {
          vpnLog(
            'tunnel.probe_failed',
            fields: {'vpn_session_id': id},
            error: error,
          );
          status = null;
        }
        _checkAttempt(attempt);
      }
      final recovery = Stopwatch()..start();
      while (_id == id && status != null && _recovering(status)) {
        if (recovery.elapsed >= recoveryTimeout) break;
        await Future<void>.delayed(recoveryPollInterval);
        _checkAttempt(attempt);
        if (_id != id) break;
        try {
          status = await _control({'method': 'status', 'id': id});
          _logStatus(id, status);
        } catch (error) {
          vpnLog(
            'tunnel.status_failed',
            fields: {'vpn_session_id': id},
            error: error,
          );
          status = null;
          break;
        }
        _checkAttempt(attempt);
      }
      if (_id == id && status != null && _usable(status)) {
        return id;
      }
      // exitReason 由原生层生成，仅包含 io::ErrorKind，不含服务端数据。
      vpnLog(
        'tunnel.invalidated',
        fields: {
          'vpn_session_id': id,
          'reason': status?['exitReason'] ?? 'worker_stopped',
        },
      );
      _invalidate(id);
      await _stop(id);
      _checkAttempt(attempt);
      if (_retryAfter != null && DateTime.now().isBefore(_retryAfter!)) {
        Error.throwWithStackTrace(_lastFailure!, _lastFailureStack!);
      }
    }
    attempt.number = ++_attemptSequence;
    vpnLog(
      'start.started',
      fields: {
        'attempt': attempt.number,
        'timeout_ms': startTimeout.inMilliseconds,
      },
    );
    await _control({'method': 'version'});
    _checkAttempt(attempt);
    vpnLog('start.native_ready', fields: {'attempt': attempt.number});
    final credentials = await vpnStage(
      'vpn.authenticate',
      _auth.obtain,
      timeout: startTimeout,
      fields: {'attempt': attempt.number, 'service': 'vpn'},
    );
    _checkAttempt(attempt);
    vpnLog('start.authenticated', fields: {'attempt': attempt.number});
    final reservation = await _control({'method': 'prepareStart'});
    final startId = reservation['startId'] as int;
    attempt.nativeStartId = startId;
    if (!_isCurrent(attempt)) {
      await _discardStart(startId);
      _checkAttempt(attempt);
    }
    var polling = false;
    final progress = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (polling || !_isCurrent(attempt)) return;
      polling = true;
      try {
        final status = await _control({
          'method': 'startStatus',
          'startId': startId,
        });
        vpnLog(
          'start.progress',
          fields: {
            'attempt': attempt.number,
            'native_start_id': startId,
            'native_stage': vpnNativeStage(status['stage']),
            'stage_elapsed_ms': status['stageElapsedMs'],
            'duration_ms': status['elapsedMs'],
          },
        );
      } catch (_) {
        // 启动刚完成时，登记项可能已经释放。
      } finally {
        polling = false;
      }
    });
    final Map<String, dynamic> result;
    try {
      result = await _native.call({
        'method': 'start',
        'startId': startId,
        'host': credentials.host,
        'port': credentials.port,
        'user': credentials.user,
        'token': credentials.token,
      });
    } finally {
      progress.cancel();
    }
    final id = result['id'] as int;
    if (!_isCurrent(attempt)) {
      await _stop(id);
      throw const SocketException('VPN 会话已取消');
    }
    _id = id;
    _sessionStartedAt = DateTime.now();
    _statusSignature = null;
    _statusLoggedAt = DateTime.now();
    if (result['startup'] case final Map startup) {
      vpnLog(
        'start.native_completed',
        fields: {
          'attempt': attempt.number,
          'duration_ms': startup['elapsedMs'],
          ...vpnNativeTimings(startup['timings']),
        },
      );
    }
    _startMonitor();
    unawaited(_auth.register(result['virtualIp'] as String, credentials.host));
    return id;
  }

  @override
  Future<ConnectionTask<Socket>> connect(Uri uri) async {
    final log = VpnConnectionLog.current ?? VpnConnectionLog(uri);
    var cancelled = false;
    Socket? local;
    int? targetOpenId;
    int? targetSessionId;
    final cancellation = Completer<Socket>();
    final generation = _generation;
    final opening =
        () async {
          var id = await _ensureConnected(useRecentPreparation: true);
          if (cancelled || generation != _generation) {
            throw const SocketException('VPN 连接已取消');
          }
          Map<String, dynamic> result;
          try {
            result = await _open(id, uri, log, cancellation.future, generation);
          } catch (_) {
            _preparedAt = null;
            if (cancelled || generation != _generation) rethrow;
            Map<String, dynamic>? status;
            try {
              status = await _control({'method': 'status', 'id': id});
              _logStatus(id, status, force: true);
            } catch (error) {
              log.write(
                'connection.status_failed',
                fields: {'vpn_session_id': id},
                error: error,
              );
            }
            if (status != null && _usable(status)) rethrow;
            // 尚未交付 Socket、没有发送业务请求体，允许合流重建后重试一次。
            log.write('connection.retry', fields: {'vpn_session_id': id});
            id = await _ensureConnected();
            if (cancelled || generation != _generation) {
              throw const SocketException('VPN 连接已取消');
            }
            result = await _open(id, uri, log, cancellation.future, generation);
          }
          targetOpenId = result['openId'] as int?;
          targetSessionId = id;
          if (cancelled || generation != _generation) {
            throw const SocketException('VPN 连接已取消');
          }
          final socket = await Socket.connect(
            InternetAddress.loopbackIPv4,
            result['port'] as int,
            timeout: const Duration(seconds: 3),
          );
          local = socket;
          if (cancelled || generation != _generation) {
            socket.destroy();
            throw const SocketException('VPN 连接已取消');
          }
          final secret = result['secret'] as String;
          final bytes = Uint8List.fromList([
            for (var i = 0; i < secret.length; i += 2)
              int.parse(secret.substring(i, i + 2), radix: 16),
          ]);
          try {
            socket.add(bytes);
            await socket.flush();
          } catch (_) {
            socket.destroy();
            rethrow;
          } finally {
            bytes.fillRange(0, bytes.length, 0);
          }
          if (cancelled || generation != _generation) {
            socket.destroy();
            throw const SocketException('VPN 连接已取消');
          }
          log.write('tcp.ready', fields: {'vpn_session_id': id});
          if (targetOpenId != null) {
            unawaited(_releaseTarget(id, targetOpenId!, cancel: false));
            targetOpenId = null;
          }
          return socket;
        }().catchError((Object error, StackTrace stack) {
          if (targetOpenId != null && targetSessionId != null) {
            unawaited(
              _releaseTarget(targetSessionId!, targetOpenId!, cancel: true),
            );
          }
          log.write('connection.failed', error: error);
          Error.throwWithStackTrace(error, stack);
        });
    return ConnectionTask.fromSocket(
      Future.any([opening, cancellation.future]),
      () {
        log.write('connection.cancelled', fields: {'cancelled': true});
        cancelled = true;
        local?.destroy();
        if (targetOpenId != null && targetSessionId != null) {
          unawaited(
            _releaseTarget(targetSessionId!, targetOpenId!, cancel: true),
          );
        }
        if (!cancellation.isCompleted) {
          cancellation.completeError(const SocketException('VPN 连接已取消'));
        }
      },
    );
  }

  void _releaseOpen() {
    if (_openingConnections > 0) _openingConnections--;
    while (_openQueue.isNotEmpty && _openingConnections < 8) {
      final waiter = _openQueue.removeFirst();
      if (waiter.generation != _generation) {
        waiter.ready.completeError(const SocketException('VPN 连接已取消'));
        continue;
      }
      _openingConnections++;
      waiter.granted = true;
      waiter.ready.complete();
    }
  }

  Future<void> _acquireOpen(Future<Socket> cancellation, int generation) async {
    if (generation != _generation) throw const SocketException('VPN 连接已取消');
    if (_openingConnections < 8 && _openQueue.isEmpty) {
      _openingConnections++;
      return;
    }
    final waiter = _OpenWaiter(generation);
    _openQueue.addLast(waiter);
    try {
      await Future.any([waiter.ready.future, cancellation.then<void>((_) {})]);
    } catch (_) {
      if (!_openQueue.remove(waiter) && waiter.granted) {
        _releaseOpen();
      }
      rethrow;
    }
  }

  void _cancelQueuedOpens() {
    while (_openQueue.isNotEmpty) {
      _openQueue.removeFirst().ready.completeError(
        const SocketException('VPN 连接已取消'),
      );
    }
  }

  Future<Map<String, dynamic>> _open(
    int id,
    Uri uri,
    VpnConnectionLog log,
    Future<Socket> cancellation,
    int generation,
  ) async {
    await _acquireOpen(cancellation, generation);
    int? openId;
    var cancelled = false;
    var completed = false;
    unawaited(
      cancellation.then<void>(
        (_) {},
        onError: (Object _) {
          cancelled = true;
          if (!completed && openId != null) {
            unawaited(_releaseTarget(id, openId, cancel: true));
          }
        },
      ),
    );
    try {
      if (generation != _generation) throw const SocketException('VPN 连接已取消');
      final reservation = await _control({'method': 'prepareOpen', 'id': id});
      openId = reservation['openId'] as int;
      if (cancelled || generation != _generation) {
        throw const SocketException('VPN 连接已取消');
      }
      final result = await log.run(
        () => _native
            .call({
              'method': 'open',
              'id': id,
              'openId': openId,
              'host': uri.host,
              'port': uri.port,
            })
            .timeout(
              const Duration(seconds: 24),
              onTimeout: () {
                throw const SocketException('VPN 目标连接超时，请重试');
              },
            ),
      );
      if (cancelled || generation != _generation) {
        throw const SocketException('VPN 连接已取消');
      }
      completed = true;
      return {...result, 'openId': openId};
    } finally {
      if (!completed && openId != null) {
        await _releaseTarget(id, openId, cancel: true);
      }
      _releaseOpen();
    }
  }

  Future<void> _releaseTarget(
    int id,
    int openId, {
    required bool cancel,
  }) async {
    try {
      await _control({
        'method': cancel ? 'cancelOpen' : 'releaseOpen',
        'id': id,
        'openId': openId,
      });
    } catch (error) {
      vpnLog(
        'connection.cleanup_failed',
        fields: {'vpn_session_id': id},
        error: error,
      );
    }
  }

  /// 解绑或换号时关闭隧道；代次检查防止旧登录结果恢复到新会话。
  Future<void> reset() {
    if (_resetting case final resetting?) return resetting;
    _generation++;
    _cancelQueuedOpens();
    vpnLog('session.reset');
    final pending = _pending;
    final id = _id;
    _id = null;
    _monitor?.cancel();
    _lastFailure = null;
    _lastFailureStack = null;
    _retryAfter = null;
    _consecutiveFailures = 0;
    _unstableSessions = 0;
    _sessionStartedAt = null;
    _preparedAt = null;
    if (pending != null) {
      _failAttempt(
        pending,
        const SocketException('VPN 会话已取消'),
        StackTrace.current,
      );
      _lastFailure = null;
      _lastFailureStack = null;
      _retryAfter = null;
      _consecutiveFailures = 0;
      _unstableSessions = 0;
    }
    late final Future<void> resetting;
    resetting =
        () async {
          try {
            if (id != null) await _stop(id);
          } finally {
            await vpnStage('vpn.clear', _auth.clear, timeout: controlTimeout);
            vpnLog('session.cleared');
          }
        }().whenComplete(() {
          if (identical(_resetting, resetting)) _resetting = null;
        });
    return _resetting = resetting;
  }
}

class _OpenWaiter {
  _OpenWaiter(this.generation);
  final int generation;
  final ready = Completer<void>();
  bool granted = false;
}

class _VpnAttempt {
  _VpnAttempt(this.generation);
  final AppLogSpan span = VpnGateway._log.startSpan();
  int? number;
  int waiters = 1;
  final int generation;
  final watch = Stopwatch()..start();
  final result = Completer<int>();
  Timer? timer;
  int? nativeStartId;
}
