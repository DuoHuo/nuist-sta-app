import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:nuist_sta_app/core/config/campus_config.dart';
import 'package:nuist_sta_app/core/logging/app_log.dart';
import 'package:nuist_sta_app/core/logging/diagnostic_error.dart';
import 'package:nuist_sta_app/core/logging/diagnostic_redactor.dart';
import 'package:nuist_sta_app/core/logging/diagnostic_worker.dart';
import 'package:nuist_sta_app/core/logging/http_diagnostics.dart';
import 'package:nuist_sta_app/core/network/vpn_native.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final records = <Map<String, Object?>>[];
  setUp(() async {
    diagnosticSpoolWriteForTesting = null;
    diagnosticSpoolDirectoryForTesting = null;
    diagnosticSpoolFailAfterBytesForTesting = null;
    diagnosticBeforePersistForTesting = null;
    await AppLog.resetForTesting();
    records.clear();
    AppLog.recordListenerForTesting = records.add;
  });
  tearDown(() async {
    diagnosticSpoolWriteForTesting = null;
    diagnosticSpoolDirectoryForTesting = null;
    diagnosticSpoolFailAfterBytesForTesting = null;
    diagnosticBeforePersistForTesting = null;
    await AppLog.resetForTesting();
  });

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

  test('共享登录消费者（独立 Trace 与同父 Trace 兄弟）只附登录证据，不混入对方业务正文', () async {
    Future<void> verify({required bool sameParent}) async {
      records.clear();
      final loginRegistered = Completer<void>();
      final finishLogin = Completer<void>();
      late Future<void> sharedLogin;
      Map<String, Object?>? loginEvidence;
      final dio = Dio(BaseOptions(responseType: ResponseType.plain));
      dio.httpClientAdapter = _Adapter((options, _) async {
        final endpoint = options.uri.pathSegments.last;
        if (endpoint == 'login') await finishLogin.future;
        return ResponseBody.fromString('shared_marker_$endpoint', 200);
      });
      installHttpDiagnostics(dio);
      addTearDown(() => dio.close(force: true));

      Future<void> run() async {
        final log = AppLog.logger('test.shared');
        final owner = log.operation<void>('owner', () async {
          await dio.get<String>('https://service.example/owner_private');
          sharedLogin = log.operation<void>('shared.login', () async {
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
        final waiter = log.operation<void>('waiter', () async {
          if (sameParent) {
            await dio.get<String>('https://service.example/waiter_private');
          }
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
      }

      if (sameParent) {
        await AppLog.logger('test.shared')
            .operation<void>('shared.parent', run);
      } else {
        await run();
      }

      final ownerRecord = failedOperation('owner');
      final waiterRecord = failedOperation('waiter');
      if (sameParent) {
        expect(ownerRecord['trace_id'], waiterRecord['trace_id']);
        expect(ownerRecord['span_id'], isNot(waiterRecord['span_id']));
      } else {
        expect(ownerRecord['trace_id'], isNot(waiterRecord['trace_id']));
      }
      final ownerEvidence = jsonEncode(evidenceOf(ownerRecord));
      final waiterEvidence = jsonEncode(evidenceOf(waiterRecord));
      expect(ownerEvidence, contains('shared_marker_owner_private'));
      expect('shared_marker_login'.allMatches(ownerEvidence), hasLength(1));
      expect('shared_marker_login'.allMatches(waiterEvidence), hasLength(1));
      expect(waiterEvidence, isNot(contains('shared_marker_owner_private')));
      if (sameParent) {
        expect(ownerEvidence, isNot(contains('shared_marker_waiter_private')));
        expect(waiterEvidence, contains('shared_marker_waiter_private'));
      }
    }

    await verify(sameParent: false);
    await verify(sameParent: true);
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
              {
                'id': 'native-icon-event',
                'ts': milliseconds,
                'scope': 'app_icon.native_background',
                'event': 'background.degraded',
                'details': {
                  'stage': 'app_icon.pin_confirmation',
                  'reason_code': 'confirmed_dynamic_cleanup_failed',
                  'native_message': 'Synthetic shortcut cleanup failure',
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
        'ids': ['native-event-a', 'native-icon-event'],
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
    final iconEvent = records.singleWhere(
      (record) => record['scope'] == 'app_icon.native_background',
    );
    expect(iconEvent['event'], 'background.degraded');
    expect(jsonEncode(iconEvent), contains('confirmed_dynamic_cleanup_failed'));
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

  test('大响应后台脱敏后才交付业务，解析失败仍包含完整证据', () async {
    final directory = await Directory.systemTemp.createTemp('http-spool-test-');
    addTearDown(() async {
      await AppLog.resetForTesting();
      await directory.delete(recursive: true);
    });
    await AppLog.initialize(directory: directory);
    final body = jsonEncode({
      'rows': List.generate(
        1200,
        (i) => {
          'id': i,
          'message': '完整非敏感正文',
          'token': 'synthetic-large-secret',
        },
      ),
      'tail': '后台处理末尾标记',
    });
    final dio = Dio(BaseOptions(responseType: ResponseType.plain));
    dio.httpClientAdapter = _Adapter(
      (_, _) async => ResponseBody.fromString(
        body,
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      ),
    );
    installHttpDiagnostics(dio);
    addTearDown(() => dio.close(force: true));
    await expectLater(
      AppLog.logger('test.large').operation<void>('parse', () async {
        final response = await dio.get<String>('https://service.example/large');
        expect(response.data, body);
        final evidence = httpDiagnosticEvidence(response.requestOptions);
        expect(
          (evidence!['exchange'] as Map)['response']['body_attachment'],
          isTrue,
        );
        final full = await AppLog.readRecord(
          evidence['record_ref'] as Map<String, Object?>,
        );
        expect(
          records.where((r) => r['event'] == 'capture.attachment_failed'),
          isEmpty,
          reason: jsonEncode(
            records
                .where((r) => r['event'] == 'attachment.write_failed')
                .toList(),
          ),
        );
        expect(jsonEncode(full), contains('后台处理末尾标记'));
        expect(jsonEncode(evidence), isNot(contains('synthetic-large-secret')));
        throw const DiagnosticException('合成解析失败', code: 'schema_changed');
      }),
      throwsA(isA<DiagnosticException>()),
    );
    final failed = failedOperation('parse');
    expect(jsonEncode(evidenceOf(failed)), contains('body_attachment'));
    expect(
      jsonEncode(evidenceOf(failed)),
      isNot(contains('synthetic-large-secret')),
    );
  });

  test('图书馆的大借阅响应不进入诊断附件且完整交付给业务', () async {
    final body = jsonEncode({
      'items': ['synthetic-library-loan' * 4000],
    });
    var spoolWrites = 0;
    diagnosticSpoolWriteForTesting = (_) async {
      spoolWrites++;
    };
    addTearDown(() => diagnosticSpoolWriteForTesting = null);
    final dio = Dio(BaseOptions(responseType: ResponseType.plain))
      ..httpClientAdapter = _Adapter(
        (_, _) async => ResponseBody.fromString(body, 200),
      );
    installHttpDiagnostics(dio);
    addTearDown(() => dio.close(force: true));

    final response = await dio.getUri<String>(
      Uri.https(CampusHosts.library, '/meta-local/opac/users/loans'),
    );
    expect(response.data, body);
    expect(spoolWrites, 0);
    final logged = exchange()['response'] as Map;
    expect(logged['body'], DiagnosticRedactor.personal);
    expect(logged['captured_bytes'], utf8.encode(body).length);
    expect(logged['complete'], isTrue);
    expect(logged, isNot(contains('body_attachment')));
    expect(jsonEncode(records), isNot(contains('synthetic-library-loan')));
  });

  test('大流式响应读完后立即失败也保留完整后台诊断', () async {
    final directory = await Directory.systemTemp.createTemp('http-spool-test-');
    addTearDown(() async {
      await AppLog.resetForTesting();
      await directory.delete(recursive: true);
    });
    await AppLog.initialize(directory: directory);
    final body = '${'合成诊断正文' * 6000}流式末尾标记';
    final dio = Dio(BaseOptions(responseType: ResponseType.stream));
    dio.httpClientAdapter = _Adapter(
      (_, _) async => ResponseBody.fromString(body, 200),
    );
    installHttpDiagnostics(dio);
    addTearDown(() => dio.close(force: true));
    await expectLater(
      AppLog.logger('test.stream').operation<void>('stream_parse', () async {
        final response = await dio.get<ResponseBody>(
          'https://service.example/stream',
        );
        await response.data!.stream.drain<void>();
        final evidence = httpDiagnosticEvidence(response.requestOptions)!;
        final full = await AppLog.readRecord(
          evidence['record_ref'] as Map<String, Object?>,
        );
        expect(jsonEncode(full), contains('流式末尾标记'));
        throw const DiagnosticException('合成解析失败', code: 'schema_changed');
      }),
      throwsA(isA<DiagnosticException>()),
    );
    expect(
      jsonEncode(evidenceOf(failedOperation('stream_parse'))),
      contains('body_attachment'),
    );
  });

  test('大响应报错后源流立即关闭，后台诊断不产生关闭后写入异常', () async {
    final directory = await Directory.systemTemp.createTemp('http-spool-test-');
    addTearDown(() async {
      await AppLog.resetForTesting();
      await directory.delete(recursive: true);
    });
    await AppLog.initialize(directory: directory);
    final source = StreamController<Uint8List>();
    final dio = Dio(BaseOptions(responseType: ResponseType.plain));
    dio.httpClientAdapter = _Adapter(
      (_, _) async => ResponseBody(source.stream, 200),
    );
    installHttpDiagnostics(dio);
    addTearDown(() => dio.close(force: true));
    final request = dio.get<String>('https://service.example/broken');
    final failure = expectLater(request, throwsA(isA<DioException>()));
    await Future<void>.delayed(Duration.zero);
    source.add(Uint8List.fromList(utf8.encode('合成中断正文' * 6000)));
    source.addError(const SocketException('synthetic connection reset'));
    await source.close();
    await failure;
    final body = exchange()['response'] as Map;
    expect(body['complete'], isFalse);
    final record = records.singleWhere(
      (r) => r['event'] == 'http.exchange_failed',
    );
    final full = await AppLog.readRecord({
      'session_id': record['session_id'],
      'seq': record['seq'],
    });
    expect(jsonEncode(full), contains('合成中断正文'));
  });

  test('后台诊断无法跨 isolate 复制时明确记录缺口且业务调用正常结束', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final result = await AppLog.recordHttpExchangeAsync('test.capture', {
      'response': {'body': 'x' * 20000},
      'invalid_test_value': server,
    });
    expect(result, isNull);
    expect(records.last['event'], 'capture.failed');
    expect(jsonEncode(records.last), contains('diagnostic_processing_failed'));
  });

  test('可信大二进制文件直接作为附件保存，正文不进入索引且所有字节可导出', () async {
    final directory = await Directory.systemTemp.createTemp(
      'native-body-test-',
    );
    addTearDown(() async {
      await AppLog.resetForTesting();
      await directory.delete(recursive: true);
    });
    await AppLog.initialize(directory: directory);
    final bytes = Uint8List.fromList(
      List.generate(2 * 1024 * 1024, (i) => i % 256),
    );
    final file = File('${directory.path}/synthetic.bin');
    await file.writeAsBytes(bytes);
    await AppLog.recordHttpFileExchange('test.native.file', {
      'response': {'status': 200},
    }, file);
    final summary = records.singleWhere(
      (r) => r['scope'] == 'test.native.file',
    );
    expect(jsonEncode(summary), isNot(contains('body_base64')));
    final preview = await AppLog.snapshot(expandAttachments: false);
    expect(preview.content.length, lessThan(4096));
    final full = await AppLog.readRecord({
      'session_id': summary['session_id'],
      'seq': summary['seq'],
    }, timeout: const Duration(seconds: 30));
    final response =
        ((full!['attrs'] as Map)['details'] as Map)['response'] as Map;
    expect(base64Decode(response['body_base64'] as String), bytes);
    final exported = await AppLog.createExport({});
    expect(await exported.length(), greaterThan(bytes.length));
    expect(await file.exists(), isTrue);
  });

  test('大请求和响应双附件，取消后仍保留已收正文并释放采集临时文件', () async {
    final directory = await Directory.systemTemp.createTemp(
      'cancel-spool-test-',
    );
    addTearDown(() async {
      await AppLog.resetForTesting();
      await directory.delete(recursive: true);
    });
    await AppLog.initialize(directory: directory);
    final source = StreamController<Uint8List>();
    final dio = Dio(BaseOptions(responseType: ResponseType.stream));
    dio.httpClientAdapter = _Adapter((_, request) async {
      await request!.drain<void>();
      return ResponseBody(source.stream, 200);
    });
    installHttpDiagnostics(dio);
    addTearDown(() => dio.close(force: true));
    final response = await dio.post<ResponseBody>(
      'https://service.example/cancel',
      data: '${'请求正文' * 10000}请求末尾',
    );
    final got = Completer<void>();
    final reading = response.data!.stream.listen((_) => got.complete());
    source.add(Uint8List.fromList(utf8.encode('${'响应正文' * 10000}取消末尾')));
    await got.future;
    await reading.cancel();
    // 直接订阅适配器外侧流；Dio 自身包装流在 cancel 时不传递源订阅关闭。
    source.addError(const SocketException('synthetic cancelled capture'));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final evidence = httpDiagnosticEvidence(response.requestOptions);
    expect(evidence, isNotNull, reason: jsonEncode(records));
    final full = await AppLog.readRecord(
      evidence!['record_ref'] as Map<String, Object?>,
    );
    final detail = (full!['attrs'] as Map)['details'] as Map;
    expect(detail['request']['body'], contains('请求末尾'));
    expect(detail['response']['body'], contains('取消末尾'));
    expect(detail['response']['complete'], isFalse);
    await source.close();
  });

  test('大认证正文按整个端点上下文脱敏，不落入附件凭据', () async {
    final directory = await Directory.systemTemp.createTemp(
      'credential-spool-test-',
    );
    addTearDown(() async {
      await AppLog.resetForTesting();
      await directory.delete(recursive: true);
    });
    await AppLog.initialize(directory: directory);
    final body = jsonEncode({
      'id': 'synthetic-credential-id',
      'padding': '正常诊断' * 20000,
    });
    final file = File('${directory.path}/synthetic.json');
    await file.writeAsString(body);
    await AppLog.recordHttpFileExchange('test.credential.file', {
      'request': {'url': 'https://service.example/authserver/startassertion'},
      'response': {'status': 200},
    }, file);
    final record = records.singleWhere(
      (r) => r['scope'] == 'test.credential.file',
    );
    final full = await AppLog.readRecord({
      'session_id': record['session_id'],
      'seq': record['seq'],
    });
    expect(jsonEncode(full), isNot(contains('synthetic-credential-id')));
    expect(jsonEncode(full), contains('正常诊断'));
  });

  test('写入大块正文途中取消等待当前块结束，不并发关闭后台回执', () async {
    final directory = await Directory.systemTemp.createTemp(
      'inflight-spool-test-',
    );
    addTearDown(() async {
      await AppLog.resetForTesting();
      await directory.delete(recursive: true);
    });
    await AppLog.initialize(directory: directory);
    final source = StreamController<Uint8List>();
    final dio = Dio(BaseOptions(responseType: ResponseType.stream));
    final token = CancelToken();
    dio.httpClientAdapter = _Adapter(
      (_, _) async => ResponseBody(source.stream, 200),
    );
    installHttpDiagnostics(dio);
    addTearDown(() => dio.close(force: true));
    final response = await dio.get<ResponseBody>(
      'https://service.example/inflight',
      cancelToken: token,
    );
    final error = expectLater(
      response.data!.stream.drain<void>(),
      throwsA(isA<DioException>()),
    );
    source.add(Uint8List(512 * 1024));
    await Future<void>.delayed(Duration.zero);
    token.cancel('synthetic cancellation');
    await error;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await source.close();
    expect(records.any((r) => r['event'] == 'capture.failed'), isFalse);
  });

  test('非流式大正文响应立即交付业务，不等待后台脱敏压缩与附件落盘', () async {
    final directory = await Directory.systemTemp.createTemp('http-async-test-');
    addTearDown(() async {
      diagnosticBeforePersistForTesting = null;
      await AppLog.resetForTesting();
      await directory.delete(recursive: true);
    });
    await AppLog.initialize(directory: directory);
    final allowPersist = Completer<void>();
    final persistStarted = Completer<void>();
    diagnosticBeforePersistForTesting = () {
      if (!persistStarted.isCompleted) persistStarted.complete();
      return allowPersist.future;
    };
    final body = jsonEncode({
      'token': 'synthetic-nonblocking-secret',
      'padding': '非阻塞正文' * 20000,
      'tail': '非阻塞末尾标记',
    });
    final dio = Dio(BaseOptions(responseType: ResponseType.plain));
    dio.httpClientAdapter = _Adapter(
      (_, _) async => ResponseBody.fromString(
        body,
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      ),
    );
    installHttpDiagnostics(dio);
    addTearDown(() => dio.close(force: true));

    final response = await dio.get<String>(
      'https://service.example/nonblocking',
    );
    expect(response.data, body);
    await persistStarted.future;
    expect(allowPersist.isCompleted, isFalse);

    final evidence = httpDiagnosticEvidence(response.requestOptions);
    expect(evidence, isNotNull);
    expect(
      (evidence!['exchange'] as Map)['response']['body_attachment'],
      isTrue,
    );
    final reference = evidence['record_ref'] as Map<String, Object?>;

    allowPersist.complete();
    final full = await AppLog.readRecord(reference);
    expect(full, isNotNull);
    expect(jsonEncode(full), contains('非阻塞末尾标记'));
    expect(jsonEncode(full), isNot(contains('synthetic-nonblocking-secret')));
  });

  test('多次大正文请求复用单一常驻后台 Worker Isolate', () async {
    final directory = await Directory.systemTemp.createTemp(
      'http-worker-test-',
    );
    addTearDown(() async {
      await AppLog.resetForTesting();
      await directory.delete(recursive: true);
    });
    await AppLog.initialize(directory: directory);
    final dio = Dio(BaseOptions(responseType: ResponseType.plain));
    dio.httpClientAdapter = _Adapter(
      (options, _) async => ResponseBody.fromString(
        '${'常驻复用正文' * 15000}-${options.uri.pathSegments.last}',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/plain'],
        },
      ),
    );
    installHttpDiagnostics(dio);
    addTearDown(() => dio.close(force: true));

    final refs = <Map<String, Object?>>[];
    for (var i = 0; i < 3; i++) {
      final response = await dio.get<String>('https://service.example/item$i');
      refs.add(
        httpDiagnosticEvidence(response.requestOptions)!['record_ref']
            as Map<String, Object?>,
      );
    }
    expect(DiagnosticWorker.spawnCountForTesting, 1);
    for (var i = 0; i < 3; i++) {
      final full = await AppLog.readRecord(refs[i]);
      expect(jsonEncode(full), contains('item$i'));
    }
  });

  test('流式响应中断（小正文与大正文背压）均保留已收前缀并标记不完整', () async {
    final directory = await Directory.systemTemp.createTemp(
      'http-backpressure-test-',
    );
    addTearDown(() async {
      await AppLog.resetForTesting();
      await directory.delete(recursive: true);
    });
    await AppLog.initialize(directory: directory);

    // 1. 小正文流中断直接内联保留前缀。
    final smallSource = StreamController<Uint8List>();
    final smallDio = Dio(BaseOptions(responseType: ResponseType.stream))
      ..httpClientAdapter = _Adapter(
        (_, _) async => ResponseBody(
          smallSource.stream,
          200,
          headers: {
            Headers.contentTypeHeader: ['text/plain'],
          },
        ),
      );
    installHttpDiagnostics(smallDio);
    addTearDown(() => smallDio.close(force: true));
    final smallResponse = await smallDio.get<ResponseBody>(
      'https://service.example/stream',
    );
    final smallFailed = expectLater(
      smallResponse.data!.stream.drain<void>(),
      throwsA(isA<SocketException>()),
    );
    smallSource.add(Uint8List.fromList(utf8.encode('partial response')));
    smallSource.addError(const SocketException('connection reset by peer'));
    await smallFailed;
    await Future<void>.delayed(Duration.zero);
    await smallSource.close();
    final smallBody = exchange()['response'] as Map;
    expect(smallBody['complete'], isFalse);
    expect(smallBody['body'], 'partial response');

    // 2. 大正文流触发背压后中断仍完整保留已接收前缀。
    records.clear();
    final source = StreamController<Uint8List>();
    final dio = Dio(BaseOptions(responseType: ResponseType.stream))
      ..httpClientAdapter = _Adapter(
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
      'https://service.example/backpressure',
    );
    final receivedBytes = <int>[];
    final done = Completer<void>();
    Object? streamError;
    response.data!.stream.listen(
      receivedBytes.addAll,
      onError: (Object error) {
        streamError = error;
        if (!done.isCompleted) done.complete();
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );

    final prefix = utf8.encode('${'背压前缀' * 40000}prefix-tail');
    source.add(Uint8List.fromList(prefix));
    source.addError(const SocketException('synthetic backpressure reset'));
    await done.future;
    await source.close();

    expect(streamError, isA<SocketException>());
    expect(receivedBytes.length, prefix.length);
    await waitForPendingHttpDiagnostics();
    final evidence = httpDiagnosticEvidence(response.requestOptions);
    expect(evidence, isNotNull);
    final full = await AppLog.readRecord(
      evidence!['record_ref'] as Map<String, Object?>,
    );
    final detail = (full!['attrs'] as Map)['details']['response'] as Map;
    expect(detail['complete'], isFalse);
    expect(detail['body'], contains('prefix-tail'));
    expect(records.any((r) => r['event'] == 'capture.failed'), isFalse);
  });

  test('非落盘中等正文在后台脱敏或持久化挂起期间报错或查询证据不丢失正文', () async {
    final directory = await Directory.systemTemp.createTemp(
      'http-medium-race-',
    );
    addTearDown(() async {
      diagnosticBeforePersistForTesting = null;
      await AppLog.resetForTesting();
      await directory.delete(recursive: true);
    });
    await AppLog.initialize(directory: directory);
    final reqBody = jsonEncode({
      'password': 'synthetic-medium-req-secret',
      'pad': '请求中等正文' * 2500,
      'tail': '请求尾部标记',
    });
    final resBody = jsonEncode({
      'token': 'synthetic-medium-res-secret',
      'pad': '响应中等正文' * 2500,
      'tail': '响应尾部标记',
    });
    expect(utf8.encode(reqBody).length, inExclusiveRange(16 * 1024, 64 * 1024));
    expect(utf8.encode(resBody).length, inExclusiveRange(16 * 1024, 64 * 1024));

    final allowFinish = Completer<void>();
    diagnosticBeforePersistForTesting = () => allowFinish.future;

    final dio = Dio(BaseOptions(responseType: ResponseType.plain));
    dio.httpClientAdapter = _Adapter((_, stream) async {
      await stream!.drain<void>();
      return ResponseBody.fromString(
        resBody,
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    });
    installHttpDiagnostics(dio);
    addTearDown(() => dio.close(force: true));

    Map<String, Object?>? liveEvidence;
    await expectLater(
      AppLog.logger('test.medium').operation<void>('medium.parse', () async {
        final response = await dio.post<String>(
          'https://service.example/medium',
          data: reqBody,
          options: Options(contentType: Headers.jsonContentType),
        );
        // 让 _finish 进入异步 _describeBodyInBackground / 挂起窗口后再同步读取证据。
        await Future<void>.delayed(const Duration(milliseconds: 20));
        liveEvidence = httpDiagnosticEvidence(response.requestOptions);
        throw const DiagnosticException('中等正文解析失败', code: 'schema_changed');
      }),
      throwsA(isA<DiagnosticException>()),
    );

    final liveJson = jsonEncode(liveEvidence);
    expect(liveJson, contains('请求尾部标记'));
    expect(liveJson, contains('响应尾部标记'));
    expect(liveJson, isNot(contains('synthetic-medium-req-secret')));
    expect(liveJson, isNot(contains('synthetic-medium-res-secret')));

    final failedJson = jsonEncode(evidenceOf(failedOperation('medium.parse')));
    expect(failedJson, contains('请求尾部标记'));
    expect(failedJson, contains('响应尾部标记'));
    expect(failedJson, isNot(contains('synthetic-medium-req-secret')));
    expect(failedJson, isNot(contains('synthetic-medium-res-secret')));

    allowFinish.complete();
    final ref = liveEvidence!['record_ref'] as Map<String, Object?>;
    final full = await AppLog.readRecord(ref);
    final persistedJson = jsonEncode(full);
    expect(persistedJson, contains('请求尾部标记'));
    expect(persistedJson, contains('响应尾部标记'));
    expect(persistedJson, isNot(contains('synthetic-medium-req-secret')));
    expect(persistedJson, isNot(contains('synthetic-medium-res-secret')));
  });

  test('流水线 spoolOpen 失败时不产生未捕获异步异常且保留错误标记', () async {
    final directory = await Directory.systemTemp.createTemp('http-open-fail-');
    final blockerDir = await Directory('${directory.path}/spool').create();
    await Directory('${blockerDir.path}/body.bin').create();
    addTearDown(() async {
      diagnosticSpoolDirectoryForTesting = null;
      await AppLog.resetForTesting();
      await directory.delete(recursive: true);
    });
    await AppLog.initialize(directory: directory);
    diagnosticSpoolDirectoryForTesting = blockerDir;

    final body = 'open失败正文' * 20000;
    final unhandled = <Object>[];
    Response<String>? response;
    await runZonedGuarded(
      () async {
        final dio = Dio(BaseOptions(responseType: ResponseType.plain));
        dio.httpClientAdapter = _Adapter(
          (_, _) async => ResponseBody.fromString(body, 200),
        );
        installHttpDiagnostics(dio);
        addTearDown(() => dio.close(force: true));
        response = await dio.get<String>('https://service.example/open-fail');
        await waitForPendingHttpDiagnostics();
      },
      (error, stack) {
        unhandled.add(error);
      },
    );

    expect(unhandled, isEmpty);
    expect(response!.data, body);
    final ref =
        httpDiagnosticEvidence(response!.requestOptions)!['record_ref']
            as Map<String, Object?>;
    final full = await AppLog.readRecord(ref);
    final captured = (full!['attrs'] as Map)['details']['response'] as Map;
    expect(captured['complete'], isFalse);
    expect(captured['incomplete_reason'], 'capture_spool_write_failed');
  });

  test('流水线触发背压或半途 spoolWrite 失败无未捕获异常、不死锁且保留精确前缀', () async {
    final directory = await Directory.systemTemp.createTemp('http-pipe-fail-');
    addTearDown(() async {
      diagnosticSpoolWriteForTesting = null;
      diagnosticSpoolFailAfterBytesForTesting = null;
      await AppLog.resetForTesting();
      await directory.delete(recursive: true);
    });
    await AppLog.initialize(directory: directory);

    Future<void> runCase(String path, String body) async {
      final unhandled = <Object>[];
      Response<String>? response;
      await runZonedGuarded(() async {
        final dio = Dio(BaseOptions(responseType: ResponseType.plain));
        dio.httpClientAdapter = _Adapter(
          (_, _) async => ResponseBody.fromString(body, 200),
        );
        installHttpDiagnostics(dio);
        addTearDown(() => dio.close(force: true));
        response = await dio.get<String>('https://service.example/$path');
        await waitForPendingHttpDiagnostics();
      }, (error, stack) => unhandled.add(error));
      expect(unhandled, isEmpty, reason: path);
      expect(response!.data, body, reason: path);
      final ref =
          httpDiagnosticEvidence(response!.requestOptions)!['record_ref']
              as Map<String, Object?>;
      final full = await AppLog.readRecord(ref);
      final captured = (full!['attrs'] as Map)['details']['response'] as Map;
      expect(captured['body'], 'A' * (64 * 1024), reason: path);
      expect(captured['complete'], isFalse, reason: path);
      expect(
        captured['incomplete_reason'],
        'capture_spool_write_failed',
        reason: path,
      );
    }

    diagnosticSpoolWriteForTesting = (written) async {
      if (written >= 64 * 1024) {
        throw const FileSystemException('synthetic disk unavailable');
      }
    };
    await runCase('partial', '${'A' * (64 * 1024)}正文末尾${'B' * (64 * 1024)}');
    diagnosticSpoolWriteForTesting = null;

    diagnosticSpoolFailAfterBytesForTesting = 64 * 1024;
    await runCase('pipe-fail', '${'A' * (64 * 1024)}${'B' * (640 * 1024)}');
  });

  group('脱敏边界', () {
    test('HTML 表单控件、无引号属性、表格列/合并表头与全角冒号脱敏', () {
      final quotedInput = DiagnosticRedactor.text(
        '<input name="token" value="synthetic-hidden-token">',
      );
      expect(quotedInput, isNot(contains('synthetic-hidden-token')));
      expect(quotedInput, contains('name="token"'));

      final unquotedAndKv = DiagnosticRedactor.text(
        '<input name=token value=synthetic-unquoted-token>'
        '<table><tr><td>姓名</td><td>synthetic-person</td><td>学号</td><td>202512340001</td></tr></table>',
      );
      expect(unquotedAndKv, isNot(contains('synthetic-unquoted-token')));
      expect(unquotedAndKv, isNot(contains('synthetic-person')));
      expect(unquotedAndKv, contains('name=token'));

      final tdTable = DiagnosticRedactor.text(
        '<table><tr><td>姓名</td><td>状态</td></tr>'
        '<tr><td>synthetic-student-name</td><td>active</td></tr></table>',
      );
      expect(tdTable, isNot(contains('synthetic-student-name')));
      expect(tdTable, contains('状态'));
      expect(tdTable, contains('active'));

      final thTable = DiagnosticRedactor.text(
        '<table><tr><th>姓名</th><th>状态</th></tr>'
        '<tr><td>synthetic-student-name</td><td>active</td></tr></table>',
      );
      expect(thTable, contains('<th>状态</th>'));
      expect(thTable, isNot(contains('synthetic-student-name')));

      final colspanTable = DiagnosticRedactor.text(
        '<table><tr><th>序号</th><th colspan="2">姓名</th><th>成绩</th></tr>'
        '<tr><td>1</td><td>synthetic-cn-name</td><td>synthetic-en-name</td><td>93.5</td></tr></table>',
      );
      expect(colspanTable, isNot(contains('synthetic-')));
      expect(colspanTable, isNot(contains('93.5')));
      expect(colspanTable, contains('<td>1</td>'));

      expect(
        DiagnosticRedactor.text('姓名：synthetic-person；请求失败'),
        isNot(contains('synthetic-person')),
      );
    });

    test('JSON 凭据、CAS 断言与 WebAuthn 内嵌表单脱敏，业务 id 与正常字段保留', () {
      const jsonRaw =
          '{"Cookie":"synthetic-cookie","Authorization":"synthetic-auth",'
          '"JSESSIONID":"synthetic-session","CASTGC":"synthetic-cas",'
          '"x-client-device-id":"synthetic-device", "message":"gateway upstream failed","count":2}';
      final jsonCleaned = DiagnosticRedactor.text(jsonRaw);
      expect(jsonCleaned, isNot(contains('synthetic-')));
      expect(jsonCleaned, contains('gateway upstream failed'));
      expect(jsonCleaned, contains('"count":2'));
      expect(jsonDecode(jsonCleaned), isA<Map>());

      expect(
        DiagnosticRedactor.text(
          '{"datas":{"anonbiometricsd":"synthetic-device-secret"}}',
        ),
        isNot(contains('synthetic-device-secret')),
      );

      final casCleaned = DiagnosticRedactor.value({
        'request': {
          'url': 'https://cas.example/authserver/startAssertion',
          'body': '{"id":"synthetic-device-secret","userId":"synthetic-user"}',
        },
      });
      expect(
        jsonEncode(casCleaned),
        isNot(contains('synthetic-device-secret')),
      );
      expect(
        DiagnosticRedactor.text('{"id":"business-id"}'),
        contains('business-id'),
      );

      final assertion = jsonEncode({
        'id': 'synthetic-credential',
        'type': 'public-key',
        'response': {'signature': 'synthetic-signature'},
      });
      final form = 'responseJson=${Uri.encodeComponent(assertion)}&mode=login';
      final webAuthn = DiagnosticRedactor.text(
        jsonEncode({
          'allowCredentials': [
            {'id': 'synthetic-credential', 'type': 'public-key'},
          ],
          'body': jsonEncode({'token': 'synthetic-token'}),
          'id': 'business-item',
        }),
      );
      expect(webAuthn, contains('business-item'));
      expect(webAuthn, isNot(contains('synthetic-credential')));
      expect(webAuthn, isNot(contains('synthetic-token')));
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

    test('URL 路由参数、Multipart 多行与 Base64 文本正文脱敏', () {
      const safeRoute =
          'https://service.example/plat-pc/?name=loginTransit&mode=full';
      expect(DiagnosticRedactor.text(safeRoute), safeRoute);
      expect(
        DiagnosticRedactor.text(
          'https://service.example/profile?name=synthetic-person',
        ),
        isNot(contains('synthetic-person')),
      );

      const safeServiceUrl =
          'https://cas.example/login?service=https://business.example/home&mode=normal';
      expect(DiagnosticRedactor.text(safeServiceUrl), safeServiceUrl);

      final hashLanding = DiagnosticRedactor.text(
        'https://service.example/plat-pc/#/login?synjones-auth=synthetic-opaque-secret&mode=full',
      );
      expect(hashLanding, contains('#/login?synjones-auth='));
      expect(hashLanding, contains('mode=full'));
      expect(hashLanding, isNot(contains('synthetic-opaque-secret')));

      final singleMultipart = DiagnosticRedactor.text(
        '--form-boundary\r\nContent-Disposition: form-data; name="password"\r\n\r\n'
        'synthetic-multipart-secret\r\n--form-boundary\r\nContent-Disposition: form-data; name="note"\r\n\r\n'
        'gateway diagnostic details\r\n--form-boundary--\r\n',
      );
      expect(singleMultipart, isNot(contains('synthetic-multipart-secret')));
      expect(singleMultipart, contains('name="password"'));
      expect(singleMultipart, contains('gateway diagnostic details'));

      final multiLineMultipart = DiagnosticRedactor.text(
        '--form-boundary\r\nContent-Disposition: form-data; name="privateKey"\r\n\r\n'
        'synthetic-secret-line-one\r\nsynthetic-secret-line-two\r\n--form-boundary--\r\n',
      );
      expect(multiLineMultipart, isNot(contains('synthetic-secret')));
      expect(multiLineMultipart, contains('name="privateKey"'));
      expect(multiLineMultipart, contains('--form-boundary--'));

      final rawBase64Json = jsonEncode({
        'token': 'synthetic-binary-token',
        'message': '中文说明' * 100,
      });
      final cleanedBase64 = DiagnosticRedactor.value(
        base64Encode(utf8.encode(rawBase64Json)),
        key: 'body_base64',
      ) as String;
      expect(
        utf8.decode(base64Decode(cleanedBase64)),
        isNot(contains('synthetic-binary-token')),
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
