import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'vpn_auth.dart';
import 'vpn_http_adapter.dart';
import 'vpn_log.dart';
import 'vpn_native.dart';

/// 所有 vpnDio 共享的校园 VPN 会话；首次请求才加载原生库和登录。
class VpnGateway implements VpnSessionConnector {
  VpnGateway({
    VpnNative? native,
    VpnAuth? auth,
    this.startTimeout = const Duration(seconds: 60),
    this.controlTimeout = const Duration(seconds: 3),
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
  int? _id;
  @override
  int? get sessionId => _id;
  int _generation = 0;
  int _attemptSequence = 0;
  _VpnAttempt? _pending;
  Future<void>? _resetting;
  Timer? _monitor;
  bool _observing = false;
  Object? _lastFailure;
  DateTime? _retryAfter;
  String? _statusSignature;
  DateTime? _statusLoggedAt;

  /// 在装入业务 Cookie 前准备隧道，避免首次请求带着 VPN 登录前的旧状态。
  Future<void> prepare() async {
    await _ensureConnected();
  }

  Future<int> _ensureConnected() async {
    if (_resetting case final resetting?) await resetting;
    if (_pending case final pending?) {
      pending.waiters++;
      return pending.result.future;
    }
    if (_retryAfter case final retryAfter?) {
      if (DateTime.now().isBefore(retryAfter)) {
        Error.throwWithStackTrace(_lastFailure!, StackTrace.current);
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

  Future<void> _runAttempt(_VpnAttempt attempt) async {
    try {
      final id = await _connect(attempt);
      _checkAttempt(attempt);
      attempt.timer?.cancel();
      _lastFailure = null;
      _retryAfter = null;
      if (identical(_pending, attempt)) _pending = null;
      attempt.result.complete(id);
      if (attempt.number case final number?) {
        vpnLog(
          '启动 S$number 成功 → 隧道 id=$id，'
          '耗时=${attempt.watch.elapsedMilliseconds}ms，合流请求=${attempt.waiters}'
          '（心跳 10s，接收超时 30s）',
        );
      }
    } catch (error, stack) {
      _failAttempt(attempt, error, stack);
    }
  }

  void _failAttempt(_VpnAttempt attempt, Object error, StackTrace stack) {
    if (attempt.result.isCompleted) return;
    attempt.timer?.cancel();
    if (identical(_pending, attempt)) {
      _pending = null;
      _lastFailure = error;
      _retryAfter = DateTime.now().add(const Duration(seconds: 2));
      _auth.cancel();
    }
    attempt.result.completeError(error, stack);
    vpnLog(
      '${attempt.number == null ? "隧道检查" : "启动 S${attempt.number}"} 失败，'
      '耗时=${attempt.watch.elapsedMilliseconds}ms，合流请求=${attempt.waiters}，'
      '类别=${vpnErrorKind(error)}，等待请求已释放'
      '${attempt.generation == _generation ? "，2s 后允许重试" : "，任务已作废"}',
    );
    if (attempt.nativeStartId case final startId?) {
      unawaited(_discardStart(startId));
    }
  }

  Future<Map<String, dynamic>> _control(Map<String, dynamic> request) =>
      _native.call(request).timeout(controlTimeout);

  Future<void> _discardStart(int startId) async {
    try {
      await _control({'method': 'cancelStart', 'startId': startId});
    } catch (error) {
      vpnLog('取消原生启动失败，类别=${vpnErrorKind(error)}');
    }
  }

  Future<void> _stop(int id) async {
    try {
      await _control({'method': 'stop', 'id': id});
    } catch (error) {
      vpnLog('关闭隧道 id=$id 失败，类别=${vpnErrorKind(error)}');
    }
  }

  void _logStatus(int id, Map<String, dynamic> status, {bool force = false}) {
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
      '隧道 id=$id 状态 alive=${status['alive']} healthy=${status['healthy']} '
      '原因=${status['exitReason'] ?? "无"} loopIdle=${status['loopIdleMs']}ms '
      'rxIdle=${status['rxIdleMs']}ms 心跳=${status['heartbeats']} '
      '收包=${status['receivedBytes']}B 恢复探测=${status['recovering']} '
      '目标超时 DNS=${status['dnsTimeouts']} TCP=${status['tcpTimeouts']}',
    );
  }

  bool _usable(Map<String, dynamic> status) =>
      status['alive'] == true && status['healthy'] != false;

  /// 回前台及定期检查已有隧道；不主动登录，也不让诊断失败冒泡到 UI。
  Future<void> checkHealth() async {
    final id = _id;
    if (id == null || _observing) return;
    _observing = true;
    try {
      final status = await _control({'method': 'status', 'id': id});
      if (_id == id) _logStatus(id, status);
    } catch (error) {
      vpnLog('隧道 id=$id 健康检查失败，类别=${vpnErrorKind(error)}');
    } finally {
      _observing = false;
    }
  }

  /// 网络出口变化时作废隧道，保留门户 Cookie，下一请求重新建连。
  Future<void> networkChanged() async {
    vpnLog('网络出口变化，作废已有隧道与连接任务');
    _generation++;
    _lastFailure = null;
    _retryAfter = null;
    final pending = _pending;
    if (pending != null) {
      _failAttempt(
        pending,
        const SocketException('网络已变化，请重试'),
        StackTrace.current,
      );
      _lastFailure = null;
      _retryAfter = null;
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
        vpnLog('隧道 id=$id 状态查询失败，准备重建，类别=${vpnErrorKind(error)}');
      }
      _checkAttempt(attempt);
      if (status != null && _usable(status)) {
        return id;
      }
      // exitReason 由原生层生成，仅包含 io::ErrorKind，不含服务端数据。
      vpnLog('隧道 id=$id 已失效，原因=${status?['exitReason'] ?? "线程或收包无进度"}，准备重建');
      await _stop(id);
      _checkAttempt(attempt);
      if (_id == id) _id = null;
    }
    attempt.number = ++_attemptSequence;
    vpnLog('启动 S${attempt.number} 开始，整体期限=${startTimeout.inSeconds}s');
    await _control({'method': 'version'});
    _checkAttempt(attempt);
    vpnLog('启动 S${attempt.number} 原生库可用，开始 VPN 认证');
    final credentials = await vpnStage(
      '启动 S${attempt.number} VPN 认证',
      _auth.obtain,
      timeout: startTimeout,
    );
    _checkAttempt(attempt);
    vpnLog('启动 S${attempt.number} 认证完成，开始建立 TLS 隧道');
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
          '启动 S${attempt.number} 原生阶段=${status['stage']} '
          '阶段耗时=${status['stageElapsedMs']}ms 总耗时=${status['elapsedMs']}ms',
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
    _statusSignature = null;
    _statusLoggedAt = DateTime.now();
    if (result['startup'] case final Map startup) {
      vpnLog(
        '启动 S${attempt.number} 原生阶段耗时=${startup['timings']} '
        '总耗时=${startup['elapsedMs']}ms',
      );
    }
    _monitor?.cancel();
    _monitor = Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(checkHealth());
    });
    unawaited(_auth.register(result['virtualIp'] as String, credentials.host));
    return id;
  }

  @override
  Future<ConnectionTask<Socket>> connect(Uri uri) async {
    final log = VpnConnectionLog.current ?? VpnConnectionLog(uri);
    var cancelled = false;
    Socket? local;
    final cancellation = Completer<Socket>();
    final generation = _generation;
    final opening =
        () async {
          var id = await _ensureConnected();
          if (cancelled || generation != _generation) {
            throw const SocketException('VPN 连接已取消');
          }
          Map<String, dynamic> result;
          try {
            result = await _open(id, uri, log);
          } catch (_) {
            if (cancelled || generation != _generation) rethrow;
            Map<String, dynamic>? status;
            try {
              status = await _control({'method': 'status', 'id': id});
              _logStatus(id, status, force: true);
            } catch (error) {
              log.write('目标连接失败后无法查询隧道 id=$id，类别=${vpnErrorKind(error)}');
            }
            if (status != null && _usable(status)) rethrow;
            // 尚未交付 Socket、没有发送业务请求体，允许合流重建后重试一次。
            log.write('隧道 id=$id 在目标建连期间失效，恢复后重试一次');
            id = await _ensureConnected();
            if (cancelled || generation != _generation) {
              throw const SocketException('VPN 连接已取消');
            }
            result = await _open(id, uri, log);
          }
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
          log.write('TCP/回环就绪，隧道 id=$id，耗时=${log.watch.elapsedMilliseconds}ms');
          return socket;
        }().catchError((Object error, StackTrace stack) {
          log.write('建连失败，类别=${vpnErrorKind(error)}');
          Error.throwWithStackTrace(error, stack);
        });
    return ConnectionTask.fromSocket(
      Future.any([opening, cancellation.future]),
      () {
        log.write('取消当前目标连接');
        cancelled = true;
        local?.destroy();
        if (!cancellation.isCompleted) {
          cancellation.completeError(const SocketException('VPN 连接已取消'));
        }
      },
    );
  }

  Future<Map<String, dynamic>> _open(int id, Uri uri, VpnConnectionLog log) =>
      log.run(
        () => _native
            .call({
              'method': 'open',
              'id': id,
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

  /// 解绑或换号时关闭隧道；代次检查防止旧登录结果恢复到新会话。
  Future<void> reset() {
    if (_resetting case final resetting?) return resetting;
    _generation++;
    vpnLog('重置 VPN 会话');
    final pending = _pending;
    final id = _id;
    _id = null;
    _monitor?.cancel();
    _lastFailure = null;
    _retryAfter = null;
    if (pending != null) {
      _failAttempt(
        pending,
        const SocketException('VPN 会话已取消'),
        StackTrace.current,
      );
      _lastFailure = null;
      _retryAfter = null;
    }
    late final Future<void> resetting;
    resetting =
        () async {
          try {
            if (id != null) await _stop(id);
          } finally {
            await vpnStage('清理 VPN 认证', _auth.clear, timeout: controlTimeout);
            vpnLog('VPN 认证状态已清理');
          }
        }().whenComplete(() {
          if (identical(_resetting, resetting)) _resetting = null;
        });
    return _resetting = resetting;
  }
}

class _VpnAttempt {
  _VpnAttempt(this.generation);
  int? number;
  int waiters = 1;
  final int generation;
  final watch = Stopwatch()..start();
  final result = Completer<int>();
  Timer? timer;
  int? nativeStartId;
}
