import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'vpn_auth.dart';
import 'vpn_http_adapter.dart';
import 'vpn_log.dart';
import 'vpn_native.dart';

/// 所有 vpnDio 共享的校园 VPN 会话；首次请求才加载原生库和登录。
class VpnGateway implements VpnConnector {
  VpnGateway({VpnNative? native, VpnAuth? auth})
    : _native = native ?? const VpnNative(),
      _auth = auth ?? VpnAuth();

  static final instance = VpnGateway();

  /// 后续接入校园网检测；未配置时 unknown 按 VPN 处理。
  static CampusNetworkDetector? campusNetworkDetector;

  final VpnNative _native;
  final VpnAuth _auth;
  int? _id;
  int _generation = 0;
  Future<int>? _pending;
  Future<void>? _resetting;

  Future<int> _ensureConnected() async {
    if (_resetting case final resetting?) await resetting;
    if (_pending case final pending?) {
      vpnLog('等待已有隧道连接任务');
      return pending;
    }
    late final Future<int> pending;
    pending = _connect().whenComplete(() {
      if (identical(_pending, pending)) _pending = null;
    });
    return _pending = pending;
  }

  Future<int> _connect() async {
    final generation = _generation;
    if (_id case final id?) {
      final status = await _native.call({'method': 'status', 'id': id});
      if (status['alive'] == true && generation == _generation) {
        vpnLog('复用隧道 #$id');
        return id;
      }
      // exitReason 由原生层生成，仅包含 io::ErrorKind，不含服务端数据。
      vpnLog('隧道 #$id 已断开，原因=${status['exitReason'] ?? "未知"}，准备重建');
      await _native.call({'method': 'stop', 'id': id});
      if (_id == id) _id = null;
    }
    vpnLog('检查原生库');
    await _native.call({'method': 'version'});
    vpnLog('原生库可用，开始 VPN 认证');
    final credentials = await _auth.obtain();
    if (generation != _generation) throw const SocketException('VPN 会话已取消');
    vpnLog('认证完成，开始建立 TLS 隧道');
    final result = await _native.call({
      'method': 'start',
      'host': credentials.host,
      'port': credentials.port,
      'user': credentials.user,
      'token': credentials.token,
    });
    final id = result['id'] as int;
    if (generation != _generation) {
      await _native.call({'method': 'stop', 'id': id});
      throw const SocketException('VPN 会话已取消');
    }
    _id = id;
    vpnLog('隧道 #$id 已建立（心跳 10s，接收超时 30s）');
    unawaited(_auth.register(result['virtualIp'] as String, credentials.host));
    return id;
  }

  @override
  Future<ConnectionTask<Socket>> connect(Uri uri) async {
    var cancelled = false;
    Socket? local;
    final cancellation = Completer<Socket>();
    final generation = _generation;
    final opening =
        () async {
          final id = await _ensureConnected();
          if (cancelled || generation != _generation) {
            throw const SocketException('VPN 连接已取消');
          }
          vpnLog('隧道 #$id 开始目标 DNS/TCP 建连：${uri.host}:${uri.port}');
          final result = await _native.call({
            'method': 'open',
            'id': id,
            'host': uri.host,
            'port': uri.port,
          });
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
          vpnLog('隧道 #$id 目标连接及回环鉴权数据已发送');
          return socket;
        }().catchError((Object error, StackTrace stack) {
          vpnLog('建立 VPN 连接失败：${vpnErrorKind(error)}');
          Error.throwWithStackTrace(error, stack);
        });
    return ConnectionTask.fromSocket(
      Future.any([opening, cancellation.future]),
      () {
        vpnLog('取消当前目标连接');
        cancelled = true;
        local?.destroy();
        if (!cancellation.isCompleted) {
          cancellation.completeError(const SocketException('VPN 连接已取消'));
        }
      },
    );
  }

  /// 解绑或换号时关闭隧道；代次检查防止旧登录结果恢复到新会话。
  Future<void> reset() {
    if (_resetting case final resetting?) return resetting;
    _generation++;
    vpnLog('重置 VPN 会话');
    final pending = _pending;
    final id = _id;
    _id = null;
    late final Future<void> resetting;
    resetting =
        () async {
          try {
            if (id != null) await _native.call({'method': 'stop', 'id': id});
            if (pending != null) {
              try {
                await pending;
              } catch (_) {
                /* 旧登录的错误由原请求接收。 */
              }
            }
          } finally {
            await _auth.clear();
            vpnLog('VPN 认证状态已清理');
          }
        }().whenComplete(() {
          if (identical(_resetting, resetting)) _resetting = null;
        });
    return _resetting = resetting;
  }
}
