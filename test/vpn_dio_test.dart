import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/auth/aia_trust.dart';
import 'package:nuist_sta_app/core/auth/portal_http.dart';
import 'package:nuist_sta_app/core/auth/portal_exceptions.dart';
import 'package:nuist_sta_app/core/auth/portal_cookie_manager.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:nuist_sta_app/core/logging/app_log.dart';
import 'package:nuist_sta_app/core/network/vpn_dio.dart';
import 'package:nuist_sta_app/core/network/vpn_auth.dart';
import 'package:nuist_sta_app/core/network/vpn_gateway.dart';
import 'package:nuist_sta_app/core/network/vpn_http_adapter.dart';
import 'package:nuist_sta_app/core/network/vpn_log.dart';
import 'package:nuist_sta_app/core/network/vpn_native.dart';
import 'package:nuist_sta_app/core/network/vpn_spa.dart';

class LocalConnector implements VpnConnector {
  int connections = 0;
  bool fail = false;

  @override
  Future<ConnectionTask<Socket>> connect(Uri uri) {
    connections++;
    if (fail) throw const SocketException('模拟 VPN 连接失败');
    return Socket.startConnect(InternetAddress.loopbackIPv4, uri.port);
  }
}

class LocalSessionConnector extends LocalConnector
    implements VpnSessionConnector {
  @override
  int? sessionId = 1;
}

class FakeNative extends VpnNative {
  FakeNative(this.port);
  final int port;
  int starts = 0;
  int opens = 0;
  final stopped = <int>[];
  final starting = Completer<void>();
  final startGate = Completer<void>();
  int _startSequence = 0;
  bool healthy = true;
  bool failOpenOnce = false;

  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> request) async {
    switch (request['method']) {
      case 'version':
        return {'abi': 1};
      case 'prepareStart':
        return {'startId': ++_startSequence};
      case 'cancelStart':
        return {};
      case 'startStatus':
        return {'stage': '测试握手'};
      case 'start':
        final id = ++starts;
        if (!starting.isCompleted) starting.complete();
        await startGate.future;
        healthy = true;
        return {'id': id, 'virtualIp': '10.0.0.2'};
      case 'status':
        return {'alive': !stopped.contains(request['id']), 'healthy': healthy};
      case 'stop':
        stopped.add(request['id'] as int);
        return {};
      case 'open':
        opens++;
        if (failOpenOnce) {
          failOpenOnce = false;
          healthy = false;
          throw const SocketException('模拟隧道在目标建连期间失效');
        }
        return {'port': port, 'secret': '00' * 32};
      default:
        throw StateError('未知测试操作');
    }
  }
}

class FakeAuth extends VpnAuth {
  int logins = 0;
  final clearing = Completer<void>();
  Completer<void>? clearGate;
  Completer<void>? obtainGate;

  @override
  Future<VpnCredentials> obtain() async {
    logins++;
    await obtainGate?.future;
    return const VpnCredentials(
      host: 'campus.test',
      port: 443,
      user: 'synthetic',
      token: 'test-token',
    );
  }

  @override
  Future<void> register(String virtualIp, String gateway) async {}

  @override
  Future<void> clear() async {
    if (!clearing.isCompleted) clearing.complete();
    await clearGate?.future;
  }
}

List<int> pem(String label, List<int> bytes) => utf8.encode(
  '-----BEGIN $label-----\n${base64Encode(bytes)}\n-----END $label-----\n',
);

