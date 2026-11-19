import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:asn1lib/asn1lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/auth/aia_trust.dart';
import 'package:nuist_sta_app/core/auth/portal_http.dart';
import 'package:nuist_sta_app/core/auth/portal_exceptions.dart';
import 'package:nuist_sta_app/core/auth/portal_cookie_manager.dart';
import 'package:cookie_jar/cookie_jar.dart';
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

class PreparedLocalConnector extends LocalSessionConnector
    implements VpnPreparedConnector {
  int preparations = 0;
  @override
  Future<void> prepare() async {
    preparations++;
    if (preparations == 2) sessionId = 2;
  }
}

class WaitingLocalConnector extends LocalSessionConnector
    implements VpnPreparedConnector {
  final entered = Completer<void>();
  final ready = Completer<void>();
  @override
  Future<void> prepare() {
    if (!entered.isCompleted) entered.complete();
    return ready.future;
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
  int _startSequence = 0;
  bool healthy = true;
  bool failOpenOnce = false;
  bool recovering = false;
  int statusCalls = 0;
  int probes = 0;
  bool needsProbe = false;
  final probeGate = Completer<void>();
  Completer<void>? openGate;
  int activeOpens = 0;
  int peakOpens = 0;
  final openedHosts = <String>[];
  int openSequence = 0;
  final openControls = <int, Completer<void>>{};
  Completer<void>? prepareOpenGate;

  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> request) async {
    switch (request['method']) {
      case 'version':
        return {'abi': 1};
      case 'prepareStart':
        return {'startId': ++_startSequence};
      case 'prepareOpen':
        final id = ++openSequence;
        openControls[id] = Completer<void>();
        await prepareOpenGate?.future;
        return {'openId': id};
      case 'cancelOpen':
        final control = openControls.remove(request['openId']);
        if (control != null && !control.isCompleted) control.complete();
        return {};
      case 'releaseOpen':
        openControls.remove(request['openId']);
        return {};
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
        statusCalls++;
        return {
          'alive': !stopped.contains(request['id']),
          'healthy': healthy,
          'recovering': recovering,
          'needsProbe': needsProbe,
        };
      case 'probe':
        probes++;
        await probeGate.future;
        needsProbe = false;
        healthy = true;
        recovering = false;
        return {'alive': true, 'healthy': true, 'needsProbe': false};
      case 'stop':
        stopped.add(request['id'] as int);
        return {};
      case 'open':
        opens++;
        openedHosts.add(request['host'] as String);
        activeOpens++;
        if (activeOpens > peakOpens) peakOpens = activeOpens;
        try {
          final control = openControls[request['openId']];
          await Future.any([
            if (openGate != null) openGate!.future else Future<void>.value(),
            if (control != null)
              control.future.then(
                (_) => throw const SocketException('synthetic open cancelled'),
              ),
          ]);
        } finally {
          activeOpens--;
        }
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

/// stop 后释放在途控制调用，模拟 Rust Runner 退出丢弃 reply 的真实行为。
class StoppableOpenNative extends FakeNative {
  StoppableOpenNative(super.port);
  final _cancelled = <int, Completer<void>>{};

  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> request) async {
    if (request['method'] == 'stop') {
      final id = request['id'] as int;
      _cancelled[id]?.complete();
      return super.call(request);
    }
    if (request['method'] != 'open') return super.call(request);
    final id = request['id'] as int;
    opens++;
    activeOpens++;
    if (activeOpens > peakOpens) peakOpens = activeOpens;
    try {
      if (id == 1) {
        await _cancelled.putIfAbsent(id, Completer<void>.new).future;
        throw const SocketException('synthetic native worker stopped');
      }
      return {'port': port, 'secret': '00' * 32};
    } finally {
      activeOpens--;
    }
  }
}

class FailingAuth extends FakeAuth {
  bool fail = true;
  @override
  Future<VpnCredentials> obtain() async {
    if (fail) {
      logins++;
      throw const SocketException('synthetic repeated failure');
    }
    return super.obtain();
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

  test('前台健康检查先发布失效代次，下一请求重建且不复用旧池', () async {
    final native = FakeNative(0)..startGate.complete();
    final gateway = VpnGateway(native: native, auth: FakeAuth());
    try {
      await gateway.prepare();
      native.healthy = false;
      await gateway.checkHealth();
      expect(gateway.sessionId, isNull);
      expect(native.stopped, [1]);
      await gateway.prepare();
      expect(gateway.sessionId, 2);
      expect(native.starts, 2);
    } finally {
      await gateway.reset();
    }
  });

  test('原生恢复探测由并发请求合流等待，恢复成功保留同一隧道', () async {
    final native = FakeNative(0)..startGate.complete();
    final auth = FakeAuth();
    final gateway = VpnGateway(
      native: native,
      auth: auth,
      recoveryTimeout: const Duration(milliseconds: 200),
      recoveryPollInterval: const Duration(milliseconds: 5),
    );
    try {
      await gateway.prepare();
      native.healthy = false;
      native.recovering = true;
      final foregroundCheck = gateway.checkHealth();
      expect(gateway.sessionId, 1);
      final queries = native.statusCalls;
      var completed = false;
      final preparing = Future.wait([
        gateway.prepare(),
        gateway.prepare(),
        gateway.prepare(),
      ]).then((_) => completed = true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(completed, isFalse);
      expect(native.starts, 1);
      native.healthy = true;
      native.recovering = false;
      await preparing;
      await foregroundCheck;
      expect(native.stopped, isEmpty);
      expect(auth.logins, 1);
      expect(gateway.sessionId, 1);
      expect(native.statusCalls - queries, lessThan(15));
    } finally {
      await gateway.reset();
    }
  });

  test('恢复探测超时只重建一次，网络变化取消旧等待而不发布旧会话', () async {
    final native = FakeNative(0)..startGate.complete();
    final gateway = VpnGateway(
      native: native,
      auth: FakeAuth(),
      recoveryTimeout: const Duration(milliseconds: 35),
      recoveryPollInterval: const Duration(milliseconds: 5),
    );
    try {
      await gateway.prepare();
      native.healthy = false;
      native.recovering = true;
      await Future.wait([gateway.prepare(), gateway.prepare()]);
      expect(native.starts, 2);
      expect(native.stopped, [1]);
      native.healthy = false;
      final waiting = gateway.prepare();
      final cancelled = expectLater(waiting, throwsA(isA<SocketException>()));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await gateway.networkChanged();
      await cancelled;
      expect(gateway.sessionId, isNull);
      expect(native.starts, 2);
      native.recovering = false;
      await gateway.prepare();
      expect(native.starts, 3);
      expect(gateway.sessionId, 3);
    } finally {
      await gateway.reset();
    }
  });

  test('连续启动失败扩大退避，网络变化解除退避且成功恢复', () async {
    final native = FakeNative(0)..startGate.complete();
    final auth = FailingAuth();
    final gateway = VpnGateway(
      native: native,
      auth: auth,
      failureBackoffBase: const Duration(milliseconds: 30),
      failureBackoffMax: const Duration(milliseconds: 100),
    );
    try {
      await expectLater(gateway.prepare(), throwsA(isA<SocketException>()));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await expectLater(gateway.prepare(), throwsA(isA<SocketException>()));
      expect(auth.logins, 2);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await expectLater(gateway.prepare(), throwsA(isA<SocketException>()));
      expect(auth.logins, 2);
      await gateway.networkChanged();
      auth.fail = false;
      await gateway.prepare();
      expect(auth.logins, 3);
      expect(native.starts, 1);
    } finally {
      await gateway.reset();
    }
  });

  test('短命隧道反复握手成功也会扩大退避，稳定复用与网络变化才解除', () async {
    final native = FakeNative(0)..startGate.complete();
    final gateway = VpnGateway(
      native: native,
      auth: FakeAuth(),
      failureBackoffBase: const Duration(milliseconds: 50),
      failureBackoffMax: const Duration(milliseconds: 300),
      stableSessionDuration: const Duration(milliseconds: 250),
    );
    try {
      await gateway.prepare();
      native.healthy = false;
      await gateway.prepare();
      expect(native.starts, 2);
      native.healthy = false;
      await expectLater(gateway.prepare(), throwsA(isA<SocketException>()));
      expect(native.starts, 2);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      await gateway.prepare();
      expect(native.starts, 3);
      native.healthy = false;
      await expectLater(gateway.prepare(), throwsA(isA<SocketException>()));
      await Future<void>.delayed(const Duration(milliseconds: 70));
      await expectLater(gateway.prepare(), throwsA(isA<SocketException>()));
      expect(native.starts, 3);
      await gateway.networkChanged();
      await gateway.prepare();
      expect(native.starts, 4);
      await Future<void>.delayed(const Duration(milliseconds: 270));
      await gateway.prepare();
      native.healthy = false;
      await gateway.prepare();
      expect(native.starts, 5);
    } finally {
      await gateway.reset();
    }
  });

  test('后台暂停监测，前台已有隧道恢复探测无需新请求即可结束', () async {
    final native = FakeNative(0)..startGate.complete();
    final gateway = VpnGateway(
      native: native,
      auth: FakeAuth(),
      recoveryTimeout: const Duration(milliseconds: 80),
      recoveryPollInterval: const Duration(milliseconds: 5),
    );
    try {
      await gateway.prepare();
      await gateway.setForeground(false);
      native.healthy = false;
      native.recovering = true;
      final checks = native.statusCalls;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(native.statusCalls, checks);
      final resumed = gateway.setForeground(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      native.recovering = false;
      native.healthy = true;
      await resumed;
      expect(gateway.sessionId, 1);
      expect(native.starts, 1);
      expect(native.stopped, isEmpty);
      await gateway.setForeground(false);
      native.healthy = false;
      native.recovering = true;
      await gateway.setForeground(true);
      expect(gateway.sessionId, isNull);
      expect(native.stopped, [1]);
      expect(native.starts, 1);
    } finally {
      await gateway.reset();
    }
  });

  test('不回复心跳的闲置隧道由前台和请求共享DNS探测，不误判死亡', () async {
    final native = FakeNative(0)..startGate.complete();
    final gateway = VpnGateway(native: native, auth: FakeAuth());
    try {
      await gateway.prepare();
      native.needsProbe = true;
      native.healthy = false;
      final checking = gateway.setForeground(true);
      final preparing = gateway.prepare();
      await Future<void>.delayed(Duration.zero);
      expect(native.probes, 1);
      expect(native.starts, 1);
      expect(gateway.sessionId, 1);
      native.probeGate.complete();
      await Future.wait([checking, preparing]);
      expect(native.starts, 1);
      expect(native.stopped, isEmpty);
      expect(gateway.sessionId, 1);
    } finally {
      await gateway.reset();
    }
  });

  test('共享启动后目标建连有界FIFO，排队取消及时退出且不占槽位', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    listener.listen((socket) {
      sockets.add(socket);
      socket.listen((_) {});
    });
    final native = FakeNative(listener.port)..startGate.complete();
    native.openGate = Completer<void>();
    final gateway = VpnGateway(native: native, auth: FakeAuth());
    try {
      await gateway.prepare();
      final tasks = <ConnectionTask<Socket>>[];
      for (var i = 0; i < 40; i++) {
        tasks.add(await gateway.connect(Uri.parse('http://campus$i.test')));
      }
      final cancelled = expectLater(
        tasks[20].socket,
        throwsA(isA<SocketException>()),
      );
      tasks[20].cancel();
      await cancelled;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(native.opens, 8);
      expect(native.peakOpens, 8);
      native.openGate!.complete();
      final connected = await Future.wait([
        for (var i = 0; i < tasks.length; i++)
          if (i != 20) tasks[i].socket,
      ]);
      expect(native.opens, 39);
      expect(native.peakOpens, lessThanOrEqualTo(8));
      expect(native.openedHosts, [
        for (var i = 0; i < 40; i++)
          if (i != 20) 'campus$i.test',
      ]);
      for (final socket in connected) {
        socket.destroy();
      }
    } finally {
      await gateway.reset();
      for (final socket in sockets) {
        socket.destroy();
      }
      await listener.close();
    }
  });

  test('重置释放8个真实行为的在途open，下一会话迅速建连且不突破总上界', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    listener.listen((socket) {
      sockets.add(socket);
      socket.listen((_) {});
    });
    final native = StoppableOpenNative(listener.port)..startGate.complete();
    final gateway = VpnGateway(native: native, auth: FakeAuth());
    try {
      await gateway.prepare();
      final tasks = <ConnectionTask<Socket>>[];
      final rejected = <Future<void>>[];
      for (var i = 0; i < 12; i++) {
        final task = await gateway.connect(Uri.parse('http://campus$i.test'));
        tasks.add(task);
        rejected.add(expectLater(task.socket, throwsA(isA<SocketException>())));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(native.activeOpens, 8);
      final started = Stopwatch()..start();
      await gateway.reset();
      final fresh = await gateway.connect(Uri.parse('http://campus.test'));
      final socket = await fresh.socket.timeout(const Duration(seconds: 1));
      await Future.wait(rejected);
      expect(started.elapsed, lessThan(const Duration(seconds: 1)));
      expect(native.peakOpens, lessThanOrEqualTo(8));
      expect(native.starts, 2);
      socket.destroy();
    } finally {
      await gateway.reset();
      for (final socket in sockets) {
        socket.destroy();
      }
      await listener.close();
    }
  });

  test('取消8个活动目标连接后，新的连接不等待原目标超时且总在途有界', () async {
    final native = FakeNative(0)..startGate.complete();
    native.openGate = Completer<void>();
    final gateway = VpnGateway(native: native, auth: FakeAuth());
    try {
      await gateway.prepare();
      final tasks = <ConnectionTask<Socket>>[];
      final rejected = <Future<void>>[];
      for (var i = 0; i < 8; i++) {
        final task = await gateway.connect(Uri.parse('http://blocked$i.test'));
        tasks.add(task);
        rejected.add(expectLater(task.socket, throwsA(isA<SocketException>())));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(native.opens, 8);
      for (final task in tasks) {
        task.cancel();
      }
      await Future.wait(rejected);
      final fresh = await gateway.connect(Uri.parse('http://fresh.test'));
      final freshRejected = expectLater(
        fresh.socket,
        throwsA(isA<SocketException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      fresh.cancel();
      await freshRejected;
      expect(native.opens, 9, reason: '已取消的8个目标连接不应占用FIFO槽到20秒超时');
      expect(native.peakOpens, lessThanOrEqualTo(8));
    } finally {
      native.openGate!.complete();
      await gateway.reset();
    }
  });

  test('目标连接登记尚未返回时取消，迟到登记释放且不会发送open', () async {
    final native = FakeNative(0)..startGate.complete();
    native.prepareOpenGate = Completer<void>();
    final gateway = VpnGateway(native: native, auth: FakeAuth());
    try {
      await gateway.prepare();
      final task = await gateway.connect(Uri.parse('http://campus.test'));
      final rejected = expectLater(
        task.socket,
        throwsA(isA<SocketException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      task.cancel();
      await rejected;
      native.prepareOpenGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(native.opens, 0);
      expect(native.openControls, isEmpty);
      expect(native.stopped, isEmpty);
    } finally {
      await gateway.reset();
    }
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
