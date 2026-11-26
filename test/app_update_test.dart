import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nuist_sta_app/app.dart';
import 'package:nuist_sta_app/core/network/client_metadata.dart';
import 'package:nuist_sta_app/core/logging/app_log.dart';
import 'package:nuist_sta_app/core/privacy/privacy_consent.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/router.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_api.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_controller.dart';
import 'package:nuist_sta_app/shell/profile/about/about_page.dart';
import 'package:nuist_sta_app/shell/update/update_api.dart';
import 'package:nuist_sta_app/shell/update/update_bridge.dart';
import 'package:nuist_sta_app/shell/update/update_controller.dart';
import 'package:nuist_sta_app/shell/update/update_models.dart';
import 'package:nuist_sta_app/shell/update/update_dialog.dart';
import 'package:nuist_sta_app/shell/update/update_store.dart';

const current = ClientMetadata(
  platform: 'android',
  appPackage: 'dev.duohuo.nuist_sta_app',
  appChannel: 'release',
  appVersion: '0.2.8',
  appVersionCode: 2800,
  androidSdk: 36,
);

UpdateRelease release({
  bool popup = false,
  String revision = 'revision-a',
  String changelog = '修复已知问题\n改进使用体验',
}) => UpdateRelease.fromJson({
  'revision': revision,
  'versionName': '0.2.9',
  'versionCode': 2900,
  'packageName': 'dev.duohuo.nuist_sta_app',
  'channel': 'release',
  'abi': 'arm64-v8a',
  'minSdk': 24,
  'title': '版本更新',
  'changelog': changelog,
  'publishedAt': '2026-11-09T00:00:00Z',
  'size': 40000000,
  'sha256': 'a' * 64,
  'downloadUrl': 'https://app.duohuo.org.cn/api/v1/updates/$revision/apk',
  'statusUrl': 'https://app.duohuo.org.cn/api/v1/updates/$revision/status',
  'popupEnabled': popup,
});

class FakeApi implements UpdateClient {
  UpdateRelease? value = release();
  int checks = 0;
  int validations = 0;
  bool failed = false;
  bool revoked = false;
  Completer<UpdateRelease?>? pending;
  Completer<void>? pendingValidation;

  @override
  Future<UpdateRelease?> check() async {
    checks++;
    if (failed) throw const FormatException('test');
    return pending?.future ?? value;
  }

  @override
  Future<void> validate(UpdateRelease release) async {
    validations++;
    await pendingValidation?.future;
    if (revoked) throw const UpdateRevoked();
  }
}

class FakeBridge implements UpdateDownloadBridge {
  final events = StreamController<UpdateTask>.broadcast(sync: true);
  UpdateTask value = const UpdateTask(installAllowed: true);
  int starts = 0;
  int installs = 0;
  int cancellations = 0;
  int resumes = 0;
  int settingsRequests = 0;
  Map<String, String>? lastHeaders;
  Map<String, String>? lastResumeHeaders;
  Completer<UpdateTask>? pendingState;
  Completer<void>? pendingSettings;
  Object? settingsError;

  @override
  Stream<UpdateTask> get states => events.stream;
  @override
  Future<UpdateTask> getState() async => pendingState?.future ?? value;
  @override
  Future<UpdateTask> start(
    UpdateRelease release,
    Map<String, String> headers,
  ) async {
    starts++;
    lastHeaders = headers;
    value = UpdateTask(
      status: UpdateTaskStatus.downloading,
      release: release,
      totalBytes: release.size,
    );
    return value;
  }

  @override
  Future<UpdateTask> resume([Map<String, String>? headers]) async {
    resumes++;
    lastResumeHeaders = headers;
    return value;
  }

  @override
  Future<UpdateTask> cancel() async {
    cancellations++;
    return value = const UpdateTask();
  }

  @override
  Future<UpdateTask> install() async {
    installs++;
    return value;
  }

  @override
  Future<void> openInstallSettings() async {
    settingsRequests++;
    if (settingsError != null) throw settingsError!;
    await pendingSettings?.future;
  }

  @override
  Future<void> requestNotificationPermission() async {}
}

