import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/auth/aia_trust.dart';
import 'package:nuist_sta_app/core/auth/portal_http.dart';
import 'package:nuist_sta_app/core/auth/portal_exceptions.dart';
import 'package:nuist_sta_app/core/network/vpn_dio.dart';
import 'package:nuist_sta_app/core/network/vpn_auth.dart';
import 'package:nuist_sta_app/core/network/vpn_gateway.dart';
import 'package:nuist_sta_app/core/network/vpn_http_adapter.dart';
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

class FakeNative extends VpnNative {
  FakeNative(this.port);
  final int port;
  int starts = 0;
  int opens = 0;
  final stopped = <int>[];
  final starting = Completer<void>();
  final startGate = Completer<void>();

  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> request) async {
    switch (request['method']) {
      case 'version':
        return {'abi': 1};
      case 'start':
        final id = ++starts;
        if (!starting.isCompleted) starting.complete();
        await startGate.future;
        return {'id': id, 'virtualIp': '10.0.0.2'};
      case 'status':
        return {'alive': !stopped.contains(request['id'])};
      case 'stop':
        stopped.add(request['id'] as int);
        return {};
      case 'open':
        opens++;
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

  @override
  Future<VpnCredentials> obtain() async {
    logins++;
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

  setUp(() async {
    requests = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      final body = await request.fold<List<int>>([], (a, b) => a..addAll(b));
      request.response.headers.contentType = ContentType.json;
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
    final original = debugPrint;
    final messages = <String>[];
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) messages.add(message);
    };
    try {
      await client.postUri(
        url.replace(path: '/private-student', query: 'ticket=secret-ticket'),
        data: {'token': 'secret-token'},
      );
      final logs = messages.join('\n');
      expect(logs, contains('[vpn] 选路=VPN'));
      expect(logs, contains('请求完成：HTTP 200'));
      for (final secret in [
        'private-student',
        'secret-ticket',
        'secret-token',
      ]) {
        expect(logs, isNot(contains(secret)));
      }
    } finally {
      debugPrint = original;
    }
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
      '202500000000',
      salt: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
      timestamp: 1700000000,
      randomValue: '1043321819600133',
    );
    expect(
      ascii.decode(encoded),
      '8BAgMEBQYHCP+okvuIjojwJJtyRtVHdFsOE8tnP56dc7CTK4zOtqsiAdRtDLlC28U33mSXX8yqRIO3i7AkUT/VQtHLhkdlRbW4PW2CnP/E4HxtTw5b3xmMtwgMfWkLjV0Wp+8L7b6ITxqRWI9j2h4J56KYvzlmIqAWSjruQstqNLFPcX5SrgNF/Z2JjcBx3BOS1PmPvUUMjs',
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
}
