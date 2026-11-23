import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/logging/app_log.dart';
import 'package:nuist_sta_app/core/network/vpn_native.dart';

/// 测试用伪造动态库：运行在真实的后台 worker Isolate 内，
/// 用于观测动态库打开次数、4 个符号查找次数、Isolate 复用、字节清零与可控阻塞/崩溃。
final class _FakeWorkerLibrary implements VpnNativePreparedLibrary {
  _FakeWorkerLibrary({
    required this.libraryName,
    required this.workerTag,
    required this.openCount,
    required this.lookupCount,
    required this.eventsPort,
  });

  final String libraryName;
  final String workerTag;
  final int openCount;
  final int lookupCount;
  final SendPort eventsPort;

  int _callCount = 0;
  Uint8List? _lastBytes;

  @override
  FutureOr<Map<String, dynamic>> invoke(Uint8List requestBytes) async {
    _callCount++;
    final previousBytesZeroed =
        _lastBytes != null && _lastBytes!.every((byte) => byte == 0);
    _lastBytes = requestBytes;

    final decoded =
        jsonDecode(utf8.decode(requestBytes)) as Map<String, dynamic>;
    final method = decoded['method'] as String? ?? 'unknown';

    eventsPort.send(<String, Object?>{
      'type': 'call',
      'method': method,
      'workerTag': workerTag,
      'id': decoded['id'],
      'startId': decoded['startId'],
      'openId': decoded['openId'],
      'tag': decoded['tag'],
      'hasToken':
          decoded['token'] is String && (decoded['token'] as String).isNotEmpty,
    });

    if (decoded['crash'] == true) {
      Isolate.current.kill(priority: Isolate.immediate);
      // 防止异步 kill 尚未生效前意外返回。
      await Completer<void>().future;
    }

    if (decoded['syncSleepMs'] case final int sleepMs) {
      sleep(Duration(milliseconds: sleepMs));
    }

    Object? gateDirective;
    if (decoded['gateKey'] case final String gateKey) {
      final gate = ReceivePort();
      eventsPort.send(<String, Object?>{
        'type': 'gate',
        'gateKey': gateKey,
        'method': method,
        'workerTag': workerTag,
        'replyPort': gate.sendPort,
      });
      gateDirective = await gate.first;
      gate.close();
    }

    if (gateDirective is Map<String, dynamic>) {
      if (gateDirective['throwSocket'] is String) {
        throw SocketException(gateDirective['throwSocket'] as String);
      }
      if (gateDirective['response'] is Map<String, dynamic>) {
        return gateDirective['response'] as Map<String, dynamic>;
      }
    }

    if (decoded['throwSocket'] case final String message) {
      throw SocketException(message);
    }

    if (decoded['errorResponse'] case final Map<String, dynamic> errorResp) {
      return errorResp;
    }

    return <String, dynamic>{
      'ok': true,
      'data': <String, dynamic>{
        'method': method,
        'workerTag': workerTag,
        'libraryName': libraryName,
        'openCount': openCount,
        'lookupCount': lookupCount,
        'callCount': _callCount,
        'previousBytesZeroed': previousBytesZeroed,
        if (decoded['returnData'] is Map<String, dynamic>)
          ...(decoded['returnData'] as Map<String, dynamic>),
      },
    };
  }
}

/// 每个 worker Isolate 独立的打开计数器，用于验证按库名缓存仅加载一次。
int _isolateOpenCount = 0;
int _isolateLookupCount = 0;
int _isolateFailOpenRemaining = 0;

VpnNativeLibraryOpener _createTestOpener(
  SendPort eventsPort, {
  int failFirstOpenCount = 0,
}) {
  return (String libraryName) {
    final workerTag =
        Isolate.current.debugName ?? 'iso-${identityHashCode(Isolate.current)}';
    if (_isolateOpenCount == 0 && failFirstOpenCount > 0) {
      _isolateFailOpenRemaining = failFirstOpenCount;
    }
    _isolateOpenCount++;
    eventsPort.send(<String, Object?>{
      'type': 'open',
      'libraryName': libraryName,
      'workerTag': workerTag,
      'openCount': _isolateOpenCount,
    });
    if (_isolateFailOpenRemaining > 0) {
      _isolateFailOpenRemaining--;
      throw VpnNativeException(
        '模拟原生库首次打开失败',
        code: 'native_library_load_failed',
        stage: 'native.load',
        cause: ArgumentError('synthetic dlopen failure'),
      );
    }
    for (final symbol in vpnNativeSymbolNames) {
      _isolateLookupCount++;
      eventsPort.send(<String, Object?>{
        'type': 'lookup',
        'symbol': symbol,
        'workerTag': workerTag,
        'lookupCount': _isolateLookupCount,
      });
    }
    return _FakeWorkerLibrary(
      libraryName: libraryName,
      workerTag: workerTag,
      openCount: _isolateOpenCount,
      lookupCount: _isolateLookupCount,
      eventsPort: eventsPort,
    );
  };
}

