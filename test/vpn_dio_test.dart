import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:asn1lib/asn1lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/auth/aia_trust.dart';
import 'package:nuist_sta_app/core/auth/portal_http.dart';
import 'package:nuist_sta_app/core/auth/portal_exceptions.dart';
import 'package:nuist_sta_app/core/auth/campus_transport.dart';
import 'package:nuist_sta_app/core/auth/portal_cookie_manager.dart';
import 'package:nuist_sta_app/core/logging/app_log.dart';
import 'package:nuist_sta_app/core/logging/diagnostic_error.dart';
import 'package:nuist_sta_app/core/logging/http_diagnostics.dart';
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

class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.respond);
  final Future<ResponseBody> Function(RequestOptions, Stream<Uint8List>?)
  respond;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelled,
  ) => respond(options, stream);
  @override
  void close({bool force = false}) {}
}

class _SyntheticAiaCertificate implements X509Certificate {
  _SyntheticAiaCertificate(this.der);
  @override
  final Uint8List der;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RepairCounterTrust extends AiaTrust {
  int repairs = 0;
  @override
  Future<bool> tryRepair(
    String host, {
    FutureOr<HttpClient> Function()? createFetchClient,
  }) async {
    repairs++;
    return true;
  }
}

Uint8List _aiaCertificate(
  Uint8List original, {
  String? issuerUrl,
  DateTime? expires,
}) {
  final certificate = ASN1Parser(original).nextObject() as ASN1Sequence;
  final parsed = certificate.elements.first as ASN1Sequence;
  final tbs = ASN1Sequence();
  for (final element in parsed.elements) {
    tbs.add(element);
  }
  final offset = tbs.elements.first.tag == 0xa0 ? 1 : 0;
  // 合成非自签证书的名称，仅供缓存/拒绝路径测试，不用于建立真实信任。
  tbs.elements[offset + 4] = ASN1Sequence()
    ..add(
      ASN1Set()..add(
        ASN1Sequence()
          ..add(ASN1ObjectIdentifier.fromComponentString('2.5.4.3'))
          ..add(ASN1UTF8String('Synthetic Intermediate')),
      ),
    );
  if (expires != null) {
    tbs.elements[offset + 3] = ASN1Sequence()
      ..add(ASN1UtcTime(DateTime.utc(2020)))
      ..add(ASN1UtcTime(expires));
  }
  if (issuerUrl != null) {
    final extension = ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponentString('1.3.6.1.5.5.7.1.1'))
      ..add(
        ASN1OctetString(
          (ASN1Sequence()..add(
                ASN1Sequence()
                  ..add(
                    ASN1ObjectIdentifier.fromComponentString(
                      '1.3.6.1.5.5.7.48.2',
                    ),
                  )
                  ..add(ASN1OctetString(ascii.encode(issuerUrl), tag: 0x86)),
              ))
              .encodedBytes,
        ),
      );
    tbs.add(ASN1Sequence(tag: 0xa3)..add(ASN1Sequence()..add(extension)));
  }
  return (ASN1Sequence()
        ..add(tbs)
        ..add(certificate.elements[1])
        ..add(certificate.elements[2]))
      .encodedBytes;
}

class LocalSessionConnector extends LocalConnector
    implements VpnSessionConnector {
  @override
  int? sessionId = 1;
}

VpnSession _testSession(int id) => VpnSession(
  engineId: id,
  proxyPort: 0,
  proxyToken: 'synthetic',
  establishedAt: DateTime(2026),
  generation: id,
);

class ChangingPreparedConnector extends LocalSessionConnector
    implements VpnPreparedConnector {
  @override
  Future<VpnSession> prepare() async {
    final locked = _testSession(sessionId!);
    scheduleMicrotask(() => sessionId = locked.engineId + 1);
    return locked;
  }
}

class DrainingDuringPreparationGateway extends VpnGateway {
  DrainingDuringPreparationGateway({
    required super.native,
    required super.auth,
  });
  bool first = true;
  @override
  Future<VpnSession> prepare() async {
    final locked = await super.prepare();
    if (first) {
      first = false;
      await onNativeEvent({
        'engineId': locked.engineId,
        'event': 'draining',
        'reason': 'receive_terminal',
      });
    }
    return locked;
  }
}

class PreparedLocalConnector extends LocalSessionConnector
    implements VpnPreparedConnector {
  int preparations = 0;
  @override
  Future<VpnSession> prepare() async {
    preparations++;
    if (preparations == 2) sessionId = 2;
    return _testSession(sessionId!);
  }
}

class WaitingLocalConnector extends LocalSessionConnector
    implements VpnPreparedConnector {
  final entered = Completer<void>();
  final ready = Completer<void>();
  @override
  Future<VpnSession> prepare() {
    if (!entered.isCompleted) entered.complete();
    return ready.future.then((_) => _testSession(sessionId!));
  }
}

