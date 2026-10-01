import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'vpn_log.dart';

/// 单次请求是否必须经过校园 VPN；只用于本地选路，不会发送给服务器。
const forceVpnKey = 'forceVpn';

/// 校园网检测结果。未知时使用 VPN，不通过实际业务请求试探网络。
enum CampusNetworkState { unknown, onCampus, offCampus }

/// 可注入的校园网检测器；具体检测策略由调用方提供。
typedef CampusNetworkDetector = Future<CampusNetworkState> Function();

/// 将目标地址连接到校园隧道，返回可取消的普通 TCP 字节流。
abstract interface class VpnConnector {
  /// 域名应在隧道内解析，HTTPS 仍由调用方对原始主机进行 TLS 校验。
  Future<ConnectionTask<Socket>> connect(Uri uri);
}

/// Dio 的校园网络适配器，分别持有直连与 VPN 的 HTTP 连接池。
class VpnHttpClientAdapter implements HttpClientAdapter {
  VpnHttpClientAdapter({
    required this.connector,
    this.detectCampusNetwork,
    this.forceVpn = false,
    this.securityContext,
    this.onBadCertificate,
    HttpClient Function()? createHttpClient,
  }) : _createHttpClient = createHttpClient ?? HttpClient.new;

  final VpnConnector connector;
  final CampusNetworkDetector? detectCampusNetwork;
  final bool forceVpn;
  final SecurityContext? securityContext;
  final bool Function(X509Certificate, String, int)? onBadCertificate;
  final HttpClient Function() _createHttpClient;
  IOHttpClientAdapter? _direct;
  IOHttpClientAdapter? _vpn;
  bool _closed = false;

  /// 证书上下文更新后关闭旧连接池，保留适配器和选路配置。
  void resetClients() {
    vpnLog('重建直连与 VPN HTTP 连接池');
    _direct?.close(force: true);
    _vpn?.close(force: true);
    _direct = null;
    _vpn = null;
  }

  /// 创建使用指定出口的短期客户端，供证书补链等附属请求使用。
  HttpClient createRoutedClient({required bool useVpn}) {
    final client = _createHttpClient();
    if (useVpn) {
      client.findProxy = (_) => 'DIRECT';
      client.connectionFactory = (uri, proxyHost, proxyPort) => _connect(uri);
    }
    return client;
  }

  IOHttpClientAdapter _adapter(bool vpn) {
    if (!vpn) {
      return _direct ??= IOHttpClientAdapter(
        createHttpClient: _createHttpClient,
      );
    }
    return _vpn ??= IOHttpClientAdapter(
      createHttpClient: () => createRoutedClient(useVpn: true),
    );
  }

  Future<ConnectionTask<Socket>> _connect(Uri uri) async {
    final task = await connector.connect(uri);
    var cancelled = false;
    Socket? active;
    final socket = task.socket.then<Socket>((raw) async {
      active = raw;
      if (cancelled) {
        raw.destroy();
        throw const SocketException('VPN 连接已取消');
      }
      if (uri.scheme != 'https') return raw;
      try {
        // 自定义 connectionFactory 时 HttpClient 不会自动执行 TLS 握手。
        final secure = await SecureSocket.secure(
          raw,
          host: uri.host,
          context: securityContext,
          onBadCertificate: (certificate) =>
              onBadCertificate?.call(certificate, uri.host, uri.port) ?? false,
        );
        active = secure;
        vpnLog('目标 TLS 校验通过：${uri.host}:${uri.port}');
        if (cancelled) {
          secure.destroy();
          throw const SocketException('VPN 连接已取消');
        }
        return secure;
      } catch (error) {
        vpnLog('目标 TLS 建连失败：${vpnErrorKind(error)}');
        raw.destroy();
        rethrow;
      }
    });
    return ConnectionTask.fromSocket(socket, () {
      cancelled = true;
      task.cancel();
      active?.destroy();
    });
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_closed) throw StateError('VPN 客户端已关闭');
    if (!['http', 'https'].contains(options.uri.scheme)) {
      throw ArgumentError('vpnDio 仅支持 HTTP 和 HTTPS');
    }
    final override = options.extra[forceVpnKey];
    if (override != null && override is! bool) {
      throw ArgumentError.value(override, forceVpnKey, '必须是 bool');
    }
    var cancelled = false;
    final aborted = Completer<bool>();
    if (cancelFuture != null) {
      unawaited(
        cancelFuture.then((_) {
          cancelled = true;
          if (!aborted.isCompleted) aborted.complete(true);
        }),
      );
    }
    final mustUseVpn = override as bool? ?? forceVpn;
    final selection = mustUseVpn ? Future.value(true) : _selectRoute();
    final useVpn = await Future.any([selection, aborted.future]).timeout(
      options.connectTimeout ?? const Duration(seconds: 30),
      onTimeout: () => throw DioException.connectionTimeout(
        requestOptions: options,
        timeout: options.connectTimeout ?? const Duration(seconds: 30),
      ),
    );
    if (cancelled) {
      throw DioException.requestCancelled(
        requestOptions: options,
        reason: '请求已取消',
      );
    }
    if (_closed) throw StateError('VPN 客户端已关闭');
    // 选路只执行一次，发送失败不切换出口，也不重放请求体。
    options.extra['vpnDio.usedVpn'] = useVpn;
    // 只输出主机和端口，路径、查询参数及请求内容均可能含个人数据。
    vpnLog(
      '选路=${useVpn ? "VPN" : "直连"}，强制=$mustUseVpn，'
      '目标=${options.uri.host}:${options.uri.port}',
    );
    try {
      final response = await _adapter(useVpn)
          .fetch(options, requestStream, cancelFuture);
      vpnLog('请求完成：HTTP ${response.statusCode}');
      return response;
    } catch (error) {
      vpnLog('请求失败：${vpnErrorKind(error)}');
      rethrow;
    }
  }

  Future<bool> _selectRoute() async {
    final detector = detectCampusNetwork;
    if (detector == null) return true;
    return await detector() != CampusNetworkState.onCampus;
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    _direct?.close(force: force);
    _vpn?.close(force: force);
  }
}
