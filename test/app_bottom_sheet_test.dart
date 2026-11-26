import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/app_manifest.dart';
import 'package:nuist_sta_app/core/app_registry.dart';
import 'package:nuist_sta_app/core/navigation/app_navigation.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/core/ui/app_bottom_sheet.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_manifest.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/router.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_api.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_controller.dart';
import 'package:nuist_sta_app/shell/home/app_grid_item.dart';
import 'package:nuist_sta_app/shell/study/study_page.dart';

Future<bool?> _backGesture(
  WidgetTester tester,
  String method, {
  double progress = 0,
  int edge = 0,
}) async {
  ByteData? response;
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    const StandardMethodCodec().encodeMethodCall(
      MethodCall(method, {
        'touchOffset': [edge == 0 ? 5.0 : 385.0, 300.0],
        'progress': progress,
        'swipeEdge': edge,
      }),
    ),
    (data) => response = data,
  );
  await tester.pumpAndSettle();
  return response == null
      ? null
      : const StandardMethodCodec().decodeEnvelope(response!) as bool?;
}

void main() {
  for (final dark in [false, true]) {
    testWidgets('${dark ? '深色' : '浅色'}底部弹层支持预测性返回缩放、取消保留与提交关闭', (tester) async {
      Object? result = 'unset';
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? appDarkTheme() : appLightTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () {
                  showAppModalBottomSheet<String>(
                    context: context,
                    builder: (_) => const Padding(
                      padding: EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [TextField(key: Key('sheet_input'))],
                      ),
                    ),
                  ).then((value) => result = value);
                },
                child: const Text('打开弹层'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开弹层'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('sheet_input')), '保留输入');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      Transform? sheetTransform() {
        final transforms = tester.widgetList<Transform>(
          find.ancestor(
            of: find.byKey(const Key('sheet_input')),
            matching: find.byType(Transform),
          ),
        );
        for (final t in transforms) {
          if (t.alignment == Alignment.bottomCenter &&
              t.transform.storage[0] < 1.0) {
            return t;
          }
        }
        return null;
      }

      expect(await _backGesture(tester, 'startBackGesture'), isTrue);
      await _backGesture(tester, 'updateBackGestureProgress', progress: 0.5);
      final scaled = sheetTransform();
      expect(scaled, isNotNull);
      expect(scaled!.transform.storage[0], lessThan(1.0));
      expect(scaled.transform.storage[5], lessThan(1.0));

      // 遮罩层不应跟随缩放。
      expect(
        find.ancestor(
          of: find.byType(ModalBarrier).last,
          matching: find.byWidgetPredicate(
            (w) =>
                w is Transform &&
                w.alignment == Alignment.bottomCenter &&
                w.transform.storage[0] < 1.0,
          ),
        ),
        findsNothing,
      );

      await _backGesture(tester, 'cancelBackGesture');
      expect(sheetTransform(), isNull);
      expect(find.text('保留输入'), findsOneWidget);

      expect(await _backGesture(tester, 'startBackGesture'), isTrue);
      await _backGesture(tester, 'updateBackGestureProgress', progress: 0.6);
      await _backGesture(tester, 'commitBackGesture');
      expect(find.byKey(const Key('sheet_input')), findsNothing);
      expect(result, isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('底部弹层内部 PopScope(canPop: false) 时不接手缩放，保留拦截回调', (tester) async {
    var intercepted = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: appLightTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                showAppModalBottomSheet<void>(
                  context: context,
                  builder: (_) => PopScope(
                    canPop: false,
                    onPopInvokedWithResult: (didPop, _) {
                      if (!didPop) intercepted++;
                    },
                    child: const SizedBox(height: 160, child: Text('受保护弹层')),
                  ),
                );
              },
              child: const Text('打开受保护弹层'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开受保护弹层'));
    await tester.pumpAndSettle();

    expect(await _backGesture(tester, 'startBackGesture'), isFalse);
    await _backGesture(tester, 'commitBackGesture');
    expect(intercepted, 1);
    expect(find.text('受保护弹层'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('宽屏双栏下非目标栏的底部弹层不接手手势，目标栏接手；真实课表入口弹层可用', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = TimetableController.instance;
    final originalClock = TimetableController.clock;
    final originalBinding = TimetableController.bindingCheck;
    final directory = Directory.systemTemp.createTempSync('app-bottom-sheet-');
    TimetableStore.debugDirectory = directory;
    TimetableController.clock = () => DateTime(2026, 11, 16, 8);
    TimetableController.bindingCheck = () async => false;
    controller.debugReset();
    controller.debugSetSnapshot(
      TimetableSnapshot(
        periods: TimetableController.defaultPeriods(),
        settings: TimetableSettings(termStartDate: DateTime(2026, 11, 2)),
      ),
    );
    addTearDown(() {
      TimetableStore.debugDirectory = null;
      TimetableController.clock = originalClock;
      TimetableController.bindingCheck = originalBinding;
      controller.debugReset();
      directory.deleteSync(recursive: true);
    });

    final navigation = AppNavigationController();
    final notices = AnnouncementController.test(
      fetch: ({etag, lastModified}) async =>
          const AnnouncementFetchResult(notModified: false, items: []),
    );
    final router = buildRouter(
      navigation: navigation,
      announcementController: notices,
      registry: AppRegistry([
        timetableManifest,
        AppManifest(
          id: 'study-probe',
          label: '学习测试',
          color: Colors.blue,
          showInHomeGrid: false,
          entry: (_) => const SizedBox.shrink(),
          studyCard: StudyCardContribution(
            builder: (_) => Builder(
              builder: (context) => TextButton(
                onPressed: () {
                  showAppModalBottomSheet<void>(
                    context: context,
                    useRootNavigator: false,
                    builder: (_) =>
                        const SizedBox(height: 160, child: Text('右栏弹层')),
                  );
                },
                child: const Text('打开右栏弹层'),
              ),
            ),
            order: 0,
          ),
        ),
      ]),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      navigation.dispose();
      router.dispose();
      notices.dispose();
    });

    await tester.pumpWidget(
      MaterialApp.router(theme: appLightTheme(), routerConfig: router),
    );
    await tester.pumpAndSettle();

    // 在右栏打开一个局部底部弹层，然后切到左栏，右栏弹层不应接手手势。
    await tester.tap(find.text('打开右栏弹层'));
    await tester.pumpAndSettle();
    expect(find.text('右栏弹层'), findsOneWidget);

    await tester.tap(find.widgetWithText(AppGridItem, '课表'));
    await tester.pumpAndSettle();
    expect(navigation.activeIndex, 0);

    // 左栏进入课表后，左栏自己是返回目标，右栏弹层不抢手势；验证左栏课表真实入口打开的弹层能接手。
    await tester.tap(
      find.byKey(const Key('timetable_schedule_switcher_button')),
    );
    await tester.pumpAndSettle();
    expect(find.text('切换周数与课表'), findsOneWidget);
    expect(await _backGesture(tester, 'startBackGesture'), isTrue);
    await _backGesture(tester, 'commitBackGesture');
    expect(find.text('切换周数与课表'), findsNothing);
    expect(find.text('右栏弹层'), findsOneWidget);

    // 切回右栏后，右栏弹层可正常接手手势并关闭。
    navigation.interact(1);
    await tester.pumpAndSettle();
    expect(await _backGesture(tester, 'startBackGesture'), isTrue);
    await _backGesture(tester, 'commitBackGesture');
    expect(find.text('右栏弹层'), findsNothing);
    expect(find.byType(StudyPage), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