class FakeNative extends VpnNative {
  FakeNative(this.port);
  final int port;
  final controller = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );
  @override
  Stream<Map<String, dynamic>> get events => controller.stream;
  int starts = 0;
  int probes = 0;
  int reservations = 0;
  final stopped = <int>[];
  Completer<void>? startGate;
  bool healthy = true;
  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> request) async {
    switch (request['method']) {
      case 'version':
        return {'abi': 2};
      case 'prepareStart':
        return {'startId': ++reservations};
      case 'cancelStart':
        return {};
      case 'start':
        final id = ++starts;
        await startGate?.future;
        return {
          'engineId': id,
          'proxyPort': port,
          'proxyToken': '00' * 32,
          'virtualIp': '10.0.0.2',
        };
      case 'probe':
        probes++;
        return {'alive': true, 'healthy': healthy};
      case 'stop':
        stopped.add(request['id'] as int);
        return {};
      default:
        throw StateError('未知测试操作');
    }
  }
}

class FakeAuth extends VpnAuth {
  int logins = 0;
  bool fail = false;
  Completer<void>? obtainGate;
  @override
  Future<VpnCredentials> obtain() async {
    logins++;
    await obtainGate?.future;
    if (fail) throw const SocketException('合成认证连接失败');
    return const VpnCredentials(
      host: 'campus.test',
      port: 443,
      user: 'synthetic',
      token: 'test-token',
    );
  }

  @override
  Future<void> register(String virtualIp, String gateway) async {}
}

class ConnectProxy {
  final sockets = <Socket>[];
  late HttpServer server;
  int connects = 0;
  int proxyRequests = 0;
  int? rejectOnceStatus;
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.method != 'CONNECT' ||
          request.headers.value('proxy-authorization') !=
              'Basic ${base64Encode(utf8.encode('vpn:${'00' * 32}'))}') {
        request.response.statusCode = 407;
        await request.response.close();
        return;
      }
      proxyRequests++;
      final rejection = rejectOnceStatus;
      rejectOnceStatus = null;
      if (rejection != null) {
        final rejected = await request.response.detachSocket(
          writeHeaders: false,
        );
        sockets.add(rejected);
        rejected.write(
          'HTTP/1.1 $rejection Proxy Failure\r\nContent-Length: 0\r\n\r\n',
        );
        await rejected.flush();
        rejected.destroy();
        return;
      }
      connects++;
      final port = int.parse(request.headers.value('host')!.split(':').last);
      final remote = await Socket.connect(InternetAddress.loopbackIPv4, port);
      final local = await request.response.detachSocket(writeHeaders: false);
      sockets.addAll([local, remote]);
      local.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      await local.flush();
      local.listen(
        remote.add,
        onError: (_) => remote.destroy(),
        onDone: () => remote.close(),
      );
      remote.listen(
        local.add,
        onError: (_) => local.destroy(),
        onDone: () => local.close(),
      );
    });
  }

  Future<void> close() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await server.close(force: true);
  }
}

class RecoverableLocalConnector extends LocalSessionConnector
    implements VpnRecoverableConnector {
  final invalidated = <int>[];
  Completer<void>? replayGate;
  Completer<void>? replayEntered;
  @override
  Future<VpnSession> prepare() async {
    sessionId ??= invalidated.length + 1;
    if (invalidated.isNotEmpty && replayGate != null) {
      if (replayEntered?.isCompleted == false) replayEntered!.complete();
      await replayGate!.future;
    }
    return _testSession(sessionId!);
  }

  @override
  Future<void> invalidate(
    int engineId, {
    String reason = 'transport_failed',
  }) async {
    invalidated.add(engineId);
    if (sessionId == engineId) sessionId = null;
  }
}

List<int> pem(String label, List<int> bytes) => utf8.encode(
  '-----BEGIN $label-----\n${base64Encode(bytes)}\n-----END $label-----\n',
);

