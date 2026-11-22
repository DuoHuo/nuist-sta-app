import 'dart:async';
import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/auth/campus_transport.dart';
import 'package:nuist_sta_app/core/auth/cas_session.dart';
import 'package:nuist_sta_app/core/auth/portal_cookie_store.dart';
import 'package:nuist_sta_app/core/auth/session_executor.dart';
import 'package:nuist_sta_app/core/config/campus_config.dart';
import 'package:nuist_sta_app/mini_apps/academic/academic_api.dart';
import 'package:nuist_sta_app/mini_apps/electricity/electricity_api.dart';
import 'package:nuist_sta_app/mini_apps/free_classroom/free_classroom_api.dart';
import 'package:nuist_sta_app/mini_apps/innovation_credit/innovation_credit_api.dart';
import 'package:nuist_sta_app/mini_apps/labor_score/labor_score_api.dart';
import 'package:nuist_sta_app/mini_apps/library/library_api.dart';
import 'package:nuist_sta_app/mini_apps/score/score_api.dart';
import 'package:nuist_sta_app/mini_apps/student_info/student_info_api.dart';

class _MemoryStorage implements Storage {
  final values = <String, String>{};
  @override
  Future<void> init(bool persistSession, bool ignoreExpires) async {}
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<void> deleteAll(List<String> keys) async {
    keys.forEach(values.remove);
  }
}

class _Harness {
  _Harness(this.failurePath, this.firstStatus) {
    dio.httpClientAdapter = _Adapter(this);
    final transport = CampusTransport.authenticated(
      dio: dio,
      cookieStore: cookies,
    );
    executor = SessionExecutor(
      transport: transport,
      cookieStore: cookies,
      authenticate: (service, {bool forceFreshWebAuthn = false}) async {
        logins++;
        final host = Uri.parse(service).host;
        return CasAuthenticationResult(
          landingUri: Uri.https(
            host,
            '/mock-landing',
            host == CampusHosts.icard
                ? {'synjones-auth': 'token-$logins'}
                : null,
          ),
        );
      },
    );
  }
  final String failurePath;
  final int firstStatus;
  final cookies = PortalCookieStore(storage: _MemoryStorage());
  final dio = Dio();
  late final SessionExecutor executor;
  final business = <RequestOptions>[];
  int logins = 0;
  int rejected = 0;

  Future<void> seed(List<String> hosts) async {
    for (final host in hosts) {
      await cookies.openJar().saveFromResponse(Uri.https(host, '/'), [
        Cookie('dirty', 'old'),
      ]);
    }
  }

