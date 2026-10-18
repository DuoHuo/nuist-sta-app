import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

Course _course(String id) => Course(
  id: id,
  name: 'C $id',
  source: CourseSource.jwxt,
  slots: [CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: '1' * 16)],
);

Response<dynamic> _resp(
  Uri url, {
  int status = 200,
  dynamic data,
  String contentType = 'application/json',
  Uri? realUri,
}) {
  final ro = RequestOptions(path: url.toString());
  return Response<dynamic>(
    requestOptions: ro,
    statusCode: status,
    data: data,
    headers: Headers.fromMap({
      Headers.contentTypeHeader: [contentType],
    }),
    isRedirect: realUri != null,
    redirects: [if (realUri != null) RedirectRecord(302, 'GET', realUri)],
  );
}

void main() {
  late Directory tmp;
  final c = TimetableController.instance;
  final loginHtml = File('test/fixtures/timetable/login_redirect_mock.html')
      .readAsStringSync();
  final gateway502Html = File('test/fixtures/timetable/gateway_502.html')
      .readAsStringSync();
  final webvpnMaintenanceHtml = File(
    'test/fixtures/timetable/webvpn_maintenance.html',
  ).readAsStringSync();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tt_fail');
    TimetableStore.debugDirectory = tmp;
    TimetableController.clock = () => DateTime(2026, 10, 11);
    c.debugReset();
  });

  tearDown(() async {
    TimetableStore.debugDirectory = null;
    TimetableApi.debugPost = null;
    TimetableApi.debugPostResponse = null;
    TimetableController.clock = TimetableApi.shanghaiToday;
    TimetableController.fetchSnapshot = (term, {baseSettings}) =>
        TimetableApi.fetchTermSnapshot(term, baseSettings: baseSettings);
    c.debugReset();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> seedCache() async {
    c.debugSetSnapshot(
      TimetableSnapshot(
        courses: [_course('cached')],
        periods: TimetableController.defaultPeriods(),
        settings: const TimetableSettings(termCode: '2026-2027-1'),
      ),
    );
  }

  Future<void> expectFailure(TimetableSyncFailure f) async {
    await seedCache();
    await c.syncFromJwxt();
    expect(c.syncStatus, TimetableSyncStatus.failure);
    expect(c.syncFailure, f);
    expect(c.jwxtCourses.map((e) => e.id), ['cached'], reason: 'cache kept');
  }

  group('classification via debugPost', () {
    test('timeout → network', () async {
      TimetableApi.debugPost = (u, f) async => throw TimeoutException('t');
      await expectFailure(TimetableSyncFailure.network);
    });
    test('SocketException/DNS → network', () async {
      TimetableApi.debugPost = (u, f) async =>
          throw const SocketException('Failed host lookup');
      await expectFailure(TimetableSyncFailure.network);
    });
    test('Dio connectionTimeout → network', () async {
      TimetableApi.debugPost = (u, f) async => throw DioException(
        requestOptions: RequestOptions(path: u.toString()),
        type: DioExceptionType.connectionTimeout,
      );
      await expectFailure(TimetableSyncFailure.network);
    });
    test('HTTP 5xx → server', () async {
      TimetableApi.debugPost = (u, f) async =>
          throw const JwxtHttpError('cxxszhxqkb.do', 502);
      await expectFailure(TimetableSyncFailure.server);
    });
    test('other → unknown', () async {
      TimetableApi.debugPost = (u, f) async => throw StateError('x');
      await expectFailure(TimetableSyncFailure.unknown);
    });
  });

  group('classification via raw response (relogin path)', () {
    test('login_redirect_mock.html after relogin → sessionExpired', () async {
      var calls = 0;
      TimetableApi.debugPostResponse = (u, f, {required force}) async {
        calls++;
        return _resp(u, data: loginHtml, contentType: 'text/html');
      };
      await expectFailure(TimetableSyncFailure.sessionExpired);
      expect(calls, 2, reason: 'one original + one relogin attempt');
    });
    test(
      '200 HTML after redirect to authserver/login → sessionExpired',
      () async {
        TimetableApi.debugPostResponse = (u, f, {required force}) async =>
            _resp(
              u,
              data: '<html><body>请登录</body></html>',
              contentType: 'text/html;charset=UTF-8',
              realUri: Uri.parse(
                'https://authserver.example.test/authserver/login?service=x',
              ),
            );
        await expectFailure(TimetableSyncFailure.sessionExpired);
      },
    );
    test('200 JSON code != 0 → unknown', () async {
      TimetableApi.debugPostResponse = (u, f, {required force}) async =>
          _resp(u, data: {'code': '1', 'msg': 'err'});
      await expectFailure(TimetableSyncFailure.unknown);
    });
    test('raw 503 → server', () async {
      TimetableApi.debugPostResponse = (u, f, {required force}) async =>
          _resp(u, status: 503, data: 'oops', contentType: 'text/plain');
      await expectFailure(TimetableSyncFailure.server);
    });
  });

  group('HTML error pages (classification order)', () {
    final errorHtml = {
      502: gateway502Html,
      // Keep 503 inline: body intentionally contains 'authserver' to ensure
      // 5xx is classified as server before session-expired HTML checks.
      503:
          '<!DOCTYPE html><html><body><h1>503 Service Unavailable</h1>'
          '<p>请访问 authserver 稍后重试</p></body></html>',
      504: gateway502Html,
    };
    for (final entry in errorHtml.entries) {
      test('${entry.key} HTML → server, 0 relogins', () async {
        var calls = 0;
        var forced = 0;
        TimetableApi.debugPostResponse = (u, f, {required force}) async {
          calls++;
          if (force) forced++;
          return _resp(
            u,
            status: entry.key,
            data: entry.value,
            contentType: 'text/html;charset=UTF-8',
          );
        };
        await expectFailure(TimetableSyncFailure.server);
        expect(forced, 0, reason: 'never relogin on 5xx');
        expect(calls, 1);
      });
    }

    test('200 casLoginForm HTML → relogin once, then sessionExpired', () async {
      var calls = 0;
      var forced = 0;
      TimetableApi.debugPostResponse = (u, f, {required force}) async {
        calls++;
        if (force) forced++;
        return _resp(
          u,
          data:
              '<html><body><form id="casLoginForm" method="post">'
              '<input name="username"/><input name="password"/>'
              '</form></body></html>',
          contentType: 'text/html;charset=UTF-8',
        );
      };
      await expectFailure(TimetableSyncFailure.sessionExpired);
      expect(forced, 1, reason: 'exactly one relogin');
      expect(calls, 2);
    });

    test('200 maintenance HTML → unknown, 0 relogins', () async {
      var calls = 0;
      var forced = 0;
      TimetableApi.debugPostResponse = (u, f, {required force}) async {
        calls++;
        if (force) forced++;
        return _resp(
          u,
          data: webvpnMaintenanceHtml,
          contentType: 'text/html;charset=UTF-8',
        );
      };
      await expectFailure(TimetableSyncFailure.unknown);
      expect(forced, 0, reason: 'maintenance page must not trigger relogin');
      expect(calls, 1);
    });
  });

  test('success resets syncFailure to none', () async {
    TimetableApi.debugPost = (u, f) async => throw TimeoutException('t');
    await expectFailure(TimetableSyncFailure.network);
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        TimetableSnapshot(
          courses: [_course('a')],
          settings: baseSettings ?? const TimetableSettings(),
        );
    await c.syncFromJwxt();
    expect(c.syncStatus, TimetableSyncStatus.success);
    expect(c.syncFailure, TimetableSyncFailure.none);
  });

  test(
    'concurrent sync calls share one in-flight Future / one request',
    () async {
      await seedCache();
      var requests = 0;
      final gate = Completer<void>();
      TimetableController.fetchSnapshot = (term, {baseSettings}) async {
        requests++;
        await gate.future;
        return TimetableSnapshot(
          courses: [_course('a')],
          settings: baseSettings ?? const TimetableSettings(),
        );
      };
      final f1 = c.syncFromJwxt();
      final f2 = c.syncFromJwxt();
      expect(identical(f1, f2), isTrue);
      gate.complete();
      await Future.wait([f1, f2]);
      expect(requests, 1);
      expect(c.syncStatus, TimetableSyncStatus.success);
    },
  );
}
