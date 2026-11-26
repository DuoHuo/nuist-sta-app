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
import 'package:nuist_sta_app/core/logging/app_log.dart';
import 'package:nuist_sta_app/core/logging/diagnostic_error.dart';
import 'package:nuist_sta_app/mini_apps/academic/academic_api.dart';
import 'package:nuist_sta_app/mini_apps/academic/academic_models.dart';
import 'package:nuist_sta_app/mini_apps/electricity/electricity_api.dart';
import 'package:nuist_sta_app/mini_apps/electricity/electricity_models.dart';
import 'package:nuist_sta_app/mini_apps/free_classroom/free_classroom_api.dart';
import 'package:nuist_sta_app/mini_apps/free_classroom/free_classroom_models.dart';
import 'package:nuist_sta_app/mini_apps/innovation_credit/innovation_credit_api.dart';
import 'package:nuist_sta_app/mini_apps/innovation_credit/innovation_credit_models.dart';
import 'package:nuist_sta_app/mini_apps/labor_score/labor_score_api.dart';
import 'package:nuist_sta_app/mini_apps/labor_score/labor_score_models.dart';
import 'package:nuist_sta_app/mini_apps/library/library_api.dart';
import 'package:nuist_sta_app/mini_apps/library/library_models.dart';
import 'package:nuist_sta_app/mini_apps/score/score_api.dart';
import 'package:nuist_sta_app/mini_apps/score/score_models.dart';
import 'package:nuist_sta_app/mini_apps/student_info/student_info_api.dart';
import 'package:nuist_sta_app/mini_apps/student_info/student_info_models.dart';

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
  _Harness(
    this.failurePath,
    this.firstStatus, {
    this.firstBody,
    this.firstContentType,
  }) {
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
  final Object? firstBody;
  final String? firstContentType;
  final cookies = PortalCookieStore(storage: _MemoryStorage());
  final dio = Dio();
  late final SessionExecutor executor;
  final business = <RequestOptions>[];
  int logins = 0;
  int rejected = 0;

  List<RequestOptions> get targetRequests => business.where(_targets).toList();

  bool _targets(RequestOptions options) {
    final requestPath = failurePath.contains('#')
        ? '${options.uri.path}#${options.uri.queryParameters['pc']}'
        : options.uri.path;
    return requestPath == failurePath;
  }

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
    if (_targets(options) && (rejected == 0 || firstStatus >= 500)) {
      rejected++;
      if (firstBody != null) {
        return ResponseBody.fromString(
          firstBody is String ? firstBody as String : jsonEncode(firstBody),
          firstStatus,
          headers: {
            Headers.contentTypeHeader: [firstContentType ?? 'application/json'],
          },
        );
      }
      if (firstStatus >= 300) {
        // 错误状态仍携带完整成功数据：旧代码会错误解析成功，不能靠坏正文蒙混通过。
        final success = _successful(options);
        return ResponseBody(
          success.stream,
          firstStatus,
          headers: success.headers,
        );
      }
      return ResponseBody.fromString(
        firstStatus == 200 ? '' : '合成服务拒绝',
        firstStatus,
      );
    }
    return _successful(options);
  }

  ResponseBody _successful(RequestOptions options) {
    final path = options.uri.path;
    if (path.endsWith('/xscjcx.do')) {
      return _json({
        'code': '0',
        'datas': {
          'xscjcx': {
            'rows': [
              {'KCM': '合成课程', 'KCH': 'mock-course', 'ZCJ': '90'},
            ],
          },
        },
      });
    }
    if (path.endsWith('/jxlcx.do')) {
      return _json({
        'code': '0',
        'datas': {
          'jxlcx': {
            'rows': [
              {'JXLDM': 'mock-building', 'JXLMC': '测试教学楼'},
            ],
          },
        },
      });
    }
    if (path.endsWith('/czjl')) {
      return _json({'XH': '202512340001', 'GPA': '3.5'});
    }
    if (path.endsWith('/getLoginUserAndGuest')) {
      return _json({
        'errcode': 0,
        'data': {
          'userAccount': '202512340001',
          'userName': '测试用户',
          'categoryName': '学生/本科生',
        },
      });
    }
    if (path.endsWith('/execTemplateMethod')) {
      return _json({
        'errcode': 0,
        'data': {
          'xn': '2026',
          'xq': '1',
          'ksrq': '2026-09-01',
          'jsrq': '2027-01-31',
          'maxWeeks': '20',
        },
      });
    }
    if (path.endsWith('/getThirdData')) {
      expect(options.headers['synjones-auth'], 'bearer token-$logins');
      return _json({
        'code': 200,
        'map': {
          'data': [
            {'name': '测试校区', 'value': 'mock-campus'},
          ],
        },
      });
    }
    if (path.endsWith('/users/loans')) {
      expect(options.headers['X-CSRF-TOKEN'], 'csrf-$logins');
      return _json({
        'code': 0,
        'data': {
          'items': [
            {
              'bibId': 'mock-book',
              'bibAttrs': {'title': '合成馆藏'},
            },
          ],
          'total': 1,
        },
      });
    }
    final table = options.extra['authTableId'];
    if (table is String) {
      final fields = switch (table) {
        'c_app_page_index_SummaryQuery_table' => {'总学分': '2', '成绩': '及格'},
        'c_app_page_index_Summary_table' => {'项目名称': '合成项目', '实际分值': '2'},
        'ResultManage_StudentResult_Index_table' => {'总积分': '12'},
        'c_app_page_index_StudentJiFen_table' => {
          '总积分': options.uri.queryParameters['pc'] == '生活' ? '3' : '4',
        },
        'ResultManage_ZYLDScoreHZ_Index_table' => {
          '专业劳动课程积分': '2',
          '竞赛项目积分': '3',
          '专业劳动累计积分': '5',
        },
        _ => throw StateError('测试中出现未定义的表格：$table'),
      };
      return ResponseBody.fromString(
        '<html><table id="$table"><thead><tr>${fields.keys.map((key) => '<th>$key</th>').join()}</tr></thead>'
        '<tbody><tr>${fields.values.map((value) => '<td>$value</td>').join()}</tr></tbody></table></html>',
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
      _expectResult(await scenario.$4(h));
      expect(h.logins, 2);
      expect(h.rejected, 1);
      expect(h.targetRequests, hasLength(2));
    });
  }
  for (final scenario in cases) {
    test('${scenario.$1}首跳401/403清Cookie并统一重登重试', () async {
      for (final status in [401, 403]) {
        final h = _Harness(scenario.$2, status);
        try {
          await h.seed(scenario.$3);
          _expectResult(await scenario.$4(h));
          expect(h.logins, 2, reason: 'status=$status');
          expect(h.rejected, 1, reason: 'status=$status');
          expect(h.targetRequests, hasLength(2), reason: 'status=$status');
          for (final host in scenario.$3) {
            final cookies = await h.cookies.openJar().loadForRequest(
              Uri.https(host, '/'),
            );
            expect(
              cookies.where((cookie) => cookie.name == 'dirty'),
              isEmpty,
              reason: 'status=$status host=$host',
            );
          }
          expect(
            h.business.every((options) => options.extra['idempotent'] == true),
            isTrue,
            reason: 'status=$status',
          );
        } finally {
          h.dio.close(force: true);
        }
      }
    });
    if (scenario.$1 != 'library') {
      test('${scenario.$1}成功形状的422正文不能当成业务成功', () async {
        final h = _Harness(scenario.$2, 422);
        addTearDown(() => h.dio.close(force: true));
        await expectLater(
          scenario.$4(h),
          throwsA(
            isA<DiagnosticException>()
                .having((error) => error.code, 'code', 'http_status_rejected')
                .having(
                  (error) => error.context['status_code'],
                  'status_code',
                  422,
                ),
          ),
        );
        expect(h.logins, 1);
        expect(h.rejected, 1);
      });
    }
    test('${scenario.$1}成功形状的503正文仍保留状态且不触发重登', () async {
      final h = _Harness(scenario.$2, 503);
      addTearDown(() => h.dio.close(force: true));
      if (scenario.$1.startsWith('labor') && scenario.$1 != 'labor主页') {
        final records = <Map<String, Object?>>[];
        AppLog.recordListenerForTesting = records.add;
        addTearDown(() => AppLog.recordListenerForTesting = null);
        final score = await scenario.$4(h) as LaborScore;
        _expectLabor(score, failedSection: scenario.$1);
        final failure = records.singleWhere(
          (record) =>
              record['scope'] == 'labor_score.api' &&
              record['event'] == 'section.unavailable',
        );
        final attrs = failure['attrs'] as Map;
        expect(attrs['status_code'], 503);
        expect(attrs['reason_code'], 'http_status_rejected');
        expect(attrs['outcome'], 'degraded');
      } else if (scenario.$1 == 'library') {
        await expectLater(
          scenario.$4(h),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              '图书馆借阅接口返回异常响应',
            ),
          ),
        );
      } else {
        await expectLater(
          scenario.$4(h),
          throwsA(
            isA<DiagnosticException>()
                .having((error) => error.code, 'code', 'http_status_rejected')
                .having(
                  (error) => error.context['status_code'],
                  'status_code',
                  503,
                ),
          ),
        );
      }
      expect(h.logins, 1);
      expect(h.rejected, 1);
    });
  }

  for (final scenario in cases.where(
    (scenario) => scenario.$1.startsWith('labor') && scenario.$1 != 'labor主页',
  )) {
    test('${scenario.$1}缺表解析错误只降级该分项并保留其他真实数据', () async {
      final h = _Harness(
        scenario.$2,
        200,
        firstBody: '<html>合成维护页</html>',
        firstContentType: 'text/html',
      );
      addTearDown(() => h.dio.close(force: true));
      final score = await scenario.$4(h) as LaborScore;
      _expectLabor(score, failedSection: scenario.$1);
      expect(h.logins, 1);
      expect(h.rejected, 1);
    });
  }

  final authResponses =
      <(String, String, Object, String, Future<Object?> Function(_Harness))>[
        (
          '门户游客',
          '/getLoginUserAndGuest',
          {
            'errcode': 0,
            'data': {'userAccount': null, 'studentId': null},
          },
          'application/json',
          cases[3].$4,
        ),
        (
          '门户校历999',
          '/execTemplateMethod',
          {'errcode': 999},
          'application/json',
          cases[4].$4,
        ),
        (
          '一卡通401业务码',
          '/charge/feeitem/getThirdData',
          {'code': 401, 'msg': 'token失效'},
          'application/json',
          cases[5].$4,
        ),
        (
          '一卡通403业务码',
          '/charge/feeitem/getThirdData',
          {'code': '403', 'msg': '认证失效'},
          'application/json',
          cases[5].$4,
        ),
        (
          '图书馆401业务码',
          '/meta-local/opac/users/loans',
          {'code': 401, 'msg': '未登录'},
          'application/json',
          cases[6].$4,
        ),
        (
          '图书馆403业务码',
          '/meta-local/opac/users/loans',
          {'code': '403', 'msg': '未登录'},
          'application/json',
          cases[6].$4,
        ),
        for (final scenario in cases)
          (
            '${scenario.$1}HTML登录页',
            scenario.$2,
            '<html><form id="casLoginForm"></form></html>',
            'text/html',
            scenario.$4,
          ),
      ];
  for (final auth in authResponses) {
    test('200 ${auth.$1}由统一执行器重登且恢复真实业务数据', () async {
      final h = _Harness(
        auth.$2,
        200,
        firstBody: auth.$3,
        firstContentType: auth.$4,
      );
      addTearDown(() => h.dio.close(force: true));
      _expectResult(await auth.$5(h));
      expect(h.logins, 2);
      expect(h.rejected, 1);
      expect(h.targetRequests, hasLength(2));
    });
  }
}