  ResponseBody response(RequestOptions options) {
    final path = options.uri.path;
    final bool landing = path == '/mock-landing';
    if (landing) {
      return ResponseBody.fromString(
        options.uri.host == CampusHosts.cxcyjy
            ? '<html><input name="__RequestVerificationToken" value="test-token"></html>'
            : '<html>业务登录成功</html>',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html'],
          if (options.uri.host == CampusHosts.library)
            'set-cookie': ['CSRF-TOKEN=csrf-$logins; Path=/'],
        },
      );
    }
    if (path.contains('/AccessSubsystem/')) {
      expect(options.headers['Referer'], 'https://${CampusHosts.cxcyjy}/pt/');
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': [
            'https://${CampusHosts.cxxf}/authserver/access?access=test-ticket',
          ],
        },
      );
    }
    if (path == '/authserver/access') {
      expect(options.headers['Referer'], 'https://${CampusHosts.cxcyjy}/pt/');
      return ResponseBody.fromString(
        '<html>换票成功</html>',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html'],
        },
      );
    }
    if (path.endsWith('/UnifiedAuthenticationLogin')) {
      return _json({
        'Success': true,
        'Data': {'RedirectUrl': '/System/User/LoginRole'},
      });
    }
    if (path.endsWith('/LoginRole') || path.endsWith('/index.do')) {
      return ResponseBody.fromString(
        '<html>业务首页</html>',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html'],
        },
      );
    }
    business.add(options);
    final matchedPath = failurePath.contains('#')
        ? '$path#${options.uri.queryParameters['pc']}'
        : path;
    if (matchedPath == failurePath && (rejected == 0 || firstStatus >= 500)) {
      rejected++;
      return ResponseBody.fromString(
        firstStatus == 200 ? '' : '合成服务拒绝',
        firstStatus,
      );
    }
    if (path.endsWith('/xscjcx.do')) {
      return _json({
        'code': '0',
        'datas': {
          'xscjcx': {'rows': []},
        },
      });
    }
    if (path.endsWith('/jxlcx.do')) {
      return _json({
        'code': '0',
        'datas': {
          'jxlcx': {'rows': []},
        },
      });
    }
    if (path.endsWith('/czjl')) return _json({'XH': '202512340001'});
    if (path.endsWith('/getLoginUserAndGuest')) {
      return _json({
        'errcode': 0,
        'data': {'userAccount': '202512340001', 'userName': '测试用户'},
      });
    }
    if (path.endsWith('/execTemplateMethod')) {
      return _json({'errcode': 0, 'data': {}});
    }
    if (path.endsWith('/getThirdData')) {
      expect(options.headers['synjones-auth'], 'bearer token-$logins');
      return _json({
        'code': 200,
        'map': {'data': []},
      });
    }
    if (path.endsWith('/users/loans')) {
      expect(options.headers['X-CSRF-TOKEN'], 'csrf-$logins');
      return _json({
        'code': 0,
        'data': {'items': [], 'total': 0},
      });
    }
    final table = options.extra['authTableId'];
    if (table is String) {
      return ResponseBody.fromString(
        '<html><table id="$table"><thead><tr><th>项目</th></tr></thead><tbody></tbody></table></html>',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html'],
        },
      );
    }
    throw StateError('测试中出现未定义的接口：$path');
  }

  static ResponseBody _json(Object value) => ResponseBody.fromString(
    jsonEncode(value),
    200,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.harness);
  final _Harness harness;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async => harness.response(options);
  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    ScoreApi.debugExecutor = null;
    FreeClassroomApi.debugExecutor = null;
    AcademicApi.debugExecutor = null;
    StudentInfoApi.debugExecutor = null;
    ElectricityApi.debugExecutor = null;
    InnovationCreditApi.debugExecutor = null;
    LaborScoreApi.debugExecutor = null;
  });

  final cases =
      <(String, String, List<String>, Future<Object?> Function(_Harness))>[
        (
          'score',
          '/jwapp/sys/cjcx/modules/cjcx/xscjcx.do',
          [CampusHosts.jwxt],
          (h) {
            ScoreApi.debugExecutor = h.executor;
            return ScoreApi.fetch();
          },
        ),
        (
          'free_classroom',
          '/jwapp/sys/kxjas/modules/kxjas/jxlcx.do',
          [CampusHosts.jwxt],
          (h) {
            FreeClassroomApi.debugExecutor = h.executor;
            return FreeClassroomApi.listBuildings();
          },
        ),
        (
          'academic',
          '/cus/jxmh/czjl',
          [CampusHosts.iportal],
          (h) {
            AcademicApi.debugExecutor = h.executor;
            return AcademicApi.fetchSummary();
          },
        ),
        (
          'student_info用户',
          '/getLoginUserAndGuest',
          [CampusHosts.iportal],
          (h) {
            StudentInfoApi.debugExecutor = h.executor;
            return StudentInfoApi.fetch();
          },
        ),
        (
          'student_info校历',
          '/execTemplateMethod',
          [CampusHosts.iportal],
          (h) {
            StudentInfoApi.debugExecutor = h.executor;
            return StudentInfoApi.fetch();
          },
        ),
        (
          'electricity',
          '/charge/feeitem/getThirdData',
          [CampusHosts.icard],
          (h) {
            ElectricityApi.debugExecutor = h.executor;
            return ElectricityApi.listCampuses();
          },
        ),
        (
          'library',
          '/meta-local/opac/users/loans',
          [CampusHosts.library],
          (h) => LibraryApi(executor: h.executor).fetchLoans(1),
        ),
        (
          'innovation汇总',
          '/XueFen/SummaryQuery/Index',
          [CampusHosts.cxcyjy, CampusHosts.cxxf],
          (h) {
            InnovationCreditApi.debugExecutor = h.executor;
            return InnovationCreditApi.fetch();
          },
        ),
        (
          'innovation明细',
          '/XueFen/Summary/Index',
          [CampusHosts.cxcyjy, CampusHosts.cxxf],
          (h) {
            InnovationCreditApi.debugExecutor = h.executor;
            return InnovationCreditApi.fetch();
          },
        ),
        (
          'labor主页',
          '/ResultManage/StudentResult',
          [CampusHosts.labor],
          (h) {
            LaborScoreApi.debugExecutor = h.executor;
            return LaborScoreApi.fetch();
          },
        ),
        (
          'labor生活',
          '/Activity/StudentJiFen/Index#生活',
          [CampusHosts.labor],
          (h) {
            LaborScoreApi.debugExecutor = h.executor;
            return LaborScoreApi.fetch();
          },
        ),
        (
          'labor服务',
          '/Activity/StudentJiFen/Index#服务',
          [CampusHosts.labor],
          (h) {
            LaborScoreApi.debugExecutor = h.executor;
            return LaborScoreApi.fetch();
          },
        ),
        (
          'labor专业',
          '/ResultManage/ZYLDScoreHZ/Index4DefaultGrades',
          [CampusHosts.labor],
          (h) {
            LaborScoreApi.debugExecutor = h.executor;
            return LaborScoreApi.fetch();
          },
        ),
      ];
  for (final scenario in cases.skip(2).take(3)) {
    test('${scenario.$1}空响应统一重登恢复', () async {
      final h = _Harness(scenario.$2, 200);
      addTearDown(() => h.dio.close(force: true));
      expect(await scenario.$4(h), isNotNull);
      expect(h.logins, 2);
      expect(h.rejected, 1);
    });
  }
  for (final scenario in cases) {
    for (final status in [401, 403]) {
      test('${scenario.$1}首跳$status清Cookie并统一重登重试', () async {
        final h = _Harness(scenario.$2, status);
        addTearDown(() => h.dio.close(force: true));
        await h.seed(scenario.$3);
        expect(await scenario.$4(h), isNotNull);
        expect(h.logins, 2);
        expect(h.rejected, 1);
        for (final host in scenario.$3) {
          final cookies = await h.cookies.openJar().loadForRequest(
            Uri.https(host, '/'),
          );
          expect(cookies.where((cookie) => cookie.name == 'dirty'), isEmpty);
        }
        expect(
          h.business.every((options) => options.extra['idempotent'] == true),
          isTrue,
        );
      });
    }
    test('${scenario.$1}服务5xx不触发重登', () async {
      final h = _Harness(scenario.$2, 503);
      addTearDown(() => h.dio.close(force: true));
      await expectLater(scenario.$4(h), throwsA(anything));
      expect(h.logins, 1);
      expect(h.rejected, 1);
    });
  }
}
