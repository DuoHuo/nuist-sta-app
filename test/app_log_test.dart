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
import 'package:nuist_sta_app/shell/profile/about/about_page.dart';
import 'package:nuist_sta_app/shell/profile/settings/settings_page.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  setUp(() async => AppLog.resetForTesting());
  tearDown(() async => AppLog.resetForTesting());
  group('完整附件与操作留存', () {
    late Directory temp;
    setUp(() async {
      temp = await Directory.systemTemp.createTemp('log_attachment_test_');
    });
    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    String record(int sequence, String trace, {int size = 0, DateTime? at}) =>
        jsonEncode({
          'ts': (at ?? DateTime.now().toUtc()).toIso8601String(),
          'seq': sequence,
          'session_id': 'a' * 16,
          'trace_id': trace,
          'event': 'sample.$sequence',
          'attrs': {
            'details': {'body': 'x' * size},
          },
        });
    RotatingLogStore create({
      int budget = 200000,
      int fileBytes = 4096,
      int files = 4,
    }) => RotatingLogStore(
      temp,
      exportDirectory: Directory('${temp.path}/exports'),
      maxFileBytes: fileBytes,
      maxFiles: files,
      maxAttachmentBytes: budget,
      sanitizeRecord: (value) => value,
    );
    List<Map<String, dynamic>> decode(LogSnapshot value) => const LineSplitter()
        .convert(value.content)
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList();

    test('大记录完整压缩存储，正常水合和导出不算损坏恢复', () async {
      final store = create();
      await store.initialize();
      final line = record(1, 'b' * 32, size: 70000);
      await store.append(line);
      final files = await Directory('${temp.path}/records')
          .list()
          .where((file) => file is File)
          .cast<File>()
          .toList();
      expect(files, hasLength(1));
      expect(await files.single.length(), lessThan(70000));
      expect(
        utf8.decode(gzip.decode(await files.single.readAsBytes())),
        '$line\n',
      );
      final snapshot = await store.snapshot();
      expect(
        (decode(snapshot).single['attrs']['details']['body'] as String).length,
        70000,
      );
      expect(snapshot.stats.recoveredFileCount, 0);
      final export = await store.createExport({'record_type': 'metadata'});
      final metadata = jsonDecode(
        const LineSplitter().convert(await export.readAsString()).first,
      );
      expect(metadata['recovered_files'], 0);
    });

    test('附件预算按解压长度整组淘汰，清空后新附件不继承旧占用', () async {
      final store = create(budget: 100000);
      await store.initialize();
      await store.append(record(1, 'b' * 32, size: 70000));
      await store.append(record(2, 'b' * 32));
      await store.append(record(3, 'c' * 32, size: 70000));
      expect(decode(await store.snapshot()).map((item) => item['seq']), [3]);
      expect(await Directory('${temp.path}/records').list().length, 1);
      await store.clear();
      expect((await store.stats()).bytes, 0);
      await store.append(record(4, 'd' * 32, size: 70000));
      expect(decode(await store.snapshot()).map((item) => item['seq']), [4]);
    });

    test('最新单条超过预算仍保留全文和超限说明，不累积旧超限附件', () async {
      final store = create(budget: 1024);
      await store.initialize();
      await store.append(record(1, 'b' * 32, size: 70000));
      var retained = decode(await store.snapshot()).single;
      expect(
        retained['attrs']['details']['storage']['budget_exceeded'],
        isTrue,
      );
      expect((retained['attrs']['details']['body'] as String).length, 70000);
      await store.append(record(2, 'b' * 32));
      final withSummary = decode(await store.snapshot());
      expect(withSummary.map((item) => item['seq']), [1, 2]);
      expect(
        (withSummary.first['attrs']['details']['body'] as String).length,
        70000,
      );
      await store.append(record(3, 'c' * 32, size: 71000));
      retained = decode(await store.snapshot()).single;
      expect(retained['seq'], 3);
      expect(await Directory('${temp.path}/records').list().length, 1);
    });

    test('索引轮转淘汰同Trace全部旧事件，后续与重启后事件声明历史缺失', () async {
      var store = create(fileBytes: 900, files: 2);
      await store.initialize();
      await store.append(record(1, 'b' * 32, size: 450));
      await store.append(record(2, 'b' * 32, size: 450));
      await store.append(record(3, 'c' * 32, size: 450));
      expect(decode(await store.snapshot()).map((item) => item['seq']), [3]);
      await store.append(record(4, 'b' * 32));
      var retained = decode(await store.snapshot())
          .singleWhere((item) => item['seq'] == 4);
      expect(
        retained['attrs']['details']['storage']['history_missing'],
        isTrue,
      );
      store = create(fileBytes: 900, files: 2);
      await store.initialize();
      await store.append(record(5, 'b' * 32));
      retained = decode(await store.snapshot())
          .singleWhere((item) => item['seq'] == 5);
      expect(
        retained['attrs']['details']['storage']['history_missing'],
        isTrue,
      );
    });

    test('不可读索引不触发附件误删，恢复后才清除真正孤立文件', () async {
      final store = create();
      await store.initialize();
      await store.append(record(1, 'b' * 32, size: 70000));
      final orphan = File('${temp.path}/records/orphan.json.gz');
      await orphan.writeAsBytes(gzip.encode(utf8.encode('orphan')));
      final blocker = await Directory('${temp.path}/app.1.log').create();
      await store.maintain();
      expect(await orphan.exists(), isTrue);
      expect(
        (await store.snapshot()).stats.unreadableFileCount,
        greaterThan(0),
      );
      expect(decode(await store.snapshot()).single['seq'], 1);
      await blocker.delete();
      await store.maintain();
      expect(await orphan.exists(), isFalse);
      expect(decode(await store.snapshot()).single['seq'], 1);
    });

    test('索引事务写入失败保留已有操作，不留下半轮转结果', () async {
      final store = create(fileBytes: 900, files: 2);
      await store.initialize();
      await store.append(record(1, 'b' * 32, size: 450));
      await store.append(record(2, 'c' * 32, size: 450));
      final before = (await store.snapshot()).content;
      final blocker = await Directory('${temp.path}/app.1.log.rewrite.tmp')
          .create();
      await expectLater(
        store.append(record(3, 'd' * 32, size: 450)),
        throwsA(isA<FileSystemException>()),
      );
      expect((await store.snapshot()).content, before);
      await blocker.delete();
      await store.append(record(3, 'd' * 32, size: 450));
      expect(decode(await store.snapshot()).map((item) => item['seq']), [2, 3]);
    });

    test('索引容量不足只清理本次新附件，不改已有数据', () async {
      final store = create(fileBytes: 80);
      await store.initialize();
      await store.append('{"event":"keep"}');
      await expectLater(
        store.append(record(1, 'b' * 32, size: 70000)),
        throwsFormatException,
      );
      expect((await store.snapshot()).content, '{"event":"keep"}\n');
      expect(await Directory('${temp.path}/records').list().length, 0);
    });

    test('普通追加不扫描附件目录，只有到期维护才清理孤立文件', () async {
      final store = create(budget: 1024);
      await store.initialize();
      await store.append(record(1, 'b' * 32, size: 70000));
      final orphan = File('${temp.path}/records/orphan.json.gz');
      await orphan.writeAsBytes(gzip.encode(utf8.encode('orphan')));
      await store.append(record(2, 'c' * 32));
      expect(await orphan.exists(), isTrue);
      await store.maintain();
      expect(await orphan.exists(), isFalse);
    });

    test('留存过期按操作整体清理，不保留同Trace的半条链路', () async {
      final store = create();
      await store.initialize();
      await store.append(
        record(
          1,
          'b' * 32,
          at: DateTime.now().subtract(const Duration(days: 8)),
        ),
      );
      await store.append(record(2, 'b' * 32));
      await store.append(record(3, 'c' * 32));
      expect(decode(await store.snapshot()).map((item) => item['seq']), [3]);
      await store.append(record(4, 'b' * 32));
      final retained = decode(await store.snapshot())
          .singleWhere((item) => item['seq'] == 4);
      expect(
        retained['attrs']['details']['storage']['history_missing'],
        isTrue,
      );
    });
  });
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
    expect(AppLog.verboseEnabled.value, isFalse);

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

  test('原始堆栈在记录、快照和导出中完整保留，异常正文不入日志', () async {
    final temp = await Directory.systemTemp.createTemp('log_stack_test_');
    addTearDown(() async {
      await AppLog.resetForTesting();
      await temp.delete(recursive: true);
    });
    await AppLog.initialize(directory: temp);
    final stack = [
      '*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***',
      'os: android arch: arm64 comp: no sim: no',
      'isolate_dso_base: 7abc0000, vm_dso_base: 7abc0000',
      '#00 abs 000000007abc1234 virt 0000000000001234 _kDartIsolateSnapshotInstructions+0x1234',
      '#0 ScoreController.refresh.<anonymous closure> (package:nuist_sta_app/app.dart:24:1)',
      '#1 List.[] (dart:core-patch/growable_array.dart:264:36)',
      '#2 main (file:///home/synthetic-user/project/main.dart:9:2)',
      r'#3 main (C:\workspace\project\main.dart:12:3)',
      '<asynchronous suspension>',
      '',
      for (var index = 4; index < 40; index++)
        '#$index SyntheticController.load.<anonymous closure> (package:nuist_sta_app/synthetic_controller.dart:42:7)',
      '',
    ].join('\n');
    Map<String, Object?>? record;
    AppLog.recordListenerForTesting = (value) => record = value;
    AppLog.logger('test.stack').error(
      'failed',
      error: StateError('token=synthetic-secret'),
      stackTrace: StackTrace.fromString(stack),
    );
    expect((record!['attrs'] as Map)['stack_trace'], stack);
    expect(jsonEncode(record), isNot(contains('synthetic-secret')));

    void expectStack(String content) {
      final saved = const LineSplitter()
          .convert(content)
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .singleWhere((value) => value['scope'] == 'test.stack');
      expect((saved['attrs'] as Map)['stack_trace'], stack);
      expect(content, isNot(contains('synthetic-secret')));
    }

    for (var attempt = 0; attempt < 2; attempt++) {
      expectStack((await AppLog.snapshot()).content);
      expectStack(
        await File('${temp.path}/nuist_sta_app/logs/app.log').readAsString(),
      );
    }
    final exported = await AppLog.createExport({});
    expectStack(await exported.readAsString());
  });

  for (final level in [AppLogLevel.warning, AppLogLevel.error]) {
    test('${level.name} 控制台保留全部堆栈帧并携带同一事件序号', () {
      final original = debugPrint;
      final messages = <String>[];
      final frames = [
        '#00 abs 000000007abc1234 _kDartIsolateSnapshotInstructions+0x1234',
        for (var index = 0; index < 12; index++)
          '#$index main (package:nuist_sta_app/main.dart:9:2)',
        '<asynchronous suspension>',
        '#12 _rootRun (dart:async/zone.dart:1525:13)',
      ];
      debugPrint = (message, {wrapWidth}) {
        if (message != null) messages.add(message);
      };
      Map<String, Object?>? record;
      AppLog.recordListenerForTesting = (value) => record = value;
      AppLog.consoleEnabledForTesting = true;
      try {
        final log = AppLog.logger('test.console_stack');
        final write = level == AppLogLevel.warning ? log.warning : log.error;
        write(
          'failed',
          fields: {
            'details': {
              'response': {'body': '完整控制台响应证据', 'complete': true},
            },
          },
          error: StateError('synthetic token=synthetic-secret'),
          stackTrace: StackTrace.fromString(frames.join('\n')),
        );
      } finally {
        AppLog.consoleEnabledForTesting = false;
        debugPrint = original;
      }
      expect(messages, hasLength(1));
      expect(messages.single, startsWith(level.name.toUpperCase()));
      expect(messages.single, contains('#000001'));
      expect(messages.single, contains(AppLog.formatDetails(record!)));
      expect(messages.single, contains('完整控制台响应证据'));
      expect(messages.single, isNot(contains('synthetic-secret')));
      expect((record!['attrs'] as Map)['stack_trace'], frames.join('\n'));
      const marker = '调用堆栈:\n';
      final stackOffset = messages.single.lastIndexOf(marker);
      expect(stackOffset, greaterThanOrEqualTo(0));
      expect(
        messages.single.substring(stackOffset + marker.length),
        frames.join('\n'),
      );
    });
  }

  test('完整控制台消息直接包含原始响应，不生成裸 null 异常占位', () {
    Map<String, Object?>? record;
    AppLog.recordListenerForTesting = (value) => record = value;
    const response = '{"message":"gateway unavailable","value":null}';
    AppLog.logger('test.console_response').warning(
      'query.failed',
      fields: {
        'details': {
          'response': {'body': response, 'complete': true},
        },
      },
      error: const PortalLoginError('响应缺少业务数据'),
    );
    final message = AppLog.formatConsoleMessage(record!);
    expect(message, contains(response));
    expect(message, contains('响应缺少业务数据'));
    expect(message, contains(AppLog.formatDetails(record!)));
    expect(message.split('\n').where((line) => line.trim() == 'null'), isEmpty);
    expect(message, isNot(contains('调用堆栈:\nnull')));
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

  testWidgets('调试构建默认简洁控制台，设置仍隐藏所有诊断入口', (tester) async {
    expect(AppLog.verboseEnabled.value, isFalse);
    expect(AppLog.diagnosticsVisible.value, isFalse);
    await tester.pumpWidget(
      MaterialApp(theme: appLightTheme(), home: const SettingsPage()),
    );

    expect(find.text('深色模式'), findsOneWidget);
    expect(find.text('诊断与日志'), findsNothing);
    expect(find.text('查看日志'), findsNothing);
    expect(find.text('导出诊断日志'), findsNothing);
    expect(find.text('清除诊断日志'), findsNothing);
    expect(find.textContaining('详细模式'), findsNothing);
    expect(find.textContaining('需要详细诊断时'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  for (final verbose in [false, true]) {
    testWidgets('版本号五连击只解锁入口，保留${verbose ? '详细' : '标准'}日志模式', (tester) async {
      final expiry = verbose ? DateTime.utc(2030, 1, 1) : null;
      AppLog.verboseEnabled.value = verbose;
      AppLog.verboseExpiresAt.value = expiry;
      await _openAboutFromSettings(tester);

      for (var count = 0; count < 4; count++) {
        await tester.tap(find.text('v1.2.3 (45)'));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(AppLog.diagnosticsVisible.value, isFalse);
      await tester.tap(find.text('v1.2.3 (45)'));
      await tester.pump();

      expect(AppLog.diagnosticsVisible.value, isTrue);
      expect(AppLog.verboseEnabled.value, verbose);
      expect(AppLog.verboseExpiresAt.value, expiry);
      expect(find.text('已显示诊断与日志入口'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('诊断与日志'), findsOneWidget);
      expect(find.text('查看日志'), findsOneWidget);
      expect(find.text('导出诊断日志'), findsOneWidget);
      expect(find.text('清除诊断日志'), findsOneWidget);
      expect(find.textContaining('需要详细诊断时'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('版本号点击间隔超过三秒后必须重新累计五次', (tester) async {
    await _openAboutFromSettings(tester);
    for (var count = 0; count < 4; count++) {
      await tester.tap(find.text('v1.2.3 (45)'));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(seconds: 4));
    await tester.tap(find.text('v1.2.3 (45)'));
    await tester.pump();
    expect(AppLog.diagnosticsVisible.value, isFalse);

    for (var count = 0; count < 4; count++) {
      await tester.tap(find.text('v1.2.3 (45)'));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(AppLog.diagnosticsVisible.value, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('解锁后点击标准模式行才开启三十分钟详细日志', (tester) async {
    AppLog.diagnosticsVisible.value = true;
    AppLog.verboseEnabled.value = false;
    await tester.pumpWidget(
      MaterialApp(theme: appLightTheme(), home: const SettingsPage()),
    );
    await tester.pumpAndSettle();
    expect(AppLog.verboseExpiresAt.value, isNull);

    final before = DateTime.now().toUtc();
    await tester.tap(find.text('标准模式 · 关键步骤摘要，完整详情已保存'));
    await tester.pumpAndSettle();

    expect(AppLog.verboseEnabled.value, isTrue);
    expect(
      AppLog.verboseExpiresAt.value?.millisecondsSinceEpoch,
      inInclusiveRange(
        before.add(const Duration(minutes: 30)).millisecondsSinceEpoch,
        DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 30))
            .millisecondsSinceEpoch,
      ),
    );
    expect(AppLog.diagnosticsVisible.value, isTrue);
    expect(find.textContaining('详细控制台 · 剩余'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '关闭'));
    await tester.pumpAndSettle();
    expect(AppLog.verboseEnabled.value, isFalse);
    expect(AppLog.verboseExpiresAt.value, isNull);
    expect(find.text('标准模式 · 关键步骤摘要，完整详情已保存'), findsOneWidget);
    expect(find.textContaining('需要详细诊断时'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await AppLog.resetForTesting();
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
        'field_validation',
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
          'A RenderFlex overflowed by 8 pixels on the right. token=synthetic-private',
        ),
        library: 'rendering library',
      ),
    );
    FlutterError.onError!(
      FlutterErrorDetails(
        exception: FlutterError(
          'Incorrect use of ParentDataWidget. token=synthetic-private',
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
          throw const PortalNetworkError('请求失败 token=synthetic-private'),
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
    expect(failure['event'], 'refresh.failed');
    expect(failure['trace_id'], parent['trace_id']);
    expect(failure['parent_span_id'], parent['span_id']);
    expect(failure['span_id'], isNot(parent['span_id']));
    expect((failure['attrs'] as Map)['outcome'], 'unavailable');
    expect((failure['attrs'] as Map)['has_cache'], isFalse);
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

  test('旧记录和导出元信息会重新清洗，保留 Trace 和原始堆栈', () async {
    final temp = await Directory.systemTemp.createTemp('log_migration_test_');
    addTearDown(() async {
      await AppLog.resetForTesting();
      await temp.delete(recursive: true);
    });
    final logs = Directory('${temp.path}/nuist_sta_app/logs');
    await logs.create(recursive: true);
    const stack =
        '#00 abs 000000007abc1234 _kDartIsolateSnapshotInstructions+0x1234\n'
        '#01 List.[] (dart:core-patch/growable_array.dart:264:36)\n'
        '<asynchronous suspension>\n';
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
        'attrs': {'detail': 'synthetic-private', 'reference': 202512340001, 'duration_ms': 42, 'stack_trace': stack},
        'request_body': 'synthetic-private',
      })}\n',
    );
    await AppLog.initialize(directory: temp);
    void expectStack(String content) {
      final record = const LineSplitter()
          .convert(content)
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .singleWhere((value) => value['scope'] == 'test.legacy');
      expect((record['attrs'] as Map)['stack_trace'], stack);
    }

    expectStack(await File('${logs.path}/app.log').readAsString());
    final snapshot = await AppLog.snapshot();
    expectStack(snapshot.content);
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
    expectStack(content);
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

Future<void> _openAboutFromSettings(WidgetTester tester) async {
  PackageInfo.setMockInitialValues(
    appName: 'NUIST++',
    packageName: 'com.example.nuist_sta_app',
    version: '1.2.3',
    buildNumber: '45',
    buildSignature: '',
  );
  await tester.pumpWidget(
    MaterialApp(theme: appLightTheme(), home: const SettingsPage()),
  );
  tester
      .state<NavigatorState>(find.byType(Navigator))
      .push(MaterialPageRoute<void>(builder: (_) => const AboutPage()));
  // 贡献者在无平台通道时可能一直加载，只等待本次测试需要的页面转场。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(find.text('v1.2.3 (45)'), findsOneWidget);
}

Future<void> _openLogPreview(WidgetTester tester, ThemeData theme) async {
  AppLog.diagnosticsVisible.value = true;
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
