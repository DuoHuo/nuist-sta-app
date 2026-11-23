import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/app_directories.dart';
import 'package:nuist_sta_app/core/auth/enrollment_year.dart' as core_year;
import 'package:nuist_sta_app/core/auth/student_academic_info.dart';
import 'package:nuist_sta_app/core/logging/app_log.dart';
import 'package:nuist_sta_app/mini_apps/student_info/student_info_academic_source.dart';
import 'package:nuist_sta_app/mini_apps/student_info/student_info_models.dart';
import 'package:nuist_sta_app/mini_apps/student_info/student_info_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_multi_models.dart'
    as timetable;

const _studentId = '202512340001';

StudentInfo _info({
  int academicYear = 2026,
  String studentId = _studentId,
  String category = '学生/本科生',
  bool hasSemester = true,
  DateTime? fetchedAt,
}) => StudentInfo(
  user: PortalUser(
    name: '测试学生',
    studentId: studentId,
    categoryName: category,
    deptName: '测试学院',
  ),
  semester: hasSemester
      ? SemesterInfo(
          year: academicYear,
          term: '1',
          start: DateTime(academicYear, 9, 1),
          end: DateTime(academicYear + 1, 1, 31),
          maxWeeks: 20,
        )
      : null,
  fetchedAt: fetchedAt ?? DateTime.now(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  late StudentInfoAcademicSource source;
  late StudentInfo? cached;
  late String? account;
  late int cacheReads;
  late int accountReads;
  late List<Directory> directories;
  late List<String> platformCalls;
  Future<StudentInfo?> Function()? readCache;
  Future<String?> Function()? readAccount;

  setUp(() async {
    AppDirectories.resetForTesting();
    await AppLog.resetForTesting();
    cached = _info();
    account = _studentId;
    cacheReads = 0;
    accountReads = 0;
    directories = [];
    platformCalls = [];
    readCache = null;
    readAccount = null;
    source = StudentInfoAcademicSource.forTesting(
      readCache: () async {
        cacheReads++;
        final callback = readCache;
        return callback == null ? cached : await callback();
      },
      readBoundAccount: () async {
        accountReads++;
        final callback = readAccount;
        return callback == null ? account : await callback();
      },
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    AppDirectories.resetForTesting();
    await AppLog.resetForTesting();
    for (final directory in directories) {
      expect(
        directory.absolute.path.toLowerCase(),
        startsWith(Directory.systemTemp.absolute.path.toLowerCase()),
      );
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  });

  Future<Directory> localDirectory() async {
    AppDirectories.resetForTesting();
    final directory = await Directory.systemTemp.createTemp(
      'student_academic_local_',
    );
    directories.add(directory);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          platformCalls.add(call.method);
          return call.method == 'getApplicationDocumentsDirectory'
              ? directory.path
              : null;
        });
    return directory;
  }

  File profileFile(Directory directory) =>
      File.fromUri(directory.uri.resolve('student_info/profile.json'));

  test('core 入学年 helper 保留课表原有导出与年份解析行为', () {
    final cases = <String?, int?>{
      _studentId: 2025,
      ' $_studentId ': 2025,
      '2025-prefix-only': 2025,
      '1990': 1990,
      '2100': 2100,
      '1989': null,
      '2101': null,
      'invalid': null,
      '': null,
      null: null,
    };
    for (final entry in cases.entries) {
      expect(core_year.enrollmentYearFromStudentId(entry.key), entry.value);
      expect(timetable.enrollmentYearFromStudentId(entry.key), entry.value);
    }
  });

  for (final entry in <int, int?>{
    2025: 1,
    2026: 2,
    2027: 3,
    2024: null,
    2101: null,
  }.entries) {
    final year = entry.key;
    final grade = entry.value;
    test('只读本地学年 $year，得到年级 $grade', () async {
      cached = _info(academicYear: year);
      final StudentAcademicSource localSource = source;

      final result = await localSource.readLocal();

      expect(result.portalBound, isTrue);
      expect(result.identityMatches, isTrue);
      expect(result.undergraduate, isTrue);
      expect(result.academicYear, year);
      expect(result.enrollmentYear, 2025);
      expect(result.grade, grade);
      expect(result.fromCache, isTrue);
      expect(result.loading, isFalse);
      expect(result.error, isNull);
      expect(cacheReads, 1);
      expect(accountReads, 2);
    });
  }

  test('没有本地缓存时返回未知年级，不补拉学生信息', () async {
    cached = null;

    final result = await source.readLocal();

    expect(result.portalBound, isTrue);
    expect(result.identityMatches, isFalse);
    expect(result.academicYear, isNull);
    expect(result.enrollmentYear, isNull);
    expect(result.grade, isNull);
    expect(result.loading, isFalse);
    expect(cacheReads, 1);
    expect(accountReads, 2);
  });

  test('缺失本地校历学年时不根据本机日期推测', () async {
    cached = _info(hasSemester: false);

    final result = await source.readLocal();

    expect(result.identityMatches, isTrue);
    expect(result.academicYear, isNull);
    expect(result.enrollmentYear, 2025);
    expect(result.grade, isNull);
  });

  test('本地校历年份格式损坏时不识别年级', () async {
    cached = StudentInfo.fromJson({
      'user': _info().user.toJson(),
      'semester': {
        'xn': 'invalid-year',
        'xq': '1',
        'ksrq': '2026-09-01',
        'jsrq': '2027-01-31',
        'maxWeeks': '20',
      },
    }, fetchedAt: DateTime.now());

    final result = await source.readLocal();

    expect(result.identityMatches, isTrue);
    expect(result.academicYear, isNull);
    expect(result.grade, isNull);
  });

  for (final category in ['学生/研究生', '学生/非本科生', '']) {
    test('用户类别「$category」没有本科生层级时返回未知年级', () async {
      cached = _info(category: category);

      final result = await source.readLocal();

      expect(result.identityMatches, isTrue);
      expect(result.undergraduate, isFalse);
      expect(result.grade, isNull);
    });
  }

  for (final studentId in ['2025', '']) {
    test('缓存学号「$studentId」格式不完整时不视为可靠身份', () async {
      cached = _info(studentId: studentId);
      account = studentId.isEmpty ? _studentId : studentId;

      final result = await source.readLocal();

      expect(result.portalBound, isTrue);
      expect(result.identityMatches, isFalse);
      expect(result.academicYear, isNull);
      expect(result.enrollmentYear, isNull);
      expect(result.fetchedAt, isNull);
      expect(result.grade, isNull);
    });
  }

  test('缓存账号与绑定账号不一致时不暴露年份和获取时间', () async {
    account = 'different-account';

    final result = await source.readLocal();

    expect(result.portalBound, isTrue);
    expect(result.identityMatches, isFalse);
    expect(result.academicYear, isNull);
    expect(result.enrollmentYear, isNull);
    expect(result.fetchedAt, isNull);
    expect(result.grade, isNull);
  });

  test('两次账号核验均去除空格，本科生层级也允许两端空格', () async {
    cached = _info(studentId: ' $_studentId ', category: ' 学生 / 本科生 ');
    account = ' $_studentId ';

    final result = await source.readLocal();

    expect(result.identityMatches, isTrue);
    expect(result.undergraduate, isTrue);
    expect(result.grade, 2);
    expect(accountReads, 2);
  });

  for (final emptyAccount in <String?>[null, '', '  ']) {
    test('绑定账号「$emptyAccount」为空时直接返回未知年级，不读缓存', () async {
      account = emptyAccount;

      final result = await source.readLocal();

      expect(result.portalBound, isFalse);
      expect(result.identityMatches, isFalse);
      expect(result.grade, isNull);
      expect(result.loading, isFalse);
      expect(cacheReads, 0);
      expect(accountReads, 1);
    });
  }

  test('过了自然日的本地缓存仍只读一次，不触发过期刷新', () async {
    final oldInfo = _info(
      academicYear: 2025,
      fetchedAt: DateTime.now().subtract(const Duration(days: 8)),
    );
    cached = oldInfo;

    final result = await source.readLocal();

    expect(result.grade, 1);
    expect(result.fetchedAt, oldInfo.fetchedAt);
    expect(result.fromCache, isTrue);
    expect(cacheReads, 1);
    expect(accountReads, 2);
    expect(platformCalls, isEmpty);
  });

  test('再次读取采用最新本地缓存，不沿用来源的旧内存状态', () async {
    cached = _info(academicYear: 2025);
    final previous = await source.readLocal();
    expect(previous.grade, 1);

    cached = null;
    final missing = await source.readLocal();
    expect(missing.grade, isNull);
    cached = _info(academicYear: 2026);
    final latest = await source.readLocal();

    expect(latest.grade, 2);
    expect(latest.fromCache, isTrue);
    expect(previous.grade, 1);
    expect(cacheReads, 3);
  });

  test('解绑后重绑同一账号，可以直接使用仍匹配的本地缓存', () async {
    cached = _info(academicYear: 2025);
    expect((await source.readLocal()).grade, 1);

    account = null;
    expect((await source.readLocal()).grade, isNull);
    account = _studentId;

    expect((await source.readLocal()).grade, 1);
    expect(cacheReads, 2);
    expect(accountReads, 5);
  });

  for (final after in <String?>[null, 'different-account']) {
    test('读缓存期间绑定变为「$after」时拒绝旧记录', () async {
      final delayedCache = Completer<StudentInfo?>();
      final cacheStarted = Completer<void>();
      readCache = () {
        cacheStarted.complete();
        return delayedCache.future;
      };
      final pending = source.readLocal();
      await cacheStarted.future;

      account = after;
      delayedCache.complete(_info(academicYear: 2025));
      final result = await pending;

      expect(result.portalBound, after != null);
      expect(result.identityMatches, isFalse);
      expect(result.academicYear, isNull);
      expect(result.enrollmentYear, isNull);
      expect(result.fetchedAt, isNull);
      expect(result.grade, isNull);
      expect(result.loading, isFalse);
      expect(accountReads, 2);
    });
  }

  test('首次账号读取晚到时，第二次核验仍阻止旧绑定穿透', () async {
    final delayedAccount = Completer<String?>();
    final beforeStarted = Completer<void>();
    var first = true;
    readAccount = () {
      if (first) {
        first = false;
        beforeStarted.complete();
        return delayedAccount.future;
      }
      return Future.value(account);
    };
    final pending = source.readLocal();
    await beforeStarted.future;

    account = 'different-account';
    delayedAccount.complete(_studentId);
    final result = await pending;

    expect(result.identityMatches, isFalse);
    expect(result.grade, isNull);
    expect(accountReads, 2);
  });

  for (final stage in [
    'bound_account_before',
    'cache_read',
    'bound_account_after',
  ]) {
    test('本地读取阶段 $stage 失败时返回未知年级并保留原始诊断', () async {
      final records = <Map<String, Object?>>[];
      AppLog.recordListenerForTesting = records.add;
      if (stage == 'cache_read') {
        readCache = () async => throw const FormatException('synthetic cache');
      } else {
        var reads = 0;
        readAccount = () async {
          reads++;
          if (stage == 'bound_account_before' || reads == 2) {
            throw StateError('synthetic binding failure');
          }
          return _studentId;
        };
      }

      final result = await source.readLocal();

      expect(result.grade, isNull);
      expect(result.error, isNotEmpty);
      expect(result.error, isNot(contains(_studentId)));
      expect(result.loading, isFalse);
      expect(result.fromCache, isTrue);
      final failure = records.singleWhere(
        (record) => record['event'] == 'grade_source.unavailable',
      );
      final attrs = failure['attrs'] as Map;
      expect(attrs['stage'], stage);
      expect(attrs['error_chain'], isNotEmpty);
      expect(attrs['stack_trace'], isNotEmpty);
    });
  }

  test('实际本地缓存不存在时，读取不创建学生信息目录', () async {
    final directory = await localDirectory();
    final profileDirectory = Directory.fromUri(
      directory.uri.resolve('student_info/'),
    );

    final result = await StudentInfoStore.read();

    expect(result, isNull);
    expect(await profileDirectory.exists(), isFalse);
    expect(await directory.list().toList(), isEmpty);
    expect(platformCalls, ['getApplicationDocumentsDirectory']);
  });

  test('实际本地缓存读完保持原始文件，来源仍进行两次绑定核验', () async {
    final directory = await localDirectory();
    final file = profileFile(directory);
    await file.parent.create(recursive: true);
    final originalInfo = _info(academicYear: 2025);
    final original = jsonEncode(originalInfo.toJson());
    await file.writeAsString(original);
    readCache = StudentInfoStore.read;

    final result = await source.readLocal();

    expect(result.grade, 1);
    expect(result.fromCache, isTrue);
    expect(result.fetchedAt, originalInfo.fetchedAt);
    expect(await file.readAsString(), original);
    expect(await file.parent.list().toList(), hasLength(1));
    expect(accountReads, 2);
    expect(platformCalls, ['getApplicationDocumentsDirectory']);
  });

  test('损坏本地 JSON 降级为未知年级且不改写原件', () async {
    final directory = await localDirectory();
    final file = profileFile(directory);
    await file.parent.create(recursive: true);
    await file.writeAsString('{broken');
    readCache = StudentInfoStore.read;
    final records = <Map<String, Object?>>[];
    AppLog.recordListenerForTesting = records.add;

    final result = await source.readLocal();

    expect(result.grade, isNull);
    expect(await file.readAsString(), '{broken');
    final failure = records.singleWhere(
      (record) => record['event'] == 'cache.read_failed',
    );
    final attrs = failure['attrs'] as Map;
    expect(attrs['error_chain'], isNotEmpty);
    expect(attrs['stack_trace'], isNotEmpty);
  });

  for (final fetchedAt in <String?>[null, 'invalid-time']) {
    test('本地缓存获取时间「$fetchedAt」无效时拒绝记录并保留诊断', () async {
      final directory = await localDirectory();
      final file = profileFile(directory);
      await file.parent.create(recursive: true);
      final data = _info().toJson()..['fetchedAt'] = fetchedAt;
      final original = jsonEncode(data);
      await file.writeAsString(original);
      final records = <Map<String, Object?>>[];
      AppLog.recordListenerForTesting = records.add;

      expect(await StudentInfoStore.read(), isNull);
      expect(await file.readAsString(), original);
      final failure = records.singleWhere(
        (record) => record['event'] == 'cache.read_failed',
      );
      final attrs = failure['attrs'] as Map;
      expect(attrs['error_type'], 'FormatException');
      expect(attrs['error_chain'], isNotEmpty);
      expect(attrs['stack_trace'], isNotEmpty);
    });
  }

  test('本地目录平台不可用时保留系统原因及堆栈', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProviderChannel,
          (_) async => throw PlatformException(code: 'synthetic_unavailable'),
        );
    final records = <Map<String, Object?>>[];
    AppLog.recordListenerForTesting = records.add;

    expect(await StudentInfoStore.read(), isNull);

    final failure = records.singleWhere(
      (record) =>
          record['scope'] == 'student_info.store' &&
          record['event'] == 'storage.unavailable',
    );
    final attrs = failure['attrs'] as Map;
    expect(attrs['error_type'], 'PlatformException');
    expect(attrs['error_chain'], isNotEmpty);
    expect(attrs['stack_trace'], isNotEmpty);
  });

  test('学生卡正常保存仍会创建本地目录且可恢复', () async {
    final directory = await localDirectory();
    final info = _info();

    await StudentInfoStore.save(info);
    final restored = await StudentInfoStore.read();

    expect(await profileFile(directory).exists(), isTrue);
    expect(restored?.user.studentId, _studentId);
    expect(restored?.semester?.year, info.semester?.year);
    expect(restored?.fetchedAt, info.fetchedAt);
  });
}
