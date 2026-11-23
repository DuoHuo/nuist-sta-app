import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../auth/portal_exceptions.dart';
import 'vpn_gateway.dart';
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

/// 在取用已缓存的 HTTP 连接前确认隧道，包含合流等待原生恢复探测。
abstract interface class VpnPreparedConnector implements VpnSessionConnector {
  /// 原子返回本次请求锁定的会话，调用方不得再读取变化中的全局状态。
  Future<VpnSession> prepare();
}

/// 可按失败引擎精确作废并单飞恢复的共享连接器。
abstract interface class VpnRecoverableConnector
    implements VpnPreparedConnector {
  Future<void> invalidate(int engineId, {String reason = 'transport_failed'});
}

/// 本地代理返回的连接失败，保留代理状态码供传输层判定。
class VpnProxyException extends SocketException {
  VpnProxyException(this.statusCode) : super('校园 VPN 本地代理连接失败（$statusCode）');
  final int statusCode;
}

/// 与会话级 CONNECT 代理建连；HTTPS 保留原 Socket 供 SecureSocket 升级。
Future<ConnectionTask<Socket>> connectVpnProxy(
  VpnSession session,
  Uri uri,
) async {
  final task = await Socket.startConnect(
    InternetAddress.loopbackIPv4,
    session.proxyPort,
  );
  Socket? active;
  var cancelled = false;
  final opening = () async {
    final socket = await task.socket;
    active = socket;
    if (cancelled) {
      socket.destroy();
      throw const SocketException('VPN 连接已取消');
    }
    final authority =
        '${uri.host.contains(':') ? '[${uri.host}]' : uri.host}:${uri.port}';
    socket.write(
      'CONNECT $authority HTTP/1.1\r\nHost: $authority\r\nProxy-Authorization: Basic ${base64Encode(utf8.encode('vpn:${session.proxyToken}'))}\r\n\r\n',
    );
    await socket.flush();
    final ready = Completer<void>();
    final bytes = <int>[];
    Uint8List remainder = Uint8List(0);
    late final StreamSubscription<Uint8List> subscription;
    subscription = socket.listen(
      (chunk) {
        bytes.addAll(chunk);
        var end = -1;
        for (var i = 0; i + 3 < bytes.length; i++) {
          if (bytes[i] == 13 &&
              bytes[i + 1] == 10 &&
              bytes[i + 2] == 13 &&
              bytes[i + 3] == 10) {
            end = i + 4;
            break;
          }
        }
        if (end < 0) {
          if (bytes.length > 16384 && !ready.isCompleted) {
            ready.completeError(const SocketException('VPN 代理响应头过长'));
          }
          return;
        }
        subscription.pause();
        final first = ascii
            .decode(bytes.sublist(0, end), allowInvalid: true)
            .split('\r\n')
            .first;
        final status = int.tryParse(first.split(' ').elementAtOrNull(1) ?? '');
        remainder = Uint8List.fromList(bytes.sublist(end));
        if (status != 200) {
          ready.completeError(VpnProxyException(status ?? 502));
        } else {
          ready.complete();
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!ready.isCompleted) ready.completeError(error, stack);
      },
      onDone: () {
        if (!ready.isCompleted) {
          ready.completeError(const SocketException('VPN 代理在 CONNECT 完成前关闭连接'));
        }
      },
    );
    try {
      try {
        await ready.future.timeout(const Duration(seconds: 10));
      } on TimeoutException catch (error, stack) {
        Error.throwWithStackTrace(
          PortalNetworkError(
            '校园 VPN CONNECT 建连超时',
            code: 'vpn_proxy_connect_timeout',
            stage: 'vpn.connect',
            cause: error,
            causeStackTrace: stack,
            context: {'vpn_session_id': session.engineId, 'timeout_ms': 10000},
          ),
          stack,
        );
      }
      if (cancelled) throw const SocketException('VPN 连接已取消');
      if (uri.scheme == 'https') return socket;
      return _ConnectedProxySocket(socket, subscription, remainder);
    } catch (_) {
      socket.destroy();
      rethrow;
    }
  }();
  return ConnectionTask.fromSocket(opening, () {
    cancelled = true;
    task.cancel();
    active?.destroy();
  });
}

