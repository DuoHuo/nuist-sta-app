import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/colors.dart';
import 'package:nuist_sta_app/core/config/campus_config.dart';
import 'package:nuist_sta_app/core/auth/portal_exceptions.dart';
import 'package:nuist_sta_app/core/logging/app_log.dart';
import 'package:nuist_sta_app/core/logging/log_store.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_controller.dart';
import 'package:nuist_sta_app/shell/profile/settings/settings_page.dart';

void main() {
  setUp(() async => AppLog.resetForTesting());
  tearDown(() async => AppLog.resetForTesting());
  test('日志文本会过滤凭据、长数字标识和主机名', () {
    final sanitized = AppLog.sanitizeTextForTesting(
      'Authorization: Bearer abc\n'
      'token=secret\nstudent=202512340001\n'
      'https://private.example/private-path\nhost=private.example',
    );

    expect(sanitized, isNot(contains('abc')));
    expect(sanitized, isNot(contains('secret')));
    expect(sanitized, isNot(contains('202512340001')));
    expect(sanitized, isNot(contains('private.example')));
    expect(sanitized, contains('[REDACTED_SECRET]'));
    expect(sanitized, contains('[REDACTED_ID]'));
    expect(sanitized, contains('[REDACTED_HOST]'));
    expect(sanitized, contains('[REDACTED_URL]'));
  });

  test('嵌套操作共用 trace 并生成独立 span', () async {
    final temp = await Directory.systemTemp.createTemp('app_log_test_');
    addTearDown(() async {
      await AppLog.resetForTesting();
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    await AppLog.resetForTesting();
    await AppLog.initialize(directory: temp);
    expect(AppLog.verboseEnabled.value, isTrue);

    final log = AppLog.logger('test.trace');
    await log.operation('outer', () async {
      await log.operation('inner', () async {});
    });

    final snapshot = await AppLog.snapshot();
    final records = snapshot.content
        .split('\n')
        .where((line) => line.isNotEmpty)
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .where((record) => record['scope'] == 'test.trace')
        .toList();
    final outer = records.firstWhere(
      (record) => record['event'] == 'outer.completed',
    );
    final inner = records.firstWhere(
      (record) => record['event'] == 'inner.completed',
    );

    expect(inner['trace_id'], outer['trace_id']);
    expect(inner['span_id'], isNot(outer['span_id']));
    expect(inner['parent_span_id'], outer['span_id']);
    expect('${outer['trace_id']}', hasLength(32));
    expect('${outer['span_id']}', hasLength(16));
    expect(records.any((record) => record['event'] == 'outer.started'), isTrue);
  });

  test('开发控制台使用便于 Flutter 面板与 logcat 阅读的单行格式', () {
    final original = debugPrint;
    final messages = <String>[];
    debugPrint = (message, {wrapWidth}) {
      if (message != null) messages.add(message);
    };
    AppLog.consoleEnabledForTesting = true;
    try {
      AppLog.logger(
        'test.console',
      ).info('refresh.completed', fields: {'duration_ms': 42, 'cache': 'hit'});
    } finally {
      AppLog.consoleEnabledForTesting = false;
      debugPrint = original;
    }

    expect(messages, hasLength(1));
    expect(messages.single, startsWith('INFO '));
    expect(messages.single, contains('[test.console] 刷新数据完成'));
    expect(messages.single, contains('缓存命中'));
    expect(messages.single, contains('耗时 42ms'));
    expect(messages.single, contains('#000001'));
    expect(messages.single, isNot(contains(RegExp(r'\d\d:\d\d:\d\d'))));
    expect(messages.single, isNot(contains('NUIST++')));
    expect(messages.single, isNot(contains('{')));
  });

  test('错误堆栈保留方法与文件行号，去掉外部路径和异常正文', () {
    Map<String, Object?>? record;
    AppLog.recordListenerForTesting = (value) => record = value;
    AppLog.logger('test.stack').error(
      'failed',
      error: StateError('token=synthetic-secret'),
      stackTrace: StackTrace.fromString(
        '#0 ScoreController.refresh (package:nuist_sta_app/app.dart:24:1)\n'
        '#1 main (file:///home/private-user/project/main.dart:9:2)',
      ),
    );
    final text = jsonEncode(record);
    expect(text, contains('ScoreController.refresh'));
    expect(text, contains('app.dart:24:1'));
    expect(text, contains('main.dart:9:2'));
    expect(text, isNot(contains('private-user')));
    expect(text, isNot(contains('synthetic-secret')));
  });

  test('WARNING 输出有限堆栈并携带同一事件序号', () {
    final original = debugPrint;
    final messages = <String>[];
    debugPrint = (message, {wrapWidth}) {
      if (message != null) messages.add(message);
    };
    AppLog.consoleEnabledForTesting = true;
    try {
      AppLog.logger('test.warning').warning(
        'failed',
        error: StateError('synthetic'),
        stackTrace: StackTrace.fromString(
          '#0 main (package:nuist_sta_app/main.dart:9:2)',
        ),
      );
    } finally {
      debugPrint = original;
    }
    expect(messages, hasLength(1));
    expect(messages.single, contains('WARNING'));
    expect(messages.single, contains('↳ #1'));
    expect(messages.single, contains('main.dart:9:2'));
  });

  test('全局 Flutter 异常仅进入统一清洗后的出口', () {
    final previous = FlutterError.onError;
    final platformPrevious = PlatformDispatcher.instance.onError;
    addTearDown(() {
      FlutterError.onError = previous;
      PlatformDispatcher.instance.onError = platformPrevious;
    });
    Map<String, Object?>? record;
    AppLog.recordListenerForTesting = (value) => record = value;
    AppLog.installErrorHandlers();
    FlutterError.onError!(
      FlutterErrorDetails(exception: StateError('token=synthetic-secret')),
    );
    expect(record?['level'], 'ERROR');
    expect(jsonEncode(record), isNot(contains('synthetic-secret')));
  });

  test('并发快照、写入与清除保持顺序，不干扰轮转', () async {
    final temp = await Directory.systemTemp.createTemp('log_serial_test_');
    addTearDown(() => temp.delete(recursive: true));
    final store = RotatingLogStore(temp, maxFileBytes: 160, maxFiles: 4);
    await store.initialize();
    var sequence = 0;
    String line() => jsonEncode({'id': sequence++, 'padding': 'x' * 30});
    for (var index = 0; index < 12; index++) {
      await store.append(line());
    }
    for (var round = 0; round < 15; round++) {
      final snapshot = store.snapshot();
      final writes = Future.wait([
        for (var index = 0; index < 10; index++) store.append(line()),
      ]);
      final records = const LineSplitter()
          .convert((await snapshot).content)
          .map((s) => (jsonDecode(s) as Map)['id'] as int)
          .toList();
      await writes;
      for (var index = 1; index < records.length; index++) {
        expect(records[index], records[index - 1] + 1);
      }
    }
    await Future.wait([store.clear(), store.append('{"event":"after_clear"}')]);
    expect((await store.snapshot()).content, '{"event":"after_clear"}\n');
  });

  test('按记录时间清除活跃文件中的过期事件', () async {
    final temp = await Directory.systemTemp.createTemp('log_retention_test_');
    addTearDown(() => temp.delete(recursive: true));
    final store = RotatingLogStore(temp);
    await store.initialize();
    final now = DateTime.now().toUtc();
    await store.append(
      jsonEncode({
        'ts': now.subtract(const Duration(days: 8)).toIso8601String(),
        'event': 'expired',
      }),
    );
    await store.append(
      jsonEncode({'ts': now.toIso8601String(), 'event': 'current'}),
    );
    final snapshot = await store.snapshot();
    expect(snapshot.content, isNot(contains('expired')));
    expect(snapshot.content, contains('current'));
    expect(snapshot.stats.oldestRecordAt, now);
    expect(
      await File('${temp.path}/app.log').readAsString(),
      isNot(contains('expired')),
    );
  });

  test('导出副本限制数量且清除时一并删除', () async {
    final temp = await Directory.systemTemp.createTemp('log_export_test_');
    addTearDown(() => temp.delete(recursive: true));
    final exports = Directory('${temp.path}/exports');
    final store = RotatingLogStore(
      Directory('${temp.path}/logs'),
      exportDirectory: exports,
    );
    await store.initialize();
    await store.append('{"level":"INFO","event":"synthetic"}');
    for (var index = 0; index < 5; index++) {
      await store.createExport({'record_type': 'diagnostics_metadata'});
    }
    expect((await exports.list().toList()), hasLength(3));
    expect((await store.stats()).exportFileCount, 3);
    await store.clear();
    expect((await exports.list().toList()), isEmpty);
    expect((await store.stats()).bytes, 0);
  });

  test('详细日志到期时间可观察并在关闭时清空', () async {
    final temp = await Directory.systemTemp.createTemp('log_verbose_test_');
    addTearDown(() async {
      await AppLog.resetForTesting();
      await temp.delete(recursive: true);
    });
    await AppLog.initialize(directory: temp);
    await AppLog.enableVerbose(duration: const Duration(seconds: 1));
    expect(AppLog.verboseExpiresAt.value, isNotNull);
    await AppLog.disableVerbose();
    expect(AppLog.verboseExpiresAt.value, isNull);
  });

  testWidgets('设置可预览日志、筛选错误并展开安全堆栈', (tester) async {
    final temp = await tester.runAsync(
      () => Directory.systemTemp.createTemp('log_preview_test_'),
    );
    addTearDown(() async {
      await tester.runAsync(() async {
        await AppLog.resetForTesting();
        await temp!.delete(recursive: true);
      });
    });
    await tester.runAsync(() async {
      await AppLog.initialize(directory: temp);
      AppLog.logger('test.preview').error(
        'synthetic.failed',
        error: StateError('synthetic'),
        stackTrace: StackTrace.fromString(
          '#0 main (package:nuist_sta_app/main.dart:9:2)',
        ),
      );
      for (var index = 0; index < 330; index++) {
        AppLog.logger('test.preview')
            .debug('synthetic.noise', fields: {'count': index});
      }
      await AppLog.snapshot();
    });
    await _openLogPreview(tester, appLightTheme());
    expect(find.textContaining('synthetic.noise'), findsNothing);
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    expect(find.textContaining('synthetic.noise'), findsWidgets);
    await tester.tap(find.text('仅错误'));
    await tester.pumpAndSettle();
    expect(find.textContaining('未分类异常（StateError）'), findsOneWidget);
    await tester.tap(find.textContaining('synthetic.failed'));
    await tester.pumpAndSettle();
    expect(find.text('调用堆栈'), findsOneWidget);
    expect(find.textContaining('main.dart:9:2'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  test('日志文件按大小轮转并限制文件数量', () async {
    final temp = await Directory.systemTemp.createTemp('log_store_test_');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final store = RotatingLogStore(temp, maxFileBytes: 80, maxFiles: 3);
    await store.initialize();
    for (var index = 0; index < 10; index++) {
      await store.append('record-$index-${'x' * 30}');
    }

    final snapshot = await store.snapshot();
    expect(snapshot.stats.fileCount, lessThanOrEqualTo(3));
    expect(snapshot.content, contains('record-9'));
    expect(snapshot.content, isNot(contains('record-0')));
  });

  test('字段白名单拒绝个人数据、长标识、错误类型和非有限数字', () {
    Map<String, Object?>? record;
    AppLog.recordListenerForTesting = (value) => record = value;
    AppLog.logger('test.privacy').info(
      'synthetic',
      fields: {
        'student_id': 202512340001,
        'reference': 202512340001,
        'name': 'synthetic-name',
        'course': 'synthetic-course',
        'score': 88.5,
        'room': 'synthetic-room',
        'query': 'synthetic-query',
        'payload': {'cookie': 'synthetic-secret'},
        'count': 202512340001,
        'request_id': 202512340001,
        'duration_ms': double.nan,
        'bytes': double.infinity,
        'method': 'GET',
        'status_code': 200,
        'response_code': '0',
        'host': CampusHosts.jwxt,
      },
    );
    final attrs = record!['attrs'] as Map;
    expect(
      attrs.keys,
      unorderedEquals([
        'method',
        'status_code',
        'response_code',
        'host',
        'service',
      ]),
    );
    expect(attrs['service'], 'jwxt');
    expect(attrs['host'], startsWith('host_'));
    final text = jsonEncode(record);
    expect(text, isNot(contains('synthetic-')));
    expect(text, isNot(contains('202512340001')));
    expect(text, isNot(contains(CampusHosts.jwxt)));
  });

  test('Basic、多值 Cookie 与完整 URL 均不会留下凭据或路径', () {
    final basic = base64Encode(utf8.encode('synthetic-secret'));
    final text = AppLog.sanitizeTextForTesting(
      'Authorization: Basic $basic\n'
      'Cookie: a=synthetic-session; b=synthetic-cookie; c=synthetic-private\n'
      'https://private.example/private-user?ticket=synthetic-ticket',
    );
    expect(text, isNot(contains('synthetic')));
    expect(text, isNot(contains(basic)));
    expect(text, isNot(contains('private-user')));
    expect(text, contains('[REDACTED_SECRET]'));
    expect(text, contains('[REDACTED_URL]'));
    final fields = AppLog.scriptEventFields(
      'page called credentials.create (rp=https://private.example/private-user)',
    );
    expect(fields, {'script_event': 'credential_create'});
  });

  test('不同的无堆栈框架错误具有独立的安全分类', () {
    final previous = FlutterError.onError;
    final platformPrevious = PlatformDispatcher.instance.onError;
    addTearDown(() {
      FlutterError.onError = previous;
      PlatformDispatcher.instance.onError = platformPrevious;
    });
    final records = <Map<String, Object?>>[];
    AppLog.recordListenerForTesting = records.add;
    AppLog.installErrorHandlers();
    FlutterError.onError!(
      FlutterErrorDetails(
        exception: FlutterError(
          'A RenderFlex overflowed by 8 pixels on the right. synthetic-private',
        ),
        library: 'rendering library',
      ),
    );
    FlutterError.onError!(
      FlutterErrorDetails(
        exception: FlutterError(
          'Incorrect use of ParentDataWidget. synthetic-private',
        ),
        library: 'widgets library',
      ),
    );
    expect((records[0]['attrs'] as Map)['framework_error'], 'flex_overflow');
    expect(
      (records[1]['attrs'] as Map)['framework_error'],
      'invalid_parent_data',
    );
    expect((records[0]['attrs'] as Map)['framework_library'], 'rendering');
    expect(jsonEncode(records), isNot(contains('synthetic-private')));
  });

  test('公告最终失败只记录一次，保留用户操作的 Trace 和父 Span', () async {
    final records = <Map<String, Object?>>[];
    AppLog.recordListenerForTesting = records.add;
    final controller = AnnouncementController.test(
      fetch: ({etag, lastModified}) async =>
          throw const PortalNetworkError('synthetic-private'),
    );
    addTearDown(controller.dispose);
    await AppLog.logger('test.user')
        .operation('refresh', controller.ensureStarted);
    final parent = records.singleWhere(
      (record) =>
          record['scope'] == 'test.user' &&
          record['event'] == 'refresh.completed',
    );
    final warnings = records
        .where((record) => record['level'] == 'WARNING')
        .toList();
    expect(warnings, hasLength(1));
    final failure = warnings.single;
    expect(failure['event'], 'refresh.failed_using_cache');
    expect(failure['trace_id'], parent['trace_id']);
    expect(failure['parent_span_id'], parent['span_id']);
    expect(failure['span_id'], isNot(parent['span_id']));
    expect((failure['attrs'] as Map)['outcome'], 'cache_fallback');
    expect(jsonEncode(records), isNot(contains('synthetic-private')));
  });

  test('截断的 UTF-8 与 JSON 尾行不会阻断有效日志、后续写入和导出', () async {
    final temp = await Directory.systemTemp.createTemp('log_recovery_test_');
    addTearDown(() => temp.delete(recursive: true));
    final logs = Directory('${temp.path}/logs');
    final exports = Directory('${temp.path}/exports');
    await logs.create();
    String line(String event) => jsonEncode({
      'ts': DateTime.now().toUtc().toIso8601String(),
      'event': event,
    });
    await File('${logs.path}/app.log')
        .writeAsBytes([...utf8.encode('${line('active')}\n'), 0xe4, 0xb8]);
    await File('${logs.path}/app.1.log')
        .writeAsString('${line('archived')}\n{"broken":');
    final store = RotatingLogStore(logs, exportDirectory: exports);
    await store.initialize();
    await store.append(line('after_recovery'));
    final snapshot = await store.snapshot();
    expect(snapshot.content, contains('active'));
    expect(snapshot.content, contains('archived'));
    expect(snapshot.content, contains('after_recovery'));
    expect(snapshot.content, isNot(contains('broken')));
    expect(snapshot.content, isNot(contains('\uFFFD')));
    expect(snapshot.stats.recoveredFileCount, 2);
    final exported = await store.createExport({
      'record_type': 'diagnostics_metadata',
    });
    expect(await exported.readAsString(), contains('after_recovery'));
  });

  test('旧记录和导出元信息会重新清洗，保留安全 Trace', () async {
    final temp = await Directory.systemTemp.createTemp('log_migration_test_');
    addTearDown(() async {
      await AppLog.resetForTesting();
      await temp.delete(recursive: true);
    });
    final logs = Directory('${temp.path}/nuist_sta_app/logs');
    await logs.create(recursive: true);
    await File('${logs.path}/app.log').writeAsString(
      '${jsonEncode({
        'ts': DateTime.now().toUtc().toIso8601String(),
        'seq': 1,
        'level': 'INFO',
        'scope': 'test.legacy',
        'event': 'state.detail',
        'session_id': 'a' * 16,
        'trace_id': 'b' * 32,
        'span_id': 'c' * 16,
        'attrs': {'detail': 'synthetic-private', 'reference': 202512340001, 'duration_ms': 42},
        'request_body': 'synthetic-private',
      })}\n',
    );
    await AppLog.initialize(directory: temp);
    final snapshot = await AppLog.snapshot();
    expect(snapshot.content, contains('b' * 32));
    expect(snapshot.content, contains('duration_ms'));
    expect(snapshot.content, isNot(contains('synthetic-private')));
    expect(
      await File('${logs.path}/app.log').readAsString(),
      isNot(contains('synthetic-private')),
    );
    final file = await AppLog.createExport({
      'app_version': '0.2.5',
      'build_number': '02500',
      'name': 'synthetic-private',
      'cookie': 'synthetic-private',
    });
    final content = await file.readAsString();
    expect(content, isNot(contains('synthetic-private')));
    final metadata = jsonDecode(content.split('\n').first) as Map;
    expect(metadata['app_version'], '0.2.5');
    expect(metadata['build_number'], '02500');
  });

  test('简洁摘要省略重复包装，详细内容保留完整追踪和准备耗时', () {
    final record = <String, Object?>{
      'scope': 'core.network.vpn',
      'level': 'DEBUG',
      'seq': 9,
      'event': 'http.completed',
      'trace_id': 'a' * 32,
      'span_id': 'b' * 16,
      'attrs': {
        'request_id': 9,
        'method': 'GET',
        'service': 'jwxt',
        'host': 'host_3',
        'status_code': 302,
        'duration_ms': 3812,
        'preparation_ms': 1189,
        'route': 'VPN',
      },
    };
    final summary = AppLog.formatSummary(record);
    expect(summary, startsWith('HTTP 请求完成 · R9 GET 教务'));
    expect(summary, contains('HTTP 302'));
    expect(summary, contains('3.81s'));
    expect(summary, contains('准备 1.19s'));
    expect(summary, contains('出口 VPN'));
    expect(summary, isNot(contains('host_3')));
    expect(summary, isNot(contains('core.network')));
    expect(summary, isNot(contains('DEBUG')));
    final details = AppLog.formatDetails(record);
    expect(details, contains('a' * 32));
    expect(details, contains('b' * 16));
    expect(details, contains('preparation_ms: 1189'));
    expect(details, contains('event: http.completed'));
    expect(details, contains('scope: core.network.vpn'));
  });

  test('失败摘要明确服务、原生阶段、本阶段耗时和实际期限', () {
    final summary = AppLog.formatSummary({
      'event': 'stage.failed',
      'attrs': {
        'stage': 'native.open',
        'connection_id': 2,
        'service': 'jwxt',
        'native_stage': 'tcp',
        'error_kind': 'connection_error',
        'os_code': 10061,
        'stage_elapsed_ms': 1200,
        'duration_ms': 3200,
        'native_timeout_ms': 24000,
        'timeout_ms': 60000,
      },
    });
    expect(summary, startsWith('VPN 目标连接失败 · C2 教务'));
    expect(summary, contains('阶段 TCP 连接'));
    expect(summary, contains('系统码 10061'));
    expect(summary, contains('本阶段 1.20s'));
    expect(summary, contains('耗时 3.20s'));
    expect(summary, contains('期限 24.00s'));
    expect(summary, isNot(contains('1m')));
    expect(summary, isNot(contains('\n')));
  });

  test('异常摘要区分网络超时与未分类异常，旧失败结果不会显示完成', () {
    expect(
      AppLog.formatSummary({
        'event': 'http.failed',
        'attrs': {'error_kind': 'network', 'dio_type': 'receiveTimeout'},
      }),
      contains('响应超时'),
    );
    expect(
      AppLog.formatSummary({
        'event': 'http.failed',
        'attrs': {'error_kind': 'unexpected', 'error_type': 'StateError'},
      }),
      contains('未分类异常（StateError）'),
    );
    final failedSync = AppLog.formatSummary({
      'event': 'sync.run.completed',
      'attrs': {'outcome': 'failure', 'failure_kind': 'sessionExpired'},
    });
    expect(failedSync, contains('课表同步失败'));
    expect(failedSync, contains('教务会话过期'));
    expect(failedSync, isNot(contains('完成')));
  });

  for (final dark in [false, true]) {
    testWidgets('诊断页${dark ? '深色' : '浅色'}横屏大字体可滚动，级别文字对比度达标', (tester) async {
      final temp = await tester.runAsync(
        () => Directory.systemTemp.createTemp('log_layout_test_'),
      );
      addTearDown(() async {
        await tester.runAsync(() async {
          await AppLog.resetForTesting();
          await temp!.delete(recursive: true);
        });
      });
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.runAsync(() async {
        await AppLog.initialize(directory: temp);
        AppLog.logger('test.layout').warning('synthetic.layout');
        await AppLog.snapshot();
      });
      await _openLogPreview(tester, dark ? appDarkTheme() : appLightTheme());
      tester.view.physicalSize = const Size(640, 320);
      tester.platformDispatcher.textScaleFactorTestValue = 3.2;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('synthetic.layout'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final badge = find.text('警告');
      final text = tester.widget<Text>(badge);
      final box = tester
          .widgetList<Container>(
            find.ancestor(of: badge, matching: find.byType(Container)),
          )
          .firstWhere(
            (widget) =>
                widget.child is Text && (widget.child as Text).data == '警告',
          );
      final palette = AppPalette.of(tester.element(badge));
      final background = Color.alphaBlend(
        (box.decoration as BoxDecoration).color!,
        palette.pageBg,
      );
      final a = text.style!.color!.computeLuminance() + 0.05;
      final b = background.computeLuminance() + 0.05;
      expect(a > b ? a / b : b / a, greaterThanOrEqualTo(4.5));
      await tester.pumpWidget(const SizedBox());
    });
  }

  test('业务代码不能绕过统一日志入口', () async {
    final violations = <String>[];
    await for (final entity in Directory('lib').list(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path
          .replaceAll('\\', '/')
          .endsWith('/core/logging/app_log.dart')) {
        continue;
      }
      final content = await entity.readAsString();
      if (RegExp(r'\bdebugPrint\s*\(').hasMatch(content) ||
          RegExp(r'\bdeveloper\.log\s*\(').hasMatch(content) ||
          RegExp(r'^\s*print\s*\(', multiLine: true).hasMatch(content)) {
        violations.add(entity.path);
      }
    }
    expect(violations, isEmpty, reason: '请改用 AppLog：$violations');
  });
}

Future<void> _openLogPreview(WidgetTester tester, ThemeData theme) async {
  await tester.pumpWidget(
    MaterialApp(theme: theme, home: const SettingsPage()),
  );
  final viewRow = find.ancestor(
    of: find.text('查看日志'),
    matching: find.byType(ListTile),
  );
  for (
    var attempt = 0;
    attempt < 40 && !tester.widget<ListTile>(viewRow).enabled;
    attempt++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
  }
  expect(tester.widget<ListTile>(viewRow).enabled, isTrue);
  await tester.ensureVisible(find.text('查看日志'));
  await tester.runAsync(() => tester.tap(find.text('查看日志')));
  for (
    var attempt = 0;
    attempt < 40 && find.text('诊断日志').evaluate().isEmpty;
    attempt++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
  expect(find.text('诊断日志'), findsOneWidget);
}