/// 测试辅助事件总线，负责收集来自各真实 worker Isolate 的观测事件与同步门控。
final class _WorkerTestHarness {
  _WorkerTestHarness() {
    _sub = _events.listen((Object? raw) {
      if (raw is! Map) return;
      final event = raw.cast<String, Object?>();
      allEvents.add(event);
      if (event['type'] == 'gate') {
        final key = event['gateKey'] as String;
        final port = event['replyPort'] as SendPort;
        _gates[key] = port;
        _gateWorkers[key] = event['workerTag'] as String;
        final waiter = _gateWaiters.remove(key);
        if (waiter != null && !waiter.isCompleted) {
          waiter.complete(port);
        }
      }
      for (final predicate in List<_EventWaiter>.of(_eventWaiters)) {
        if (predicate.matches(event)) {
          _eventWaiters.remove(predicate);
          predicate.completer.complete(event);
        }
      }
    });
  }

  final ReceivePort _events = ReceivePort();
  late final StreamSubscription<Object?> _sub;
  final List<Map<String, Object?>> allEvents = <Map<String, Object?>>[];
  final Map<String, SendPort> _gates = <String, SendPort>{};
  final Map<String, String> _gateWorkers = <String, String>{};
  final Map<String, Completer<SendPort>> _gateWaiters =
      <String, Completer<SendPort>>{};
  final List<_EventWaiter> _eventWaiters = <_EventWaiter>[];

  SendPort get sendPort => _events.sendPort;

  String? workerTagForGate(String gateKey) => _gateWorkers[gateKey];

  Future<SendPort> waitForGate(
    String gateKey, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    if (_gates[gateKey] case final existing?) {
      return Future<SendPort>.value(existing);
    }
    final completer = _gateWaiters.putIfAbsent(
      gateKey,
      Completer<SendPort>.new,
    );
    return completer.future.timeout(timeout);
  }

  void releaseGate(String gateKey, [Object? directive]) {
    final port = _gates.remove(gateKey);
    if (port == null) {
      throw StateError('门控 $gateKey 尚未到达或已释放');
    }
    port.send(directive);
  }

  Future<Map<String, Object?>> waitForEvent(
    bool Function(Map<String, Object?> event) matches, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    for (final existing in allEvents) {
      if (matches(existing)) {
        return Future<Map<String, Object?>>.value(existing);
      }
    }
    final waiter = _EventWaiter(matches);
    _eventWaiters.add(waiter);
    return waiter.completer.future.timeout(timeout);
  }