// HTTP 继续使用已经读取过 CONNECT 响应的订阅，保留同批返回的业务字节。
class _ConnectedProxySocket extends Stream<Uint8List> implements Socket {
  _ConnectedProxySocket(this.socket, this.subscription, Uint8List remainder) {
    stream = StreamController<Uint8List>(
      onListen: () {
        if (remainder.isNotEmpty) stream.add(remainder);
        subscription.onData(stream.add);
        subscription.onError(stream.addError);
        subscription.onDone(stream.close);
        subscription.resume();
      },
      onPause: subscription.pause,
      onResume: subscription.resume,
      onCancel: subscription.cancel,
    );
  }
  final Socket socket;
  final StreamSubscription<Uint8List> subscription;
  late final StreamController<Uint8List> stream;
  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => stream.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  void add(List<int> data) => socket.add(data);
  @override
  Future<void> addStream(Stream<List<int>> source) => socket.addStream(source);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      socket.addError(error, stackTrace);
  @override
  Encoding get encoding => socket.encoding;
  @override
  set encoding(Encoding value) => socket.encoding = value;
  @override
  Future<void> flush() => socket.flush();
  @override
  Future<void> close() async {
    await socket.close();
  }

  @override
  Future get done => socket.done;
  @override
  void destroy() => socket.destroy();
  @override
  void write(Object? object) => socket.write(object);
  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      socket.writeAll(objects, separator);
  @override
  void writeln([Object? object = '']) => socket.writeln(object);
  @override
  void writeCharCode(int charCode) => socket.writeCharCode(charCode);
  @override
  bool setOption(SocketOption option, bool enabled) =>
      socket.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => socket.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => socket.setRawOption(option);
  @override
  int get port => socket.port;
  @override
  int get remotePort => socket.remotePort;
  @override
  InternetAddress get address => socket.address;
  @override
  InternetAddress get remoteAddress => socket.remoteAddress;
}

/// 查询请求允许重放一次，写入失败只作废隧道并保留异常原因。
class VpnIdempotentRetryInterceptor extends Interceptor {
  VpnIdempotentRetryInterceptor(this.dio, this.adapter);
  final Dio dio;
  final VpnHttpClientAdapter adapter;
  static bool isIdempotent(RequestOptions options) {
    if (options.extra['idempotent'] == false) return false;
    return const {
          'GET',
          'HEAD',
          'OPTIONS',
        }.contains(options.method.toUpperCase()) ||
        options.extra['idempotent'] == true;
  }

