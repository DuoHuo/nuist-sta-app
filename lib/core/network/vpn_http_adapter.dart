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

/// 共享隧道的标识，用于作废仍引用旧隧道的 HTTP 连接池。
abstract interface class VpnSessionConnector implements VpnConnector {
  /// 当前已建立的隧道；尚未建立或已作废时为空。
  int? get sessionId;
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
  int? _vpnSessionId;
  bool _sessionKnown = false;

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
    if (connector case final VpnSessionConnector session) {
      if (_sessionKnown && _vpnSessionId != session.sessionId) {
        vpnLog('隧道已变化，关闭旧 VPN HTTP 连接池');
        _vpn?.close(force: true);
        _vpn = null;
      }
      _sessionKnown = true;
      _vpnSessionId = session.sessionId;
    }
    return _vpn ??= IOHttpClientAdapter(
      createHttpClient: () => createRoutedClient(useVpn: true),
    );
  }

  Future<ConnectionTask<Socket>> _connect(Uri uri) async {
    final log = VpnConnectionLog(uri);
    final task = await log.run(() => connector.connect(uri));
    var cancelled = false;
    Socket? active;
    final socket = task.socket.then<Socket>((raw) async {
      if (connector case final VpnSessionConnector session) {
        _vpnSessionId = session.sessionId;
      }
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
        log.write('TLS 就绪，耗时=${log.watch.elapsedMilliseconds}ms');
        if (cancelled) {
          secure.destroy();
          throw const SocketException('VPN 连接已取消');
        }
        return secure;
      } catch (error) {
        log.write('TLS 建连失败，类别=${vpnErrorKind(error)}');
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
    final log = VpnRequestLog.start(options);
    var useVpn = false;
    var cancelled = false;
    try {
      log?.route = '选路中';
      if (_closed) throw StateError('VPN 客户端已关闭');
      if (!['http', 'https'].contains(options.uri.scheme)) {
        throw ArgumentError('vpnDio 仅支持 HTTP 和 HTTPS');
      }
      final override = options.extra[forceVpnKey];
      if (override != null && override is! bool) {
        throw ArgumentError.value(override, forceVpnKey, '必须是 bool');
      }
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
      useVpn = await Future.any([selection, aborted.future]).timeout(
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
      log?.route = useVpn ? (mustUseVpn ? 'VPN（强制）' : 'VPN') : '直连';
      final response = await _adapter(useVpn)
          .fetch(options, requestStream, cancelFuture);
      if (log?.managedByInterceptor == false) {
        log?.complete(
          response.statusCode,
          options.uri,
          response.headers[HttpHeaders.locationHeader]?.firstOrNull,
        );
      }
      return response;
    } catch (error) {
      if (log?.managedByInterceptor == false) {
        log?.fail(
          error,
          status: error is DioException ? error.response?.statusCode : null,
        );
      }
      if (useVpn &&
          !cancelled &&
          !(error is DioException && error.type == DioExceptionType.cancel)) {
        // 不重放本次请求；下一次请求必须重新经过连接工厂检查隧道。
        _vpn?.close();
        _vpn = null;
      }
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
