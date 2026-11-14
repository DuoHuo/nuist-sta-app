import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/auth/nuist_login.dart';
import 'package:nuist_sta_app/core/auth/portal_exceptions.dart';
import 'package:nuist_sta_app/core/auth/safe_message.dart';
import 'package:nuist_sta_app/core/auth/portal_http.dart';
import 'package:nuist_sta_app/core/logging/diagnostic_error.dart';

const _forbidden = [
  '{',
  '<html',
  '<!DOCTYPE',
  'JSESSIONID',
  'CASTGC',
  'Set-Cookie',
];

void _expectSafe(Object? data) {
  try {
    NuistLogin.parseStartAssertion(data, statusCode: 502);
    fail('should throw');
  } on PortalException catch (e) {
    final msg = e.message;
    for (final f in _forbidden) {
      expect(
        msg.toLowerCase().contains(f.toLowerCase()),
        isFalse,
        reason: 'leaked "$f": $msg',
      );
    }
    expect(msg.length, lessThanOrEqualTo(100));
  }
}

void main() {
  group('认证诊断保留失败依据', () {
    test('响应外壳错误与缺少 request 有不同原因码', () {
      expect(
        () => NuistLogin.parseStartAssertion([], statusCode: 200),
        throwsA(
          isA<PortalLoginError>()
              .having((e) => e.code, 'code', 'assertion_response_not_object')
              .having((e) => e.stage, 'stage', 'cas.asserting'),
        ),
      );
      expect(
        () =>
            NuistLogin.parseStartAssertion({'success': true}, statusCode: 200),
        throwsA(
          isA<PortalLoginError>()
              .having((e) => e.code, 'code', 'assertion_request_missing')
              .having((e) => e.context['status_code'], 'status', 200),
        ),
      );
    });

    test('HTTP错误保留状态、Dio原因与原始栈，不误报门户登录失败', () async {
      final dio = Dio();
      addTearDown(() => dio.close(force: true));
      final options = RequestOptions(path: 'https://campus.test/service');
      final originalStack = StackTrace.fromString(
        '#0 syntheticTransport (transport.dart:4:2)',
      );
      final original = DioException(
        requestOptions: options,
        type: DioExceptionType.badResponse,
        response: Response<dynamic>(requestOptions: options, statusCode: 503),
        stackTrace: originalStack,
      );
      try {
        await PortalHttp(dio).send(() => Future.error(original, originalStack));
        fail('应抛出服务响应错误');
      } catch (error, stackTrace) {
        expect(error, isA<DiagnosticException>());
        final diagnostic = error as DiagnosticException;
        expect(diagnostic.code, 'http_status_rejected');
        expect(diagnostic.context['status_code'], 503);
        expect(diagnostic.cause, same(original));
        expect(diagnostic.causeStackTrace, same(originalStack));
        expect(stackTrace.toString(), originalStack.toString());
      }
    });

    test('Dio包裹的门户异常使用原始栈重新抛出', () async {
      final dio = Dio();
      addTearDown(() => dio.close(force: true));
      const original = PortalCredentialError(
        '合成凭据已失效',
        code: 'credential_not_allowed',
        stage: 'cas.signing',
      );
      final originalStack = StackTrace.fromString(
        '#0 syntheticSign (signer.dart:8:2)',
      );
      final wrapped = DioException(
        requestOptions: RequestOptions(path: 'https://campus.test/service'),
        error: original,
        stackTrace: originalStack,
      );
      try {
        await PortalHttp(dio).send(() => Future.error(wrapped));
        fail('应保留凭据错误');
      } catch (error, stackTrace) {
        expect(error, same(original));
        expect(stackTrace.toString(), originalStack.toString());
      }
    });
  });
  // L01
  group('L01 startAssertion 错误文案不泄漏原始响应', () {
    test('gateway_502.html', () {
      _expectSafe(
        File('test/fixtures/timetable/gateway_502.html').readAsStringSync(),
      );
    });
    test('login_redirect_mock.html', () {
      _expectSafe(
        File('test/fixtures/timetable/login_redirect_mock.html')
            .readAsStringSync(),
      );
    });
    test('JSON body without request / success:false without message', () {
      _expectSafe({
        'code': 1,
        'datas': {'x': 'JSESSIONID=abc'},
      });
      _expectSafe({
        'success': false,
        'data': {'CASTGC': 'TGT-1'},
      });
      _expectSafe('{"foo":"bar","Set-Cookie":"JSESSIONID=1"}');
    });
    test('server message itself is HTML / cookie / too long', () {
      const html = '<!DOCTYPE html><html><body>502 Bad Gateway</body></html>';
      _expectSafe({'success': false, 'message': html});
      _expectSafe({'message': html});
      _expectSafe({'success': false, 'message': 'Set-Cookie: CASTGC=TGT-x'});
      _expectSafe({'message': '错' * 150});
      _expectSafe({
        'success': false,
        'message': {'nested': 1},
      });
    });
    test('plain short server message is kept', () {
      expect(
        () => NuistLogin.parseStartAssertion({'message': '未查询到设备信息'}),
        throwsA(
          isA<PortalCredentialError>().having(
            (e) => e.message,
            'message',
            startsWith('未查询到设备信息'),
          ),
        ),
      );
      expect(
        () => NuistLogin.parseStartAssertion({
          'success': false,
          'message': '<b>x</b>',
        }),
        throwsA(
          isA<PortalLoginError>().having(
            (e) => e.message,
            'message',
            kLoginFailedText,
          ),
        ),
      );
    });
  });

  test('safeServerMessage', () {
    expect(safeServerMessage('设备不存在'), '设备不存在');
    expect(safeServerMessage(42), kLoginFailedText);
    expect(safeServerMessage('{"a":1}'), kLoginFailedText);
    expect(safeServerMessage('JSESSIONID=1'), kLoginFailedText);
    expect(prefixedServerMessage('前缀：', '<html>'), kLoginFailedText);
  });
}
