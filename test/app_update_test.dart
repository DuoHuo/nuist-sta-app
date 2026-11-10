import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nuist_sta_app/app.dart';
import 'package:nuist_sta_app/core/network/client_metadata.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/router.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_api.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_controller.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_models.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_overlay.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_sheet.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_web_page.dart';
import 'package:nuist_sta_app/shell/profile/about/about_page.dart';
import 'package:nuist_sta_app/shell/update/update_api.dart';
import 'package:nuist_sta_app/shell/update/update_bridge.dart';
import 'package:nuist_sta_app/shell/update/update_controller.dart';
import 'package:nuist_sta_app/shell/update/update_models.dart';
import 'package:nuist_sta_app/shell/update/update_dialog.dart';
import 'package:nuist_sta_app/shell/update/update_markdown.dart';
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
  Future<UpdateTask> resume() async {
    resumes++;
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

Future<void> backGesture(
  WidgetTester tester,
  String method, [
  double progress = 0,
]) async {
  ByteData? response;
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    const StandardMethodCodec().encodeMethodCall(
      MethodCall(method, {
        'touchOffset': [5.0, 300.0],
        'progress': progress,
        'swipeEdge': 0,
      }),
    ),
    (value) => response = value,
  );
  if (method == 'startBackGesture') {
    expect(const StandardMethodCodec().decodeEnvelope(response!), isTrue);
  }
  await pumpInteraction(tester);
}

