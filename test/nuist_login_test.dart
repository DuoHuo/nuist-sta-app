import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/auth/nuist_login.dart';
import 'package:nuist_sta_app/core/auth/portal_exceptions.dart';
import 'package:nuist_sta_app/core/auth/safe_message.dart';

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
          isA<PortalCredentialError>().having(
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