void main() {
  late HttpServer server;
  late LocalConnector connector;
  late Dio client;
  late Uri url;
  late int requests;
  late int responseStatus;
  late List<Map<String, Object?>> logRecords;

  setUp(() async {
    logRecords = [];
    AppLog.recordListenerForTesting = logRecords.add;
    requests = 0;
    responseStatus = 200;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      final body = await request.fold<List<int>>([], (a, b) => a..addAll(b));
      request.response.headers.contentType = ContentType.json;
      request.response.statusCode = responseStatus;
      request.response.write(
        jsonEncode({
          'method': request.method,
          'body': utf8.decode(body),
          'host': request.headers.host,
          'forceVpn': request.headers.value('forceVpn'),
        }),
      );
      await request.response.close();
    });
    url = Uri.parse('http://127.0.0.1:${server.port}/');
    connector = LocalConnector();
    client = vpnDio(connector: connector);
  });

  tearDown(() async {
    AppLog.recordListenerForTesting = null;
    client.close(force: true);
    await server.close(force: true);
  });

  test('未知环境使用 VPN，保留 JSON、表单与下载语义', () async {
    final json = await client.postUri<Map<String, dynamic>>(
      url,
      data: {'message': '校园'},
    );
    expect(json.data!['body'], '{"message":"校园"}');
    final form = await client.postUri<Map<String, dynamic>>(
      url,
      data: FormData.fromMap({'token': 'synthetic'}),
    );
    expect(form.data!['body'], contains('name="token"'));
    expect(form.data!['body'], contains('synthetic'));
    final dir = await Directory.systemTemp.createTemp('vpn-dio-');
    try {
      final path = '${dir.path}/response.json';
      await client.downloadUri(url, path);
      expect(jsonDecode(await File(path).readAsString())['method'], 'GET');
    } finally {
      await dir.delete(recursive: true);
    }
    expect(connector.connections, greaterThan(0));
  });

  test('VPN 日志能独立输出且不泄露 URL 路径、参数和请求体', () async {
    final messages = <String>[];
    await client.postUri(
      url.replace(path: '/private-student', query: 'ticket=secret-ticket'),
      data: {'token': 'secret-token'},
    );
    final requests = logRecords
        .where((record) => record['scope'] == 'core.network.vpn')
        .where((record) => '${record['event']}'.startsWith('http.'))
        .toList();
    expect(requests, hasLength(2));
    final completed = requests.last;
    final attrs = (completed['attrs'] as Map).cast<String, Object?>();
    expect(completed['event'], 'http.completed');
    expect(attrs['route'], 'VPN');
    expect(attrs['status_code'], 200);
    expect(attrs['request_id'], (requests.first['attrs'] as Map)['request_id']);
    final logs = jsonEncode(logRecords);
    for (final secret in ['private-student', 'secret-ticket', 'secret-token']) {
      expect(logs, isNot(contains(secret)));
    }
    messages.clear();
    final previousLogger = portalLogger;
    portalLogger = messages.add;
    try {
      client.interceptors.add(PortalCookieManager(CookieJar()));
      await PortalHttp(client).get(
        url.replace(path: '/private-student', query: 'ticket=secret-ticket'),
      );
      final portalLogs = messages.join('\n');
      expect(portalLogs, isEmpty);
      expect(jsonEncode(logRecords), isNot(contains('private-student')));
      expect(jsonEncode(logRecords), isNot(contains('secret-ticket')));
    } finally {
      portalLogger = previousLogger;
    }
  });

  test('并发请求日志能按编号对应，重用 RequestOptions 也分配新编号', () async {
    client.interceptors.add(PortalCookieManager(CookieJar()));
    await Future.wait([
      client.getUri(url),
      client.postUri(url, data: 'synthetic'),
    ]);
    final starts = logRecords
        .where((record) => record['event'] == 'http.started')
        .toList();
    expect(starts, hasLength(2));
    final ids = {
      for (final start in starts) (start['attrs'] as Map)['request_id'],
    };
    expect(ids, hasLength(2));
    for (final id in ids) {
      final lines = logRecords
          .where((record) => (record['attrs'] as Map?)?['request_id'] == id)
          .toList();
      expect(lines, hasLength(2));
      expect(lines.last['event'], 'http.completed');
      expect((lines.last['attrs'] as Map)['status_code'], 200);
      expect((lines.last['attrs'] as Map)['preparation_ms'], isA<int>());
    }
    logRecords.clear();
    final options = RequestOptions(path: url.toString());
    await client.fetch<dynamic>(options);
    await client.fetch<dynamic>(options);
    final reused = logRecords
        .where((record) => record['event'] == 'http.started')
        .toList();
    expect(reused, hasLength(2));
    expect(
      (reused.first['attrs'] as Map)['request_id'],
      isNot((reused.last['attrs'] as Map)['request_id']),
    );
  });

  test('403 与 500 保留状态码，传输失败只输出一次请求结果', () async {
    final messages = <String>[];
    final previousLogger = portalLogger;
    portalLogger = messages.add;
    try {
      client.interceptors.add(PortalCookieManager(CookieJar()));
      responseStatus = 403;
      expect((await PortalHttp(client).get(url)).statusCode, 403);
      expect(
        logRecords.where(
          (record) =>
              record['event'] == 'http.completed' &&
              (record['attrs'] as Map)['status_code'] == 403,
        ),
        hasLength(1),
      );
      messages.clear();
      logRecords.clear();
      responseStatus = 500;
      await expectLater(
        PortalHttp(client).get(url),
        throwsA(isA<PortalLoginError>()),
      );
      expect(
        logRecords.where(
          (record) =>
              record['event'] == 'http.failed' &&
              (record['attrs'] as Map)['status_code'] == 500,
        ),
        hasLength(1),
      );
      messages.clear();
      logRecords.clear();
      connector.fail = true;
      (client.httpClientAdapter as VpnHttpClientAdapter).resetClients();
      await expectLater(
        PortalHttp(client).get(url),
        throwsA(isA<PortalNetworkError>()),
      );
      final requestLines = logRecords
          .where((record) => '${record['event']}'.startsWith('http.'))
          .toList();
      expect(requestLines, hasLength(2));
      expect(requestLines.last['event'], 'http.failed');
      expect(
        (requestLines.last['attrs'] as Map)['error_kind'],
        'connection_error',
      );
    } finally {
      portalLogger = previousLogger;
    }
  });

  test('内部快速步骤不刷屏，等待与超时仍可定位且不展开异常', () async {
    await vpnStage('快速步骤', () async {});
    expect(logRecords, isEmpty);
    final gate = Completer<void>();
    final waiting = vpnStage('测试等待', () => gate.future);
    await Future<void>.delayed(const Duration(milliseconds: 5050));
    expect(logRecords.single['event'], 'stage.waiting');
    gate.complete();
    await waiting;
    expect(logRecords.last['event'], 'stage.completed');
    expect(
      (logRecords.first['attrs'] as Map)['stage_id'],
      (logRecords.last['attrs'] as Map)['stage_id'],
    );
    logRecords.clear();
    final rejected = expectLater(
      vpnStage(
        '测试超时',
        () => Completer<void>().future,
        timeout: const Duration(milliseconds: 10),
      ),
      throwsA(isA<TimeoutException>()),
    );
    await rejected;
    expect(logRecords.single['event'], 'stage.failed');
    expect((logRecords.single['attrs'] as Map)['error_kind'], 'timeout');
  });

  test('直连与强制 VPN 的连接池隔离，单次参数不影响其他请求', () async {
    client.close(force: true);
    client = vpnDio(
      connector: connector,
      detectCampusNetwork: () async => CampusNetworkState.onCampus,
    );
    await client.getUri(url);
    expect(connector.connections, 0);
    final forced = await client.getUri<Map<String, dynamic>>(
      url,
      options: Options(extra: {forceVpnKey: true}),
    );
    expect(connector.connections, 1);
    expect(forced.data!['forceVpn'], isNull);
    await client.getUri(url);
    expect(connector.connections, 1);
    (client.httpClientAdapter as VpnHttpClientAdapter).resetClients();
    await client.getUri(url, options: Options(extra: {forceVpnKey: true}));
    expect(connector.connections, 2);
  });

  test('客户端强制参数可覆盖，强制模式不执行校园网检测', () async {
    client.close(force: true);
    var detections = 0;
    client = vpnDio(
      connector: connector,
      forceVpn: true,
      detectCampusNetwork: () async {
        detections++;
        return CampusNetworkState.onCampus;
      },
    );
    await client.getUri(url);
    expect(detections, 0);
    expect(connector.connections, 1);
    await client.getUri(url, options: Options(extra: {forceVpnKey: false}));
    expect(detections, 1);
    expect(connector.connections, 1);
  });

  test('隧道变化后同一客户端丢弃旧连接池并重新建连', () async {
    client.close(force: true);
    final session = LocalSessionConnector();
    client = vpnDio(connector: session, forceVpn: true);
    await client.getUri(url);
    expect(session.connections, 1);
    session.sessionId = 2;
    await client.getUri(url);
    expect(session.connections, 2);
    expect(requests, 2);
  });

  test('强制 VPN 失败不直连、不重放 POST', () async {
    connector.fail = true;
    await expectLater(
      client.postUri(
        url,
        data: '不得重放',
        options: Options(extra: {forceVpnKey: true}),
      ),
      throwsA(isA<DioException>()),
    );
    expect(requests, 0);
    expect(connector.connections, 1);
  });

  test('校园网检测等待期间取消请求不会建立连接', () async {
    client.close(force: true);
    final detector = Completer<CampusNetworkState>();
    client = vpnDio(
      connector: connector,
      detectCampusNetwork: () => detector.future,
    );
    final token = CancelToken();
    final request = client.getUri(url, cancelToken: token);
    await Future<void>.delayed(Duration.zero);
    token.cancel();
    await expectLater(
      request,
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    detector.complete(CampusNetworkState.offCampus);
    await Future<void>.delayed(Duration.zero);
    expect(connector.connections, 0);
  });

  test('VPN 内层 HTTPS 对原始域名校验证书，拒绝错误证书', () async {
    // 仅限本地测试的合成证书和私钥，不对应任何真实服务。
    final certificate = await File('test/fixtures/vpn/certificate.der')
        .readAsBytes();
    final key = await File('test/fixtures/vpn/private_key.der').readAsBytes();
    final serverContext = SecurityContext()
      ..useCertificateChainBytes(pem('CERTIFICATE', certificate))
      ..usePrivateKeyBytes(pem('PRIVATE KEY', key));
    final https = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    https.listen((request) async {
      request.response.write(request.headers.host);
      await request.response.close();
    }, onError: (_) {});
    final trust = AiaTrust(withTrustedRoots: false);
    trust.context.setTrustedCertificatesBytes(pem('CERTIFICATE', certificate));
    final secureClient = vpnDio(
      connector: connector,
      securityContext: trust.context,
      onBadCertificate: trust.onBadCertificate,
    );
    try {
      final response = await secureClient.get<String>(
        'https://campus.test:${https.port}/',
      );
      expect(response.data, 'campus.test');
      await expectLater(
        PortalHttp(secureClient)
            .get(Uri.parse('https://wrong.test:${https.port}/')),
        throwsA(isA<PortalNetworkError>()),
      );
    } finally {
      secureClient.close(force: true);
      await https.close(force: true);
    }
  });

  test('SPA 与 Python PoC 的固定向量一致', () {
    final encoded = VpnSpa.encode(
      '202512340001',
      salt: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
      timestamp: 1700000000,
      randomValue: '1043321819600133',
    );
    expect(
      ascii.decode(encoded),
      '8BAgMEBQYHCP+okvuIjojwJJtyRtVHdFsa7VNrRHNUnv1POq3fPGbt1mhnRIF7dsBRLDWoWA914s7ddaXLtfkLKZ/DmJENWKy93v10iYs0iVIIqmmHrOGEi1WWrxGvG/ODTu7t4O0QL4pAZd03C4zRP/BjOEMoRh0CJeTC03PK1vzs4gVyAr6jx45g5ru8sxrtHkNfTfz3vs',
    );
  });

  test('重置会话丢弃旧握手，新请求等待 Cookie 清理后重新登录', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    listener.listen((socket) {
      sockets.add(socket);
      socket.listen((_) {});
    });
    final native = FakeNative(listener.port);
    final auth = FakeAuth()..clearGate = Completer<void>();
    final gateway = VpnGateway(native: native, auth: auth);
    try {
      final old = await gateway.connect(Uri.parse('https://campus.test'));
      final rejected = expectLater(old.socket, throwsA(isA<SocketException>()));
      await native.starting.future;
      final reset = gateway.reset();
      final fresh = await gateway.connect(Uri.parse('https://campus.test'));
      native.startGate.complete();
      await rejected;
      await auth.clearing.future;
      await Future<void>.delayed(Duration.zero);
      expect(native.stopped, [1]);
      expect(native.starts, 1);
      auth.clearGate!.complete();
      await reset;
      final socket = await fresh.socket;
      expect(native.starts, 2);
      expect(auth.logins, 2);
      expect(native.opens, 1);
      socket.destroy();
    } finally {
      await gateway.reset();
      for (final socket in sockets) {
        socket.destroy();
      }
      await listener.close();
    }
  });

  test('并发请求共享登录，取消一个请求不会取消其他请求的隧道', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    listener.listen((socket) {
      sockets.add(socket);
      socket.listen((_) {});
    });
    final native = FakeNative(listener.port);
    final auth = FakeAuth();
    final gateway = VpnGateway(native: native, auth: auth);
    try {
      final cancelled = await gateway.connect(Uri.parse('https://campus.test'));
      final rejected = expectLater(
        cancelled.socket,
        throwsA(isA<SocketException>()),
      );
      final retained = await gateway.connect(Uri.parse('https://campus.test'));
      await native.starting.future;
      cancelled.cancel();
      await rejected;
      native.startGate.complete();
      final socket = await retained.socket;
      expect(auth.logins, 1);
      expect(native.starts, 1);
      expect(native.opens, 1);
      expect(native.stopped, isEmpty);
      socket.destroy();
    } finally {
      await gateway.reset();
      for (final socket in sockets) {
        socket.destroy();
      }
      await listener.close();
    }
  });

  test('真实 Rust ABI 可加载且拒绝不完整配置', () async {
    final native = VpnNative();
    expect((await native.call({'method': 'version'}))['abi'], 1);
    await expectLater(
      native.call({'method': 'start'}),
      throwsA(isA<SocketException>()),
    );
  }, skip: const String.fromEnvironment('VPN_NATIVE_LIBRARY').isEmpty);

  test('共享启动超时释放所有等待者，reset 不等待卡住的认证，迟到结果不启动隧道', () async {
    final native = FakeNative(0);
    final auth = FakeAuth()..obtainGate = Completer<void>();
    final gateway = VpnGateway(
      native: native,
      auth: auth,
      startTimeout: const Duration(milliseconds: 100),
    );
    final first = gateway.prepare();
    final second = gateway.prepare();
    await Future.wait([
      expectLater(first, throwsA(isA<SocketException>())),
      expectLater(second, throwsA(isA<SocketException>())),
    ]);
    expect(auth.logins, 1);
    await gateway.reset().timeout(const Duration(seconds: 1));
    auth.obtainGate!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(native.starts, 0);
    native.startGate.complete();
    await gateway.prepare();
    expect(native.starts, 1);
    await gateway.reset();
  });

  test('reset 在原生握手不返回时仍完成，迟到的隧道被关闭', () async {
    final native = FakeNative(0);
    final gateway = VpnGateway(native: native, auth: FakeAuth());
    final prepared = gateway.prepare();
    final rejected = expectLater(prepared, throwsA(isA<SocketException>()));
    await native.starting.future;
    await gateway.reset().timeout(const Duration(seconds: 1));
    await rejected;
    expect(native.stopped, isEmpty);
    native.startGate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(native.stopped, [1]);
    await gateway.prepare();
    expect(native.starts, 2);
    await gateway.reset();
  });

  test('alive 但无进度的隧道由并发准备请求合流重建', () async {
    final native = FakeNative(0)..startGate.complete();
    final gateway = VpnGateway(native: native, auth: FakeAuth());
    await gateway.prepare();
    native.healthy = false;
    await Future.wait([
      gateway.prepare(),
      gateway.prepare(),
      gateway.prepare(),
    ]);
    expect(native.starts, 2);
    expect(native.stopped, [1]);
    await gateway.reset();
  });

  test('健康复用不增加启动编号，健康状态变化立即记录', () async {
    final native = FakeNative(0)..startGate.complete();
    final gateway = VpnGateway(native: native, auth: FakeAuth());
    try {
      await gateway.prepare();
      final first = logRecords.singleWhere(
        (record) => record['event'] == 'start.completed',
      );
      expect((first['attrs'] as Map)['attempt'], 1);
      expect((first['attrs'] as Map)['vpn_session_id'], 1);
      logRecords.clear();
      await Future.wait([gateway.prepare(), gateway.prepare()]);
      await gateway.checkHealth();
      expect(logRecords, isEmpty);
      native.healthy = false;
      await gateway.checkHealth();
      expect(logRecords.single['event'], 'tunnel.status');
      expect((logRecords.single['attrs'] as Map)['healthy'], isFalse);
      logRecords.clear();
      await gateway.checkHealth();
      expect(logRecords, isEmpty);
      await gateway.prepare();
      final second = logRecords.singleWhere(
        (record) => record['event'] == 'start.completed',
      );
      expect((second['attrs'] as Map)['attempt'], 2);
      expect(native.starts, 2);
    } finally {
      await gateway.reset();
    }
  });

  test('目标建连期间隧道失效只重建一次，尚未发送业务数据', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    listener.listen((socket) {
      sockets.add(socket);
      socket.listen((_) {});
    });
    final native = FakeNative(listener.port)..startGate.complete();
    final gateway = VpnGateway(native: native, auth: FakeAuth());
    try {
      await gateway.prepare();
      native.failOpenOnce = true;
      final task = await gateway.connect(Uri.parse('https://campus.test'));
      final socket = await task.socket;
      expect(native.starts, 2);
      expect(native.opens, 2);
      expect(native.stopped, [1]);
      socket.destroy();
    } finally {
      await gateway.reset();
      for (final socket in sockets) {
        socket.destroy();
      }
      await listener.close();
    }
  });

  test('请求准备超时归为网络错误，迟到的准备结果不能发送请求', () async {
    final gate = Completer<void>();
    client.interceptors.add(
      PortalCookieManager(
        CookieJar(),
        beforeRequest: () => gate.future,
        preparationTimeout: const Duration(milliseconds: 50),
      ),
    );
    await expectLater(
      PortalHttp(client).get(url),
      throwsA(isA<PortalNetworkError>()),
    );
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(requests, 0);
    await client.getUri(url);
    expect(requests, 1);
  });

  test('请求准备期间取消不会发送请求或影响其他客户端', () async {
    final gate = Completer<void>();
    client.interceptors.add(
      PortalCookieManager(CookieJar(), beforeRequest: () => gate.future),
    );
    final token = CancelToken();
    final request = client.getUri(url, cancelToken: token);
    final rejected = expectLater(
      request,
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    token.cancel();
    await rejected;
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(requests, 0);
  });
}
