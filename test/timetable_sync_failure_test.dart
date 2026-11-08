import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/auth/portal_http.dart';
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
  Dio? fakeDio;
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
    TimetableApi.debugClientFor = null;
    fakeDio?.close(force: true);
    fakeDio = null;
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

  group('HTTP 403 与手动同步重登', () {
    late Future<bool> Function() originalBindingCheck;
    final freshJson = {
      'code': '0',
      'datas': {
        'cxxszhxqkb': {
          'rows': [
            {
              'KCM': '更新后的课程',
              'KCH': 'mock-course',
              'SKXQ': 1,
              'KSJC': 1,
              'JSJC': 2,
              'SKZC': '1111111111111111',
            },
          ],
        },
      },
    };

    setUp(() async {
      originalBindingCheck = TimetableController.bindingCheck;
      TimetableController.bindingCheck = () async => true;
      TimetableController.fetchSnapshot = (term, {baseSettings}) =>
          TimetableApi.fetchTermSnapshot(term, baseSettings: baseSettings);
      await c.ensureStarted();
      await seedCache();
      await TimetableStore.saveSnapshot(c.snapshot);
    });

    tearDown(() => TimetableController.bindingCheck = originalBindingCheck);

    for (final error in [
      const JwxtHttpError('cxxszhxqkb.do', 403),
      DioException(
        requestOptions: RequestOptions(path: '/mock'),
        type: DioExceptionType.badResponse,
        response: _resp(Uri.parse('https://jwxt.test/mock'), status: 403),
      ),
    ]) {
      test('${error.runtimeType} 的 403 归为会话失效', () async {
        TimetableApi.debugPost = (url, form) async => throw error;
        expect(await c.manualSync(), isTrue);
        expect(c.syncFailure, TimetableSyncFailure.sessionExpired);
        expect(c.portalSessionExpired, isTrue);
        expect(c.jwxtCourses.single.id, 'cached');
      });
    }

    test('403 后强制重登成功，同一次同步后续 403 不再重登', () async {
      final attempts = <String, List<bool>>{};
      TimetableApi.debugPostResponse = (url, form, {required force}) async {
        final endpoint = url.pathSegments.last;
        attempts.putIfAbsent(endpoint, () => []).add(force);
        if (endpoint == 'cxxszhxqkb.do') {
          return _resp(url, status: force ? 200 : 403, data: freshJson);
        }
        if (endpoint == 'xswpkc.do') return _resp(url, status: 403);
        return _resp(url, data: {'code': '0', 'datas': <String, dynamic>{}});
      };

      expect(await c.manualSync(), isTrue);
      expect(attempts['cxxszhxqkb.do'], [false, true]);
      expect(attempts['xswpkc.do'], [false]);
      expect(
        attempts.values.expand((values) => values).where((force) => force),
        hasLength(1),
      );
      expect(c.syncStatus, TimetableSyncStatus.success);
      expect(c.portalSessionExpired, isFalse);
      expect(c.jwxtCourses.single.name, '更新后的课程');
    });

    test('连续 403 仅重登一次并保留缓存，下次手动同步可重新恢复', () async {
      final attempts = <bool>[];
      var recovered = false;
      TimetableApi.debugPostResponse = (url, form, {required force}) async {
        if (url.pathSegments.last == 'cxxszhxqkb.do') {
          attempts.add(force);
          return _resp(
            url,
            status: recovered && force ? 200 : 403,
            data: freshJson,
          );
        }
        return _resp(url, data: {'code': '0', 'datas': <String, dynamic>{}});
      };

      expect(await c.manualSync(), isTrue);
      expect(attempts, [false, true]);
      expect(c.syncStatus, TimetableSyncStatus.failure);
      expect(c.syncFailure, TimetableSyncFailure.sessionExpired);
      expect(c.portalSessionExpired, isTrue);
      expect(c.jwxtCourses.single.id, 'cached');
      expect(
        (await TimetableStore.readSnapshot())!.courses.single.id,
        'cached',
      );

      recovered = true;
      expect(await c.manualSync(), isTrue);
      expect(attempts, [false, true, false, true]);
      expect(c.syncStatus, TimetableSyncStatus.success);
      expect(c.portalSessionExpired, isFalse);
      expect(c.jwxtCourses.single.name, '更新后的课程');
    });

    for (final homepageRecovers in [true, false]) {
      test(
        homepageRecovers
            ? '首页 403 重登成功后 POST 仍 403，总共只重登一次并保留缓存'
            : '首页持续 403 只重登一次，不发送 POST 并保留缓存',
        () async {
          // 原始响应钩子将应用首页缓存置为失效，保证测试不依赖其他测试的 ready 状态。
          TimetableApi.debugPostResponse = (
            url,
            form, {
            required force,
          }) async => _resp(url, status: 403);
          await expectLater(
            TimetableApi.fetchTermSnapshot(c.settings.termCode),
            throwsA(isA<JwxtSessionExpiredError>()),
          );
          TimetableApi.debugPostResponse = null;

          final clients = <bool>[];
          final methods = <String>[];
          var reloggedIn = false;
          fakeDio = Dio()
            ..interceptors.add(
              InterceptorsWrapper(
                onRequest: (options, handler) {
                  methods.add(options.method);
                  handler.resolve(
                    Response<dynamic>(
                      requestOptions: options,
                      statusCode:
                          options.method == 'GET' &&
                              homepageRecovers &&
                              reloggedIn
                          ? 200
                          : 403,
                      data: '<html><body>模拟业务响应</body></html>',
                      headers: Headers.fromMap({
                        Headers.contentTypeHeader: ['text/html'],
                      }),
                    ),
                  );
                },
              ),
            );
          TimetableApi.debugClientFor = ({required force}) async {
            clients.add(force);
            if (force) reloggedIn = true;
            return PortalHttp(fakeDio!);
          };

          expect(await c.manualSync(), isTrue);
          expect(clients, [false, true]);
          expect(
            methods,
            homepageRecovers ? ['GET', 'GET', 'POST'] : ['GET', 'GET'],
          );
          expect(c.syncStatus, TimetableSyncStatus.failure);
          expect(c.syncFailure, TimetableSyncFailure.sessionExpired);
          expect(c.portalSessionExpired, isTrue);
          expect(c.jwxtCourses.single.id, 'cached');
          expect(
            (await TimetableStore.readSnapshot())!.courses.single.id,
            'cached',
          );
        },
      );
    }
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
    expect(saved.settings.showSaturday, isFalse);
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