void main() {
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

  for (final allowed in [true, false]) {
    test('安装来源${allowed ? '授权' : '拒绝'}返回早于设置通道完成仍只消费一次', () async {
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
    });
  }

  for (final outcome in ['拒绝授权', '设置打开失败']) {
    test('$outcome 不留下自动安装请求，用户可以重新操作', () async {
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
    });
  }

  for (final outcome in ['取消任务', '更换修订', '不再就绪', '撤包']) {
    test('安装来源授权期间$outcome 不自动安装', () async {
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
      expect(bridge.installs, 0);
      expect(bridge.cancellations, outcome == '撤包' ? 1 : 0);
      bridge.value = readyTask(allowed: true);
      await controller.onResumed();
      expect(bridge.installs, 0);
    });
  }

  for (final revoked in [true, false]) {
    test('授权续装复查期间任务更换，旧修订${revoked ? '撤包' : '可用'}均不安装或取消新任务', () async {
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
    });
  }

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
    test('服务端下发即接受，${metadata.appChannel ?? '缺少元数据'}不在本地判断兼容性', () async {
      controller.dispose();
      controller = UpdateController(
        api: api,
        bridge: bridge,
        metadataProvider: () async => metadata,
      );
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
    });
  }

  for (final dark in [false, true]) {
    for (final popup in [false, true]) {
      testWidgets(
        '${dark ? '深色' : '浅色'}真实公告列表关闭后补展示晚到的${popup ? '更新弹窗' : '更新悬浮条'}，关闭后不重复',
        (tester) async {
          api.pending = Completer<UpdateRelease?>();
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
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('公告'));
          await tester.pumpAndSettle();
          expect(find.text('暂无公告'), findsOneWidget);

          api.pending!.complete(release(popup: popup));
          await tester.pumpAndSettle();
          expect(find.byType(UpdateDetailsDialog), findsNothing);
          expect(find.byTooltip('收起'), findsNothing);
          expect(
            popup ? controller.shouldPrompt : controller.shouldShowBanner,
            isTrue,
          );
          expect(find.text('发现新版本 v0.2.9'), findsOneWidget);
          expect(find.text('查看更新'), findsOneWidget);
          expect(
            tester
                .widget<AnnouncementDialog>(find.byType(AnnouncementDialog))
                .items
                .first
                .id,
            'app-update:revision-a',
          );

          await tester.tap(find.text('我知道了'));
          await tester.pumpAndSettle();
          expect(find.text('发现新版本 v0.2.9'), findsOneWidget);
          if (popup) {
            expect(find.byType(UpdateDetailsDialog), findsOneWidget);
            await tester.tap(find.text('稍后提醒'));
          } else {
            expect(find.byType(UpdateDetailsDialog), findsNothing);
            await tester.tap(find.byTooltip('收起'));
          }
          await tester.pumpAndSettle();
          await controller.refreshTask();
          await tester.pumpAndSettle();
          expect(find.text('发现新版本 v0.2.9'), findsNothing);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }

    testWidgets('${dark ? '深色' : '浅色'}公告列表转进真实详情入口时不抢弹，返回首页后补展示', (
      tester,
    ) async {
      final previousBuilder = announcementWebPageBuilder;
      addTearDown(() => announcementWebPageBuilder = previousBuilder);
      // 只替换平台 WebView 内容，保留公告按钮实际的关闭与导航逻辑。
      announcementWebPageBuilder = (_) =>
          Scaffold(appBar: AppBar(title: const Text('公告网页')));
      final announcements = AnnouncementController.test(
        fetch: ({etag, lastModified}) async => const AnnouncementFetchResult(
          notModified: false,
          items: [
            Announcement(
              id: 'detail',
              title: '普通公告',
              link: AnnouncementLink(
                label: '公告详情',
                url: 'https://example.com/detail',
              ),
            ),
          ],
        ),
      );
      addTearDown(announcements.dispose);
      api.pending = Completer<UpdateRelease?>();
      final router = buildRouter(
        updateController: controller,
        announcementController: announcements,
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          theme: dark ? appDarkTheme() : appLightTheme(),
          routerConfig: router,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('公告'));
      await tester.pumpAndSettle();
      api.pending!.complete(release(popup: true));
      await tester.pumpAndSettle();
      await tester.tap(find.text('公告详情'));
      await tester.pumpAndSettle();
      expect(find.text('公告网页'), findsOneWidget);
      expect(find.byType(UpdateDetailsDialog), findsNothing);
      expect(controller.shouldPrompt, isTrue);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('公告网页'), findsNothing);
      expect(find.byType(UpdateDetailsDialog), findsOneWidget);
      await tester.tap(find.text('稍后提醒'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('${dark ? '深色' : '浅色'}更新伪公告并入悬浮条和公告列表，不自动弹窗', (tester) async {
      final announcements = AnnouncementController.test(
        fetch: ({etag, lastModified}) async => AnnouncementFetchResult(
          notModified: false,
          items: [
            Announcement(
              id: 'notice',
              title: '普通公告',
              publishedAt: DateTime.utc(2026, 11, 10),
              remind: AnnouncementRemind.badge,
            ),
            Announcement(
              id: 'pinned-old',
              title: '置顶旧公告',
              pinned: true,
              publishedAt: DateTime.utc(2026, 11, 11),
            ),
            Announcement(
              id: 'notice-new',
              title: '普通新公告',
              publishedAt: DateTime.utc(2026, 11, 14),
            ),
            Announcement(
              id: 'pinned-new',
              title: '置顶新公告',
              pinned: true,
              publishedAt: DateTime.utc(2026, 11, 13),
            ),
          ],
        ),
      );
      addTearDown(announcements.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? appDarkTheme() : appLightTheme(),
          home: Scaffold(
            appBar: AppBar(
              actions: [
                AnnouncementBell(
                  controller: announcements,
                  updates: controller,
                ),
              ],
            ),
            body: AnnouncementOverlay(
              controller: announcements,
              updates: controller,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(UpdateDetailsDialog), findsNothing);
      expect(find.text('共 2 条公告'), findsOneWidget);
      await tester.tap(find.byTooltip('公告'));
      await tester.pumpAndSettle();
      expect(find.text('普通公告'), findsWidgets);
      expect(find.text('发现新版本 v0.2.9'), findsOneWidget);
      expect(find.text('查看更新'), findsOneWidget);
      final realOrder = ['pinned-new', 'pinned-old', 'notice-new', 'notice'];
      expect(
        tester
            .widget<AnnouncementDialog>(find.byType(AnnouncementDialog))
            .items
            .map((item) => item.id),
        ['app-update:revision-a', ...realOrder],
      );
      expect(controller.hasUnreadAnnouncement, isFalse);
      // 已打开的列表不随提醒方式变化移除更新，只有候选撤回才移除。
      for (final popup in [true, false]) {
        api.value = release(popup: popup);
        await controller.check(manual: true);
        await tester.pumpAndSettle();
        expect(find.byType(UpdateDetailsDialog), findsNothing);
        expect(find.text('查看更新'), findsOneWidget);
        expect(find.text('共 2 条公告'), popup ? findsNothing : findsOneWidget);
        expect(
          tester
              .widget<AnnouncementDialog>(find.byType(AnnouncementDialog))
              .items
              .map((item) => item.id),
          ['app-update:revision-a', ...realOrder],
        );
      }
      await tester.tap(find.text('查看更新'));
      await tester.pumpAndSettle();
      expect(find.byType(AnnouncementDialog), findsNothing);
      expect(find.byType(UpdateDetailsDialog), findsOneWidget);
      await tester.tap(find.byTooltip('关闭更新详情'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('公告'));
      await tester.pumpAndSettle();
      api.value = null;
      await controller.check(manual: true);
      await tester.pumpAndSettle();
      // 已经打开的列表同步移除撤包更新，真实公告仍然可读。
      expect(find.text('查看更新'), findsNothing);
      expect(find.text('普通公告'), findsWidgets);
      expect(
        tester
            .widget<AnnouncementDialog>(find.byType(AnnouncementDialog))
            .items
            .map((item) => item.id),
        realOrder,
      );
      await tester.tap(find.text('我知道了'));
      await tester.pumpAndSettle();
      expect(find.text('共 2 条公告'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('${dark ? '深色' : '浅色'}开启弹窗的更新仍置顶公告列表，查看后不再重复弹出', (
      tester,
    ) async {
      api.value = release(popup: true);
      final announcements = AnnouncementController.test(
        fetch: ({etag, lastModified}) async => AnnouncementFetchResult(
          notModified: false,
          items: [
            Announcement(
              id: 'pinned',
              title: '置顶公告',
              pinned: true,
              publishedAt: DateTime.utc(2026, 11, 12),
            ),
            Announcement(
              id: 'recent',
              title: '最新普通公告',
              publishedAt: DateTime.utc(2026, 11, 13),
            ),
          ],
        ),
      );
      addTearDown(announcements.dispose);
      final router = buildRouter(
        updateController: controller,
        announcementController: announcements,
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          theme: dark ? appDarkTheme() : appLightTheme(),
          routerConfig: router,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(UpdateDetailsDialog), findsOneWidget);
      await tester.tap(find.text('稍后提醒'));
      await tester.pumpAndSettle();
      expect(find.byType(UpdateDetailsDialog), findsNothing);
      expect(find.byTooltip('收起'), findsNothing);
      await tester.tap(find.byTooltip('公告'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AnnouncementDialog>(find.byType(AnnouncementDialog))
            .items
            .map((item) => item.id),
        ['app-update:revision-a', 'pinned', 'recent'],
      );
      expect(find.text('查看更新'), findsOneWidget);
      await tester.tap(find.text('查看更新'));
      await tester.pumpAndSettle();
      expect(find.byType(AnnouncementDialog), findsNothing);
      expect(find.byType(UpdateDetailsDialog), findsOneWidget);
      expect(find.text('下载更新'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭更新详情'));
      await tester.pumpAndSettle();
      expect(find.byType(UpdateDetailsDialog), findsNothing);
      expect(find.byTooltip('收起'), findsNothing);
      await tester.tap(find.byTooltip('公告'));
      await tester.pumpAndSettle();
      api.value = null;
      await controller.check(manual: true);
      await tester.pumpAndSettle();
      expect(find.text('查看更新'), findsNothing);
      expect(
        tester
            .widget<AnnouncementDialog>(find.byType(AnnouncementDialog))
            .items
            .map((item) => item.id),
        ['pinned', 'recent'],
      );
      await tester.tap(find.text('我知道了'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    });

    for (final outcome in ['update', 'none', 'failed']) {
      testWidgets('${dark ? '深色' : '浅色'}关于页手动检查 $outcome 只显示底部浮条', (
        tester,
      ) async {
        api.value = null;
        await pumpAbout(tester, controller, dark: dark);
        final previousChecks = api.checks;
        api.value = outcome == 'update' ? release(popup: true) : null;
        api.failed = outcome == 'failed';
        await tester.tap(find.text('检查更新'));
        await pumpInteraction(tester);
        expect(api.checks, previousChecks + 1);
        expect(
          GoRouterState.of(tester.element(find.byType(AboutPage))).uri.path,
          '/about',
        );
        expect(find.byType(UpdateDetailsDialog), findsNothing);
        expect(find.byType(SnackBar), findsOneWidget);
        final message = switch (outcome) {
          'update' => '发现新版本 v0.2.9',
          'none' => '暂无新版本',
          _ => '检查更新失败',
        };
        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.text(message),
          ),
          findsOneWidget,
        );
        if (outcome == 'update') {
          await tester.tap(
            find.descendant(
              of: find.byType(SnackBar),
              matching: find.text('查看'),
            ),
          );
          await pumpInteraction(tester);
          expect(find.byType(UpdateDetailsDialog), findsOneWidget);
          expect(
            GoRouterState.of(tester.element(find.byType(AboutPage))).uri.path,
            '/about',
          );
          await tester.tap(find.byTooltip('关闭更新详情'));
          await pumpInteraction(tester);
        }
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('${dark ? '深色' : '浅色'}真实关于入口关闭详情不取消下载，页面预测返回可取消和完成', (
      tester,
    ) async {
      api.value = null;
      await pumpAbout(tester, controller, dark: dark);
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
      // 系统返回先关闭真实详情弹层，不影响后面的关于页和下载任务。
      await tester.binding.handlePopRoute();
      await pumpInteraction(tester);
      expect(find.byType(UpdateDetailsDialog), findsNothing);
      expect(
        GoRouterState.of(tester.element(find.byType(AboutPage))).uri.path,
        '/about',
      );
      expect(bridge.cancellations, 0);
      await tester.tap(find.text('下载进度'));
      await pumpInteraction(tester);
      expect(find.byType(UpdateDetailsDialog), findsOneWidget);
      expect(find.text('取消下载'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭更新详情'));
      await pumpInteraction(tester);

      final pageContext = tester.element(find.byType(AboutPage));
      final route = ModalRoute.of(pageContext)! as PageRoute;
      expect(route.popGestureEnabled, isTrue);
      await backGesture(tester, 'startBackGesture');
      await backGesture(tester, 'updateBackGestureProgress', 0.4);
      expect(route.animation!.value, closeTo(0.6, 0.001));
      await backGesture(tester, 'cancelBackGesture');
      expect(find.byType(AboutPage), findsOneWidget);
      await backGesture(tester, 'startBackGesture');
      await backGesture(tester, 'updateBackGestureProgress', 0.4);
      await backGesture(tester, 'commitBackGesture');
      expect(find.byType(AboutPage), findsNothing);
      expect(find.text('首页'), findsOneWidget);
      expect(bridge.cancellations, 0);
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('自动更新提示原地下载，关闭后不重复弹出', (tester) async {
    api.value = release(popup: true);
    final router = buildRouter(
      updateController: controller,
      announcementController: freshAnnouncements(),
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(theme: appLightTheme(), routerConfig: router),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('立即下载'));
    await pumpInteraction(tester);
    expect(bridge.starts, 1);
    expect(find.byType(UpdateDetailsDialog), findsOneWidget);
    expect(find.text('取消下载'), findsOneWidget);
    expect(router.routerDelegate.currentConfiguration.uri.path, '/');
    await tester.tap(find.byTooltip('关闭更新详情'));
    await pumpInteraction(tester);
    expect(find.byType(UpdateDetailsDialog), findsNothing);
    expect(bridge.cancellations, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('真实壳路由隐藏首页时不弹更新，回首页才弹，撤包后自动关闭', (tester) async {
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
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('公告更新入口打开同一详情，关闭后仍保留首页', (tester) async {
    final router = buildRouter(
      updateController: controller,
      announcementController: freshAnnouncements(),
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(theme: appDarkTheme(), routerConfig: router),
    );
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 v0.2.9'), findsOneWidget);
    await tester.tap(find.byTooltip('公告'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看更新'));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDetailsDialog), findsOneWidget);
    expect(router.routerDelegate.currentConfiguration.uri.path, '/');
    await tester.tap(find.byTooltip('关闭更新详情'));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDetailsDialog), findsNothing);
    expect(find.text('首页'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('关于页连续点击共用检查请求，完成后只出现一条结果', (tester) async {
    api.value = null;
    await pumpAbout(tester, controller);
    final previousChecks = api.checks;
    api.pending = Completer<UpdateRelease?>();
    await tester.tap(find.text('检查更新'));
    await tester.tap(find.text('检查更新'));
    await pumpInteraction(tester);
    expect(api.checks, previousChecks + 1);
    expect(find.byType(SnackBar), findsNothing);
    api.pending!.complete(release());
    await pumpInteraction(tester);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.byType(UpdateDetailsDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('离开关于页后浮条查看仍能打开详情', (tester) async {
    api.value = null;
    final router = await pumpAbout(tester, controller);
    api.value = release(popup: true);
    await tester.tap(find.text('检查更新'));
    await pumpInteraction(tester);
    router.pop();
    await pumpInteraction(tester);
    expect(find.byType(AboutPage), findsNothing);
    await tester.tap(
      find.descendant(of: find.byType(SnackBar), matching: find.text('查看')),
    );
    await pumpInteraction(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(UpdateDetailsDialog), findsOneWidget);
    await tester.tap(find.byTooltip('关闭更新详情'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  for (final coldStart in [true, false]) {
    testWidgets('真实应用${coldStart ? '冷启动' : '前台'}通知打开详情，重复通知不叠加页面', (
      tester,
    ) async {
      api.value = null;
      const channel = MethodChannel('nuist/app_update/test_notification');
      var launchReads = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        expect(call.method, 'takeLaunchRequest');
        launchReads++;
        return coldStart;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      if (coldStart) bridge.pendingState = Completer<UpdateTask>();
      await tester.pumpWidget(
        NuistApp(
          updates: controller,
          updateBridge: AppUpdateBridge(channel: channel),
        ),
      );
      await pumpInteraction(tester);
      expect(launchReads, 1);
      expect(find.byType(UpdateDetailsDialog), findsNothing);
      GoRouter? router;
      if (!coldStart) {
        router = GoRouter.of(tester.element(find.text('NUIST++')));
        router.push('/about');
        await pumpInteraction(tester);
      }
      bridge.value = UpdateTask(
        status: UpdateTaskStatus.ready,
        release: release(),
        totalBytes: release().size,
        downloadedBytes: release().size,
        installAllowed: true,
      );
      if (coldStart) {
        bridge.pendingState!.complete(bridge.value);
      }
      Future<void> notify() =>
          tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('onOpenUpdate'),
            ),
            (_) {},
          );
      await notify();
      await pumpInteraction(tester);
      await pumpInteraction(tester);
      expect(find.byType(UpdateDetailsDialog), findsOneWidget);
      expect(find.text('安装更新'), findsOneWidget);
      await notify();
      await pumpInteraction(tester);
      expect(find.byType(UpdateDetailsDialog), findsOneWidget);
      await tester.tap(find.byTooltip('关闭更新详情'));
      await pumpInteraction(tester);
      expect(find.byType(UpdateDetailsDialog), findsNothing);
      if (coldStart) {
        expect(find.text('首页'), findsOneWidget);
      } else {
        expect(find.byType(AboutPage), findsOneWidget);
        expect(router!.canPop(), isTrue);
      }
      expect(bridge.cancellations, 0);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('详情重复入口共用弹层，关闭后可以重新打开，空日志不占位', (tester) async {
    api.value = release(changelog: '   ');
    await controller.onLaunch();
    Future<void>? first;
    Future<void>? second;
    await tester.pumpWidget(
      MaterialApp(
        theme: appLightTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                first = showUpdateDetails(context, controller: controller);
                second = showUpdateDetails(context, controller: controller);
              },
              child: const Text('查看详情'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();
    expect(second, same(first));
    expect(find.byType(UpdateDetailsDialog), findsOneWidget);
    expect(find.byType(UpdateChangelog), findsNothing);
    expect(find.text('此版本暂无更新日志'), findsNothing);
    await tester.tap(find.byTooltip('关闭更新详情'));
    await tester.pumpAndSettle();
    await first;
    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDetailsDialog), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  for (final dark in [false, true]) {
    for (final size in [const Size(320, 600), const Size(600, 320)]) {
      testWidgets(
        '${dark ? '深色' : '浅色'} ${size.width.toInt()}×${size.height.toInt()} 大字号长 Markdown 可滚动且操作可达',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final longCode = List.filled(24, 'value').join(' + ');
          final longCell = List.filled(12, '长表格内容').join();
          final content = [
            '# Markdown 标题',
            '',
            '**粗体内容**与*斜体内容*以及`行内代码`',
            '',
            '- 无序列表项目',
            '',
            '1. 有序列表项目',
            '',
            '> 引用内容',
            '',
            '```dart',
            longCode,
            '```',
            '',
            '| 项目 | 结果 |',
            '| --- | --- |',
            '| $longCell | 表格内容 |',
            '',
            for (var i = 0; i < 220; i++) ...['第 $i 条更新：支持长日志阅读，保留完整说明。', ''],
            '日志末尾标记',
          ].join('\n');
          api.value = release(changelog: content);
          await controller.onLaunch();
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? appDarkTheme() : appLightTheme(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.8)),
                child: child!,
              ),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () =>
                        showUpdateDetails(context, controller: controller),
                    child: const Text('查看详情'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('查看详情'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Markdown 标题', findRichText: true), findsWidgets);
          expect(find.text('# Markdown 标题', findRichText: true), findsNothing);
          final scroll = tester
              .widget<SingleChildScrollView>(
                find.byKey(const ValueKey('update-changelog-scroll')),
              )
              .controller!;
          expect(scroll.position.maxScrollExtent, greaterThan(1000));
          scroll.jumpTo(scroll.position.maxScrollExtent);
          await tester.pump();
          expect(
            find.text('日志末尾标记', findRichText: true).hitTestable(),
            findsWidgets,
          );
          final markdown = tester.widget<UpdateChangelog>(
            find.byType(UpdateChangelog),
          );
          final beforeDownloadOffset = scroll.offset;
          await tester.ensureVisible(find.text('下载更新'));
          await tester.tap(find.text('下载更新'));
          await pumpInteraction(tester);
          expect(bridge.starts, 1);
          bridge.value = UpdateTask(
            status: UpdateTaskStatus.downloading,
            release: UpdateRelease.fromJson(api.value!.toJson()),
            downloadedBytes: 10000000,
            totalBytes: api.value!.size,
          );
          bridge.events.add(bridge.value);
          await tester.pump();
          expect(
            tester.widget<UpdateChangelog>(find.byType(UpdateChangelog)),
            same(markdown),
          );
          expect(scroll.offset, beforeDownloadOffset);
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(find.text('关闭'));
          await tester.tap(find.text('关闭'));
          await tester.pumpAndSettle();
          expect(find.byType(UpdateDetailsDialog), findsNothing);
          expect(bridge.cancellations, 0);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('Markdown 链接复用网页入口，返回后保留原详情和日志', (tester) async {
    final previousBuilder = announcementWebPageBuilder;
    addTearDown(() => announcementWebPageBuilder = previousBuilder);
    announcementWebPageBuilder = (link) => Scaffold(
      appBar: AppBar(title: Text(link.label)),
      body: const Text('链接网页内容'),
    );
    api.value = release(changelog: '[更新说明](https://example.com/release)');
    await controller.onLaunch();
    await tester.pumpWidget(
      MaterialApp(
        theme: appLightTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showUpdateDetails(context, controller: controller),
              child: const Text('查看详情'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新说明', findRichText: true).last);
    await tester.pumpAndSettle();
    expect(find.text('链接网页内容'), findsOneWidget);
    expect(
      find.byType(UpdateDetailsDialog, skipOffstage: false),
      findsOneWidget,
    );
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDetailsDialog), findsOneWidget);
    expect(find.text('更新说明', findRichText: true), findsWidgets);
    await tester.tap(find.byTooltip('关闭更新详情'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });
}