  static bool retryable(DioException error) =>
      error.type != DioExceptionType.cancel &&
      error.error is! HandshakeException &&
      error.error is! VpnProxyException &&
      (error.error is SocketException ||
          error.error is HttpException ||
          error.type == DioExceptionType.connectionError ||
          error.type == DioExceptionType.connectionTimeout ||
          (error.error is PortalNetworkError &&
              (error.error as PortalNetworkError).code ==
                  'vpn_proxy_connect_timeout'));
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final options = err.requestOptions;
    if (options.extra['vpnDio.usedVpn'] != true ||
        options.cancelToken?.isCancelled == true ||
        !retryable(err)) {
      handler.next(err);
      return;
    }
    final failedId = options.extra['vpnDio.engineId'];
    adapter.discardVpnPool(failedId is int ? failedId : null);
    try {
      if (adapter.connector case final VpnRecoverableConnector connector) {
        if (failedId is int) await connector.invalidate(failedId);
        if (isIdempotent(options) && options.extra['_vpnReplayed'] != true) {
          options.extra['_vpnReplayed'] = true;
          if (options.cancelToken?.isCancelled == true) {
            throw options.cancelToken!.cancelError!;
          }
          final preparing = connector.prepare();
          final cancelled = options.cancelToken?.whenCancel.then<VpnSession>(
            (error) => throw error,
          );
          await (cancelled == null
              ? preparing
              : Future.any([preparing, cancelled]));
          if (options.cancelToken?.isCancelled == true) {
            throw options.cancelToken!.cancelError!;
          }
          if (options.data is FormData) {
            options.data = (options.data as FormData).clone();
          }
          final response = await dio.fetch<dynamic>(options);
          handler.resolve(response);
          return;
        }
      } else {
        handler.next(err);
        return;
      }
      handler.next(
        err.copyWith(
          error: PortalNetworkError(
            '校园 VPN 连接中断，请重试',
            code: 'vpn_transport_failed',
            stage: 'vpn.transport',
            cause: err,
            causeStackTrace: err.stackTrace,
            context: {'method': options.method, 'host': options.uri.host},
          ),
        ),
      );
    } catch (failure, stack) {
      handler.next(
        failure is DioException
            ? failure
            : DioException(
                requestOptions: options,
                error: failure,
                stackTrace: stack,
              ),
      );
    }
  }
}

/// Dio 的校园网络适配器，分别持有直连与 VPN 的 HTTP 连接池。
class VpnHttpClientAdapter implements HttpClientAdapter {
  VpnHttpClientAdapter({
    required this.connector,
    this.detectCampusNetwork,
    this.forceVpn = false,
    this.securityContext,
    this.securityContextProvider,
    this.onBadCertificate,
    HttpClient Function()? createHttpClient,
  }) : _createHttpClient = createHttpClient ?? HttpClient.new;

  final VpnConnector connector;
  final CampusNetworkDetector? detectCampusNetwork;
  final bool forceVpn;
  final SecurityContext? securityContext;

  /// 证书缓存到期重建时取得最新上下文，不捕获过期对象。
  final SecurityContext Function()? securityContextProvider;
  final bool Function(X509Certificate, String, int)? onBadCertificate;
  final HttpClient Function() _createHttpClient;
  IOHttpClientAdapter? _direct;
  IOHttpClientAdapter? _vpn;
  bool _closed = false;
  int? _vpnSessionId;
  int? _vpnGeneration;
  bool _sessionKnown = false;

  /// 仅关闭仍引用失败引擎的连接池，迟到请求不得关闭新池。
  void discardVpnPool(int? engineId) {
    if (engineId == null || _vpnSessionId != engineId) return;
    _vpn?.close(force: true);
    _vpn = null;
  }

  /// 证书上下文更新后关闭旧连接池，保留适配器和选路配置。
  void resetClients() {
    vpnLog('clients.reset');
    _direct?.close(force: true);
    _vpn?.close(force: true);
    _direct = null;
    _vpn = null;
  }

  /// 创建使用指定出口的短期客户端，供证书补链等附属请求使用。
  HttpClient createRoutedClient({required bool useVpn, VpnSession? session}) {
    final client = _createHttpClient();
    if (useVpn) {
      client.findProxy = (_) => 'DIRECT';
      client.connectionFactory = (uri, proxyHost, proxyPort) =>
          _connect(uri, session: session);
    }
    return client;
  }

  /// TLS 预补链沿用与普通请求相同的选路策略，不试探业务接口。
  Future<HttpClient> createPreparationClient() async =>
      createRoutedClient(useVpn: forceVpn || await _selectRoute());

