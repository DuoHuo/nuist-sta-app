import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/config/campus_config.dart';
import 'package:nuist_sta_app/core/auth/portal_exceptions.dart';
import 'package:nuist_sta_app/core/logging/app_log.dart';
import 'package:nuist_sta_app/core/logging/log_store.dart';
import 'package:nuist_sta_app/core/logging/diagnostic_redactor.dart';

Map<String, Object?>? _redactStoredRecord(Map<String, Object?> record) => {
  ...record,
  'attrs': DiagnosticRedactor.value(record['attrs']),
};

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

    test('大正文只进入附件，不占索引容量；预览只读摘要、精确读取及导出保留全文', () async {
      final store = create(budget: 8 * 1024 * 1024, fileBytes: 4096);
      await store.initialize();
      for (var i = 1; i <= 3; i++) {
        await store.append(record(i, 'b' * 32, size: 1024 * 1024));
      }
      final preview = await store.snapshot(expandAttachments: false);
      expect(preview.stats.bytes, lessThan(4096));
      expect(decode(preview), hasLength(3));
      expect(preview.content, isNot(contains('x' * 1024)));
      expect(
        decode(preview).every((row) => row['record_attachment'] is String),
        isTrue,
      );
      final full = await store.findRecord('a' * 16, 2);
      expect((full!['attrs'] as Map)['details']['body'].length, 1024 * 1024);
      final export = await store.createExport({});
      final exported = const LineSplitter()
          .convert(await export.readAsString())
          .skip(1)
          .map(jsonDecode)
          .toList();
      expect(exported, hasLength(3));
      expect(
        exported.every(
          (row) => row['attrs']['details']['body'].length == 1024 * 1024,
        ),
        isTrue,
      );
    });

    test('后台结构化写入仍按调用顺序快照、导出和清除', () async {
      final store = create(budget: 8 * 1024 * 1024);
      await store.initialize();
      final first = store.appendRecord(
        jsonDecode(record(1, 'b' * 32, size: 2 * 1024 * 1024))
            as Map<String, Object?>,
        background: true,
      );
      final second = store.appendRecord(
        jsonDecode(record(2, 'c' * 32)) as Map<String, Object?>,
      );
      final snapshot = store.snapshot();
      final cleared = store.clear();
      final third = store.appendRecord(
        jsonDecode(record(3, 'd' * 32, size: 70000)) as Map<String, Object?>,
      );
      final exported = store.createExport({'record_type': 'metadata'});
      await Future.wait([first, second, cleared, third]);
      final captured = decode(await snapshot);
      expect(captured.map((item) => item['seq']), [1, 2]);
      expect(
        (captured.first['attrs']['details']['body'] as String).length,
        2 * 1024 * 1024,
      );
      final rows = const LineSplitter()
          .convert(await (await exported).readAsString())
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .toList();
      expect(rows.skip(1).map((item) => item['seq']), [3]);
      expect((rows.last['attrs']['details']['body'] as String).length, 70000);
    });

    test('后台水合重新脱敏旧附件，附件丢失仍声明内容不完整', () async {
      final store = RotatingLogStore(
        temp,
        exportDirectory: Directory('${temp.path}/exports'),
        maxFileBytes: 4096,
        sanitizeRecord: _redactStoredRecord,
      );
      await store.initialize();
      final legacy =
          jsonDecode(record(1, 'b' * 32, size: 100000)) as Map<String, Object?>;
      final details = ((legacy['attrs'] as Map)['details'] as Map);
      details['request'] = {
        'headers': {
          'Authorization': 'Bearer legacy-private',
          'Cookie': 'session=private-cookie',
        },
        'body_text': '{"student_id":"202512340001","value":"safe"}',
      };
      await store.appendRecord(legacy, background: true);
      final snapshot = await store.snapshot();
      expect(snapshot.content, isNot(contains('legacy-private')));
      expect(snapshot.content, isNot(contains('private-cookie')));
      expect(snapshot.content, isNot(contains('202512340001')));
      expect(snapshot.content, contains('safe'));
      expect(
        (decode(snapshot).single['attrs']['details']['body'] as String).length,
        100000,
      );
      expect(snapshot.stats.recoveredFileCount, 1);
      final attachment = await Directory('${temp.path}/records')
          .list()
          .where((entry) => entry is File)
          .single;
      await attachment.delete();
      final missing = decode(await store.snapshot()).single;
      expect(missing['attrs']['details']['complete'], isFalse);
      expect(
        missing['attrs']['details']['incomplete_reason'],
        'diagnostic_attachment_unavailable',
      );
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

    test('索引轮转按大小和数量淘汰同 Trace 旧事件，后续与重启后声明历史缺失', () async {
      var store = create(fileBytes: 900, files: 2);
      await store.initialize();
      await store.append(record(1, 'b' * 32, size: 450));
      await store.append(record(2, 'b' * 32, size: 450));
      await store.append(record(3, 'c' * 32, size: 450));
      final rotated = await store.snapshot();
      expect(rotated.stats.fileCount, lessThanOrEqualTo(2));
      expect(decode(rotated).map((item) => item['seq']), [3]);
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

    test('留存过期按操作整体清理活跃与归档记录，更新最早记录时间并标记历史缺失', () async {
      final store = create();
      await store.initialize();
      final now = DateTime.now().toUtc();
      await store.append(
        record(1, 'b' * 32, at: now.subtract(const Duration(days: 8))),
      );
      await store.append(record(2, 'b' * 32, at: now));
      await store.append(record(3, 'c' * 32, at: now));
      final snapshot = await store.snapshot();
      expect(decode(snapshot).map((item) => item['seq']), [3]);
      expect(snapshot.stats.oldestRecordAt, now);
      expect(
        await File('${temp.path}/app.log').readAsString(),
        isNot(contains('sample.1')),
      );
      await store.append(record(4, 'b' * 32));
      final retained = decode(await store.snapshot())
          .singleWhere((item) => item['seq'] == 4);
      expect(
        retained['attrs']['details']['storage']['history_missing'],
        isTrue,
      );
    });
  });

  test('日志文本过滤凭据、Basic、多值 Cookie、长数字、主机名与 URL，并规范脚本事件', () {
    final basic = base64Encode(utf8.encode('synthetic-secret'));
    final sanitized = AppLog.sanitizeTextForTesting(
      'Authorization: Bearer abc\n'
      'Authorization: Basic $basic\n'
      'Cookie: a=synthetic-session; b=synthetic-cookie; c=synthetic-private\n'
      'token=secret\nstudent=202512340001\n'
      'https://private.example/private-user?ticket=synthetic-ticket\n'
      'host=private.example',
    );

    expect(sanitized, isNot(contains('abc')));
    expect(sanitized, isNot(contains('secret')));
    expect(sanitized, isNot(contains('synthetic')));
    expect(sanitized, isNot(contains(basic)));
    expect(sanitized, isNot(contains('202512340001')));
    expect(sanitized, isNot(contains('private.example')));
    expect(sanitized, isNot(contains('private-user')));
    expect(sanitized, contains('[REDACTED_SECRET]'));
    expect(sanitized, contains('[REDACTED_ID]'));
    expect(sanitized, contains('[REDACTED_HOST]'));
    expect(sanitized, contains('[REDACTED_URL]'));

    final fields = AppLog.scriptEventFields(
      'page called credentials.create (rp=https://private.example/private-user)',
    );
    expect(fields, {'script_event': 'credential_create'});
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

  test('日志初始化前的事件按序保留，初始化不丢首帧诊断', () async {
    final temp = await Directory.systemTemp.createTemp('log_startup_queue_');
    addTearDown(() async {
      await AppLog.resetForTesting();
      await temp.delete(recursive: true);
    });
    AppLog.logger('test.startup').info('first');
    AppLog.logger('test.startup').info(
      'second',
      fields: {
        'details': {'token': 'synthetic-startup-secret', 'message': '首帧诊断'},
      },
    );
    await AppLog.initialize(directory: temp);
    final snapshot = await AppLog.snapshot();
    final startup = const LineSplitter()
        .convert(snapshot.content)
        .map(jsonDecode)
        .where((row) => row['scope'] == 'test.startup')
        .toList();
    expect(startup.map((row) => row['event']), ['first', 'second']);
    expect(snapshot.content, contains('首帧诊断'));
    expect(snapshot.content, isNot(contains('synthetic-startup-secret')));
  });

  test('初始化前大正文旁路保存附件，不挤掉普通首帧事件', () async {
    final temp = await Directory.systemTemp.createTemp('large_startup_queue_');
    addTearDown(() async {
      await AppLog.resetForTesting();
      await temp.delete(recursive: true);
    });
    final starting = AppLog.initialize(directory: temp);
    final body = '${'x' * (3 * 1024 * 1024)}启动末尾';
    final evidence = AppLog.recordHttpExchange('test.startup.large', {
      'response': {'body': body},
    });
    AppLog.logger('test.startup.small').info('after');
    await starting;
    final snapshot = await AppLog.snapshot();
    expect(snapshot.content, contains('启动末尾'));
    expect(snapshot.content, contains('test.startup.small'));
    final preview = await AppLog.snapshot(expandAttachments: false);
    expect(preview.content.length, lessThan(4096));
    final full = await AppLog.readRecord(
      evidence!['record_ref'] as Map<String, Object?>,
      // 回读须还原 3 MiB 附件；此处验证完整性，不考核并行测试期间的读取速度。
      timeout: const Duration(seconds: 15),
    );
    expect(full, isNotNull, reason: '初始化后必须保留原始记录引用，不能重建新 seq');
    expect((full!['attrs'] as Map)['details']['response']['body'], body);
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

  test('warning 与 error 控制台保留全部堆栈帧与原始响应，无堆栈时不生成裸 null', () {
    final original = debugPrint;
    final frames = [
      '#00 abs 000000007abc1234 _kDartIsolateSnapshotInstructions+0x1234',
      for (var index = 0; index < 12; index++)
        '#$index main (package:nuist_sta_app/main.dart:9:2)',
      '<asynchronous suspension>',
      '#12 _rootRun (dart:async/zone.dart:1525:13)',
    ];
    for (final level in [AppLogLevel.warning, AppLogLevel.error]) {
      final messages = <String>[];
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
      expect(
        messages.single,
        contains('#${'${record!['seq']}'.padLeft(6, '0')}'),
      );
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
    }

    Map<String, Object?>? noStackRecord;
    AppLog.recordListenerForTesting = (value) => noStackRecord = value;
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
    final message = AppLog.formatConsoleMessage(noStackRecord!);
    expect(message, contains(response));
    expect(message, contains('响应缺少业务数据'));
    expect(message, contains(AppLog.formatDetails(noStackRecord!)));
    expect(message.split('\n').where((line) => line.trim() == 'null'), isEmpty);
    expect(message, isNot(contains('调用堆栈:\nnull')));
  });

  test('全局 Flutter 异常统一清洗入口并对无堆栈框架错误安全分类', () {
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
      FlutterErrorDetails(exception: StateError('token=synthetic-secret')),
    );
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
    expect(records[0]['level'], 'ERROR');
    expect((records[1]['attrs'] as Map)['framework_error'], 'flex_overflow');
    expect((records[1]['attrs'] as Map)['framework_library'], 'rendering');
    expect(
      (records[2]['attrs'] as Map)['framework_error'],
      'invalid_parent_data',
    );
    expect(jsonEncode(records), isNot(contains('synthetic-secret')));
    expect(jsonEncode(records), isNot(contains('synthetic-private')));
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

  test('摘要格式化区分成功、原生失败与异常类型，详情保留完整追踪字段', () {
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

    final nativeSummary = AppLog.formatSummary({
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
    expect(nativeSummary, startsWith('VPN 目标连接失败 · C2 教务'));
    expect(nativeSummary, contains('阶段 TCP 连接'));
    expect(nativeSummary, contains('系统码 10061'));
    expect(nativeSummary, contains('本阶段 1.20s'));
    expect(nativeSummary, contains('耗时 3.20s'));
    expect(nativeSummary, contains('期限 24.00s'));
    expect(nativeSummary, isNot(contains('1m')));
    expect(nativeSummary, isNot(contains('\n')));

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

  test('RotatingLogStore 短窗口批量缓冲合并写入并在阈值或定时器到期后落盘', () async {
    final temp = await Directory.systemTemp.createTemp('log_batch_test_');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final store = RotatingLogStore(
      temp,
      flushInterval: const Duration(milliseconds: 120),
      flushThresholdBytes: 4 * 1024,
    );
    addTearDown(store.close);
    await store.initialize();

    await store.append('{"event":"batch_1"}');
    await store.append('{"event":"batch_2"}');
    expect(store.pendingBufferBytes, greaterThan(0));
    expect(store.writeBatchCountForTesting, 0);

    await Future<void>.delayed(const Duration(milliseconds: 220));
    expect(store.pendingBufferBytes, 0);
    expect(store.writeBatchCountForTesting, 1);
    final logContent = await File('${temp.path}/app.log').readAsString();
    expect(logContent, contains('batch_1'));
    expect(logContent, contains('batch_2'));

    await store.append('{"event":"threshold","pad":"${'x' * 4500}"}');
    expect(store.pendingBufferBytes, 0);
    expect(store.writeBatchCountForTesting, 2);
  });

  test('warning 与 error 级别日志触发立即刷盘，resetForTesting 清理定时器', () async {
    final temp = await Directory.systemTemp.createTemp('log_urgent_flush_');
    addTearDown(() async {
      await AppLog.resetForTesting();
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    AppLog.flushIntervalForTesting = const Duration(seconds: 10);
    await AppLog.initialize(directory: temp);
    final logFile = File('${temp.path}/nuist_sta_app/logs/app.log');
    // session.started 本身是 info 级，批量窗口内尚未刷盘；先观察其大小。
    final beforeBytes = await logFile.exists() ? await logFile.length() : 0;

    AppLog.logger('test.batch').info('buffered.info');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await logFile.exists() ? await logFile.length() : 0, beforeBytes);

    AppLog.logger('test.batch').warning('urgent.warning');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final afterWarning = await logFile.readAsString();
    expect(afterWarning, contains('buffered.info'));
    expect(afterWarning, contains('urgent.warning'));

    AppLog.logger('test.batch').info('buffered.before.error');
    final bytesAfterWarning = await logFile.length();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await logFile.length(), bytesAfterWarning);

    AppLog.logger('test.batch')
        .error('urgent.error', error: StateError('boom'));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final afterError = await logFile.readAsString();
    expect(afterError, contains('buffered.before.error'));
    expect(afterError, contains('urgent.error'));
  });

  test('RotatingLogStore 外部删除活跃日志文件时保留后续日志', () async {
    final temp = await Directory.systemTemp.createTemp('log_recreate_test_');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final store = RotatingLogStore(
      temp,
      flushInterval: const Duration(milliseconds: 50),
    );
    addTearDown(store.close);
    await store.initialize();

    await store.append('{"event":"first"}', immediateFlush: true);
    final logFile = File('${temp.path}/app.log');
    expect(await logFile.exists(), isTrue);

    if (Platform.isWindows) {
      // Windows 的打开句柄不共享删除权限；删除被拒绝后仍应保留后续写入。
      await expectLater(
        logFile.delete(),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.osError?.errorCode,
            'Windows 共享冲突',
            32,
          ),
        ),
      );
      expect(await logFile.exists(), isTrue);
    } else {
      // Android、Linux 等平台允许删除活跃文件，需要验证句柄自动重建。
      await logFile.delete();
      expect(await logFile.exists(), isFalse);
    }

    await store.append('{"event":"second"}', immediateFlush: true);
    expect(await logFile.exists(), isTrue);
    final content = await logFile.readAsString();
    expect(content, contains('second'));
    if (Platform.isWindows) expect(content, contains('first'));
  });
}