void _expectResult(Object? result) {
  switch (result) {
    case ScoreReport report:
      expect(report.records.single.courseName, '合成课程');
      expect(report.records.single.score, '90');
    case List<Building> buildings:
      expect(buildings.single.code, 'mock-building');
      expect(buildings.single.name, '测试教学楼');
    case AcademicSummary summary:
      expect(summary.studentId, '202512340001');
      expect(summary.gpa, '3.5');
    case StudentInfo info:
      expect(info.user.studentId, '202512340001');
      expect(info.user.categoryName, '学生/本科生');
      expect(info.semester?.year, 2026);
    case List<ElecOption> options:
      expect(options.single.value, 'mock-campus');
    case LibraryResultPage<LibraryLoan> loans:
      expect(loans.total, 1);
      expect(loans.items.single.bookId, 'mock-book');
      expect(loans.items.single.title, '合成馆藏');
    case InnovationCredit credit:
      expect(credit.total, '2');
      expect(credit.grade, '及格');
      expect(credit.items.single.name, '合成项目');
    case LaborScore score:
      _expectLabor(score);
    default:
      fail('测试未覆盖的实际返回类型：${result.runtimeType}');
  }
}

void _expectLabor(LaborScore score, {String? failedSection}) {
  expect(score.official?.total, '12');
  expect(score.liveLife, failedSection == 'labor生活' ? isNull : '3');
  expect(score.liveService, failedSection == 'labor服务' ? isNull : '4');
  if (failedSection == 'labor专业') {
    expect(score.liveMajor, isNull);
  } else {
    expect(score.liveMajor?.course, '2');
    expect(score.liveMajor?.contest, '3');
    expect(score.liveMajor?.total, '5');
  }
}
