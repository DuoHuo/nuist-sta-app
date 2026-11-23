import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/logging/diagnostic_error.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:nuist_sta_app/core/auth/campus_transport.dart';
import 'package:nuist_sta_app/core/auth/cas_session.dart';
import 'package:nuist_sta_app/core/auth/portal_cookie_store.dart';
import 'package:nuist_sta_app/core/auth/portal_exceptions.dart';
import 'package:nuist_sta_app/core/auth/session_executor.dart';
import 'package:nuist_sta_app/core/config/campus_config.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

Course _course(String id, {int day = 1}) => Course(
  id: id,
  name: 'C $id',
  source: CourseSource.jwxt,
  slots: [CourseSlot(day: day, startNode: 1, endNode: 2, weeks: '1' * 16)],
);

class _DelayedChangeLogFile implements File {
  _DelayedChangeLogFile(this.file, this.entered, this.release);

  final File file;
  final Completer<void> entered;
  final Future<void> release;

  @override
  String get path => file.path;

  @override
  Future<bool> exists() => file.exists();

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async {
    if (!entered.isCompleted) entered.complete();
    await release;
    return file.readAsString(encoding: encoding);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
  _AuthHarness? auth;
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
    TimetableApi.debugExecutor = null;
    TimetableApi.rolePreCallRoleId = null;
    auth?.dio.close(force: true);
    auth = null;
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

  Future<void> whileSyncLogPaused(Future<void> Function() action) async {
    final log = File('${tmp.path}/sync_changes.json')
      ..writeAsStringSync('{"changes":[]}');
    final entered = Completer<void>();
    final release = Completer<void>();
    final outsideZone = Zone.current;
    await IOOverrides.runZoned(
      () async {
        final sync = c.syncFromJwxt();
        try {
          await entered.future.timeout(const Duration(seconds: 5));
          await action();
        } finally {
          release.complete();
          await sync;
        }
      },
      createFile: (path) =>
          path.replaceAll('\\', '/').endsWith('/sync_changes.json')
          ? _DelayedChangeLogFile(log, entered, release.future)
          : outsideZone.run(() => File(path)),
    );
  }

  group('classification via debugPost', () {
    test('缺少 rows 属于响应结构错误，不能成功返回空课表', () async {
      TimetableApi.debugPost = (u, f) async => {
        'code': '0',
        'datas': {'cxxszhxqkb': <String, Object?>{}},
      };
      await expectLater(
        TimetableApi.fetchSemesterCourses('2026-2027-1'),
        throwsA(
          isA<DiagnosticException>().having(
            (e) => e.code,
            'code',
            'response_rows_missing',
          ),
        ),
      );
      await expectLater(
        TimetableApi.fetchTermSnapshot('2026-2027-1'),
        throwsA(
          isA<DiagnosticException>().having(
            (e) => e.code,
            'code',
            'response_rows_missing',
          ),
        ),
      );
    });

    test('真正的空 rows 仍是合法空课表', () async {
      TimetableApi.debugPost = (u, f) async => {
        'code': '0',
        'datas': {
          'cxxszhxqkb': {'rows': <Object?>[]},
        },
      };
      expect(await TimetableApi.fetchSemesterCourses('2026-2027-1'), isEmpty);
    });

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

  _AuthHarness install(
    FutureOr<Response<dynamic>> Function(RequestOptions options, int logins)
    route,
  ) {
    auth = _AuthHarness(route);
    TimetableApi.debugExecutor = auth!.executor;
    return auth!;
  }

  group('统一鉴权真实请求链路', () {
    final freshJson = {
      'code': '0',
      'datas': {
        'cxxszhxqkb': {'rows': <Object?>[]},
      },
    };
    Response<dynamic> queryResponse(RequestOptions options) {
      final endpoint = options.uri.pathSegments.last.replaceFirst('.do', '');
      return _resp(
        options.uri,
        data: {
          'code': '0',
          'datas': {
            endpoint: {'rows': <Object?>[]},
          },
        },
      );
    }

    test('业务403清脏Cookie后重进首页与角色，再重放POST', () async {
      TimetableApi.rolePreCallRoleId = 'mock-role';
      final order = <String>[];
      final h = install((options, logins) {
        final path = options.uri.path;
        order.add('$logins:${options.method}:${path.split('/').last}');
        if (path.endsWith('cxxszhxqkb.do') && logins == 1) {
          return _resp(options.uri, status: 403);
        }
        if (options.method == 'POST') {
          return queryResponse(options);
        }
        return _resp(
          options.uri,
          data: '<html>业务首页</html>',
          contentType: 'text/html',
        );
      });
      await h.cookies.openJar().saveFromResponse(
        Uri.https(CampusHosts.jwxt, '/'),
        [Cookie('dirty', 'old')],
      );
      expect(await TimetableApi.fetchSemesterCourses('2026-2027-1'), isEmpty);
      expect(h.logins, 2);
      expect(order.where((e) => e.endsWith('index.do')), hasLength(2));
      expect(
        order.where((e) => e.endsWith('setJwCommonAppRole.do')),
        hasLength(2),
      );
      expect(
        order.indexOf('2:POST:setJwCommonAppRole.do'),
        lessThan(order.indexOf('2:POST:cxxszhxqkb.do')),
      );
      expect(
        await h.cookies.openJar().loadForRequest(
          Uri.https(CampusHosts.jwxt, '/'),
        ),
        isEmpty,
      );
    });

    test('角色初始化失败时不发送任何业务查询', () async {
      TimetableApi.rolePreCallRoleId = 'mock-role';
      final order = <String>[];
      final h = install((options, logins) {
        final endpoint = options.uri.pathSegments.last;
        order.add(endpoint);
        return _resp(
          options.uri,
          status: endpoint == 'setJwCommonAppRole.do' ? 403 : 200,
          data: '<html>业务首页</html>',
          contentType: 'text/html',
        );
      });
      await expectLater(
        TimetableApi.fetchSemesterCourses('2026-2027-1'),
        throwsA(isA<PortalLoginError>()),
      );
      expect(order, ['mock-landing', 'index.do', 'setJwCommonAppRole.do']);
      expect(h.logins, 1);
    });

    test('课表重登后考试403仍有独立恢复机会', () async {
      var courseRejected = false;
      var examRejected = false;
      final h = install((options, logins) {
        final path = options.uri.path;
        if (path.endsWith('cxxszhxqkb.do') && !courseRejected) {
          courseRejected = true;
          return _resp(options.uri, status: 403);
        }
        if (path.endsWith('cxxsksap.do') && !examRejected) {
          examRejected = true;
          return _resp(options.uri, status: 403);
        }
        if (options.method == 'POST') {
          return queryResponse(options);
        }
        return _resp(
          options.uri,
          data: '<html>业务首页</html>',
          contentType: 'text/html',
        );
      });
      expect(
        (await TimetableApi.fetchTermSnapshot('2026-2027-1')).courses,
        isEmpty,
      );
      expect(await TimetableApi.fetchExams('2026-2027-1'), isEmpty);
      expect(h.logins, 4, reason: '两个应用各自初始化，两次失效各自恢复');
    });

    test('五个错峰403只共享一次重登，较晚响应复用新revision', () async {
      final delayed = Completer<void>();
      final started = Completer<void>();
      var rejected = 0;
      final h = install((options, logins) async {
        if (options.method != 'POST') {
          return _resp(
            options.uri,
            data: '<html>首页</html>',
            contentType: 'text/html',
          );
        }
        if (logins == 1) {
          rejected++;
          if (rejected == 5) started.complete();
          if (rejected >= 3) await delayed.future;
          return _resp(options.uri, status: 403);
        }
        return _resp(options.uri, data: freshJson);
      });
      final requests = List.generate(
        5,
        (_) => TimetableApi.fetchSemesterCourses('2026-2027-1'),
      );
      await started.future;
      await pumpEventQueue();
      expect(h.logins, 2);
      delayed.complete();
      expect(await Future.wait(requests), everyElement(isEmpty));
      expect(h.logins, 2);
    });

    for (final entry in <String, (int, String, TimetableSyncFailure)>{
      '登录HTML': (200, loginHtml, TimetableSyncFailure.sessionExpired),
      'casLoginForm': (
        200,
        '<html><form id="casLoginForm"></form></html>',
        TimetableSyncFailure.sessionExpired,
      ),
      '普通维护HTML': (200, webvpnMaintenanceHtml, TimetableSyncFailure.unknown),
      '502网关': (502, gateway502Html, TimetableSyncFailure.server),
      '503含authserver': (
        503,
        '<html>authserver维护</html>',
        TimetableSyncFailure.server,
      ),
      '504网关': (504, gateway502Html, TimetableSyncFailure.server),
    }.entries) {
      test('${entry.key}正确分类并保持缓存', () async {
        final h = install((options, logins) {
          if (options.method != 'POST') {
            return _resp(
              options.uri,
              data: '<html>首页</html>',
              contentType: 'text/html',
            );
          }
          return _resp(
            options.uri,
            status: entry.value.$1,
            data: entry.value.$2,
            contentType: 'text/html',
          );
        });
        await expectFailure(entry.value.$3);
        expect(
          h.logins,
          entry.value.$3 == TimetableSyncFailure.sessionExpired ? 2 : 1,
        );
      });
    }

    test('200业务JSON错误不重登', () async {
      final h = install(
        (options, logins) => options.method == 'POST'
            ? _resp(options.uri, data: {'code': '1', 'msg': '合成错误'})
            : _resp(
                options.uri,
                data: '<html>首页</html>',
                contentType: 'text/html',
              ),
      );
      await expectFailure(TimetableSyncFailure.unknown);
      expect(h.logins, 1);
    });

    for (final error in [
      const PortalLoginError(
        '教务拒绝',
        code: 'service_status_rejected',
        context: {'status_code': 403},
      ),
      const PortalLoginError('重登耗尽', code: 'reauthentication_exhausted'),
      const PortalLoginError('账号变化', code: 'session_generation_changed'),
    ]) {
      test('${error.code}归为sessionExpired', () async {
        TimetableApi.debugPost = (url, form) async => throw error;
        await expectFailure(TimetableSyncFailure.sessionExpired);
      });
    }
    test('PortalLoginError保留5xx服务器分类', () {
      expect(
        classifySyncError(
          const PortalLoginError('服务拒绝', context: {'status_code': 503}),
        ),
        TimetableSyncFailure.server,
      );
    });

    test('每个请求重登耗尽后保留缓存，下次请求仍能恢复', () async {
      var recover = false;
      final h = install((options, logins) {
        if (options.method != 'POST') {
          return _resp(
            options.uri,
            data: '<html>首页</html>',
            contentType: 'text/html',
          );
        }
        if (!recover) return _resp(options.uri, status: 403);
        return queryResponse(options);
      });
      await expectFailure(TimetableSyncFailure.sessionExpired);
      expect(h.logins, 2);
      recover = true;
      await c.syncFromJwxt();
      expect(c.syncStatus, TimetableSyncStatus.success);
      expect(c.portalSessionExpired, isFalse);
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

  test('学期设置提交失败时回退快照文件，并保留内存中的旧课表', () async {
    await seedCache();
    await TimetableStore.saveSnapshot(c.snapshot);
    final snapshotFile = File('${tmp.path}/snapshot.json');
    final settingsFile = File('${tmp.path}/settings.json');
    settingsFile.writeAsStringSync(
      jsonEncode({
        'termCode': c.settings.termCode,
        'periodHeight': 44,
        'futureKey': 'keep',
      }),
    );
    final previousSnapshot = snapshotFile.readAsStringSync();
    final previousSettings = settingsFile.readAsStringSync();
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        TimetableSnapshot(
          courses: [_course('new')],
          settings: const TimetableSettings(termCode: '2026-2027-2'),
        );
    TimetableStore.debugBeforeBatchReplace = (index) {
      if (index == 1) throw const FileSystemException('合成设置提交失败');
    };
    addTearDown(() => TimetableStore.debugBeforeBatchReplace = null);

    await c.syncFromJwxt();

    expect(c.syncStatus, TimetableSyncStatus.failure);
    expect(c.jwxtCourses.map((course) => course.id), ['cached']);
    expect(c.settings.termCode, '2026-2027-1');
    expect(c.lastSyncSuccessAt, isNull);
    expect(snapshotFile.readAsStringSync(), previousSnapshot);
    expect(settingsFile.readAsStringSync(), previousSettings);
  });

  test('同步等待变更日志时保存设置，内存、磁盘和重启均保留新课表', () async {
    await seedCache();
    await TimetableStore.saveSnapshot(c.snapshot);
    await TimetableStore.saveSettings(c.settings);
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        TimetableSnapshot(
          courses: [_course('new', day: 2)],
          settings: baseSettings!,
        );

    await whileSyncLogPaused(() async {
      await c.updateSettings(
        c.settingsForEditing.copyWith(showSaturday: false),
      );
    });

    expect(c.syncStatus, TimetableSyncStatus.success);
    expect(c.jwxtCourses.single.id, 'new');
    expect(c.settings.showSaturday, isFalse);
    final saved = (await TimetableStore.readSnapshot())!;
    expect(saved.courses.single.id, 'new');
    expect((await TimetableStore.readSettings()).showSaturday, isFalse);
    final originalBinding = TimetableController.bindingCheck;
    addTearDown(() => TimetableController.bindingCheck = originalBinding);
    TimetableController.bindingCheck = () async => false;
    c.debugReset();
    await c.ensureStarted();
    expect(c.jwxtCourses.single.id, 'new');
    expect(c.settings.showSaturday, isFalse);
  });

  test('远程响应等待期间仍能保存设置，同步保留最新展示偏好和课表名', () async {
    await seedCache();
    final entered = Completer<void>();
    final response = Completer<void>();
    TimetableController.fetchSnapshot = (term, {baseSettings}) async {
      entered.complete();
      await response.future;
      return TimetableSnapshot(
        courses: [_course('new')],
        settings: baseSettings!.copyWith(nodesPerDay: 12),
      );
    };
    final sync = c.syncFromJwxt();
    try {
      await entered.future;
      await c.updateSettings(
        c.settingsForEditing.copyWith(
          showSaturday: false,
          paletteScheme: 'B',
          scheduleName: '新课表名',
        ),
      );
      expect(c.loading, isTrue);
      expect(c.settings.showSaturday, isFalse);
    } finally {
      response.complete();
      await sync;
    }

    expect(c.syncStatus, TimetableSyncStatus.success);
    expect(c.jwxtCourses.single.id, 'new');
    for (final settings in [
      c.settings,
      (await TimetableStore.readSnapshot())!.settings,
    ]) {
      expect(settings.showSaturday, isFalse);
      expect(settings.paletteScheme, 'B');
      expect(settings.scheduleName, '新课表名');
      expect(settings.nodesPerDay, 12);
    }
  });

  test('同步等待变更日志期间解绑，不恢复快照也不发布旧同步成功', () async {
    await seedCache();
    await TimetableStore.saveSnapshot(c.snapshot);
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        TimetableSnapshot(
          courses: [_course('new', day: 2)],
          settings: baseSettings!,
        );
    late final Future<void> unbound;

    await whileSyncLogPaused(() async {
      unbound = c.onPortalBindingChanged(false);
    });
    await unbound;

    expect(c.portalBound, isFalse);
    expect(c.jwxtCourses, isEmpty);
    expect(c.syncStatus, TimetableSyncStatus.idle);
    expect(c.lastSyncSuccessAt, isNull);
    expect(await TimetableStore.readSnapshot(), isNull);
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

class _AuthHarness {
  _AuthHarness(this.route) {
    dio.httpClientAdapter = _RouteAdapter((options) => route(options, logins));
    final transport = CampusTransport.authenticated(
      dio: dio,
      cookieStore: cookies,
    );
    executor = SessionExecutor(
      transport: transport,
      cookieStore: cookies,
      authenticate: (service, {bool forceFreshWebAuthn = false}) async {
        logins++;
        return CasAuthenticationResult(
          landingUri: Uri.https(CampusHosts.jwxt, '/mock-landing'),
        );
      },
    );
  }
  final FutureOr<Response<dynamic>> Function(RequestOptions options, int logins)
  route;
  final cookies = PortalCookieStore(storage: _MemoryStorage());
  final dio = Dio();
  late final SessionExecutor executor;
  int logins = 0;
}

class _RouteAdapter implements HttpClientAdapter {
  _RouteAdapter(this.route);
  final FutureOr<Response<dynamic>> Function(RequestOptions options) route;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final response = await route(options);
    return ResponseBody.fromString(
      response.data is String
          ? response.data as String
          : jsonEncode(response.data),
      response.statusCode ?? 200,
      headers: response.headers.map,
    );
  }

  @override
  void close({bool force = false}) {}
}