AnnouncementController freshAnnouncements() {
  final c = AnnouncementController.test(
    fetch: ({etag, lastModified}) async =>
        const AnnouncementFetchResult(notModified: false, items: []),
  );
  addTearDown(c.dispose);
  return c;
}

/// 关于页的贡献者加载独立于更新，测试只推进本次交互与路由动画。
Future<void> pumpInteraction(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

Future<GoRouter> pumpAbout(
  WidgetTester tester,
  UpdateController controller, {
  bool dark = false,
}) async {
  final router = buildRouter(
    updateController: controller,
    announcementController: freshAnnouncements(),
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    MaterialApp.router(
      theme: dark ? appDarkTheme() : appLightTheme(),
      routerConfig: router,
    ),
  );
  await pumpInteraction(tester);
  router.push('/about');
  await pumpInteraction(tester);
  return router;
}

void main() {
  test('原生下载失败记录真实状态和原因，进度变化不重复记录终态', () async {
    final records = <Map<String, Object?>>[];
    AppLog.recordListenerForTesting = records.add;
    final bridge = FakeBridge();
    final controller = UpdateController(
      api: FakeApi(),
      bridge: bridge,
      metadataProvider: () async => current,
    );
    try {
      await controller.ensureStarted();
      await controller.check(manual: true);
      await controller.download();
      bridge.events.add(
        UpdateTask(
          status: UpdateTaskStatus.downloading,
          release: release(),
          downloadedBytes: 20,
          totalBytes: 100,
        ),
      );
      bridge.events.add(
        UpdateTask(
          status: UpdateTaskStatus.failed,
          release: release(),
          errorCode: 'hash_mismatch',
        ),
      );
      final states = records
          .where((event) => event['event'] == 'download.state_changed')
          .toList();
      expect(states, hasLength(2));
      expect(states.last['level'], 'WARNING');
      expect(states.last.toString(), contains('hash_mismatch'));
      expect(
        records.any((event) => event['event'] == 'download.completed'),
        isFalse,
      );
      expect(
        records.any(
          (event) => event['event'] == 'download.start_command.completed',
        ),
        isTrue,
      );
    } finally {
      controller.dispose();
      await bridge.events.close();
      AppLog.recordListenerForTesting = null;
    }
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeApi api;
  late FakeBridge bridge;
  late UpdateController controller;
  late DateTime now;
  UpdatePreferences saved = const UpdatePreferences();

  setUp(() {
    api = FakeApi();
    bridge = FakeBridge();
    now = DateTime.utc(2026, 11, 9);
    saved = const UpdatePreferences();
    controller = UpdateController(
      api: api,
      bridge: bridge,
      metadataProvider: () async => current,
      now: () => now,
      savePreferences: (preferences) async => saved = preferences,
    );
  });
  tearDown(() async {
    PrivacyConsent.dialogPending.value = false;
    PrivacyConsent.openPolicy = null;
    controller.dispose();
    await bridge.events.close();
  });

  test('更新描述保留服务端内容，下载仍限定自有服务', () {
    final json = release().toJson();
    expect(UpdateRelease.fromJson(json).toJson(), json);
    expect(
      () => UpdateRelease.fromJson({
        ...json,
        'downloadUrl': 'https://example.com/update.apk',
      }),
      throwsFormatException,
    );
  });

  test('自动检查单飞和六小时节流，手动操作绕过节流', () async {
    api.pending = Completer();
    final first = controller.onLaunch();
    final second = controller.check(manual: true);
    await Future<void>.delayed(Duration.zero);
    expect(api.checks, 1);
    api.pending!.complete(release());
    await Future.wait([first, second]);
    api.pending = null;
    await controller.onResumed();
    expect(api.checks, 1);
    await controller.check(manual: true);
    expect(api.checks, 2);
    now = now.add(const Duration(hours: 6));
    await controller.onResumed();
    expect(api.checks, 3);
  });

  test('默认只做伪公告，已读与悬浮条去重独立于弹窗', () async {
    await controller.onLaunch();
    expect(controller.shouldPrompt, isFalse);
    expect(controller.shouldShowBanner, isTrue);
    controller.markBannerShown();
    expect(controller.shouldShowBanner, isFalse);
    expect(controller.hasUnreadAnnouncement, isTrue);
    await controller.markAnnouncementRead();
    expect(controller.hasUnreadAnnouncement, isFalse);
    expect(saved.readRevision, release().revision);
    api.value = release(revision: 'revision-b');
    await controller.check(manual: true);
    expect(controller.shouldShowBanner, isTrue);
  });

  test('稍后提醒仅当前进程生效，后台返回不重弹，新进程仍然提示', () async {
    api.value = release(popup: true);
    await controller.onLaunch();
    expect(controller.shouldPrompt, isTrue);
    expect(controller.hasUnreadAnnouncement, isFalse);
    controller.markPrompted(api.value!);
    expect(controller.shouldPrompt, isFalse);
    now = now.add(const Duration(days: 2));
    await controller.onResumed();
    expect(controller.shouldPrompt, isFalse);
    controller.dispose();
    controller = UpdateController(
      api: api,
      bridge: bridge,
      metadataProvider: () async => current,
      readPreferences: () async => saved,
      savePreferences: (preferences) async => saved = preferences,
      now: () => now,
    );
    await controller.onLaunch();
    expect(controller.shouldPrompt, isTrue);
    api.failed = true;
    await controller.check(manual: true);
    expect(controller.available, isNull);
    expect(controller.checkError, isNotNull);
  });

  test('旧偏好的稍后提醒字段忽略，只保留检查时间和已读修订', () async {
    final oldPreferences = UpdatePreferences.fromJson({
      'lastAttempt': now.toIso8601String(),
      'readRevision': 'revision-a',
      'snoozedRevision': 'revision-a',
      'snoozedUntil': now.add(const Duration(days: 365)).toIso8601String(),
    });
    expect(oldPreferences.toJson(), {
      'lastAttempt': now.toIso8601String(),
      'readRevision': 'revision-a',
    });
    controller.dispose();
    controller = UpdateController(
      api: api,
      bridge: bridge,
      metadataProvider: () async => current,
      readPreferences: () async => oldPreferences,
      now: () => now,
    );
    api.value = release(popup: true);
    await controller.onLaunch();
    expect(controller.shouldPrompt, isTrue);
  });

  test('下载前撤包不启动原生任务，安装前撤包不调用安装器', () async {
    await controller.onLaunch();
    api.revoked = true;
    await controller.download();
    expect(bridge.starts, 0);
    expect(controller.actionError, contains('停止分发'));
    bridge.value = UpdateTask(
      status: UpdateTaskStatus.ready,
      release: release(),
      installAllowed: true,
    );
    await controller.refreshTask();
    await controller.install();
    expect(bridge.installs, 0);
    expect(controller.task.hasTask, isFalse);
  });

  UpdateTask readyTask({bool allowed = false, UpdateRelease? artifact}) =>
      UpdateTask(
        status: UpdateTaskStatus.ready,
        release: artifact ?? release(),
        installAllowed: allowed,
      );

  test('安装来源授权返回后续装一次，无关恢复不会唤起安装', () async {
    bridge.value = readyTask(allowed: true);
    await controller.onResumed();
    expect(bridge.installs, 0);
    bridge.value = readyTask();
    await controller.refreshTask();
    await controller.openInstallSettings();
    expect(bridge.settingsRequests, 1);
    expect(bridge.installs, 0);

    bridge.value = readyTask(allowed: true);
    await Future.wait([controller.onResumed(), controller.onResumed()]);
    expect(bridge.installs, 1);
    expect(api.validations, 1);
    await controller.onResumed();
    expect(bridge.installs, 1);
  });

  UpdateController resetController({
    Future<ClientMetadata> Function()? metadataProvider,
  }) {
    controller.dispose();
    api = FakeApi();
    bridge.events.close();
    bridge = FakeBridge();
    return controller = UpdateController(
      api: api,
      bridge: bridge,
      metadataProvider: metadataProvider ?? () async => current,
      now: () => now,
      savePreferences: (preferences) async => saved = preferences,
    );
  }

  test('安装来源授权或拒绝返回早于设置通道完成仍只消费一次，拒绝与设置失败不留挂起请求', () async {
    for (final allowed in [true, false]) {
      resetController();
      bridge.value = readyTask();
      await controller.ensureStarted();
      bridge.pendingSettings = Completer<void>();
      final opening = controller.openInstallSettings();
      await Future<void>.delayed(Duration.zero);
      expect(controller.acting, isTrue);
      bridge.value = readyTask(allowed: allowed);
      await controller.onResumed();
      expect(bridge.installs, 0);
      bridge.pendingSettings!.complete();
      await opening;
      expect(controller.acting, isFalse);
      expect(bridge.installs, allowed ? 1 : 0);

      bridge.value = readyTask(allowed: true);
      await controller.onResumed();
      expect(bridge.installs, allowed ? 1 : 0);
    }

    for (final outcome in ['拒绝授权', '设置打开失败']) {
      resetController();
      bridge.value = readyTask();
      await controller.ensureStarted();
      if (outcome == '设置打开失败') {
        bridge.settingsError = PlatformException(code: 'settings_failed');
      }
      await controller.openInstallSettings();
      await controller.onResumed();
      expect(bridge.installs, 0);
      bridge.value = readyTask(allowed: true);
      await controller.onResumed();
      expect(bridge.installs, 0);

      bridge.settingsError = null;
      bridge.value = readyTask();
      await controller.refreshTask();
      await controller.openInstallSettings();
      bridge.value = readyTask(allowed: true);
      await controller.onResumed();
      expect(bridge.settingsRequests, 2);
      expect(bridge.installs, 1);
    }
  });

  test('安装来源授权期间取消任务、更换修订、不再就绪或撤包均不自动安装', () async {
    for (final outcome in ['取消任务', '更换修订', '不再就绪', '撤包']) {
      resetController();
      bridge.value = readyTask();
      await controller.ensureStarted();
      await controller.openInstallSettings();
      bridge.value = switch (outcome) {
        '取消任务' => const UpdateTask(),
        '更换修订' => readyTask(
          allowed: true,
          artifact: release(revision: 'revision-b'),
        ),
        '不再就绪' => UpdateTask(
          status: UpdateTaskStatus.paused,
          release: release(),
          installAllowed: true,
        ),
        _ => readyTask(allowed: true),
      };
      api.revoked = outcome == '撤包';
      await controller.onResumed();
      expect(bridge.installs, 0, reason: outcome);
      expect(bridge.cancellations, outcome == '撤包' ? 1 : 0, reason: outcome);
      bridge.value = readyTask(allowed: true);
      await controller.onResumed();
      expect(bridge.installs, 0, reason: outcome);
    }
  });

  test('授权续装复查期间任务更换，旧修订撤包或可用均不安装或取消新任务', () async {
    for (final revoked in [true, false]) {
      resetController();
      bridge.value = readyTask();
      await controller.ensureStarted();
      await controller.openInstallSettings();
      bridge.value = readyTask(allowed: true);
      api.pendingValidation = Completer<void>();
      final returning = controller.onResumed();
      await Future<void>.delayed(Duration.zero);
      expect(api.validations, 1);
      expect(controller.acting, isTrue);
      bridge.value = readyTask(
        allowed: true,
        artifact: release(revision: 'revision-b'),
      );
      bridge.events.add(bridge.value);
      api.revoked = revoked;
      api.pendingValidation!.complete();
      await returning;
      expect(bridge.installs, 0);
      expect(bridge.cancellations, 0);
      expect(controller.task.release!.revision, 'revision-b');
    }
  });

  test('服务端下发即接受，不因不同渠道或缺少元数据在本地过滤兼容性', () async {
    for (final metadata in [
      current,
      const ClientMetadata(
        platform: 'android',
        appPackage: 'dev.duohuo.nuist_sta_app.debug',
        appChannel: 'dev',
        appVersionCode: 2800,
        androidSdk: 36,
      ),
      const ClientMetadata(platform: 'android'),
    ]) {
      resetController(metadataProvider: () async => metadata);
      api.value = UpdateRelease.fromJson({
        ...release().toJson(),
        'packageName': 'dev.duohuo.nuist_sta_app.debug',
        'channel': 'ci',
        'versionCode': 1,
        'minSdk': 99,
        'abi': 'x86_64',
      });
      await controller.check(manual: true);
      expect(api.checks, 1);
      expect(controller.available, same(api.value));
      expect(controller.checkError, isNull);
      await controller.download();
      expect(bridge.starts, 1);
      expect(bridge.lastHeaders, metadata.headers);
      await controller.resume();
      expect(bridge.resumes, 1);
      expect(bridge.lastResumeHeaders, metadata.headers);
    }
  });

  test('旧的非活跃任务不屏蔽新版本且允许替换下载，活跃任务或同修订仍拦截', () async {
    final revA = release(revision: 'revision-a');
    final revB = release(revision: 'revision-b', popup: true);
    for (final status in [
      UpdateTaskStatus.revoked,
      UpdateTaskStatus.paused,
      UpdateTaskStatus.failed,
      UpdateTaskStatus.ready,
    ]) {
      bridge.value = UpdateTask(status: status, release: revA);
      await controller.refreshTask();
      api.value = revB;
      await controller.check(manual: true);
      expect(controller.hasActiveTask, isFalse);
      expect(controller.taskSuperseded, isTrue);
      expect(controller.shouldPrompt, isTrue);

      api.value = release(revision: 'revision-b', popup: false);
      await controller.check(manual: true);
      expect(controller.shouldShowBanner, isTrue);

      await controller.download();
      expect(controller.actionError, isNull);
      expect(controller.task.release?.revision, 'revision-b');
      await controller.cancel();
    }

    // 同修订非 revoked 任务不可重复下载。
    bridge.value = UpdateTask(status: UpdateTaskStatus.paused, release: revA);
    await controller.refreshTask();
    await controller.download(revA);
    expect(controller.actionError, '已有更新任务');

    // revoked 的同修订经过服务端校验可重新下载。
    bridge.value = UpdateTask(status: UpdateTaskStatus.revoked, release: revA);
    await controller.refreshTask();
    await controller.download(revA);
    expect(controller.actionError, isNull);
    expect(controller.task.status, UpdateTaskStatus.downloading);

    // 活跃任务（downloading/verifying/installing）不能被新版本打断。
    for (final activeStatus in [
      UpdateTaskStatus.downloading,
      UpdateTaskStatus.verifying,
      UpdateTaskStatus.installing,
    ]) {
      bridge.value = UpdateTask(status: activeStatus, release: revA);
      await controller.refreshTask();
      api.value = revB;
      await controller.check(manual: true);
      expect(controller.hasActiveTask, isTrue);
      expect(controller.taskSuperseded, isFalse);
      expect(controller.shouldPrompt, isFalse);
      await controller.download();
      expect(controller.actionError, '已有更新任务');
    }
  });

  test('download 与 resume 每次实时读取最新隐私元数据', () async {
    var dynamicMeta = const ClientMetadata(
      platform: 'android',
      appPackage: 'dev.duohuo.nuist_sta_app',
      appChannel: 'release',
      appVersion: '0.2.8',
      appVersionCode: 2800,
    );
    controller.dispose();
    controller = UpdateController(
      api: api,
      bridge: bridge,
      metadataProvider: () async => dynamicMeta,
    );
    await controller.check(manual: true);

    dynamicMeta = const ClientMetadata(
      platform: 'android',
      appPackage: 'dev.duohuo.nuist_sta_app',
      appChannel: 'release',
      appVersion: '0.2.9',
      appVersionCode: 2900,
      anonymousId: 'anon-1',
    );
    await controller.download();
    expect(bridge.lastHeaders, dynamicMeta.headers);

    dynamicMeta = const ClientMetadata(
      platform: 'android',
      appPackage: 'dev.duohuo.nuist_sta_app',
      appChannel: 'release',
      appVersion: '0.2.10',
      appVersionCode: 2901,
      anonymousId: 'anon-2',
    );
    await controller.resume();
    expect(bridge.lastResumeHeaders, dynamicMeta.headers);
    expect(bridge.lastResumeHeaders, isNot(equals(bridge.lastHeaders)));
  });

  test('并发手动检查不被节流跳过阻塞；检查失败不写入 6 小时节流，仅退避 2 分钟', () async {
    // 先完成一次成功检查，进入 6 小时自动节流期。
    await controller.check(manual: true);
    expect(api.checks, 1);
    expect(saved.lastAttempt, now);

    // 自动检查被节流跳过，不应阻塞并发发起的手动检查。
    await Future.wait([controller.onResumed(), controller.check(manual: true)]);
    expect(api.checks, 2);

    // 6 小时后触发失败检查：不更新持久化的 lastAttempt，只设内存 2 分钟冷却。
    now = now.add(const Duration(hours: 6));
    final previousAttempt = saved.lastAttempt;
    api.failed = true;
    await controller.onResumed();
    expect(api.checks, 3);
    expect(controller.checkError, '检查更新失败');
    expect(saved.lastAttempt, previousAttempt);

    // 2 分钟内自动检查被退避拦截，但手动检查仍可立即重试。
    await controller.onResumed();
    expect(api.checks, 3);
    api.failed = false;
    await controller.check(manual: true);
    expect(api.checks, 4);
    expect(controller.checkError, isNull);

    // 再次制造失败并在 2 分钟后允许自动重试。
    now = now.add(const Duration(hours: 6));
    api.failed = true;
    await controller.onResumed();
    expect(api.checks, 5);
    now = now.add(const Duration(minutes: 2));
    api.failed = false;
    await controller.onResumed();
    expect(api.checks, 6);
  });

  testWidgets('深色真实关于入口关闭详情与退出页面不取消下载，disabled 时隐藏检查更新', (tester) async {
    api.value = null;
    await pumpAbout(tester, controller, dark: true);
    api.value = release();
    await tester.tap(find.text('检查更新'));
    await pumpInteraction(tester);
    await tester.tap(
      find.descendant(of: find.byType(SnackBar), matching: find.text('查看')),
    );
    await pumpInteraction(tester);
    await tester.tap(find.text('下载更新'));
    await pumpInteraction(tester);
    expect(bridge.starts, 1);
    expect(find.text('取消下载'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await pumpInteraction(tester);
    expect(find.byType(UpdateDetailsDialog), findsNothing);
    expect(bridge.cancellations, 0);

    await tester.binding.handlePopRoute();
    await pumpInteraction(tester);
    expect(find.byType(AboutPage), findsNothing);
    expect(bridge.cancellations, 0);

    final disabledController = UpdateController(
      api: api,
      bridge: bridge,
      metadataProvider: () async => current,
      disabled: true,
    );
    addTearDown(disabledController.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: appLightTheme(),
        home: AboutPage(updates: disabledController),
      ),
    );
    await pumpInteraction(tester);
    expect(find.text('检查更新'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('壳路由隐藏首页推迟弹窗、回首页触发原地下载及撤包关闭', (tester) async {
    api.value = null;
    final router = buildRouter(
      updateController: controller,
      announcementController: freshAnnouncements(),
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(theme: appLightTheme(), routerConfig: router),
    );
    await tester.pumpAndSettle();
    router.go('/profile');
    await tester.pumpAndSettle();
    api.value = release(popup: true);
    await controller.check(manual: true);
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDetailsDialog), findsNothing);
    router.go('/');
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDetailsDialog), findsOneWidget);
    api.value = null;
    await controller.check(manual: true);
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDetailsDialog), findsNothing);
    api.value = release(revision: 'revision-b', popup: true);
    await controller.check(manual: true);
    await tester.pumpAndSettle();
    await tester.tap(find.text('立即下载'));
    await pumpInteraction(tester);
    expect(bridge.starts, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('被新版本取代的旧任务在详情弹窗中直接展示新版本与下载按钮', (tester) async {
    final revA = release(revision: 'revision-a', changelog: '旧版本日志');
    final revB = release(revision: 'revision-b', changelog: '新版本日志');
    bridge.value = UpdateTask(
      status: UpdateTaskStatus.failed,
      release: revA,
      errorCode: 'incompatible',
    );
    api.value = revB;
    await controller.check(manual: true);
    expect(controller.taskSuperseded, isTrue);

    await tester.pumpWidget(
      MaterialApp(
        theme: appLightTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showUpdateDetails(context, controller: controller),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('新版本日志', findRichText: true), findsOneWidget);
    expect(find.text('下载更新'), findsOneWidget);
    expect(find.text('清除任务'), findsNothing);
    expect(find.text('安装包与当前设备或签名不兼容'), findsNothing);
    await tester.tap(find.text('下载更新'));
    await pumpInteraction(tester);
    expect(bridge.starts, 1);
    expect(controller.task.release?.revision, 'revision-b');
    await tester.tap(find.byTooltip('关闭更新详情'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('incompatible、普通 failed、paused 与 installing 按钮及文案区分', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appLightTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showUpdateDetails(context, controller: controller),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    api.value = release();
    bridge.value = UpdateTask(
      status: UpdateTaskStatus.failed,
      release: release(),
      errorCode: 'incompatible',
    );
    await controller.check(manual: true);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('安装失败'), findsOneWidget);
    expect(find.text('安装包与当前设备或签名不兼容'), findsOneWidget);
    expect(find.text('清除任务'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
    expect(find.text('继续下载'), findsNothing);
    expect(find.text('重新下载'), findsNothing);

    bridge.value = UpdateTask(
      status: UpdateTaskStatus.failed,
      release: release(),
      errorCode: 'network_error',
    );
    bridge.events.add(bridge.value);
    await tester.pumpAndSettle();
    expect(find.text('下载失败'), findsOneWidget);
    expect(find.text('网络连接失败'), findsOneWidget);
    expect(find.text('取消下载'), findsOneWidget);
    expect(find.text('重新下载'), findsOneWidget);

    bridge.value = UpdateTask(
      status: UpdateTaskStatus.paused,
      release: release(),
    );
    bridge.events.add(bridge.value);
    await tester.pumpAndSettle();
    expect(find.text('下载已暂停'), findsOneWidget);
    expect(find.text('继续下载'), findsOneWidget);

    bridge.value = UpdateTask(
      status: UpdateTaskStatus.installing,
      release: release(),
    );
    bridge.events.add(bridge.value);
    await tester.pumpAndSettle();
    expect(find.text('正在安装'), findsOneWidget);
    expect(find.text('取消安装'), findsOneWidget);

    await tester.tap(find.text('取消安装'));
    await pumpInteraction(tester);
    expect(bridge.cancellations, 1);
    expect(find.text('下载更新'), findsOneWidget);
    await tester.tap(find.text('下载更新'));
    await pumpInteraction(tester);
    expect(bridge.starts, 1);

    await tester.tap(find.byTooltip('关闭更新详情'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('首次未选隐私政策时推迟更新检查，选择后触发更新展示', (tester) async {
    api.value = release(popup: true);
    const channel = MethodChannel('nuist/app_update/test_privacy');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => false,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final consent = PrivacyConsent(directory: () async => null);
    await tester.pumpWidget(
      NuistApp(
        updates: controller,
        updateBridge: AppUpdateBridge(channel: channel),
        consent: consent,
      ),
    );
    await tester.pumpAndSettle();
    expect(PrivacyConsent.dialogPending.value, isTrue);
    expect(api.checks, 0);
    expect(find.textContaining('欢迎使用 NUIST++'), findsOneWidget);
    expect(find.byType(UpdateDetailsDialog), findsNothing);

    await tester.tap(find.text('同意'));
    await tester.pumpAndSettle();
    expect(PrivacyConsent.dialogPending.value, isFalse);
    expect(api.checks, 1);
    expect(find.byType(UpdateDetailsDialog), findsOneWidget);

    await tester.tap(find.text('稍后提醒'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });
}
