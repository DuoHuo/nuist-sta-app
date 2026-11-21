import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/auth/enrollment_year.dart' as core_year;
import 'package:nuist_sta_app/core/logging/app_log.dart';
import 'package:nuist_sta_app/core/refresh/silent_refresh.dart';
import 'package:nuist_sta_app/mini_apps/student_info/student_info_academic_source.dart';
import 'package:nuist_sta_app/mini_apps/student_info/student_info_controller.dart';
import 'package:nuist_sta_app/mini_apps/student_info/student_info_models.dart';
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

  late StudentInfoController controller;
  late StudentInfoAcademicSource source;
  late StudentInfo? cached;
  late StudentInfo nextFetch;
  late bool bound;
  late String? account;
  late bool sourceDisposed;
  late int cacheReads;
  late int fetches;
  late List<StudentInfo> saved;
  Future<StudentInfo?> Function()? readCache;
  Future<StudentInfo> Function()? fetch;
  Future<String?> Function()? readAccount;

  setUp(() async {
    await AppLog.resetForTesting();
    SilentRefresh.updated.value = 0;
    cached = _info();
    nextFetch = _info();
    bound = true;
    account = _studentId;
    sourceDisposed = false;
    cacheReads = 0;
    fetches = 0;
    saved = [];
    readCache = null;
    fetch = null;
    readAccount = null;
    controller = StudentInfoController.forTesting(
      readCache: () async {
        cacheReads++;
        final callback = readCache;
        return callback == null ? cached : await callback();
      },
      saveCache: (info) async {
        saved.add(info);
        cached = info;
      },
      fetch: () async {
        fetches++;
        final callback = fetch;
        return callback == null ? nextFetch : await callback();
      },
      bindingCheck: () async => bound,
    );
    source = StudentInfoAcademicSource.forTesting(
      controller: controller,
      readBoundAccount: () async {
        final callback = readAccount;
        return callback == null ? account : await callback();
      },
    );
  });

  tearDown(() async {
    if (!sourceDisposed) source.dispose();
    controller.dispose();
    SilentRefresh.updated.value = 0;
    await AppLog.resetForTesting();
  });

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
    test('根据门户学年 ${entry.key} 与入学年计算年级 ${entry.value}', () async {
      cached = _info(academicYear: entry.key);

      await source.ensureStarted();

      expect(source.value.portalBound, isTrue);
      expect(source.value.identityMatches, isTrue);
      expect(source.value.undergraduate, isTrue);
      expect(source.value.academicYear, entry.key);
      expect(source.value.enrollmentYear, 2025);
      expect(source.value.grade, entry.value);
      expect(source.value.loading, isFalse);
      expect(source.value.error, isNull);
      expect(fetches, 0);
    });
  }

  test('缺失校历学年时不根据本机日期推测年级', () async {
    cached = _info(hasSemester: false);

    await source.ensureStarted();

    expect(source.value.identityMatches, isTrue);
    expect(source.value.academicYear, isNull);
    expect(source.value.enrollmentYear, 2025);
    expect(source.value.grade, isNull);
  });

  test('门户校历年份格式损坏时不识别年级', () async {
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

    await source.ensureStarted();

    expect(source.value.identityMatches, isTrue);
    expect(source.value.academicYear, isNull);
    expect(source.value.grade, isNull);
  });

  for (final category in ['学生/研究生', '学生/非本科生', '']) {
    test('用户类别「$category」没有明确本科生层级时不识别年级', () async {
      cached = _info(category: category);

      await source.ensureStarted();

      expect(source.value.identityMatches, isTrue);
      expect(source.value.undergraduate, isFalse);
      expect(source.value.grade, isNull);
    });
  }

  test('身份字段两端空格及本科生层级空格可正常核对', () async {
    cached = _info(studentId: ' $_studentId ', category: ' 学生 / 本科生 ');
    account = ' $_studentId ';

    await source.ensureStarted();

    expect(source.value.identityMatches, isTrue);
    expect(source.value.undergraduate, isTrue);
    expect(source.value.grade, 2);
  });

  test('学号只有年份前缀时不能因 helper 能解析就视为可靠身份', () async {
    cached = _info(studentId: '2025');
    account = '2025';

    await source.ensureStarted();

    expect(source.value.portalBound, isTrue);
    expect(source.value.identityMatches, isFalse);
    expect(source.value.enrollmentYear, isNull);
    expect(source.value.academicYear, isNull);
    expect(source.value.fetchedAt, isNull);
    expect(source.value.grade, isNull);
  });

  test('缓存账号与当前绑定账号不一致时撤回年份和获取时间', () async {
    account = 'different-account';

    await source.ensureStarted();

    expect(source.value.portalBound, isTrue);
    expect(source.value.identityMatches, isFalse);
    expect(source.value.academicYear, isNull);
    expect(source.value.enrollmentYear, isNull);
    expect(source.value.fetchedAt, isNull);
    expect(source.value.grade, isNull);
  });

  test('安全存储没有当前绑定账号时不信任缓存身份', () async {
    account = null;

    await source.ensureStarted();

    expect(source.value.portalBound, isFalse);
    expect(source.value.identityMatches, isFalse);
    expect(source.value.academicYear, isNull);
    expect(source.value.enrollmentYear, isNull);
    expect(source.value.grade, isNull);
  });

  test('未绑定门户时即使缓存身份有效也不识别年级', () async {
    bound = false;

    await source.ensureStarted();

    expect(source.value.portalBound, isFalse);
    expect(source.value.identityMatches, isFalse);
    expect(source.value.grade, isNull);
    expect(fetches, 0);
    expect(saved, isEmpty);
  });

  test('解绑时立即撤回已确认年级并保留学生卡缓存', () async {
    await source.ensureStarted();
    final cachedIdentity = controller.info;
    expect(source.value.grade, 2);

    bound = false;
    account = null;
    await controller.onPortalBindingChanged(false);

    expect(source.value.portalBound, isFalse);
    expect(source.value.identityMatches, isFalse);
    expect(source.value.grade, isNull);
    expect(source.value.loading, isFalse);
    expect(controller.info, same(cachedIdentity));
  });

  test('没有缓存且学生信息拉取失败时不返回猜测的年级', () async {
    cached = null;
    fetch = () async => throw const FormatException('synthetic invalid info');

    await source.ensureStarted();

    expect(source.value.grade, isNull);
    expect(source.value.identityMatches, isFalse);
    expect(source.value.academicYear, isNull);
    expect(source.value.enrollmentYear, isNull);
    expect(source.value.loading, isFalse);
    expect(saved, isEmpty);
  });

  test('缓存恢复标记来源为缓存，成功刷新后切换为本次拉取', () async {
    final cachedInfo = _info(academicYear: 2025);
    final freshInfo = _info(academicYear: 2026);
    cached = cachedInfo;
    nextFetch = freshInfo;

    await source.ensureStarted();
    expect(source.value.fromCache, isTrue);
    expect(source.value.fetchedAt, cachedInfo.fetchedAt);
    expect(source.value.grade, 1);
    expect(cacheReads, 1);
    expect(fetches, 0);

    await source.refresh();
    expect(source.value.fromCache, isFalse);
    expect(source.value.fetchedAt, freshInfo.fetchedAt);
    expect(source.value.grade, 2);
    expect(fetches, 1);
    expect(saved, [freshInfo]);
  });

  test('初始化合并调用只读取一次缓存', () async {
    await Future.wait([source.ensureStarted(), source.ensureStarted()]);

    expect(cacheReads, 1);
    expect(fetches, 0);
    expect(source.value.grade, 2);
  });

  test('晚到的旧绑定读取不能覆盖重新核对后的身份状态', () async {
    await source.ensureStarted();
    final delayedAccount = Completer<String?>();
    var deferNext = true;
    account = 'different-account';
    readAccount = () {
      if (deferNext) {
        deferNext = false;
        return delayedAccount.future;
      }
      return Future.value(account);
    };
    var notifications = 0;
    source.addListener(() => notifications++);

    await source.refresh();
    final current = source.value;
    final completedNotifications = notifications;
    expect(current.identityMatches, isFalse);
    expect(current.grade, isNull);

    delayedAccount.complete(_studentId);
    await Future<void>.delayed(Duration.zero);

    expect(source.value, same(current));
    expect(source.value.identityMatches, isFalse);
    expect(source.value.grade, isNull);
    expect(notifications, completedNotifications);
  });

  test('解绑后晚到的绑定读取不能重新恢复年级', () async {
    await source.ensureStarted();
    final delayedAccount = Completer<String?>();
    final readStarted = Completer<void>();
    readAccount = () {
      if (!readStarted.isCompleted) readStarted.complete();
      return delayedAccount.future;
    };
    final refresh = source.refresh();
    await readStarted.future;

    bound = false;
    account = null;
    await controller.onPortalBindingChanged(false);
    expect(source.value.portalBound, isFalse);
    expect(source.value.grade, isNull);

    delayedAccount.complete(_studentId);
    await refresh;

    expect(source.value.portalBound, isFalse);
    expect(source.value.identityMatches, isFalse);
    expect(source.value.grade, isNull);
    expect(source.value.loading, isFalse);
  });

  test('绑定读取失败时保留诊断并提示手动选择年级', () async {
    final records = <Map<String, Object?>>[];
    AppLog.recordListenerForTesting = records.add;
    readAccount = () async => throw StateError('synthetic unavailable binding');

    await source.ensureStarted();

    expect(source.value.grade, isNull);
    expect(source.value.error, isNotEmpty);
    expect(source.value.loading, isFalse);
    final failure = records.lastWhere(
      (record) => record['event'] == 'grade_source.unavailable',
    );
    final attrs = failure['attrs'] as Map;
    expect(attrs['error_chain'], isNotEmpty);
    expect(attrs['stack_trace'], isNotEmpty);
  });

  test('dispose 后晚到的绑定错误不会通知或恢复状态', () async {
    await source.ensureStarted();
    final delayedAccount = Completer<String?>();
    final readStarted = Completer<void>();
    readAccount = () {
      if (!readStarted.isCompleted) readStarted.complete();
      return delayedAccount.future;
    };
    var notifications = 0;
    source.addListener(() => notifications++);
    final refresh = source.refresh();
    await readStarted.future;
    final beforeDispose = source.value;
    final completedNotifications = notifications;

    source.dispose();
    sourceDisposed = true;
    delayedAccount.completeError(StateError('synthetic late binding failure'));
    await refresh;

    expect(source.value, same(beforeDispose));
    expect(notifications, completedNotifications);
    final completedFetches = fetches;
    await source.ensureStarted();
    await source.refresh();
    expect(fetches, completedFetches);
  });

  test('缓存启动尚未完成时 dispose，晚到结果不会通知已释放来源', () async {
    final delayedCache = Completer<StudentInfo?>();
    readCache = () => delayedCache.future;
    var notifications = 0;
    source.addListener(() => notifications++);

    final startup = source.ensureStarted();
    final completedNotifications = notifications;
    source.dispose();
    sourceDisposed = true;
    delayedCache.complete(_info());
    await startup;

    expect(notifications, completedNotifications);
    expect(cacheReads, 1);
    expect(fetches, 0);
  });
}
