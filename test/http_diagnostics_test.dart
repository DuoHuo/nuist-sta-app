import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:nuist_sta_app/core/logging/app_log.dart';
import 'package:nuist_sta_app/core/logging/diagnostic_error.dart';
import 'package:nuist_sta_app/core/logging/diagnostic_redactor.dart';
import 'package:nuist_sta_app/core/logging/http_diagnostics.dart';
import 'package:nuist_sta_app/core/network/vpn_native.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final records = <Map<String, Object?>>[];
  setUp(() async {
    await AppLog.resetForTesting();
    records.clear();
    AppLog.recordListenerForTesting = records.add;
  });
  tearDown(AppLog.resetForTesting);

  Map<String, Object?> exchange() =>
      (records.singleWhere(
                (record) =>
                    record['event'].toString().startsWith('http.exchange'),
              )['attrs']
              as Map)['details']
          as Map<String, Object?>;

  Map<String, Object?> failedOperation(String event) =>
      records.singleWhere((record) => record['event'] == '$event.failed');

  List<Object?> evidenceOf(Map<String, Object?> record) =>
      ((record['attrs'] as Map)['details'] as Map)['evidence'] as List<Object?>;

  test('HTTP 成功后业务解析失败，失败记录直接携带完整响应且不改变实际交流', () async {
    const requestBody =
        '{"password":"synthetic-request-secret","mode":"diagnostic-case"}';
    const responseBody =
        '{"token":"synthetic-response-secret","message":"完整原始响应尾部证据"}';
    String? sent;
    String? received;
    final dio = Dio(BaseOptions(responseType: ResponseType.plain));
    dio.httpClientAdapter = _Adapter((_, stream) async {
      sent = utf8.decode(await stream!.expand((chunk) => chunk).toList());
      return ResponseBody.fromString(
        responseBody,
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    });
    installHttpDiagnostics(dio);
    addTearDown(() => dio.close(force: true));
    await expectLater(
      AppLog.logger('test.business')
          .operation<void>('business.parse', () async {
            final response = await dio.post<String>(
              'https://service.example/business',
              data: requestBody,
              options: Options(contentType: Headers.jsonContentType),
            );
            received = response.data;
            throw const DiagnosticException(
              '业务响应缺少目标列表',
              code: 'response_rows_missing',
            );
          }),
      throwsA(isA<DiagnosticException>()),
    );
    expect(sent, requestBody);
    expect(received, responseBody);
    final failed = failedOperation('business.parse');
    final evidence = jsonEncode(evidenceOf(failed));
    expect(evidence, contains('完整原始响应尾部证据'));
    expect(evidence, contains('diagnostic-case'));
    expect(evidence, isNot(contains('synthetic-request-secret')));
    expect(evidence, isNot(contains('synthetic-response-secret')));
    expect(AppLog.formatDetails(failed), contains('完整原始响应尾部证据'));
  });

  test('同一客户端的并发业务根操作不会互相收集响应正文', () async {
    final entered = Completer<void>();
    final gates = {'alpha': Completer<void>(), 'beta': Completer<void>()};
    var requests = 0;
    final dio = Dio(BaseOptions(responseType: ResponseType.plain));
    dio.httpClientAdapter = _Adapter((options, _) async {
      final operation = options.uri.pathSegments.last;
      if (++requests == 2) entered.complete();
      await gates[operation]!.future;
      return ResponseBody.fromString('raw_body_marker_$operation', 200);
    });
    installHttpDiagnostics(dio);
    addTearDown(() => dio.close(force: true));
    Future<void> query(String name) =>
        AppLog.logger('test.concurrent').operation<void>(name, () async {
          await dio.get<String>('https://service.example/$name');
          throw const DiagnosticException(
            '业务数据不可用',
            code: 'response_schema_mismatch',
          );
        });
    final alpha = expectLater(
      query('alpha'),
      throwsA(isA<DiagnosticException>()),
    );
    final beta = expectLater(
      query('beta'),
      throwsA(isA<DiagnosticException>()),
    );
    await entered.future;
    gates['beta']!.complete();
    gates['alpha']!.complete();
    await Future.wait([alpha, beta]);
    final alphaRecord = failedOperation('alpha');
    final betaRecord = failedOperation('beta');
    expect(alphaRecord['trace_id'], isNot(betaRecord['trace_id']));
    final alphaEvidence = jsonEncode(evidenceOf(alphaRecord));
    final betaEvidence = jsonEncode(evidenceOf(betaRecord));
    expect(alphaEvidence, contains('raw_body_marker_alpha'));
    expect(alphaEvidence, isNot(contains('raw_body_marker_beta')));
    expect(betaEvidence, contains('raw_body_marker_beta'));
    expect(betaEvidence, isNot(contains('raw_body_marker_alpha')));
  });

  test('兄弟操作证据隔离，父操作汇总原始交流时不重复嵌套失败详情', () async {
    final dio = Dio(BaseOptions(responseType: ResponseType.plain));
    dio.httpClientAdapter = _Adapter(
      (options, _) async => ResponseBody.fromString(
        'raw_sibling_marker_${options.uri.pathSegments.last}',
        200,
      ),
    );
    installHttpDiagnostics(dio);
    addTearDown(() => dio.close(force: true));
    final log = AppLog.logger('test.tree');
    await expectLater(
      log.operation<void>('parent', () async {
        await Future.wait([
          for (final name in ['left', 'right'])
            log
                .operation<void>('child.$name', () async {
                  await dio.get<String>('https://service.example/$name');
                  throw const DiagnosticException(
                    '子操作失败',
                    code: 'response_schema_mismatch',
                  );
                })
                .catchError((_) {}),
        ]);
        throw const DiagnosticException(
          '汇总操作失败',
          code: 'child_operation_failed',
        );
      }),
      throwsA(isA<DiagnosticException>()),
    );
    final left = jsonEncode(evidenceOf(failedOperation('child.left')));
    final right = jsonEncode(evidenceOf(failedOperation('child.right')));
    expect(left, contains('raw_sibling_marker_left'));
    expect(left, isNot(contains('raw_sibling_marker_right')));
    expect(right, contains('raw_sibling_marker_right'));
    expect(right, isNot(contains('raw_sibling_marker_left')));
    final parent = jsonEncode(evidenceOf(failedOperation('parent')));
    expect('raw_sibling_marker_left'.allMatches(parent), hasLength(1));
    expect('raw_sibling_marker_right'.allMatches(parent), hasLength(1));
  });

  test('共享登录的两个消费者只附登录证据，不借用生产者其他业务正文', () async {
    final loginRegistered = Completer<void>();
    final finishLogin = Completer<void>();
    late Future<void> sharedLogin;
    Map<String, Object?>? loginEvidence;
    final dio = Dio(BaseOptions(responseType: ResponseType.plain));
    dio.httpClientAdapter = _Adapter((options, _) async {
      final endpoint = options.uri.pathSegments.last;
      if (endpoint == 'login') await finishLogin.future;
      return ResponseBody.fromString('shared_case_marker_$endpoint', 200);
    });
    installHttpDiagnostics(dio);
    addTearDown(() => dio.close(force: true));
    final owner = AppLog.logger('test.owner')
        .operation<void>('owner', () async {
          await dio.get<String>('https://service.example/owner_private');
          sharedLogin = AppLog.logger('test.auth')
              .operation<void>('shared.login', () async {
                final response = await dio.get<String>(
                  'https://service.example/login',
                );
                loginEvidence = httpDiagnosticEvidence(response.requestOptions);
                throw const DiagnosticException(
                  '共享认证响应无效',
                  code: 'login_response_invalid',
                );
              });
          loginRegistered.complete();
          await sharedLogin;
        });
    final ownerFailure = expectLater(
      owner,
      throwsA(isA<DiagnosticException>()),
    );
    await loginRegistered.future;
    final waiter = AppLog.logger('test.waiter')
        .operation<void>('waiter', () async {
          try {
            await sharedLogin;
          } finally {
            if (loginEvidence case final evidence?) {
              AppLog.addEvidence('shared.login', evidence);
            }
          }
        });
    final waiterFailure = expectLater(
      waiter,
      throwsA(isA<DiagnosticException>()),
    );
    finishLogin.complete();
    await Future.wait([ownerFailure, waiterFailure]);
    final ownerEvidence = jsonEncode(evidenceOf(failedOperation('owner')));
    final waiterEvidence = jsonEncode(evidenceOf(failedOperation('waiter')));
    expect(ownerEvidence, contains('shared_case_marker_owner_private'));
    expect(ownerEvidence, contains('shared_case_marker_login'));
    expect(waiterEvidence, contains('shared_case_marker_login'));
    expect(waiterEvidence, isNot(contains('shared_case_marker_owner_private')));
  });

  test('同一父 Trace 内共享登录的兄弟消费者各自保留原文且不混入兄弟正文', () async {
    final loginRegistered = Completer<void>();
    final finishLogin = Completer<void>();
    late Future<void> sharedLogin;
    Map<String, Object?>? loginEvidence;
    final dio = Dio(BaseOptions(responseType: ResponseType.plain));
    dio.httpClientAdapter = _Adapter((options, _) async {
      final endpoint = options.uri.pathSegments.last;
      if (endpoint == 'login') await finishLogin.future;
      return ResponseBody.fromString('sibling_login_marker_$endpoint', 200);
    });
    installHttpDiagnostics(dio);
    addTearDown(() => dio.close(force: true));
    final log = AppLog.logger('test.shared_siblings');
    await log.operation<void>('shared.parent', () async {
      final owner = log.operation<void>('sibling.owner', () async {
        await dio.get<String>('https://service.example/owner_private');
        sharedLogin = log.operation<void>('sibling.login', () async {
          final response = await dio.get<String>(
            'https://service.example/login',
          );
          loginEvidence = httpDiagnosticEvidence(response.requestOptions);
          throw const DiagnosticException(
            '共享登录未完成',
            code: 'login_response_invalid',
          );
        });
        loginRegistered.complete();
        await sharedLogin;
      });
      final ownerFailure = expectLater(
        owner,
        throwsA(isA<DiagnosticException>()),
      );
      await loginRegistered.future;
      final waiter = log.operation<void>('sibling.waiter', () async {
        await dio.get<String>('https://service.example/waiter_private');
        try {
          await sharedLogin;
        } finally {
          if (loginEvidence case final evidence?) {
            AppLog.addEvidence('shared.login', evidence);
          }
        }
      });
      final waiterFailure = expectLater(
        waiter,
        throwsA(isA<DiagnosticException>()),
      );
      finishLogin.complete();
      await Future.wait([ownerFailure, waiterFailure]);
    });
    final owner = failedOperation('sibling.owner');
    final waiter = failedOperation('sibling.waiter');
    expect(owner['trace_id'], waiter['trace_id']);
    expect(owner['span_id'], isNot(waiter['span_id']));
    final ownerEvidence = jsonEncode(evidenceOf(owner));
    final waiterEvidence = jsonEncode(evidenceOf(waiter));
    expect(ownerEvidence, contains('sibling_login_marker_login'));
    expect(waiterEvidence, contains('sibling_login_marker_login'));
    expect(ownerEvidence, contains('sibling_login_marker_owner_private'));
    expect(
      ownerEvidence,
      isNot(contains('sibling_login_marker_waiter_private')),
    );
    expect(waiterEvidence, contains('sibling_login_marker_waiter_private'));
    expect(
      waiterEvidence,
      isNot(contains('sibling_login_marker_owner_private')),
    );
    expect(
      'sibling_login_marker_login'.allMatches(ownerEvidence),
      hasLength(1),
    );
    expect(
      'sibling_login_marker_login'.allMatches(waiterEvidence),
      hasLength(1),
    );
  });

  test('业务重试后的失败详情同时保留各次原始响应', () async {
    var attempt = 0;
    final dio = Dio(BaseOptions(responseType: ResponseType.plain));
    dio.httpClientAdapter = _Adapter(
      (_, _) async =>
          ResponseBody.fromString('raw_attempt_marker_${++attempt}', 200),
    );
    installHttpDiagnostics(dio);
    addTearDown(() => dio.close(force: true));
    await expectLater(
      AppLog.logger('test.retry').operation<void>('retry', () async {
        await dio.get<String>('https://service.example/query');
        await dio.get<String>('https://service.example/query');
        throw const DiagnosticException(
          '重试后仍然缺少数据',
          code: 'response_rows_missing',
        );
      }),
      throwsA(isA<DiagnosticException>()),
    );
    final evidence = jsonEncode(evidenceOf(failedOperation('retry')));
    expect('raw_attempt_marker_1'.allMatches(evidence), hasLength(1));
    expect('raw_attempt_marker_2'.allMatches(evidence), hasLength(1));
  });

  test('未发请求的输入证据同步脱敏并保存调用时快照', () async {
    final input = <String, Object?>{
      'token': 'synthetic-input-secret',
      'payload': 'original_input_marker',
    };
    await expectLater(
      AppLog.logger('test.input').operation<void>('input.parse', () async {
        AppLog.addEvidence('file.input', input);
        expect(input['token'], 'synthetic-input-secret');
        input['payload'] = 'mutated_after_recording';
        throw const FormatException('本地输入格式错误');
      }),
      throwsA(isA<FormatException>()),
    );
    final evidence = jsonEncode(evidenceOf(failedOperation('input.parse')));
    expect(evidence, contains('original_input_marker'));
    expect(evidence, isNot(contains('mutated_after_recording')));
    expect(evidence, isNot(contains('synthetic-input-secret')));
    expect(
      records.where(
        (record) => record['event'].toString().startsWith('http.exchange'),
      ),
      isEmpty,
    );
  });

  test('JSON 解码失败仍保留完整的解析前正文与原始错误', () async {
    final dio = Dio(BaseOptions(responseType: ResponseType.json));
    dio.httpClientAdapter = _Adapter(
      (_, _) async => ResponseBody.fromString(
        '{"token":"synthetic-secret","data": [broken response tail',
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      ),
    );
    installHttpDiagnostics(dio);
    addTearDown(() => dio.close(force: true));
    await expectLater(
      dio.get('https://service.example/balance'),
      throwsA(isA<DioException>()),
    );
    final detail = exchange();
    expect((detail['response'] as Map)['complete'], isTrue);
    expect(
      (detail['response'] as Map)['body'],
      contains('broken response tail'),
    );
    expect(jsonEncode(records), isNot(contains('synthetic-secret')));
    final failure = records.singleWhere(
      (record) => record['event'] == 'http.exchange_failed',
    );
    expect((failure['attrs'] as Map)['status_code'], 200);
    expect((failure['attrs'] as Map)['error_chain'], isNotEmpty);
  });

  test('VPN 原生原因码和系统码保留，故障上下文不覆盖请求原文', () {
    final native = VpnNativeException.fromResponse({
      'error': 'TLS peer rejected certificate',
      'diagnostic': {
        'code': 'native_start_failed',
        'stage': 'TLS',
        'native_kind': 'Other',
        'os_code': 42,
        'causes': ['CERTIFICATE_VERIFY_FAILED'],
      },
    }, method: 'start');
    AppLog.recordHttpExchange('test.vpn', {
      'request': {
        'url': 'https://service.example/path',
        'logical_body': 'mode=query',
      },
    }, error: native);
    final attrs = records.single['attrs'] as Map;
    expect(attrs['reason_code'], 'native_start_failed');
    expect(attrs['error_kind'], 'tls_handshake');
    expect(attrs['os_code'], 42);
    expect((attrs['details'] as Map)['request']['logical_body'], 'mode=query');
    expect(
      jsonEncode(attrs['error_chain']),
      contains('CERTIFICATE_VERIFY_FAILED'),
    );
  });

  test('TLS 在发送正文前失败仍保留请求输入和底层原因', () async {
    final dio = Dio();
    dio.httpClientAdapter = _Adapter(
      (_, _) async => throw HandshakeException('CERTIFICATE_VERIFY_FAILED'),
    );
    installHttpDiagnostics(dio);
    addTearDown(() => dio.close(force: true));
    await expectLater(
      dio.post(
        'https://service.example/balance',
        data: {'token': 'synthetic-secret', 'action': 'balance'},
      ),
      throwsA(isA<DioException>()),
    );
    final request = exchange()['request'] as Map;
    expect(request['complete'], isFalse);
    expect((request['logical_body'] as Map)['action'], 'balance');
    expect(jsonEncode(records), isNot(contains('synthetic-secret')));
    expect(jsonEncode(records), contains('CERTIFICATE_VERIFY_FAILED'));
  });

  test('完整堆栈保留帧与位置，仅遮蔽其中的认证参数', () {
    AppLog.logger('test.stack').warning(
      'failed',
      error: StateError('可定位的原始错误'),
      stackTrace: StackTrace.fromString(
        '#0 connect (https://service.example/path?ticket=synthetic-ticket:1:2)\n#1 main (package:nuist_sta_app/main.dart:9:2)',
      ),
    );
    final stack = (records.single['attrs'] as Map)['stack_trace'] as String;
    expect(stack, contains('#1 main (package:nuist_sta_app/main.dart:9:2)'));
    expect(stack, isNot(contains('synthetic-ticket')));
    expect(AppLog.formatDetails(records.single), contains('可定位的原始错误'));
  });

  test('一卡通固定路由参数不被当作姓名，真正个人参数仍遮蔽', () {
    const route =
        'https://service.example/plat-pc/?name=loginTransit&mode=full';
    expect(DiagnosticRedactor.text(route), route);
    expect(
      DiagnosticRedactor.text(
        'https://service.example/profile?name=synthetic-person',
      ),
      isNot(contains('synthetic-person')),
    );
  });

  test('落地地址的hash路由授权值遮蔽，保留实际位置与其他参数', () {
    const landing =
        'https://service.example/plat-pc/#/login?synjones-auth=synthetic-opaque-secret&mode=full';
    final cleaned = DiagnosticRedactor.text(landing);
    expect(cleaned, contains('#/login?synjones-auth='));
    expect(cleaned, contains('mode=full'));
    expect(cleaned, isNot(contains('synthetic-opaque-secret')));
  });

  test('共享登录详情关联生产者且不混入其他启动会话', () {
    final related = AppLog.relatedTraceIds([
      {
        'session_id': 'session-a',
        'trace_id': 'consumer',
        'attrs': {'shared_login_id': 7},
      },
      {
        'session_id': 'session-a',
        'trace_id': 'producer',
        'attrs': {'login_id': 7},
      },
      {
        'session_id': 'session-b',
        'trace_id': 'unrelated',
        'attrs': {'login_id': 7},
      },
    ], 'consumer');
    expect(related, {'consumer', 'producer'});
  });

  test('后台原生诊断先持久化再确认，保留原发生时间并再次脱敏', () async {
    final temp = await Directory.systemTemp.createTemp(
      'native_diagnostics_test_',
    );
    const channel = MethodChannel('nuist/diagnostic_logging');
    final at = DateTime.now().toUtc().subtract(const Duration(minutes: 3));
    final milliseconds = at.millisecondsSinceEpoch;
    final acknowledgements = <Object?>[];
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await AppLog.resetForTesting();
      await temp.delete(recursive: true);
    });
    await AppLog.initialize(directory: temp);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'readNativeDiagnostics') {
            return [
              {
                'id': 'native-event-a',
                'ts': milliseconds,
                'event': 'background.failed',
                'details': {
                  'stage': 'notification.deliver',
                  'reason_code': 'permission_denied',
                  'native_message': 'Permission denied token=synthetic-secret',
                },
              },
            ];
          }
          if (call.method == 'acknowledgeNativeDiagnostics') {
            expect(
              (await AppLog.snapshot()).content,
              contains('native-event-a'),
            );
            acknowledgements.add(call.arguments);
          }
          return null;
        });
    await AppLog.collectNativeDiagnosticsForTesting();
    expect(acknowledgements, [
      {
        'ids': ['native-event-a'],
      },
    ]);
    final imported = records.singleWhere(
      (record) => record['scope'] == 'timetable.native_background',
    );
    expect(
      imported['ts'],
      DateTime.fromMillisecondsSinceEpoch(
        milliseconds,
        isUtc: true,
      ).toIso8601String(),
    );
    expect(jsonEncode(imported), contains('Permission denied'));
    expect(jsonEncode(imported), isNot(contains('synthetic-secret')));
  });

  test('后台诊断写盘失败时保留原生队列，不提前确认删除', () async {
    final temp = await Directory.systemTemp.createTemp(
      'native_diagnostics_failure_test_',
    );
    const channel = MethodChannel('nuist/diagnostic_logging');
    var acknowledged = false;
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await AppLog.resetForTesting();
      await temp.delete(recursive: true);
    });
    await AppLog.initialize(directory: temp);
    await AppLog.snapshot();
    final logs = Directory('${temp.path}/nuist_sta_app/logs');
    await logs.delete(recursive: true);
    await File(logs.path).writeAsString('synthetic occupied path');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'readNativeDiagnostics') {
            return [
              {
                'id': 'native-event-b',
                'ts': DateTime.now().millisecondsSinceEpoch,
                'event': 'background.failed',
                'details': {'reason_code': 'permission_denied'},
              },
            ];
          }
          if (call.method == 'acknowledgeNativeDiagnostics') {
            acknowledged = true;
          }
          return null;
        });
    await AppLog.collectNativeDiagnosticsForTesting();
    expect(acknowledged, isFalse);
    expect(AppLog.storageAvailable.value, isFalse);
  });

  test('旁路采集不改变请求和响应，分片中的凭据在完整正文中脱敏', () async {
    String? sent;
    final dio = Dio(BaseOptions(responseType: ResponseType.plain));
    dio.httpClientAdapter = _Adapter((_, stream) async {
      sent = utf8.decode(await stream!.expand((part) => part).toList());
      return ResponseBody(
        Stream.fromIterable([
          Uint8List.fromList(utf8.encode('{"token":"synthetic-')),
          Uint8List.fromList(utf8.encode('secret","message":"原始错误详情"}')),
        ]),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    });
    installHttpDiagnostics(dio);
    installHttpDiagnostics(dio);
    addTearDown(() => dio.close(force: true));
    final result = await AppLog.logger('test.operation').operation(
      'query',
      () => dio.post(
        'https://service.example/query?ticket=synthetic-ticket&mode=full',
        data: '{"password":"synthetic-password","mode":"full"}',
        options: Options(
          contentType: Headers.jsonContentType,
          headers: {'Authorization': 'Bearer synthetic-auth'},
        ),
      ),
    );
    expect(sent, contains('synthetic-password'));
    expect(result.data, contains('synthetic-secret'));
    final detail = exchange();
    expect((detail['response'] as Map)['body'], contains('原始错误详情'));
    expect((detail['request'] as Map)['url'], contains('mode=full'));
    expect(
      jsonEncode(records),
      isNot(contains(RegExp(r'synthetic-(?:secret|password|auth|ticket)'))),
    );
    final root = records.singleWhere(
      (record) => record['event'] == 'query.completed',
    );
    final request = records.singleWhere(
      (record) => record['event'] == 'http.exchange',
    );
    expect(request['trace_id'], root['trace_id']);
    expect(request['parent_span_id'], root['span_id']);
  });

  test('TLS 最底层错误、系统码与原始堆栈在包装后可查看', () {
    final original = StackTrace.fromString(
      '#0 SecureSocket.secure (dart:io/secure_socket.dart:1:1)',
    );
    final cause = HandshakeException(
      'CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate',
    );
    AppLog.logger('test.tls').warning(
      'request.failed',
      error: DiagnosticException(
        '门户请求失败',
        code: 'tls_failed',
        stage: 'tls.handshake',
        cause: cause,
        causeStackTrace: original,
      ),
    );
    final attrs = records.single['attrs'] as Map;
    expect(attrs['error_kind'], 'tls_handshake');
    final chain = attrs['error_chain'] as List;
    expect(
      chain.last['message'],
      contains('unable to get local issuer certificate'),
    );
    expect(chain.last['stack_trace'], original.toString());
    expect(
      AppLog.formatDetails(records.single),
      contains('CERTIFICATE_VERIFY_FAILED'),
    );
  });

  test('中断响应保留已收到内容并明确标记不完整', () async {
    final dio = Dio(BaseOptions(responseType: ResponseType.stream));
    final source = StreamController<Uint8List>();
    dio.httpClientAdapter = _Adapter(
      (_, _) async => ResponseBody(
        source.stream,
        200,
        headers: {
          Headers.contentTypeHeader: ['text/plain'],
        },
      ),
    );
    installHttpDiagnostics(dio);
    addTearDown(() => dio.close(force: true));
    final response = await dio.get<ResponseBody>(
      'https://service.example/stream',
    );
    final reading = response.data!.stream.drain<void>();
    final failed = expectLater(reading, throwsA(isA<SocketException>()));
    source.add(Uint8List.fromList(utf8.encode('partial response')));
    source.addError(const SocketException('connection reset by peer'));
    await failed;
    await Future<void>.delayed(Duration.zero);
    await source.close();
    final body = exchange()['response'] as Map;
    expect(body['complete'], isFalse);
    expect(body['body'], 'partial response');
  });

  test('WebAuthn 与表单内嵌 JSON 脱敏，业务 id 保留', () {
    final assertion = jsonEncode({
      'id': 'synthetic-credential',
      'type': 'public-key',
      'response': {'signature': 'synthetic-signature'},
    });
    final form = 'responseJson=${Uri.encodeComponent(assertion)}&mode=login';
    final raw = jsonEncode({
      'allowCredentials': [
        {'id': 'synthetic-credential', 'type': 'public-key'},
      ],
      'body': jsonEncode({'token': 'synthetic-token'}),
      'id': 'business-item',
    });
    final cleaned = DiagnosticRedactor.text(raw);
    expect(cleaned, contains('business-item'));
    expect(cleaned, isNot(contains('synthetic-credential')));
    expect(cleaned, isNot(contains('synthetic-token')));
    expect(
      DiagnosticRedactor.text(form),
      isNot(contains('synthetic-credential')),
    );
    expect(
      DiagnosticRedactor.text(form),
      isNot(contains('synthetic-signature')),
    );
    expect(
      DiagnosticRedactor.text('Bad state: token=synthetic-token'),
      isNot(contains('synthetic-token')),
    );
  });

  test('大正文超过旧单条限制仍完整落盘、导出与清除', () async {
    final temp = await Directory.systemTemp.createTemp(
      'diagnostic_payload_test_',
    );
    addTearDown(() async {
      await AppLog.resetForTesting();
      await temp.delete(recursive: true);
    });
    await AppLog.initialize(directory: temp);
    final body = '${'x' * 700000}\n完整末尾标记';
    AppLog.recordHttpExchange('test.large', {
      'request_id': 1,
      'response': {'body': body, 'complete': true},
    });
    final snapshot = await AppLog.snapshot();
    expect(snapshot.content, contains('完整末尾标记'));
    final record = const LineSplitter()
        .convert(snapshot.content)
        .map(jsonDecode)
        .singleWhere((record) => record['scope'] == 'test.large');
    expect(record['attrs']['details']['response']['body'], body);
    final export = await AppLog.createExport({});
    expect(await export.readAsString(), contains('完整末尾标记'));
    final attachments = Directory('${temp.path}/nuist_sta_app/logs/records');
    expect(await attachments.list().length, 1);
    await AppLog.clear();
    expect(await attachments.list().length, 0);
    expect((await AppLog.snapshot()).content, isEmpty);
  });

  group('独立审查：脱敏边界', () {
    test('HTML控件名保留语义且隐藏token值', () {
      const raw = '<input name="token" value="synthetic-hidden-token">';
      final cleaned = DiagnosticRedactor.text(raw);
      expect(cleaned.contains('synthetic-hidden-token'), isFalse);
      expect(cleaned, contains('name="token"'));
    });

    test('中文文本装在base64正文时仍清除敏感字段', () {
      final raw = jsonEncode({
        'token': 'synthetic-binary-token',
        'message': '中文说明' * 100,
      });
      final cleaned = DiagnosticRedactor.value(
        base64Encode(utf8.encode(raw)),
        key: 'body_base64',
      ) as String;
      expect(
        utf8.decode(base64Decode(cleaned)).contains('synthetic-binary-token'),
        isFalse,
      );
    });

    test('td表头按列清除个人值并保留正常列', () {
      const raw =
          '<table><tr><td>姓名</td><td>状态</td></tr>'
          '<tr><td>synthetic-student-name</td><td>active</td></tr></table>';
      final cleaned = DiagnosticRedactor.text(raw);
      expect(cleaned.contains('synthetic-student-name'), isFalse);
      expect(cleaned, contains('状态'));
      expect(cleaned, contains('active'));
    });

    test('th敏感列后的普通表头不能被误当作个人值', () {
      const raw =
          '<table><tr><th>姓名</th><th>状态</th></tr>'
          '<tr><td>synthetic-student-name</td><td>active</td></tr></table>';
      final cleaned = DiagnosticRedactor.text(raw);
      expect(cleaned, contains('<th>状态</th>'));
      expect(cleaned.contains('synthetic-student-name'), isFalse);
    });

    test('CAS响应中的匿名凭据标识必须遮蔽', () {
      const raw = '{"datas":{"anonbiometricsd":"synthetic-device-secret"}}';
      expect(
        DiagnosticRedactor.text(raw).contains('synthetic-device-secret'),
        isFalse,
      );
    });

    test('CAS断言请求的id按接口语义遮蔽，业务id不受影响', () {
      final cleaned = DiagnosticRedactor.value({
        'request': {
          'url': 'https://cas.example/authserver/startAssertion',
          'body': '{"id":"synthetic-device-secret","userId":"synthetic-user"}',
        },
      });
      expect(jsonEncode(cleaned).contains('synthetic-device-secret'), isFalse);
      expect(
        DiagnosticRedactor.text('{"id":"business-id"}'),
        contains('business-id'),
      );
    });

    test('multipart只隐藏敏感字段值，不删字段名或后续正文', () {
      const raw =
          '--form-boundary\r\nContent-Disposition: form-data; name="password"\r\n\r\n'
          'synthetic-multipart-secret\r\n--form-boundary\r\nContent-Disposition: form-data; name="note"\r\n\r\n'
          'gateway diagnostic details\r\n--form-boundary--\r\n';
      final cleaned = DiagnosticRedactor.text(raw);
      expect(cleaned.contains('synthetic-multipart-secret'), isFalse);
      expect(cleaned, contains('name="password"'));
      expect(cleaned, contains('gateway diagnostic details'));
    });

    test('multipart多行敏感值必须整段替换', () {
      const raw =
          '--form-boundary\r\nContent-Disposition: form-data; name="privateKey"\r\n\r\n'
          'synthetic-secret-line-one\r\nsynthetic-secret-line-two\r\n--form-boundary--\r\n';
      final cleaned = DiagnosticRedactor.text(raw);
      expect(cleaned.contains('synthetic-secret'), isFalse);
      expect(cleaned, contains('name="privateKey"'));
      expect(cleaned, contains('--form-boundary--'));
    });

    test('HTML无引号属性与键值表格也正确处理', () {
      const raw =
          '<input name=token value=synthetic-unquoted-token>'
          '<table><tr><td>姓名</td><td>synthetic-person</td><td>学号</td><td>202512340001</td></tr></table>';
      final cleaned = DiagnosticRedactor.text(raw);
      expect(cleaned.contains('synthetic-unquoted-token'), isFalse);
      expect(cleaned.contains('synthetic-person'), isFalse);
      expect(cleaned, contains('name=token'));
    });

    test('JSON凭据净化不吞掉后续正常字段和错误说明', () {
      const raw =
          '{"Cookie":"synthetic-cookie","Authorization":"synthetic-auth",'
          '"JSESSIONID":"synthetic-session","CASTGC":"synthetic-cas",'
          '"x-client-device-id":"synthetic-device", "message":"gateway upstream failed","count":2}';
      final cleaned = DiagnosticRedactor.text(raw);
      expect(cleaned.contains('synthetic-'), isFalse);
      expect(cleaned, contains('gateway upstream failed'));
      expect(cleaned, contains('"count":2'));
      expect(jsonDecode(cleaned), isA<Map>());
    });

    test('没有敏感值的嵌套服务地址保留原始编码', () {
      const raw =
          'https://cas.example/login?service=https://business.example/home&mode=normal';
      expect(DiagnosticRedactor.text(raw), raw);
    });

    test('合并表头后的成绩列仍按实际列号脱敏', () {
      const raw =
          '<table><tr><th>序号</th><th colspan="2">姓名</th><th>成绩</th></tr>'
          '<tr><td>1</td><td>synthetic-cn-name</td><td>synthetic-en-name</td><td>93.5</td></tr></table>';
      final cleaned = DiagnosticRedactor.text(raw);
      expect(cleaned.contains('synthetic-'), isFalse);
      expect(cleaned.contains('93.5'), isFalse);
      expect(cleaned, contains('<td>1</td>'));
    });

    test('中文全角冒号后的个人值也会遮蔽', () {
      expect(
        DiagnosticRedactor.text('姓名：synthetic-person；请求失败')
            .contains('synthetic-person'),
        isFalse,
      );
    });
  });
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.callback);
  final Future<ResponseBody> Function(RequestOptions, Stream<Uint8List>?)
  callback;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => callback(options, requestStream);

  @override
  void close({bool force = false}) {}
}
