import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/app_directories.dart';
import 'package:nuist_sta_app/core/logging/app_log.dart';
import 'package:nuist_sta_app/core/privacy/privacy_consent.dart';
import 'package:nuist_sta_app/core/theme_mode.dart';
import 'package:nuist_sta_app/mini_apps/academic/academic_store.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_detail_store.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_store.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_cache.dart';
import 'package:nuist_sta_app/mini_apps/electricity/electricity_store.dart';
import 'package:nuist_sta_app/mini_apps/score/score_store.dart';
import 'package:nuist_sta_app/mini_apps/student_info/student_info_models.dart';
import 'package:nuist_sta_app/mini_apps/student_info/student_info_store.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_store.dart';
import 'package:nuist_sta_app/shell/update/update_store.dart';
// 与现有 WebView 测试一致，仅使用已安装插件的平台接口验证平台注入兼容性。
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform({
    this.documentsPath,
    this.supportPath,
    this.temporaryPath,
  });

  String? documentsPath;
  String? supportPath;
  String? temporaryPath;
  Object? documentsError;
  Object? supportError;
  Object? temporaryError;

  int documentsCalls = 0;
  int supportCalls = 0;
  int temporaryCalls = 0;

  @override
  Future<String?> getApplicationDocumentsPath() async {
    documentsCalls++;
    if (documentsError case final error?) throw error;
    return documentsPath;
  }

  @override
  Future<String?> getApplicationSupportPath() async {
    supportCalls++;
    if (supportError case final error?) throw error;
    return supportPath;
  }

  @override
  Future<String?> getTemporaryPath() async {
    temporaryCalls++;
    if (temporaryError case final error?) throw error;
    return temporaryPath;
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  late Directory rootTemp;
  late Directory docsDir;
  late Directory supportDir;
  late Directory tempDir;

  setUp(() async {
    AppDirectories.resetForTesting();
    await AppLog.resetForTesting();
    rootTemp = await Directory.systemTemp.createTemp('app_directories_test_');
    docsDir = await Directory('${rootTemp.path}/docs').create();
    supportDir = await Directory('${rootTemp.path}/support').create();
    tempDir = await Directory('${rootTemp.path}/temp').create();
  });

  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      null,
    );
    AppDirectories.resetForTesting();
    AppThemeMode.instance.value = ThemeMode.system;
    await AppLog.resetForTesting();
    if (await rootTemp.exists()) {
      await rootTemp.delete(recursive: true);
    }
  });

  group('缓存命中与目录槽位隔离', () {
    test('三类目录各自缓存命中，同一类型仅触发一次底层调用', () async {
      var docsCalls = 0;
      var supportCalls = 0;
      var tempCalls = 0;

      AppDirectories.overrideForTesting(
        applicationDocuments: () async {
          docsCalls++;
          return docsDir;
        },
        applicationSupport: () async {
          supportCalls++;
          return supportDir;
        },
        temporary: () async {
          tempCalls++;
          return tempDir;
        },
      );

      final d1 = await AppDirectories.applicationDocuments();
      final d2 = await AppDirectories.applicationDocuments();
      expect(d1.path, docsDir.path);
      expect(identical(d1, d2), isTrue);
      expect(docsCalls, 1);
      expect(supportCalls, 0);
      expect(tempCalls, 0);

      final s1 = await AppDirectories.applicationSupport();
      final s2 = await AppDirectories.applicationSupport();
      expect(s1.path, supportDir.path);
      expect(identical(s1, s2), isTrue);
      expect(docsCalls, 1);
      expect(supportCalls, 1);
      expect(tempCalls, 0);

      final t1 = await AppDirectories.temporary();
      final t2 = await AppDirectories.temporary();
      expect(t1.path, tempDir.path);
      expect(identical(t1, t2), isTrue);
      expect(docsCalls, 1);
      expect(supportCalls, 1);
      expect(tempCalls, 1);
    });
  });

  group('并发去重', () {
    test('同一目录并发请求共享同一在途 Future，只调用一次底层加载器', () async {
      final docsGate = Completer<Directory>();
      final supportGate = Completer<Directory>();
      final tempGate = Completer<Directory>();
      var docsCalls = 0;
      var supportCalls = 0;
      var tempCalls = 0;

      AppDirectories.overrideForTesting(
        applicationDocuments: () {
          docsCalls++;
          return docsGate.future;
        },
        applicationSupport: () {
          supportCalls++;
          return supportGate.future;
        },
        temporary: () {
          tempCalls++;
          return tempGate.future;
        },
      );

      final docsFutures = List.generate(
        5,
        (_) => AppDirectories.applicationDocuments(),
      );
      final supportFutures = List.generate(
        4,
        (_) => AppDirectories.applicationSupport(),
      );
      final tempFutures = List.generate(3, (_) => AppDirectories.temporary());

      expect(docsCalls, 1);
      expect(supportCalls, 1);
      expect(tempCalls, 1);
      for (final f in docsFutures.skip(1)) {
        expect(identical(f, docsFutures.first), isTrue);
      }
      for (final f in supportFutures.skip(1)) {
        expect(identical(f, supportFutures.first), isTrue);
      }
      for (final f in tempFutures.skip(1)) {
        expect(identical(f, tempFutures.first), isTrue);
      }

      docsGate.complete(docsDir);
      supportGate.complete(supportDir);
      tempGate.complete(tempDir);

      final docsResults = await Future.wait(docsFutures);
      final supportResults = await Future.wait(supportFutures);
      final tempResults = await Future.wait(tempFutures);

      expect(docsResults.every((d) => identical(d, docsDir)), isTrue);
      expect(supportResults.every((d) => identical(d, supportDir)), isTrue);
      expect(tempResults.every((d) => identical(d, tempDir)), isTrue);

      // 完成后再次请求直接命中缓存。
      expect(
        identical(await AppDirectories.applicationDocuments(), docsDir),
        isTrue,
      );
      expect(
        identical(await AppDirectories.applicationSupport(), supportDir),
        isTrue,
      );
      expect(identical(await AppDirectories.temporary(), tempDir), isTrue);
      expect(docsCalls, 1);
      expect(supportCalls, 1);
      expect(tempCalls, 1);
    });
  });

  group('异常不缓存与重试恢复', () {
    test('异步异常不缓存，并发调用方全部收到原异常且后续调用可成功恢复', () async {
      final firstGate = Completer<Directory>();
      var calls = 0;

      AppDirectories.overrideForTesting(
        applicationDocuments: () {
          calls++;
          if (calls == 1) return firstGate.future;
          return Future<Directory>.value(docsDir);
        },
      );

      final f1 = AppDirectories.applicationDocuments();
      final f2 = AppDirectories.applicationDocuments();
      expect(identical(f1, f2), isTrue);
      expect(calls, 1);

      final expectedError = PlatformException(
        code: 'channel_error',
        message: 'synthetic failure',
      );
      firstGate.completeError(expectedError, StackTrace.current);

      final errors = <Object>[];
      final stacks = <StackTrace>[];
      for (final f in [f1, f2]) {
        try {
          await f;
          fail('应抛出底层异常');
        } catch (error, stackTrace) {
          errors.add(error);
          stacks.add(stackTrace);
        }
      }
      expect(errors, [same(expectedError), same(expectedError)]);
      expect(stacks.every((s) => s.toString().isNotEmpty), isTrue);

      // 槽位已释放，下次调用重试并成功缓存。
      final recovered = await AppDirectories.applicationDocuments();
      expect(identical(recovered, docsDir), isTrue);
      expect(calls, 2);

      expect(
        identical(await AppDirectories.applicationDocuments(), docsDir),
        isTrue,
      );
      expect(calls, 2);
    });

    test('超时异常与同步异常均不缓存，且不影响其他目录槽位', () async {
      var supportCalls = 0;
      var tempCalls = 0;
      var docsCalls = 0;

      AppDirectories.overrideForTesting(
        applicationDocuments: () async {
          docsCalls++;
          return docsDir;
        },
        applicationSupport: () {
          supportCalls++;
          if (supportCalls == 1) {
            return Future<Directory>.error(
              TimeoutException('synthetic timeout'),
            );
          }
          return Future<Directory>.value(supportDir);
        },
        temporary: () {
          tempCalls++;
          if (tempCalls == 1) {
            throw StateError('synthetic sync failure');
          }
          return Future<Directory>.value(tempDir);
        },
      );

      // 先缓存 docsDir。
      expect(await AppDirectories.applicationDocuments(), same(docsDir));
      expect(docsCalls, 1);

      // support 超时失败后下次可恢复。
      await expectLater(
        AppDirectories.applicationSupport(),
        throwsA(isA<TimeoutException>()),
      );
      expect(await AppDirectories.applicationSupport(), same(supportDir));
      expect(supportCalls, 2);

      // temporary 同步抛错不锁死在途槽位，下次可恢复。
      await expectLater(AppDirectories.temporary(), throwsA(isA<StateError>()));
      expect(await AppDirectories.temporary(), same(tempDir));
      expect(tempCalls, 2);

      // 已缓存的 docsDir 不受影响。
      expect(await AppDirectories.applicationDocuments(), same(docsDir));
      expect(docsCalls, 1);
    });
  });

  group('reset 清理与在途竞态保护', () {
    test('resetForTesting 清理缓存后重新获取，并按 keepOverrides 控制是否保留注入器', () async {
      var docsCalls = 0;
      AppDirectories.overrideForTesting(
        applicationDocuments: () async {
          docsCalls++;
          return docsDir;
        },
      );

      expect(await AppDirectories.applicationDocuments(), same(docsDir));
      expect(docsCalls, 1);

      // 仅清缓存、保留自定义加载器。
      AppDirectories.resetForTesting(keepOverrides: true);
      expect(await AppDirectories.applicationDocuments(), same(docsDir));
      expect(docsCalls, 2);

      // 彻底重置后恢复走默认 path_provider 通道。
      final channelCalls = <String>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pathProviderChannel,
        (call) async {
          channelCalls.add(call.method);
          if (call.method == 'getApplicationDocumentsDirectory') {
            return supportDir.path;
          }
          return null;
        },
      );

      AppDirectories.resetForTesting();
      final viaChannel = await AppDirectories.applicationDocuments();
      expect(viaChannel.path, supportDir.path);
      expect(docsCalls, 2);
      expect(channelCalls, ['getApplicationDocumentsDirectory']);

      // 再次 reset 后重新触发平台通道。
      AppDirectories.resetForTesting();
      await AppDirectories.applicationDocuments();
      expect(channelCalls, [
        'getApplicationDocumentsDirectory',
        'getApplicationDocumentsDirectory',
      ]);
    });

    test('在途请求尚未返回时执行 reset 或新覆盖，旧结果不会污染新缓存', () async {
      final staleGate = Completer<Directory>();
      final freshGate = Completer<Directory>();

      AppDirectories.overrideForTesting(
        applicationDocuments: () => staleGate.future,
      );
      final staleFuture = AppDirectories.applicationDocuments();

      // 旧请求仍在途时重置并注入新解析器。
      AppDirectories.overrideForTesting(
        applicationDocuments: () => freshGate.future,
      );
      final freshFuture = AppDirectories.applicationDocuments();
      expect(identical(staleFuture, freshFuture), isFalse);

      // 旧请求先返回：不得覆盖新槽位，也不得清掉 freshFuture。
      staleGate.complete(tempDir);
      expect(await staleFuture, same(tempDir));

      // 仍在等待 freshFuture 时并发调用应继续复用 freshFuture。
      final joinedFresh = AppDirectories.applicationDocuments();
      expect(identical(joinedFresh, freshFuture), isTrue);

      freshGate.complete(docsDir);
      expect(await freshFuture, same(docsDir));
      expect(await AppDirectories.applicationDocuments(), same(docsDir));
    });
  });

  group('与 PathProviderPlatform 及全仓 Store 协同', () {
    test(
      '切换 PathProviderPlatform.instance 配合 resetForTesting 正常缓存与恢复',
      () async {
        final originalPlatform = PathProviderPlatform.instance;
        addTearDown(() {
          PathProviderPlatform.instance = originalPlatform;
          AppDirectories.resetForTesting();
        });

        final firstPlatform = _FakePathProviderPlatform(
          documentsPath: docsDir.path,
          supportPath: supportDir.path,
          temporaryPath: tempDir.path,
        );
        PathProviderPlatform.instance = firstPlatform;
        AppDirectories.resetForTesting();

        expect(
          (await AppDirectories.applicationDocuments()).path,
          docsDir.path,
        );
        expect(
          (await AppDirectories.applicationDocuments()).path,
          docsDir.path,
        );
        expect(firstPlatform.documentsCalls, 1);

        expect(
          (await AppDirectories.applicationSupport()).path,
          supportDir.path,
        );
        expect(
          (await AppDirectories.applicationSupport()).path,
          supportDir.path,
        );
        expect(firstPlatform.supportCalls, 1);

        expect((await AppDirectories.temporary()).path, tempDir.path);
        expect((await AppDirectories.temporary()).path, tempDir.path);
        expect(firstPlatform.temporaryCalls, 1);

        // 切换新的平台替身，先模拟一次失败（返回 null），再恢复正常。
        final secondDocs = await Directory('${rootTemp.path}/docs2').create();
        final secondPlatform = _FakePathProviderPlatform(
          documentsPath: null,
          supportPath: supportDir.path,
          temporaryPath: tempDir.path,
        );
        PathProviderPlatform.instance = secondPlatform;
        AppDirectories.resetForTesting();

        await expectLater(
          AppDirectories.applicationDocuments(),
          throwsA(isA<Exception>()),
        );
        expect(secondPlatform.documentsCalls, 1);

        secondPlatform.documentsPath = secondDocs.path;
        expect(
          (await AppDirectories.applicationDocuments()).path,
          secondDocs.path,
        );
        expect(
          (await AppDirectories.applicationDocuments()).path,
          secondDocs.path,
        );
        expect(secondPlatform.documentsCalls, 2);
      },
    );

    test('多个 Store 并发与顺序读写共享单次 MethodChannel 查询，失败后仍可恢复', () async {
      final calls = <String>[];
      var failDocs = true;

      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pathProviderChannel,
        (call) async {
          calls.add(call.method);
          return switch (call.method) {
            'getApplicationDocumentsDirectory' =>
              failDocs
                  ? throw PlatformException(code: 'temp_unavailable')
                  : docsDir.path,
            'getApplicationSupportDirectory' => supportDir.path,
            'getTemporaryDirectory' => tempDir.path,
            _ => null,
          };
        },
      );

      // 1) 平台暂时不可用时 Store 按既有逻辑降级为 null，且不缓存失败。
      expect(await StudentInfoStore.read(), isNull);
      expect(calls, ['getApplicationDocumentsDirectory']);

      // 2) 平台恢复后，多个文档目录 Store 并发调用仅再触发一次通道查询。
      failDocs = false;
      await Future.wait<Object?>([
        AcademicStore.read(),
        ScoreStore.read(),
        StudentInfoStore.read(),
        ElectricityStore.readRoom(),
        AnnouncementStore.readCache(),
        BulletinStore().read(),
        CampusMapCache().read('default'),
      ]);

      final info = StudentInfo(
        user: const PortalUser(
          name: '测试学生',
          studentId: '202512340001',
          categoryName: '学生/本科生',
          deptName: '测试学院',
        ),
        semester: SemesterInfo(
          year: 2026,
          term: '1',
          start: DateTime(2026, 9, 1),
          end: DateTime(2027, 1, 31),
          maxWeeks: 20,
        ),
        fetchedAt: DateTime(2026, 9, 10),
      );
      await StudentInfoStore.save(info);
      final restored = await StudentInfoStore.read();
      expect(restored?.user.studentId, '202512340001');

      expect(
        calls.where((m) => m == 'getApplicationDocumentsDirectory'),
        hasLength(2), // 首次失败 1 次 + 恢复后成功并缓存 1 次
      );

      // 3) 支持目录：PrivacyConsent、AppThemeMode、UpdateStore 共享 1 次查询。
      final consent = PrivacyConsent();
      await Future.wait([
        consent.load(),
        AppThemeMode.instance.set(ThemeMode.dark),
        UpdateStore.read(),
      ]);
      expect(
        calls.where((m) => m == 'getApplicationSupportDirectory'),
        hasLength(1),
      );

      // 4) 临时目录：BulletinDetailStore 与 AppDirectories.temporary 共享 1 次查询。
      final detailStore = BulletinDetailStore();
      await Future.wait([
        detailStore.read(Uri.parse('https://bulletin.campus.invalid/1.htm')),
        AppDirectories.temporary(),
      ]);
      expect(calls.where((m) => m == 'getTemporaryDirectory'), hasLength(1));
    });
  });
}