  Future<void> waitUntil(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final watch = Stopwatch()..start();
    while (!condition()) {
      if (watch.elapsed >= timeout) {
        throw TimeoutException('等待条件超时', timeout);
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> close() async {
    await _sub.cancel();
    _events.close();
  }
}

final class _EventWaiter {
  _EventWaiter(this.matches);

  final bool Function(Map<String, Object?> event) matches;
  final Completer<Map<String, Object?>> completer =
      Completer<Map<String, Object?>>();
}

void main() {
  late List<Map<String, Object?>> logRecords;

  setUp(() {
    logRecords = <Map<String, Object?>>[];
    AppLog.recordListenerForTesting = logRecords.add;
  });

  tearDown(() async {
    AppLog.recordListenerForTesting = null;
    await VpnNative.resetForTesting();
  });

  test('同一 worker 内多次调用仅打开动态库并查找 4 个符号一次，控制面与阻塞面各自复用', () async {
    final harness = _WorkerTestHarness();
    final native = VpnNative.forTesting(
      libraryOpener: _createTestOpener(harness.sendPort),
      libraryNameOverride: 'libnuist_vpn_unit.so',
    );
    addTearDown(() async {
      await native.disposeForTesting();
      await harness.close();
    });

    final controlMethods = <String>[
      'version',
      'status',
      'prepareStart',
      'startStatus',
      'cancelStart',
    ];
    final controlResults = <Map<String, dynamic>>[];
    for (final method in controlMethods) {
      controlResults.add(await native.call({'method': method}));
    }

    final controlWorker = controlResults.first['workerTag'] as String;
    for (var i = 0; i < controlResults.length; i++) {
      expect(controlResults[i]['workerTag'], controlWorker);
      expect(controlResults[i]['openCount'], 1);
      expect(controlResults[i]['lookupCount'], 4);
      expect(controlResults[i]['callCount'], i + 1);
    }
    expect(native.statsForTesting.controlSpawnCount, 1);
    expect(native.statsForTesting.blockingSpawnCount, 0);
    expect(native.statsForTesting.hasControlWorker, isTrue);

    final blockingMethods = <String>['start', 'open', 'probe'];
    final blockingResults = <Map<String, dynamic>>[];
    for (final method in blockingMethods) {
      blockingResults.add(await native.call({'method': method}));
    }

    final blockingWorker = blockingResults.first['workerTag'] as String;
    expect(blockingWorker, isNot(controlWorker));
    for (var i = 0; i < blockingResults.length; i++) {
      expect(blockingResults[i]['workerTag'], blockingWorker);
      expect(blockingResults[i]['openCount'], 1);
      expect(blockingResults[i]['lookupCount'], 4);
      expect(blockingResults[i]['callCount'], i + 1);
    }
    expect(native.statsForTesting.blockingSpawnCount, 1);
    expect(native.statsForTesting.idleBlockingWorkers, 1);

    final controlLookups = harness.allEvents
        .where((e) => e['type'] == 'lookup' && e['workerTag'] == controlWorker)
        .map((e) => e['symbol'])
        .toList();
    expect(controlLookups, vpnNativeSymbolNames);
  });

  test('首次打开动态库失败不污染缓存，真实默认加载失败保留诊断上下文', () async {
    final harness = _WorkerTestHarness();
    final native = VpnNative.forTesting(
      libraryOpener: _createTestOpener(harness.sendPort, failFirstOpenCount: 1),
      libraryNameOverride: 'libnuist_vpn_transient.so',
    );
    addTearDown(() async {
      await native.disposeForTesting();
      await harness.close();
    });

    await expectLater(
      native.call({'method': 'version'}),
      throwsA(
        isA<VpnNativeException>()
            .having((e) => e.code, 'code', 'native_library_load_failed')
            .having((e) => e.stage, 'stage', 'native.load'),
      ),
    );

    final second = await native.call({'method': 'version'});
    final third = await native.call({'method': 'status'});
    expect(second['openCount'], 2);
    expect(third['openCount'], 2);
    expect(third['workerTag'], second['workerTag']);
    expect(native.statsForTesting.controlSpawnCount, 1);

    final realMissing = VpnNative.forTesting(
      libraryNameOverride: 'libnuist_vpn_nonexistent_99999.so',
    );
    addTearDown(realMissing.disposeForTesting);

    await expectLater(
      realMissing.call({'method': 'version'}),
      throwsA(
        isA<VpnNativeException>()
            .having((e) => e.code, 'code', 'native_library_load_failed')
            .having((e) => e.stage, 'stage', 'native.load')
            .having(
              (e) => e.diagnosticContext['error_kind'],
              'error_kind',
              'platform_unavailable',
            )
            .having((e) => e.cause, 'cause', isNotNull)
            .having((e) => e.causeStackTrace, 'causeStackTrace', isNotNull),
      ),
    );
  });

  test('敏感请求字节数组在成功、业务失败与底层异常后均原地清零且不进入日志', () async {
    final harness = _WorkerTestHarness();
    final native = VpnNative.forTesting(
      libraryOpener: _createTestOpener(harness.sendPort),
      libraryNameOverride: 'libnuist_vpn_zero.so',
    );
    addTearDown(() async {
      await native.disposeForTesting();
      await harness.close();
    });

    const token1 = 'synthetic-secret-token-202512340001-ok';
    const token2 = 'synthetic-secret-token-202512340001-err';
    const token3 = 'synthetic-secret-token-202512340001-throw';

    // 1. 成功调用后请求字节被清零
    final first = await native.call({'method': 'start', 'token': token1});
    final afterFirst = await native.call({'method': 'open'});
    expect(afterFirst['workerTag'], first['workerTag']);
    expect(afterFirst['previousBytesZeroed'], isTrue);

    // 2. 原生 ok:false 业务错误后请求字节仍被清零
    await expectLater(
      native.call({
        'method': 'start',
        'token': token2,
        'errorResponse': {
          'ok': false,
          'error': '合成鉴权失败',
          'diagnostic': {'code': 'native_start_failed', 'stage': '协议鉴权'},
        },
      }),
      throwsA(isA<VpnNativeException>()),
    );
    final afterSecond = await native.call({'method': 'probe'});
    expect(afterSecond['workerTag'], first['workerTag']);
    expect(afterSecond['previousBytesZeroed'], isTrue);

    // 3. 同步抛出异常后请求字节仍被清零
    await expectLater(
      native.call({'method': 'open', 'token': token3, 'throwSocket': '合成底层异常'}),
      throwsA(isA<SocketException>()),
    );
    final afterThird = await native.call({'method': 'open'});
    expect(afterThird['workerTag'], first['workerTag']);
    expect(afterThird['previousBytesZeroed'], isTrue);

    final serializedLogs = jsonEncode(logRecords);
    expect(serializedLogs, isNot(contains(token1)));
    expect(serializedLogs, isNot(contains(token2)));
    expect(serializedLogs, isNot(contains(token3)));
  });

  test('阻塞命令池并发执行、超上限排队，突发结束后按空闲上限裁剪并复用', () async {
    final harness = _WorkerTestHarness();
    final native = VpnNative.forTesting(
      libraryOpener: _createTestOpener(harness.sendPort),
      libraryNameOverride: 'libnuist_vpn_pool.so',
      maxBlockingWorkers: 3,
      maxIdleBlockingWorkers: 2,
    );
    addTearDown(() async {
      await native.disposeForTesting();
      await harness.close();
    });

    final futures = <Future<Map<String, dynamic>>>[
      for (var i = 0; i < 5; i++)
        native.call({'method': 'open', 'gateKey': 'open-$i', 'tag': 'req-$i'}),
    ];

    await Future.wait([
      harness.waitForGate('open-0'),
      harness.waitForGate('open-1'),
      harness.waitForGate('open-2'),
    ]);

    expect(native.statsForTesting.activeBlockingWorkers, 3);
    expect(native.statsForTesting.queuedBlockingRequests, 2);
    expect(native.statsForTesting.blockingSpawnCount, 3);
    final initialWorkers = <String>{
      harness.workerTagForGate('open-0')!,
      harness.workerTagForGate('open-1')!,
      harness.workerTagForGate('open-2')!,
    };
    expect(initialWorkers, hasLength(3));

    // 释放前两个任务，队列中第 4、5 个任务立即复用空出的 worker。
    harness.releaseGate('open-0');
    harness.releaseGate('open-1');
    await Future.wait([
      harness.waitForGate('open-3'),
      harness.waitForGate('open-4'),
    ]);
    expect(native.statsForTesting.blockingSpawnCount, 3);
    expect(native.statsForTesting.queuedBlockingRequests, 0);

    harness.releaseGate('open-2');
    harness.releaseGate('open-3');
    harness.releaseGate('open-4');

    final results = await Future.wait(futures);
    expect(results, hasLength(5));
    expect(native.statsForTesting.activeBlockingWorkers, 0);
    expect(native.statsForTesting.idleBlockingWorkers, 2);
    expect(native.statsForTesting.blockingSpawnCount, 3);

    // 再次发起 2 路阻塞调用，应完全复用空闲池中的 2 个 Isolate。
    final reuseA = native.call({'method': 'probe', 'gateKey': 'reuse-a'});
    final reuseB = native.call({'method': 'open', 'gateKey': 'reuse-b'});
    await Future.wait([
      harness.waitForGate('reuse-a'),
      harness.waitForGate('reuse-b'),
    ]);
    expect(native.statsForTesting.blockingSpawnCount, 3);
    expect(initialWorkers, contains(harness.workerTagForGate('reuse-a')));
    expect(initialWorkers, contains(harness.workerTagForGate('reuse-b')));

    harness.releaseGate('reuse-a');
    harness.releaseGate('reuse-b');
    await Future.wait([reuseA, reuseB]);
    expect(native.statsForTesting.idleBlockingWorkers, 2);
  });

  test('并发隔离：阻塞池满载挂起及真实同步阻塞时，控制面命令仍瞬时响应', () async {
    final harness = _WorkerTestHarness();
    final native = VpnNative.forTesting(
      libraryOpener: _createTestOpener(harness.sendPort),
      libraryNameOverride: 'libnuist_vpn_iso.so',
      maxBlockingWorkers: 2,
      maxIdleBlockingWorkers: 2,
    );
    addTearDown(() async {
      await native.disposeForTesting();
      await harness.close();
    });

    // 场景 A：阻塞池 2 个槽位全部挂起 + 1 个排队
    final blockedStart = native.call({
      'method': 'start',
      'gateKey': 'iso-start',
    });
    final blockedOpen = native.call({'method': 'open', 'gateKey': 'iso-open'});
    final queuedProbe = native.call({'method': 'probe'});

    await Future.wait([
      harness.waitForGate('iso-start'),
      harness.waitForGate('iso-open'),
    ]);
    expect(native.statsForTesting.activeBlockingWorkers, 2);
    expect(native.statsForTesting.queuedBlockingRequests, 1);

    final watch = Stopwatch()..start();
    final cancelStart = await native.call({
      'method': 'cancelStart',
      'startId': 1,
    });
    final cancelOpen = await native.call({
      'method': 'cancelOpen',
      'id': 1,
      'openId': 2,
    });
    final stop = await native.call({'method': 'stop', 'id': 1});
    final status = await native.call({'method': 'status', 'id': 1});
    watch.stop();

    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(native.statsForTesting.controlSpawnCount, 1);
    expect(cancelStart['workerTag'], status['workerTag']);
    expect(cancelOpen['workerTag'], status['workerTag']);
    expect(stop['workerTag'], status['workerTag']);
    expect(status['workerTag'], isNot(harness.workerTagForGate('iso-start')));
    expect(status['workerTag'], isNot(harness.workerTagForGate('iso-open')));

    harness.releaseGate('iso-start');
    harness.releaseGate('iso-open');
    await Future.wait([blockedStart, blockedOpen, queuedProbe]);

    // 场景 B：两个阻塞 worker 线程被 sleep 真正同步卡死 260ms，控制面仍低延迟返回
    final sleepA = native.call({'method': 'start', 'syncSleepMs': 260});
    final sleepB = native.call({'method': 'open', 'syncSleepMs': 260});
    await harness.waitUntil(
      () => native.statsForTesting.activeBlockingWorkers == 2,
    );
    final syncWatch = Stopwatch()..start();
    await native.call({'method': 'status', 'id': 9});
    await native.call({'method': 'cancelStart', 'startId': 9});
    await native.call({'method': 'stop', 'id': 9});
    syncWatch.stop();

    expect(syncWatch.elapsedMilliseconds, lessThan(180));
    await Future.wait([sleepA, sleepB]);
  });

  test('阻塞调用超时后立即退役旧 worker、新请求启用新 worker、迟到返回触发 stop 清理并退出', () async {
    final harness = _WorkerTestHarness();
    final native = VpnNative.forTesting(
      libraryOpener: _createTestOpener(harness.sendPort),
      libraryNameOverride: 'libnuist_vpn_timeout.so',
      maxBlockingWorkers: 1,
      maxIdleBlockingWorkers: 1,
      timeoutForMethod: (method) => method == 'start'
          ? const Duration(milliseconds: 80)
          : const Duration(seconds: 2),
    );
    addTearDown(() async {
      await native.disposeForTesting();
      await harness.close();
    });

    final timedOutStart = native.call({
      'method': 'start',
      'gateKey': 'hung-start',
      'returnData': {'id': 42, 'virtualIp': '10.0.0.2'},
    });
    await harness.waitForGate('hung-start');
    final hungWorkerTag = harness.workerTagForGate('hung-start')!;

    await expectLater(
      timedOutStart,
      throwsA(
        isA<VpnNativeException>()
            .having((e) => e.code, 'code', 'native_call_timeout')
            .having((e) => e.stage, 'stage', 'native.start')
            .having(
              (e) => e.diagnosticContext['error_kind'],
              'error_kind',
              'timeout',
            ),
      ),
    );

    // 旧 worker 已退役剥离，不占活跃槽位也不回到空闲池
    expect(native.statsForTesting.retiredWorkers, 1);
    expect(native.statsForTesting.activeBlockingWorkers, 0);
    expect(native.statsForTesting.idleBlockingWorkers, 0);

    // 即使旧 worker 仍在挂起，新阻塞请求立刻启用新 worker 完成
    final freshOpen = await native.call({'method': 'open'});
    expect(freshOpen['workerTag'], isNot(hungWorkerTag));
    expect(native.statsForTesting.blockingSpawnCount, 2);
    expect(native.statsForTesting.idleBlockingWorkers, 1);

    // 放行旧 worker 的迟到结果：应触发 stop(id=42) 孤立清理，随后旧 worker 退出
    harness.releaseGate('hung-start');
    final stopEvent = await harness.waitForEvent(
      (e) => e['type'] == 'call' && e['method'] == 'stop' && e['id'] == 42,
    );
    expect(stopEvent['workerTag'], isNot(hungWorkerTag));

    await harness.waitUntil(() => native.statsForTesting.retiredWorkers == 0);
    expect(native.statsForTesting.idleBlockingWorkers, 1);
  });

  test('超时后的迟到异常仅记录 native.late_failure 并回收过期 worker，不影响后续调用', () async {
    final harness = _WorkerTestHarness();
    final native = VpnNative.forTesting(
      libraryOpener: _createTestOpener(harness.sendPort),
      libraryNameOverride: 'libnuist_vpn_late_err.so',
      maxBlockingWorkers: 1,
      timeoutForMethod: (method) => method == 'open'
          ? const Duration(milliseconds: 60)
          : const Duration(seconds: 2),
    );
    addTearDown(() async {
      await native.disposeForTesting();
      await harness.close();
    });

    final hungOpen = native.call({'method': 'open', 'gateKey': 'late-err'});
    await harness.waitForGate('late-err');

    await expectLater(
      hungOpen,
      throwsA(
        isA<VpnNativeException>().having(
          (e) => e.code,
          'code',
          'native_call_timeout',
        ),
      ),
    );
    expect(native.statsForTesting.retiredWorkers, 1);

    harness.releaseGate('late-err', <String, dynamic>{
      'response': <String, dynamic>{
        'ok': false,
        'error': '迟到建连失败',
        'diagnostic': {'code': 'native_open_failed', 'stage': 'TCP'},
      },
    });

    await harness.waitUntil(
      () => logRecords.any((r) => r['event'] == 'native.late_failure'),
    );
    await harness.waitUntil(() => native.statsForTesting.retiredWorkers == 0);

    final healthy = await native.call({'method': 'probe'});
    expect(healthy['method'], 'probe');
  });

  test('控制面 prepareStart/prepareOpen 超时退役旧控制 worker，新 worker 执行迟到取消清理', () async {
    final harness = _WorkerTestHarness();
    final native = VpnNative.forTesting(
      libraryOpener: _createTestOpener(harness.sendPort),
      libraryNameOverride: 'libnuist_vpn_ctrl_timeout.so',
      timeoutForMethod: (method) =>
          (method == 'prepareStart' || method == 'prepareOpen')
          ? const Duration(milliseconds: 70)
          : const Duration(seconds: 2),
    );
    addTearDown(() async {
      await native.disposeForTesting();
      await harness.close();
    });

    // 1. prepareStart 超时 -> 退役控制 worker #1 -> 后续控制调用立刻使用 #2 -> 迟到返回触发 cancelStart
    final hungPrepareStart = native.call({
      'method': 'prepareStart',
      'gateKey': 'hung-prepare-start',
      'returnData': {'startId': 101},
    });
    await harness.waitForGate('hung-prepare-start');
    final worker1 = harness.workerTagForGate('hung-prepare-start')!;

    await expectLater(
      hungPrepareStart,
      throwsA(
        isA<VpnNativeException>().having(
          (e) => e.code,
          'code',
          'native_call_timeout',
        ),
      ),
    );
    expect(native.statsForTesting.retiredWorkers, 1);

    final statusAfterStartTimeout = await native.call({'method': 'status'});
    final worker2 = statusAfterStartTimeout['workerTag'] as String;
    expect(worker2, isNot(worker1));
    expect(native.statsForTesting.controlSpawnCount, 2);

    harness.releaseGate('hung-prepare-start');
    final cancelStartEvent = await harness.waitForEvent(
      (e) =>
          e['type'] == 'call' &&
          e['method'] == 'cancelStart' &&
          e['startId'] == 101,
    );
    expect(cancelStartEvent['workerTag'], worker2);
    await harness.waitUntil(() => native.statsForTesting.retiredWorkers == 0);

    // 2. prepareOpen 超时 -> 退役控制 worker #2 -> 迟到返回在新控制 worker #3 上执行 cancelOpen
    final hungPrepareOpen = native.call({
      'method': 'prepareOpen',
      'id': 7,
      'gateKey': 'hung-prepare-open',
      'returnData': {'openId': 202},
    });
    await harness.waitForGate('hung-prepare-open');
    expect(harness.workerTagForGate('hung-prepare-open'), worker2);

    await expectLater(
      hungPrepareOpen,
      throwsA(
        isA<VpnNativeException>().having(
          (e) => e.code,
          'code',
          'native_call_timeout',
        ),
      ),
    );
    expect(native.statsForTesting.retiredWorkers, 1);

    harness.releaseGate('hung-prepare-open');
    final cancelOpenEvent = await harness.waitForEvent(
      (e) =>
          e['type'] == 'call' &&
          e['method'] == 'cancelOpen' &&
          e['id'] == 7 &&
          e['openId'] == 202,
    );
    expect(cancelOpenEvent['workerTag'], isNot(worker2));
    expect(native.statsForTesting.controlSpawnCount, 3);
    await harness.waitUntil(() => native.statsForTesting.retiredWorkers == 0);
  });

  test('排队中的阻塞请求超时仅退出队列，不污染正在执行的健康 worker', () async {
    final harness = _WorkerTestHarness();
    final native = VpnNative.forTesting(
      libraryOpener: _createTestOpener(harness.sendPort),
      libraryNameOverride: 'libnuist_vpn_queue_timeout.so',
      maxBlockingWorkers: 1,
      timeoutForMethod: (method) => method == 'open'
          ? const Duration(milliseconds: 60)
          : const Duration(seconds: 2),
    );
    addTearDown(() async {
      await native.disposeForTesting();
      await harness.close();
    });

    final occupy = native.call({'method': 'start', 'gateKey': 'occupy-slot'});
    await harness.waitForGate('occupy-slot');
    final workerTag = harness.workerTagForGate('occupy-slot')!;

    final queuedOpen = native.call({'method': 'open', 'tag': 'never-run'});
    expect(native.statsForTesting.queuedBlockingRequests, 1);

    await expectLater(
      queuedOpen,
      throwsA(
        isA<VpnNativeException>().having(
          (e) => e.code,
          'code',
          'native_call_timeout',
        ),
      ),
    );
    expect(native.statsForTesting.queuedBlockingRequests, 0);
    expect(native.statsForTesting.retiredWorkers, 0);
    expect(native.statsForTesting.activeBlockingWorkers, 1);

    harness.releaseGate('occupy-slot');
    final startResult = await occupy;
    expect(startResult['workerTag'], workerTag);

    // 后续调用仍复用同一个未受污染的 worker，且已超时的排队请求从未被派发执行
    final next = await native.call({'method': 'probe'});
    expect(next['workerTag'], workerTag);
    expect(native.statsForTesting.blockingSpawnCount, 1);
    expect(harness.allEvents.where((e) => e['tag'] == 'never-run'), isEmpty);
  });

  test('原生业务错误与底层异常保留完整诊断字段且不中毒 worker', () async {
    final harness = _WorkerTestHarness();
    final native = VpnNative.forTesting(
      libraryOpener: _createTestOpener(harness.sendPort),
      libraryNameOverride: 'libnuist_vpn_error.so',
    );
    addTearDown(() async {
      await native.disposeForTesting();
      await harness.close();
    });

    final baseline = await native.call({'method': 'start'});
    final workerTag = baseline['workerTag'] as String;

    await expectLater(
      native.call({
        'method': 'start',
        'errorResponse': {
          'ok': false,
          'error': '合成 TLS 握手失败',
          'diagnostic': {
            'code': 'native_start_failed',
            'stage': 'TLS',
            'native_kind': 'InvalidData',
            'os_code': 104,
            'causes': ['顶层原因', '底层原因'],
          },
        },
      }),
      throwsA(
        isA<VpnNativeException>()
            .having((e) => e.message, 'message', '合成 TLS 握手失败')
            .having((e) => e.code, 'code', 'native_start_failed')
            .having((e) => e.stage, 'stage', 'TLS')
            .having((e) => e.osError?.errorCode, 'osError', 104)
            .having(
              (e) => e.diagnosticContext['native_stage'],
              'native_stage',
              'tls',
            )
            .having(
              (e) => e.diagnosticContext['error_kind'],
              'error_kind',
              'tls_handshake',
            )
            .having((e) => e.cause.toString(), 'cause', '顶层原因'),
      ),
    );

    await expectLater(
      native.call({'method': 'open', 'throwSocket': '合成 Socket 失败'}),
      throwsA(
        isA<SocketException>().having(
          (e) => e.message,
          'message',
          '合成 Socket 失败',
        ),
      ),
    );

    final recovered = await native.call({'method': 'probe'});
    expect(recovered['workerTag'], workerTag);
    expect(native.statsForTesting.blockingSpawnCount, 1);
  });

  test('控制与阻塞 worker 意外退出后自动重建健康 worker 并推进队列', () async {
    final harness = _WorkerTestHarness();
    final native = VpnNative.forTesting(
      libraryOpener: _createTestOpener(harness.sendPort),
      libraryNameOverride: 'libnuist_vpn_crash.so',
      maxBlockingWorkers: 1,
    );
    addTearDown(() async {
      await native.disposeForTesting();
      await harness.close();
    });

    // 1. 控制 worker 崩溃后自动重建
    final ctrlBefore = await native.call({'method': 'version'});
    await expectLater(
      native.call({'method': 'status', 'crash': true}),
      throwsA(
        isA<VpnNativeException>().having(
          (e) => e.code,
          'code',
          'native_worker_exited',
        ),
      ),
    );
    final ctrlAfter = await native.call({'method': 'version'});
    expect(ctrlAfter['workerTag'], isNot(ctrlBefore['workerTag']));
    expect(native.statsForTesting.controlSpawnCount, 2);

    // 2. 阻塞 worker 崩溃后，排队中的下一个阻塞请求自动在新 worker 上完成
    final blockingBefore = await native.call({'method': 'open'});
    final crashing = native.call({'method': 'open', 'crash': true});
    final queued = native.call({'method': 'probe'});

    await expectLater(
      crashing,
      throwsA(
        isA<VpnNativeException>().having(
          (e) => e.code,
          'code',
          'native_worker_exited',
        ),
      ),
    );
    final queuedResult = await queued;
    expect(queuedResult['workerTag'], isNot(blockingBefore['workerTag']));
    expect(native.statsForTesting.blockingSpawnCount, 2);
  });

  test('真实同步阻塞超时后退役旧 worker，新请求不等待阻塞结束，迟到返回触发 stop 清理并退出', () async {
    final harness = _WorkerTestHarness();
    final native = VpnNative.forTesting(
      libraryOpener: _createTestOpener(harness.sendPort),
      libraryNameOverride: 'libnuist_vpn_sync_timeout.so',
      maxBlockingWorkers: 1,
      timeoutForMethod: (method) => method == 'start'
          ? const Duration(milliseconds: 60)
          : const Duration(seconds: 2),
    );
    addTearDown(() async {
      await native.disposeForTesting();
      await harness.close();
    });

    final watch = Stopwatch()..start();
    await expectLater(
      native.call({
        'method': 'start',
        'syncSleepMs': 240,
        'returnData': {'id': 77},
      }),
      throwsA(
        isA<VpnNativeException>().having(
          (e) => e.code,
          'code',
          'native_call_timeout',
        ),
      ),
    );
    expect(native.statsForTesting.retiredWorkers, 1);

    // 旧 worker 仍在 OS sleep 中，新阻塞请求应立即在新 worker 上完成
    final fresh = await native.call({'method': 'open'});
    expect(fresh['method'], 'open');
    expect(watch.elapsedMilliseconds, lessThan(220));
    expect(native.statsForTesting.blockingSpawnCount, 2);

    // 待旧 worker sleep 返回后，自动触发 stop(id=77) 并关闭过期 worker
    await harness.waitForEvent(
      (e) => e['type'] == 'call' && e['method'] == 'stop' && e['id'] == 77,
    );
    await harness.waitUntil(() => native.statsForTesting.retiredWorkers == 0);
  });

  test('控制面在途命令超时退役后，已排队的后续控制命令立即迁移至新控制 worker 执行', () async {
    final harness = _WorkerTestHarness();
    final native = VpnNative.forTesting(
      libraryOpener: _createTestOpener(harness.sendPort),
      libraryNameOverride: 'libnuist_vpn_ctrl_queue_migrate.so',
      timeoutForMethod: (method) => method == 'prepareStart'
          ? const Duration(milliseconds: 70)
          : const Duration(seconds: 2),
    );
    addTearDown(() async {
      await native.disposeForTesting();
      await harness.close();
    });

    final first = native.call({
      'method': 'prepareStart',
      'gateKey': 'ctrl-stuck-first',
      'returnData': {'startId': 303},
    });
    await harness.waitForGate('ctrl-stuck-first');
    final firstWorker = harness.workerTagForGate('ctrl-stuck-first')!;

    // 在首个控制命令超时前就将第二个控制命令排入队列
    final queuedStatus = native.call({'method': 'status'});
    expect(native.statsForTesting.queuedControlRequests, 1);

    await expectLater(
      first,
      throwsA(
        isA<VpnNativeException>().having(
          (e) => e.code,
          'code',
          'native_call_timeout',
        ),
      ),
    );

    // 排队中的 status 不等待卡死的 first，立即被派发到新建控制 worker 完成
    final statusResult = await queuedStatus;
    expect(statusResult['workerTag'], isNot(firstWorker));
    expect(native.statsForTesting.controlSpawnCount, 2);

    harness.releaseGate('ctrl-stuck-first');
    await harness.waitForEvent(
      (e) =>
          e['type'] == 'call' &&
          e['method'] == 'cancelStart' &&
          e['startId'] == 303,
    );
    await harness.waitUntil(() => native.statsForTesting.retiredWorkers == 0);
  });

  test('默认无参 const VpnNative 构造保持完全兼容', () async {
    const a = VpnNative();
    const b = VpnNative();
    expect(identical(a, b), isTrue);
    expect(a.statsForTesting.controlSpawnCount, 0);
    expect(a.statsForTesting.blockingSpawnCount, 0);
    await VpnNative.resetForTesting();
  });
}
