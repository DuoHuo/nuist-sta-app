import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/app_directories.dart';
import 'package:nuist_sta_app/core/logging/app_log.dart';
import 'package:nuist_sta_app/mini_apps/sunshine_run/sunshine_run_models.dart';
import 'package:nuist_sta_app/mini_apps/sunshine_run/sunshine_run_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory directory;

  final state = SunshineRunState(
    grade: 1,
    exemption: SunshineRunExemption.half,
    baseTotal: 10,
    baseMorning: 3,
    activities: {'regular': 4, 'morning': 5, 'fluorescent': 2, 'monday': 1},
    customActivities: [
      SunshineRunCustomActivity(
        id: 'custom-test',
        label: '测试活动',
        total: 3,
        morning: 1,
        count: 2,
      ),
    ],
  );

  File stateFile() => File('${directory.path}/state.json');

  setUp(() async {
    AppDirectories.resetForTesting();
    await AppLog.resetForTesting();
    directory = await Directory.systemTemp.createTemp('sunshine_run_store_');
    SunshineRunStore.debugDirectory = directory;
  });

  tearDown(() async {
    SunshineRunStore.debugDirectory = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    AppDirectories.resetForTesting();
    await AppLog.resetForTesting();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('首次使用没有状态和警告', () async {
    final result = await SunshineRunStore.read();

    expect(result.state, isNull);
    expect(result.warning, isNull);
    expect(result.corrupt, isFalse);
    expect(result.available, isTrue);
    expect(await directory.list().toList(), isEmpty);
  });

  test('年级、减免、已有次数和全部活动完整恢复', () async {
    expect(await SunshineRunStore.save(state), isTrue);

    final result = await SunshineRunStore.read();
    expect(result.state, state);
    expect(result.state!.calculate().total, 31);
    expect(result.state!.calculate().morning, 16);
    expect(result.warning, isNull);
    expect(result.corrupt, isFalse);
    expect(result.available, isTrue);
    expect(jsonDecode(await stateFile().readAsString()), state.toJson());
    expect(await File('${stateFile().path}.tmp').exists(), isFalse);
  });

  test('缺少自定义活动字段的旧记录可正常恢复', () async {
    final legacy = state.toJson()..remove('customActivities');
    await stateFile().writeAsString(jsonEncode(legacy));

    final result = await SunshineRunStore.read();
    expect(result.state, state.copyWith(customActivities: []));
    expect(result.warning, isNull);
    expect(await stateFile().readAsString(), jsonEncode(legacy));
  });

  test('普通保存有效记录时保持原行为，不额外创建备份', () async {
    expect(await SunshineRunStore.save(SunshineRunState.initial()), isTrue);
    expect(await SunshineRunStore.save(state), isTrue);

    expect((await SunshineRunStore.read()).state, state);
    expect(await directory.list().toList(), hasLength(1));
    expect(await File('${stateFile().path}.backup').exists(), isFalse);
  });

  test('显式重试替换有效旧记录前先完整备份原始字节', () async {
    final previous = state.withActivity('regular', 1);
    final original =
        '${const JsonEncoder.withIndent('  ').convert(previous.toJson())}\n';
    await stateFile().writeAsString(original);

    expect(await SunshineRunStore.save(state, replaceCorrupt: true), isTrue);

    expect((await SunshineRunStore.read()).state, state);
    expect(
      await File('${stateFile().path}.backup').readAsBytes(),
      utf8.encode(original),
    );
    expect(await File('${stateFile().path}.corrupt').exists(), isFalse);
    expect(await File('${stateFile().path}.tmp').exists(), isFalse);
  });

  test('有效记录的显式重试不会覆盖此前已有备份', () async {
    final firstBackup = File('${stateFile().path}.backup');
    await firstBackup.writeAsString('earlier-backup');
    final previous = state.withActivity('regular', 1);
    final original = jsonEncode(previous.toJson());
    await stateFile().writeAsString(original);

    expect(await SunshineRunStore.save(state, replaceCorrupt: true), isTrue);
    final secondOriginal = await stateFile().readAsString();
    final latest = state.withActivity('regular', 6);
    expect(await SunshineRunStore.save(latest, replaceCorrupt: true), isTrue);

    final addedBackups = await directory
        .list()
        .where(
          (file) => file.uri.pathSegments.last.startsWith('state.json.backup.'),
        )
        .cast<File>()
        .toList();
    expect(await firstBackup.readAsString(), 'earlier-backup');
    expect(addedBackups, hasLength(2));
    expect(
      await Future.wait(addedBackups.map((file) => file.readAsString())),
      unorderedEquals([original, secondOriginal]),
    );
    expect((await SunshineRunStore.read()).state, latest);
  });

  test('显式重试没有旧文件时直接保存，不生成空备份', () async {
    expect(await SunshineRunStore.save(state, replaceCorrupt: true), isTrue);

    expect((await SunshineRunStore.read()).state, state);
    expect(await directory.list().toList(), hasLength(1));
    expect(await File('${stateFile().path}.backup').exists(), isFalse);
    expect(await File('${stateFile().path}.corrupt').exists(), isFalse);
  });

  final corruptRecords = <String, List<int>>{
    '坏 JSON': utf8.encode('{broken'),
    '非对象根节点': utf8.encode('[]'),
    '损坏字段': utf8.encode('{"version":1}'),
    '无效 UTF-8': [0xc3, 0x28],
  };
  for (final entry in corruptRecords.entries) {
    test('${entry.key}读取时保留原文件并明确警告', () async {
      await stateFile().writeAsBytes(entry.value);
      final result = await SunshineRunStore.read();

      expect(result.state, isNull);
      expect(result.warning, isNotEmpty);
      expect(result.corrupt, isTrue);
      expect(result.available, isTrue);
      expect(await stateFile().readAsBytes(), entry.value);
      expect(await directory.list().toList(), hasLength(1));
    });
  }

  test('损坏日志保留异常原因与原始调用堆栈', () async {
    final records = <Map<String, Object?>>[];
    AppLog.recordListenerForTesting = records.add;
    await stateFile().writeAsString('{broken');

    await SunshineRunStore.read();

    final failure = records.singleWhere(
      (record) => record['event'] == 'state.corrupt',
    );
    final attrs = failure['attrs'] as Map;
    expect(attrs['error_type'], 'FormatException');
    expect(attrs['error_chain'], isNotEmpty);
    expect(
      attrs['stack_trace'],
      allOf(
        contains('_ChunkedJsonParser'),
        contains('SunshineRunStore._readFile'),
      ),
    );
  });

  test('普通保存拒绝覆盖已有损坏记录', () async {
    const original = '{broken';
    await stateFile().writeAsString(original);

    expect(await SunshineRunStore.save(state), isFalse);
    expect(await stateFile().readAsString(), original);
    expect(await directory.list().toList(), hasLength(1));
  });

  test('明确重试先备份原始字节再保存当前记录', () async {
    final original = [0xc3, 0x28, 0xff];
    await stateFile().writeAsBytes(original);

    expect(await SunshineRunStore.save(state, replaceCorrupt: true), isTrue);
    expect((await SunshineRunStore.read()).state, state);
    expect(await File('${stateFile().path}.corrupt').readAsBytes(), original);
    expect(await File('${stateFile().path}.tmp').exists(), isFalse);
  });

  test('多次重试保留已有备份，并为每次损坏记录创建新备份', () async {
    final firstBackup = File('${stateFile().path}.corrupt');
    await firstBackup.writeAsString('previous-backup');
    await stateFile().writeAsString('{first-broken');
    expect(await SunshineRunStore.save(state, replaceCorrupt: true), isTrue);

    await stateFile().writeAsString('{second-broken');
    expect(
      await SunshineRunStore.save(
        state.withActivity('regular', 6),
        replaceCorrupt: true,
      ),
      isTrue,
    );

    final addedBackups = await directory
        .list()
        .where(
          (file) =>
              file.uri.pathSegments.last.startsWith('state.json.corrupt.'),
        )
        .cast<File>()
        .toList();
    expect(await firstBackup.readAsString(), 'previous-backup');
    expect(addedBackups, hasLength(2));
    expect(
      await Future.wait(addedBackups.map((file) => file.readAsString())),
      unorderedEquals(['{first-broken', '{second-broken']),
    );
    expect((await SunshineRunStore.read()).state!.activities['regular'], 6);
  });

  test('备份名称已被目录占用时保留目录并使用新名称', () async {
    final occupied = Directory('${stateFile().path}.corrupt');
    await occupied.create();
    await stateFile().writeAsString('{broken');

    expect(await SunshineRunStore.save(state, replaceCorrupt: true), isTrue);
    expect(await occupied.exists(), isTrue);
    final addedBackups = await directory
        .list()
        .where(
          (file) =>
              file.uri.pathSegments.last.startsWith('state.json.corrupt.'),
        )
        .cast<File>()
        .toList();
    expect(addedBackups, hasLength(1));
    expect(await addedBackups.single.readAsString(), '{broken');
  });

  test('无平台存储时返回警告且不能虚称保存成功', () async {
    SunshineRunStore.debugDirectory = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProviderChannel,
          (_) async => throw PlatformException(code: 'storage_unavailable'),
        );

    final result = await SunshineRunStore.read();
    expect(result.state, isNull);
    expect(result.warning, isNotEmpty);
    expect(result.corrupt, isFalse);
    expect(result.available, isFalse);
    expect(await SunshineRunStore.save(state), isFalse);
    expect(await directory.list().toList(), isEmpty);
  });

  test('存储目录被文件占用时降级为内存计算', () async {
    final obstruction = File('${directory.path}/blocked');
    await obstruction.writeAsString('keep');
    SunshineRunStore.debugDirectory = Directory(obstruction.path);

    final result = await SunshineRunStore.read();
    expect(result.state, isNull);
    expect(result.warning, isNotEmpty);
    expect(result.corrupt, isFalse);
    expect(result.available, isFalse);
    expect(await SunshineRunStore.save(state), isFalse);
    expect(await obstruction.readAsString(), 'keep');
  });

  test('记录位置被目录占用时不将它当作缺失或损坏文件', () async {
    await Directory(stateFile().path).create();

    final result = await SunshineRunStore.read();
    expect(result.state, isNull);
    expect(result.warning, isNotEmpty);
    expect(result.corrupt, isFalse);
    expect(result.available, isFalse);
    expect(await SunshineRunStore.save(state), isFalse);
    expect(await Directory(stateFile().path).exists(), isTrue);
  });

  test('写入临时文件失败时旧的有效记录保持原样', () async {
    final previous = state.withActivity('regular', 1);
    expect(await SunshineRunStore.save(previous), isTrue);
    final originalBytes = await stateFile().readAsBytes();
    final obstruction = Directory('${stateFile().path}.tmp');
    await obstruction.create();

    expect(await SunshineRunStore.save(state), isFalse);
    expect(await stateFile().readAsBytes(), originalBytes);
    expect((await SunshineRunStore.read()).state, previous);
    expect(await obstruction.exists(), isTrue);

    await obstruction.delete();
    expect(await SunshineRunStore.save(state), isTrue);
    expect((await SunshineRunStore.read()).state, state);
  });

  test('损坏记录的重试写入失败时仍保留原文件', () async {
    const original = '{broken';
    await stateFile().writeAsString(original);
    await Directory('${stateFile().path}.tmp').create();

    expect(await SunshineRunStore.save(state, replaceCorrupt: true), isFalse);
    expect(await stateFile().readAsString(), original);
    expect(await File('${stateFile().path}.corrupt').exists(), isFalse);
  });

  for (final failCreate in [true, false]) {
    test('有效旧记录备份${failCreate ? '创建' : '写入'}失败时拒绝替换并保留原件', () async {
      final previous = state.withActivity('regular', 1);
      expect(await SunshineRunStore.save(previous), isTrue);
      final original = await stateFile().readAsBytes();
      final backup = File('${stateFile().path}.backup');
      final failingBackup = _FailingBackupFile(backup, failCreate: failCreate);
      final records = <Map<String, Object?>>[];
      AppLog.recordListenerForTesting = records.add;

      final saved = await IOOverrides.runWithIOOverrides(
        () => SunshineRunStore.save(state, replaceCorrupt: true),
        _BackupFailureOverrides(failingBackup),
      );

      expect(saved, isFalse);
      expect(failingBackup.createAttempted, isTrue);
      expect(failingBackup.writeAttempted, !failCreate);
      expect(await stateFile().readAsBytes(), original);
      expect((await SunshineRunStore.read()).state, previous);
      expect(await backup.exists(), isFalse);
      expect(await File('${stateFile().path}.tmp').exists(), isFalse);
      final failure = records.singleWhere(
        (record) => record['event'] == 'state.save_failed',
      );
      final attrs = failure['attrs'] as Map;
      expect(attrs['stage'], 'valid_backup');
      expect(attrs['error_chain'], isNotEmpty);
      expect(attrs['stack_trace'], isNotEmpty);
    });
  }

  test('连续并发保存按调用顺序完成，最终恢复最后一次状态', () async {
    final completed = <int>[];
    final operations = [
      for (var count = 1; count <= 12; count++)
        SunshineRunStore.save(state.withActivity('morning', count))
            .then((saved) {
              completed.add(count);
              return saved;
            }),
    ];

    expect(await Future.wait(operations), everyElement(isTrue));
    expect(completed, [for (var count = 1; count <= 12; count++) count]);
    expect((await SunshineRunStore.read()).state!.activities['morning'], 12);
    expect(await File('${stateFile().path}.tmp').exists(), isFalse);
  });

  test('队列前一次失败不会阻断后续保存，目录按调用时确定', () async {
    final obstruction = File('${directory.path}/blocked');
    await obstruction.writeAsString('keep');
    SunshineRunStore.debugDirectory = Directory(obstruction.path);
    final failed = SunshineRunStore.save(SunshineRunState.initial());

    SunshineRunStore.debugDirectory = directory;
    final succeeded = SunshineRunStore.save(state);

    expect(await Future.wait([failed, succeeded]), [false, true]);
    expect((await SunshineRunStore.read()).state, state);
    expect(await obstruction.readAsString(), 'keep');
  });
}

/// 只替换备份文件的 I/O，原记录和临时写入仍使用真实临时目录。
final class _BackupFailureOverrides extends IOOverrides {
  _BackupFailureOverrides(this.backup);

  final File backup;

  @override
  File createFile(String path) =>
      path.endsWith('state.json.backup') ? backup : super.createFile(path);
}

/// 分别模拟备份创建失败和部分写入后失败，验证原件与失败残片保护。
class _FailingBackupFile implements File {
  _FailingBackupFile(this.file, {required this.failCreate});

  final File file;
  final bool failCreate;
  bool createAttempted = false;
  bool writeAttempted = false;

  @override
  String get path => file.path;

  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) async {
    createAttempted = true;
    if (failCreate) {
      throw FileSystemException('synthetic backup create failure', path);
    }
    await file.create(recursive: recursive, exclusive: exclusive);
    return this;
  }

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    writeAttempted = true;
    await file.writeAsBytes(bytes.take(3).toList(), mode: mode, flush: flush);
    throw FileSystemException('synthetic backup write failure', path);
  }

  @override
  Future<bool> exists() => file.exists();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      file.delete(recursive: recursive);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