  IOHttpClientAdapter _adapter(bool vpn, {VpnSession? session}) {
    if (!vpn) {
      return _direct ??= IOHttpClientAdapter(
        createHttpClient: _createHttpClient,
      );
    }
    final engineId =
        session?.engineId ??
        (connector is VpnPreparedConnector
            ? null
            : connector is VpnSessionConnector
            ? (connector as VpnSessionConnector).sessionId
            : null);
    final boundSession = connector is VpnGateway ? session : null;
    if (session != null &&
        _vpnGeneration != null &&
        session.generation < _vpnGeneration!) {
      return IOHttpClientAdapter(
        createHttpClient: () =>
            createRoutedClient(useVpn: true, session: boundSession),
      );
    }
    if (engineId != null) {
      if (_sessionKnown && _vpnSessionId != engineId) {
        vpnLog('clients.session_changed');
        _vpn?.close();
        _vpn = null;
      }
      _sessionKnown = true;
      _vpnSessionId = engineId;
      if (session != null) _vpnGeneration = session.generation;
    }
    return _vpn ??= IOHttpClientAdapter(
      createHttpClient: () =>
          createRoutedClient(useVpn: true, session: boundSession),
    );
  }

  Future<ConnectionTask<Socket>> _connect(
    Uri uri, {
    VpnSession? session,
  }) async {
    final log = VpnConnectionLog(uri);
    final task = await log.run(
      () => session == null
          ? connector.connect(uri)
          : connectVpnProxy(session, uri),
    );
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
          context: securityContextProvider?.call() ?? securityContext,
          onBadCertificate: (certificate) =>
              onBadCertificate?.call(certificate, uri.host, uri.port) ?? false,
        );
        active = secure;
        log.write('tls.ready');
        if (cancelled) {
          secure.destroy();
          throw const SocketException('VPN 连接已取消');
        }
        return secure;
      } catch (error) {
        log.write('tls.failed', error: error);
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
    final log = VpnRequestLog.start(options)!;
    return log.run(() => _fetch(options, requestStream, cancelFuture, log));
  }

  Future<ResponseBody> _fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
    VpnRequestLog? log,
  ) async {
    var useVpn = false;
    var cancelled = false;
    VpnSession? session;
    try {
      options.extra.remove('vpnDio.engineId');
      options.extra.remove('vpnDio.usedVpn');
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
      // 同一次尝试只选路一次，重放仍使用校园 VPN。
      options.extra['vpnDio.usedVpn'] = useVpn;
      log?.route = useVpn ? (mustUseVpn ? 'VPN（强制）' : 'VPN') : '直连';
      if (useVpn && connector is VpnPreparedConnector) {
        final prepared = connector as VpnPreparedConnector;
        session =
            await Future.any<VpnSession>([
              prepared.prepare(),
              aborted.future.then<VpnSession>(
                (_) => throw DioException.requestCancelled(
                  requestOptions: options,
                  reason: '请求已取消',
                ),
              ),
            ]).timeout(
              options.connectTimeout ?? const Duration(seconds: 70),
              onTimeout: () => throw DioException.connectionTimeout(
                requestOptions: options,
                timeout: options.connectTimeout ?? const Duration(seconds: 70),
              ),
            );
        if (cancelled) {
          throw DioException.requestCancelled(
            requestOptions: options,
            reason: '请求已取消',
          );
        }
        if (_closed) throw StateError('VPN 客户端已关闭');
      }
      if (useVpn && session != null) {
        options.extra['vpnDio.engineId'] = session.engineId;
      } else if (useVpn &&
          connector is VpnSessionConnector &&
          connector is! VpnPreparedConnector) {
        options.extra['vpnDio.engineId'] =
            (connector as VpnSessionConnector).sessionId;
      } else {
        options.extra.remove('vpnDio.engineId');
      }
      final response = await _adapter(
        useVpn,
        session: session,
      ).fetch(options, requestStream, cancelFuture);
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
      final failure = error is DioException
          ? error
          : DioException(requestOptions: options, error: error);
      if (useVpn &&
          !cancelled &&
          VpnIdempotentRetryInterceptor.retryable(failure)) {
        final id = options.extra['vpnDio.engineId'];
        discardVpnPool(id is int ? id : null);
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