void main() {
  group('AIA 缓存与预补链', () {
    test('补链成功仍握手失败时同一请求最多重试一次，不重放更多POST', () async {
      final trust = _RepairCounterTrust();
      var requests = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests++;
              handler.reject(
                DioException(
                  requestOptions: options,
                  error: const HandshakeException('合成不完整链仍验证失败'),
                  type: DioExceptionType.connectionError,
                ),
                true,
              );
            },
          ),
        );
      try {
        await expectLater(
          PortalHttp(
            dio,
            trust: trust,
          ).post(Uri.parse('https://synthetic.test/'), data: 'read-only-query'),
          throwsA(isA<PortalNetworkError>()),
        );
        expect(requests, 2);
        expect(trust.repairs, 1);
      } finally {
        dio.close(force: true);
      }
    });
    test('坏AIA长度字段安全拒绝，合法URI仍可解析', () {
      final prefix = [
        0x06,
        0x08,
        0x2b,
        0x06,
        0x01,
        0x05,
        0x05,
        0x07,
        0x30,
        0x02,
        0x86,
      ];
      for (final suffix in [
        [0x84],
        [0x80],
        [0x85, 1, 2, 3, 4, 5],
        [0x82, 0xff],
      ]) {
        expect(
          AiaTrust.caIssuersUrlForTesting(
            Uint8List.fromList([...prefix, ...suffix]),
          ),
          isNull,
        );
      }
      final uri = ascii.encode('http://127.0.0.1/issuer.der');
      expect(
        AiaTrust.caIssuersUrlForTesting(
          Uint8List.fromList([...prefix, uri.length, ...uri]),
        ),
        'http://127.0.0.1/issuer.der',
      );
    });

    test('同主机并发补链合流，同叶子新握手失败可重新取证书，过期issuer不加入信任', () async {
      final original = await File('test/fixtures/vpn/certificate.der')
          .readAsBytes();
      final issuer = _aiaCertificate(original, expires: DateTime.utc(2021));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      final gate = Completer<void>();
      server.listen((request) async {
        requests++;
        await gate.future;
        request.response.add(issuer);
        await request.response.close();
      });
      final leaf = _SyntheticAiaCertificate(
        _aiaCertificate(
          original,
          issuerUrl: 'http://127.0.0.1:${server.port}/issuer.der',
        ),
      );
      final trust = AiaTrust(withTrustedRoots: false);
      try {
        expect(trust.onBadCertificate(leaf, 'synthetic.test', 443), isFalse);
        final first = trust.tryRepair(
          'synthetic.test',
          createFetchClient: () => HttpClient()..findProxy = (_) => 'DIRECT',
        );
        final second = trust.tryRepair('synthetic.test');
        expect(second, same(first));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        gate.complete();
        expect(await first, isFalse, reason: '过期证书不可加入信任');
        expect(requests, 1);
        trust.onBadCertificate(leaf, 'synthetic.test', 443);
        expect(
          await trust.tryRepair(
            'synthetic.test',
            createFetchClient: () => HttpClient()..findProxy = (_) => 'DIRECT',
          ),
          isFalse,
        );
        expect(requests, 2, reason: '下一次同叶子失败允许重新下载');
      } finally {
        if (!gate.isCompleted) gate.complete();
        await server.close(force: true);
      }
    });

    test('缓存证书到期重建上下文，根证书缓存不导入；预探测不发送HTTP正文', () async {
      final original = await File('test/fixtures/vpn/certificate.der')
          .readAsBytes();
      final key = await File('test/fixtures/vpn/private_key.der').readAsBytes();
      final directory = await Directory.systemTemp.createTemp('aia_test');
      var now = DateTime.utc(2026, 11, 17);
      final intermediate = _aiaCertificate(
        original,
        expires: DateTime.utc(2027),
      );
      await File('${directory.path}/issuer.der').writeAsBytes(intermediate);
      final trust = AiaTrust(
        withTrustedRoots: false,
        now: () => now,
        resolveCacheDir: () async => directory,
      );
      final before = trust.context;
      await trust.preload();
      expect(trust.context, same(before));
      now = DateTime.utc(2028);
      await trust.preload();
      expect(trust.context, isNot(same(before)));
      expect(await File('${directory.path}/issuer.der').exists(), isFalse);
      await File('${directory.path}/root.der').writeAsBytes(original);
      final cold = AiaTrust(
        withTrustedRoots: false,
        resolveCacheDir: () async => directory,
      );
      await cold.preload();
      expect(await File('${directory.path}/root.der').exists(), isFalse);
      final https = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        SecurityContext()
          ..useCertificateChainBytes(pem('CERTIFICATE', original))
          ..usePrivateKeyBytes(pem('PRIVATE KEY', key)),
      );
      var requests = 0;
      https.listen((request) async {
        requests++;
        await request.response.close();
      }, onError: (_) {});
      try {
        final probe = AiaTrust(withTrustedRoots: false);
        expect(
          await probe.prepareHost(
            Uri.parse('https://127.0.0.1:${https.port}/'),
          ),
          isFalse,
        );
        expect(requests, 0, reason: '预探测不能发送业务HTTP或凭据');
        final localConnector = LocalConnector();
        final routed = VpnHttpClientAdapter(
          connector: localConnector,
          detectCampusNetwork: () async => CampusNetworkState.offCampus,
          securityContextProvider: () => probe.context,
          createHttpClient: probe.createHttpClient,
          onBadCertificate: probe.onBadCertificate,
        );
        try {
          await probe.prepareHost(
            Uri.parse('https://campus.test:${https.port}/'),
            createProbeClient: routed.createPreparationClient,
            createFetchClient: routed.createPreparationClient,
          );
          expect(localConnector.connections, 1, reason: '未知/校外预补仍走原VPN连接工厂');
          expect(requests, 0);
        } finally {
          routed.close(force: true);
        }
      } finally {
        await https.close(force: true);
        await directory.delete(recursive: true);
      }
    });
  });
  test('原生错误保留阶段、系统类别和底层原因且兼容 SocketException', () {
    final error = VpnNativeException.fromResponse({
      'ok': false,
      'error': '合成握手失败',
      'diagnostic': {
        'code': 'native_start_failed',
        'stage': 'TLS',
        'native_kind': 'InvalidData',
        'causes': ['合成证书验证失败'],
      },
    }, method: 'start');
    expect(error, isA<SocketException>());
    expect(error.message, '合成握手失败');
    expect(error.diagnosticContext['native_stage'], 'tls');
    expect(error.diagnosticContext['native_kind'], 'InvalidData');
    expect(error.cause.toString(), '合成证书验证失败');
    final legacy = VpnNativeException.fromResponse({
      'error': '旧版错误',
    }, method: 'open');
    expect(legacy.diagnosticContext['native_diagnostics_available'], isFalse);
  });
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

  test('VPN 日志与完整HTTP原文关联且凭据被脱敏', () async {
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
    final exchange = logRecords.singleWhere(
      (record) => record['event'] == 'http.exchange',
    );
    expect(exchange['trace_id'], completed['trace_id']);
    expect((exchange['attrs'] as Map)['request_id'], attrs['request_id']);
    final logs = jsonEncode(logRecords);
    expect(logs, contains('private-student'));
    for (final secret in ['secret-ticket', 'secret-token']) {
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
      expect(jsonEncode(logRecords), contains('private-student'));
      expect(jsonEncode(logRecords), isNot(contains('secret-ticket')));
    } finally {
      portalLogger = previousLogger;
    }
  });

  test('并发请求日志能按编号对应，重用 RequestOptions 也分配新编号', () async {
    CampusTransport.fromDio(client);
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
          .where((record) => record['scope'] == 'core.network.vpn')
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
        throwsA(
          isA<DiagnosticException>().having(
            (error) => error.code,
            'code',
            'http_status_rejected',
          ),
        ),
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
      (unwrapHttpDiagnostics(client.httpClientAdapter) as VpnHttpClientAdapter)
          .resetClients();
      await expectLater(
        PortalHttp(client).get(url),
        throwsA(isA<PortalNetworkError>()),
      );
      final requestLines = logRecords
          .where((record) => record['scope'] == 'core.network.vpn')
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
    (unwrapHttpDiagnostics(client.httpClientAdapter) as VpnHttpClientAdapter)
        .resetClients();
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

  test('缓存 HTTP 连接复用前也等待准备，恢复换代后旧池不再发送请求', () async {
    client.close(force: true);
    final session = PreparedLocalConnector();
    client = vpnDio(connector: session, forceVpn: true);
    await client.getUri(url);
    await client.getUri(url);
    expect(session.preparations, 2);
    expect(session.connections, 2);
    expect(requests, 2);
  });

  test('等待共享恢复时取消一个 HTTP 请求，其余消费者完成且不重放请求', () async {
    client.close(force: true);
    final session = WaitingLocalConnector();
    client = vpnDio(connector: session, forceVpn: true);
    final token = CancelToken();
    final cancelled = client.getUri(url, cancelToken: token);
    final rejection = expectLater(
      cancelled,
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    final retained = client.getUri(url);
    await session.entered.future;
    token.cancel();
    await rejection;
    expect(session.connections, 0);
    expect(requests, 0);
    session.ready.complete();
    await retained;
    expect(session.connections, 1);
    expect(requests, 1);
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
    final proxy = ConnectProxy();
    await proxy.start();
    final native = FakeNative(proxy.server.port);
    final gateway = VpnGateway(native: native, auth: FakeAuth());
    final secureClient = vpnDio(
      connector: gateway,
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
      expect(gateway.sessionId, 1);
      expect(native.stopped, isEmpty);
      expect(native.starts, 1);
    } finally {
      secureClient.close(force: true);
      await gateway.dispose();
      await native.controller.close();
      await proxy.close();
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

  test('常驻CONNECT代理HTTP转发可复用连接池，错误口令返回407', () async {
    final proxy = ConnectProxy();
    await proxy.start();
    final native = FakeNative(proxy.server.port);
    final gateway = VpnGateway(native: native, auth: FakeAuth());
    final proxied = vpnDio(connector: gateway);
    try {
      expect(
        (await proxied.getUri<Map<String, dynamic>>(
          url.replace(host: 'campus.test'),
        )).data!['method'],
        'GET',
      );
      await proxied.getUri(url.replace(host: 'campus.test'));
      expect(proxy.connects, 1);
      final invalid = await connectVpnProxy(
        VpnSession(
          engineId: 1,
          proxyPort: proxy.server.port,
          proxyToken: 'bad',
          establishedAt: DateTime.now(),
          generation: 1,
        ),
        url.replace(host: 'campus.test'),
      );
      await expectLater(
        invalid.socket,
        throwsA(
          isA<VpnProxyException>().having((e) => e.statusCode, 'status', 407),
        ),
      );
    } finally {
      proxied.close(force: true);
      await gateway.dispose();
      await native.controller.close();
      await proxy.close();
    }
  });

  test('无状态Dio的默认状态校验允许手动重定向，307保留POST而303清空正文', () async {
    final redirectServer = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final seen = <String>[];
    redirectServer.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      seen.add('${request.method}:${request.uri.path}:$body');
      if (request.uri.path == '/307' || request.uri.path == '/303') {
        request.response.statusCode = int.parse(request.uri.path.substring(1));
        request.response.headers.set('location', '/target');
      } else {
        request.response.write('ok');
      }
      await request.response.close();
    });
    final transport = CampusTransport.stateless(dio: Dio());
    final origin = 'http://127.0.0.1:${redirectServer.port}';
    try {
      final preserved = await transport.dio.post<String>(
        '$origin/307',
        data: 'query=one',
      );
      expect(preserved.data, 'ok');
      expect(preserved.redirects, hasLength(1));
      expect(seen, ['POST:/307:query=one', 'POST:/target:query=one']);
      seen.clear();
      await transport.dio.post('$origin/303', data: 'query=two');
      expect(seen, ['POST:/303:query=two', 'GET:/target:']);
    } finally {
      transport.close(force: true);
      await redirectServer.close(force: true);
    }
    final unsafe = Dio()..interceptors.add(PortalCookieManager(CookieJar()));
    expect(() => CampusTransport.stateless(dio: unsafe), throwsArgumentError);
    unsafe.close(force: true);
  });

  test('启动结果前收到原生退出事件时拒绝发布Ready，下一主动请求可恢复', () async {
    final native = FakeNative(0)..startGate = Completer<void>();
    final gateway = VpnGateway(native: native, auth: FakeAuth());
    final rejected = expectLater(
      gateway.prepare(),
      throwsA(isA<SocketException>()),
    );
    while (native.starts == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    await gateway.onNativeEvent({
      'engineId': 1,
      'event': 'exited',
      'reason': 'eof',
    });
    native.startGate!.complete();
    await rejected;
    expect(gateway.state, isA<VpnDisconnected>());
    await gateway.prepare();
    expect(gateway.sessionId, 2);
    expect(native.stopped, contains(1));
    await gateway.dispose();
    await native.controller.close();
  });

  test('P1-9 AIA补链重试克隆已finalize的FormData，Stream请求不重放', () async {
    final bodies = <String>[];
    final trust = _RepairCounterTrust();
    final mock = Dio()
      ..httpClientAdapter = _ScriptedAdapter((options, stream) async {
        bodies.add(
          utf8.decode(
            await stream!.fold<List<int>>([], (all, part) => all..addAll(part)),
          ),
        );
        if (bodies.length == 1) throw const HandshakeException('合成缺链');
        return ResponseBody.fromString('ok', 200);
      });
    final http = PortalHttp(mock, trust: trust);
    try {
      expect(
        (await http.post(
          Uri.parse('https://synthetic.test/query'),
          data: FormData.fromMap({'query': 'read-only-value'}),
        )).data,
        'ok',
      );
      expect(bodies, hasLength(2));
      expect(bodies[1], bodies[0]);
      expect(RegExp('name="query"').allMatches(bodies[1]), hasLength(1));
      expect(bodies[1], contains('read-only-value'));
      expect(trust.repairs, 1);
    } finally {
      mock.close(force: true);
    }
    var streamCalls = 0;
    final noReplayTrust = _RepairCounterTrust();
    final streamDio = Dio()
      ..httpClientAdapter = _ScriptedAdapter((options, stream) async {
        streamCalls++;
        await stream!.drain<void>();
        throw const HandshakeException('合成Stream缺链');
      });
    try {
      await expectLater(
        PortalHttp(streamDio, trust: noReplayTrust).post(
          Uri.parse('https://synthetic.test/query'),
          data: Stream<Uint8List>.value(Uint8List.fromList([1, 2, 3])),
        ),
        throwsA(isA<PortalNetworkError>()),
      );
      expect(streamCalls, 1);
      expect(noReplayTrust.repairs, 0);
    } finally {
      streamDio.close(force: true);
    }
  });

  test('P1-13 AIA预探测失败不能缓存，成功后才复用标记', () async {
    final trust = AiaTrust();
    var probes = 0;
    HttpClient failed() {
      probes++;
      return HttpClient()
        ..connectionFactory = (uri, host, port) =>
            throw const SocketException('合成探测失败');
    }

    expect(await trust.prepareHost(url, createProbeClient: failed), isFalse);
    expect(await trust.prepareHost(url, createProbeClient: failed), isFalse);
    expect(probes, 2);
    await trust.prepareHost(
      url,
      createProbeClient: () {
        probes++;
        return HttpClient();
      },
    );
    await trust.prepareHost(url, createProbeClient: failed);
    expect(probes, 3);
    expect(requests, 0);
  });

  for (final code in [301, 302, 303]) {
    for (final method in ['HEAD', 'PUT', 'POST']) {
      test('P1-9 redirect$code保持$method的RFC方法语义并清理跨跳重放状态', () async {
        final seen = <RequestOptions>[];
        bool guard(int? status) => status == 200;
        final dio = Dio()
          ..httpClientAdapter = _ScriptedAdapter((options, stream) async {
            await stream?.drain<void>();
            seen.add(options);
            return options.uri.path == '/start'
                ? ResponseBody.fromString(
                    '',
                    code,
                    headers: {
                      'location': ['/next'],
                    },
                  )
                : ResponseBody.fromString('', 200);
          });
        final transport = CampusTransport.stateless(dio: dio);
        try {
          final result = await transport.dio.request(
            'http://synthetic.test/start',
            data: 'body=kept',
            options: Options(
              method: method,
              extra: {
                '_vpnReplayed': true,
                '_aiaRepaired': true,
                '_redirectValidateStatus': guard,
                'vpnDio.engineId': 77,
              },
            ),
          );
          expect(result.statusCode, 200);
          expect(seen, hasLength(2));
          final expectedGet = code == 303 ? method != 'HEAD' : method == 'POST';
          expect(seen[1].method, expectedGet ? 'GET' : method);
          expect(seen[1].data, expectedGet ? null : 'body=kept');
          for (final key in [
            '_vpnReplayed',
            '_aiaRepaired',
            'vpnDio.engineId',
          ]) {
            expect(seen[1].extra.containsKey(key), isFalse);
          }
          expect(seen[1].extra['_redirectValidateStatus'], isNot(same(guard)));
          expect(result.redirects, hasLength(1));
        } finally {
          transport.close(force: true);
        }
      });
    }
  }

  test('P1-9 非法Location保留原因，PortalHttp重定向503不泄露裸DioException', () async {
    final invalidDio = Dio()
      ..httpClientAdapter = _ScriptedAdapter(
        (options, stream) async => ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': ['http://bad.test:invalid/'],
          },
        ),
      );
    final invalid = CampusTransport.stateless(dio: invalidDio);
    try {
      await expectLater(
        invalid.get(Uri.parse('http://synthetic.test/start')),
        throwsA(
          isA<PortalLoginError>()
              .having((e) => e.code, 'code', 'redirect_location_invalid')
              .having((e) => e.cause, 'cause', isA<FormatException>()),
        ),
      );
    } finally {
      invalid.close(force: true);
    }
    var calls = 0;
    final rejectingDio = Dio()
      ..httpClientAdapter = _ScriptedAdapter((options, stream) async {
        calls++;
        return calls == 1
            ? ResponseBody.fromString(
                '',
                302,
                headers: {
                  'location': ['/failed'],
                },
              )
            : ResponseBody.fromString('temporarily unavailable', 503);
      });
    final http = PortalHttp(rejectingDio);
    try {
      final landed = await http.get(Uri.parse('http://synthetic.test/start'));
      await expectLater(
        http.followRedirects(landed),
        throwsA(
          isA<DiagnosticException>()
              .having((e) => e.diagnosticContext['status_code'], 'status', 503)
              .having((e) => e.cause, 'cause', isA<DioException>()),
        ),
      );
      expect(calls, 2);
    } finally {
      rejectingDio.close(force: true);
    }
  });

  test('P0-3 prepare返回后全局代次变化仍使用锁定会话，未知失败ID不关闭活跃池', () async {
    final changing = ChangingPreparedConnector();
    final atomicClient = vpnDio(connector: changing, forceVpn: true);
    try {
      final first = await atomicClient.getUri(url);
      expect(first.requestOptions.extra['vpnDio.engineId'], 1);
      expect(changing.sessionId, 2);
      final second = await atomicClient.getUri(url);
      expect(second.requestOptions.extra['vpnDio.engineId'], 2);
      expect(changing.connections, 2);
    } finally {
      atomicClient.close(force: true);
    }
    final stable = PreparedLocalConnector();
    final pooled = vpnDio(connector: stable);
    try {
      await pooled.getUri(url);
      final adapter = unwrapHttpDiagnostics(
        pooled.httpClientAdapter,
      ) as VpnHttpClientAdapter;
      adapter.discardVpnPool(null);
      stable.preparations = 2;
      await pooled.getUri(url);
      expect(stable.connections, 1);
    } finally {
      pooled.close(force: true);
    }
  });

  test('P0-3 prepare之后Draining不能把请求归属转交给新引擎', () async {
    final proxy = ConnectProxy();
    await proxy.start();
    final native = FakeNative(proxy.server.port);
    final gateway = DrainingDuringPreparationGateway(
      native: native,
      auth: FakeAuth(),
    );
    final lockedClient = vpnDio(connector: gateway);
    try {
      final result = await lockedClient.getUri(
        url.replace(host: 'campus.test'),
      );
      expect(result.requestOptions.extra['vpnDio.engineId'], 1);
      expect(native.starts, 1);
      expect(gateway.state, isA<VpnDraining>());
    } finally {
      lockedClient.close(force: true);
      await gateway.dispose();
      await native.controller.close();
      await proxy.close();
    }
  });

  for (final status in [502, 504, 503]) {
    test('P1-7 CONNECT$status不误杀健康隧道', () async {
      final proxy = ConnectProxy()..rejectOnceStatus = status;
      await proxy.start();
      final native = FakeNative(proxy.server.port);
      final gateway = VpnGateway(native: native, auth: FakeAuth());
      final query = vpnDio(connector: gateway);
      try {
        final result = query.getUri(url.replace(host: 'campus.test'));
        await expectLater(
          result,
          throwsA(
            isA<DioException>().having(
              (e) => (e.error as VpnProxyException).statusCode,
              'proxy_status',
              status,
            ),
          ),
        );
        expect(proxy.proxyRequests, 1);
        expect(gateway.sessionId, 1);
        expect(native.stopped, isEmpty);
        expect(native.starts, 1);
      } finally {
        query.close(force: true);
        await gateway.dispose();
        await native.controller.close();
        await proxy.close();
      }
    });
  }

  test('P1-7 connectionTimeout也触发唯一一次恢复', () async {
    final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    proxy.listen((socket) {
      sockets.add(socket);
      socket.listen((_) {});
    });
    final native = FakeNative(proxy.port);
    final gateway = VpnGateway(native: native, auth: FakeAuth());
    final timed = vpnDio(
      connector: gateway,
      options: BaseOptions(connectTimeout: const Duration(milliseconds: 60)),
    );
    try {
      await expectLater(
        timed.get('http://campus.test/'),
        throwsA(isA<DioException>()),
      );
      expect(native.starts, 2);
      expect(native.stopped, [1, 2]);
    } finally {
      timed.close(force: true);
      await gateway.dispose();
      await native.controller.close();
      for (final socket in sockets) {
        socket.destroy();
      }
      await proxy.close();
    }
  });

  test('P1-7 重放准备中取消一个请求不取消共享准备或其他请求', () async {
    final failing = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var attempts = 0;
    failing.listen((request) async {
      attempts++;
      if (attempts == 1) {
        (await request.response.detachSocket(writeHeaders: false)).destroy();
      } else {
        request.response.write('retained');
        await request.response.close();
      }
    });
    final shared = RecoverableLocalConnector()
      ..replayGate = Completer<void>()
      ..replayEntered = Completer<void>();
    final replay = vpnDio(connector: shared);
    final token = CancelToken();
    try {
      final cancelled = replay.get<String>(
        'http://127.0.0.1:${failing.port}/',
        cancelToken: token,
      );
      final rejected = expectLater(
        cancelled,
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      await shared.replayEntered!.future;
      final retained = replay.get<String>('http://127.0.0.1:${failing.port}/');
      token.cancel();
      await rejected.timeout(const Duration(seconds: 1));
      expect(shared.replayGate!.isCompleted, isFalse);
      shared.replayGate!.complete();
      expect((await retained).data, 'retained');
      expect(attempts, 2);
      expect(shared.invalidated, [1]);
    } finally {
      replay.close(force: true);
      await failing.close(force: true);
    }
  });

  test('P1-4 scheduler_stall保留原生DNS探活机会而不是立即停止引擎', () async {
    final native = FakeNative(0);
    final gateway = VpnGateway(native: native, auth: FakeAuth());
    await gateway.setForeground(false);
    await gateway.prepare();
    await gateway.onNativeEvent({
      'engineId': 1,
      'event': 'unhealthy',
      'reason': 'scheduler_stall',
    });
    expect(gateway.sessionId, 1);
    expect(native.stopped, isEmpty);
    await gateway.onNativeEvent({
      'engineId': 1,
      'event': 'healthy',
      'reason': 'probe_completed',
    });
    expect(gateway.sessionId, 1);
    await gateway.onNativeEvent({
      'engineId': 1,
      'event': 'exited',
      'reason': 'recovery_timeout',
    });
    expect(gateway.state, isA<VpnDisconnected>());
    expect(native.stopped, [1]);
    await gateway.dispose();
    await native.controller.close();
  });

  test('五个并发请求共享启动，网络变化不取消正在建立的隧道', () async {
    final native = FakeNative(0)..startGate = Completer<void>();
    final auth = FakeAuth();
    final gateway = VpnGateway(native: native, auth: auth);
    final waiting = List.generate(5, (_) => gateway.ensureReady());
    while (native.starts == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    final networkChange = gateway.networkChanged();
    native.startGate!.complete();
    await networkChange;
    expect(native.probes, 1);
    final sessions = await Future.wait(waiting);
    expect(auth.logins, 1);
    expect(native.starts, 1);
    expect(
      sessions.every((session) => identical(session, sessions.first)),
      isTrue,
    );
    expect(gateway.state, isA<VpnReady>());
    await gateway.dispose();
    await native.controller.close();
  });

  test('启动超时只拒绝本次等待，主动请求立即重建且迟到结果不恢复旧会话', () async {
    final native = FakeNative(0);
    final auth = FakeAuth()..obtainGate = Completer<void>();
    final gateway = VpnGateway(
      native: native,
      auth: auth,
      startTimeout: const Duration(milliseconds: 50),
    );
    await Future.wait([
      for (var i = 0; i < 3; i++)
        expectLater(gateway.prepare(), throwsA(isA<SocketException>())),
    ]);
    expect(auth.logins, 1);
    auth.obtainGate!.complete();
    await gateway.prepare();
    expect(auth.logins, 2);
    expect(native.starts, 1);
    await gateway.dispose();
    await native.controller.close();
  });

  test('reset不等待卡住的握手，迟到引擎关闭且不清空Cookie', () async {
    final native = FakeNative(0)..startGate = Completer<void>();
    final gateway = VpnGateway(native: native, auth: FakeAuth());
    final rejected = expectLater(
      gateway.prepare(),
      throwsA(isA<SocketException>()),
    );
    while (native.starts == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    await gateway.reset().timeout(const Duration(seconds: 1));
    native.startGate!.complete();
    await rejected;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(native.stopped, contains(1));
    await gateway.prepare();
    expect(gateway.sessionId, 2);
    await gateway.invalidate(1);
    expect(gateway.sessionId, 2);
    await gateway.dispose();
    await native.controller.close();
  });

  test('原生排空和退出事件推动状态，后台退避不阻挡主动重试', () async {
    final native = FakeNative(0);
    final auth = FakeAuth();
    final gateway = VpnGateway(native: native, auth: auth);
    await gateway.setForeground(false);
    await gateway.prepare();
    await gateway.onNativeEvent({
      'engineId': 1,
      'event': 'draining',
      'reason': 'eof',
    });
    expect(gateway.state, isA<VpnDraining>());
    await gateway.prepare();
    expect(gateway.sessionId, 2);
    expect(native.stopped, isNot(contains(1)));
    await gateway.onNativeEvent({'engineId': 1, 'event': 'exited'});
    expect(gateway.sessionId, 2);
    native.healthy = false;
    await gateway.checkHealth();
    expect(gateway.state, isA<VpnDisconnected>());
    auth.fail = true;
    await expectLater(gateway.prepare(), throwsA(isA<SocketException>()));
    auth.fail = false;
    await gateway.prepare();
    expect(gateway.state, isA<VpnReady>());
    await gateway.dispose();
    await native.controller.close();
  });

  test('真实 Rust FFI 支持多个实例并发调用与错误回调', () async {
    const first = VpnNative();
    const second = VpnNative();
    final versions = await Future.wait([
      first.call({'method': 'version'}),
      second.call({'method': 'version'}),
    ]);
    expect(versions.map((response) => response['abi']), everyElement(2));
    await expectLater(
      first.call({'method': 'start'}),
      throwsA(isA<SocketException>()),
    );
    expect((await second.call({'method': 'version'}))['abi'], 2);
  }, skip: const String.fromEnvironment('VPN_NATIVE_LIBRARY').isEmpty);

  test('VPN 原生主动状态事件广播给所有共享网关订阅者', () async {
    const first = VpnNative();
    const second = VpnNative();
    final firstEvent = first.events.first;
    final secondEvent = second.events.first;
    const event = <String, dynamic>{
      'engineId': 42,
      'event': 'draining',
      'reason': 'remote_fin',
    };

    VpnNative.debugPublishEventForTesting(event);

    expect(await firstEvent, event);
    expect(await secondEvent, event);
  });

  for (final method in ['GET', 'POST', 'WRITE', 'FAIL']) {
    test('VPN断连：$method按幂等声明恢复并最多重放一次', () async {
      final failingServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      var attempts = 0;
      failingServer.listen((request) async {
        attempts++;
        if (attempts == 1 || method == 'FAIL') {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          if (method == 'GET') {
            socket.write(
              'HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\npartial',
            );
            await socket.flush();
          }
          socket.destroy();
        } else {
          request.response.write('recovered');
          await request.response.close();
        }
      });
      final recovering = RecoverableLocalConnector();
      final retryClient = vpnDio(connector: recovering);
      try {
        final result = retryClient.request<String>(
          'http://127.0.0.1:${failingServer.port}/',
          data: method == 'GET' ? null : 'query=data',
          options: Options(
            method: method == 'GET' ? 'GET' : 'POST',
            responseType: ResponseType.plain,
            // 只有显式声明幂等的方法才重放；GET 本身幂等，不需要额外标记。
            extra: method == 'POST' || method == 'FAIL'
                ? {'idempotent': true}
                : null,
          ),
        );
        if (method == 'WRITE' || method == 'FAIL') {
          await expectLater(result, throwsA(isA<DioException>()));
          expect(attempts, method == 'WRITE' ? 1 : 2);
        } else {
          expect((await result).data, 'recovered');
          expect(attempts, 2);
        }
        expect(recovering.invalidated, method == 'FAIL' ? [1, 2] : [1]);
      } finally {
        retryClient.close(force: true);
        await failingServer.close(force: true);
      }
    });
  }

  test('请求准备超时归为网络错误，迟到的准备结果不能发送请求', () async {
    final gate = Completer<void>();
    client.interceptors.add(
      VpnPreparationInterceptor(
        client,
        beforeRequest: () => gate.future,
        timeout: const Duration(milliseconds: 50),
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
      VpnPreparationInterceptor(client, beforeRequest: () => gate.future),
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
