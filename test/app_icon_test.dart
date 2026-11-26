import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/logging/app_log.dart';
import 'package:nuist_sta_app/shell/profile/settings/app_icon_bridge.dart';
import 'package:nuist_sta_app/shell/profile/settings/app_icon_controller.dart';
import 'package:nuist_sta_app/shell/profile/settings/app_icon_models.dart';
import 'package:nuist_sta_app/shell/profile/settings/app_icon_page.dart';

const _defaultState = AppIconState(
  supported: true,
  builtinId: AppIconIds.defaultIcon,
  canPin: true,
  customPinned: false,
  pending: false,
);

AppIconState _state({
  String builtinId = AppIconIds.defaultIcon,
  bool supported = true,
  bool canPin = true,
  bool customPinned = false,
  bool pending = false,
  Uint8List? customIcon,
}) => AppIconState(
  supported: supported,
  builtinId: builtinId,
  canPin: canPin,
  customPinned: customPinned,
  pending: pending,
  customIcon: customIcon,
);

class _FakeBridge implements AppIconBridge {
  _FakeBridge({AppIconState state = _defaultState})
    : pickResult = null,
      current = state;

  AppIconState current;
  Uint8List? pickResult;
  Completer<AppIconState>? builtinGate;
  Completer<AppIconState>? customGate;
  Completer<AppIconState>? pinGate;
  Completer<Uint8List?>? pickGate;
  Object? builtinError;
  Object? pickError;
  Object? customError;
  Object? pinError;
  int getStateCalls = 0;
  int setBuiltinCalls = 0;
  int pickCalls = 0;
  int setCustomCalls = 0;
  int pinCalls = 0;
  final builtinIds = <String>[];

  @override
  Future<AppIconState> getState() async {
    getStateCalls++;
    return current;
  }

  @override
  Future<AppIconState> setBuiltin(String id) async {
    setBuiltinCalls++;
    builtinIds.add(id);
    if (builtinError != null) throw builtinError!;
    if (builtinGate != null) return builtinGate!.future;
    current = _state(
      builtinId: id,
      canPin: current.canPin,
      customPinned: current.customPinned,
      pending: current.pending,
      customIcon: current.customIcon,
    );
    return current;
  }

  @override
  Future<Uint8List?> pickImage() async {
    pickCalls++;
    if (pickError != null) throw pickError!;
    if (pickGate != null) return pickGate!.future;
    return pickResult;
  }

  @override
  Future<AppIconState> setCustomIcon(Uint8List pngBytes) async {
    setCustomCalls++;
    if (customError != null) throw customError!;
    if (customGate != null) return customGate!.future;
    current = _state(
      builtinId: current.builtinId,
      canPin: current.canPin,
      customPinned: true,
      customIcon: pngBytes,
    );
    return current;
  }

  @override
  Future<AppIconState> pinCustomIcon() async {
    pinCalls++;
    if (pinError != null) throw pinError!;
    if (pinGate != null) return pinGate!.future;
    current = _state(
      builtinId: current.builtinId,
      canPin: current.canPin,
      customPinned: true,
      customIcon: current.customIcon,
    );
    return current;
  }
}

Uint8List _wideImage() =>
    File('test/fixtures/app_icon_wide.png').readAsBytesSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('内置图标保持默认顺序并识别所有已保存的标识', () {
    expect(appIconChoices.map((choice) => choice.id), [
      AppIconIds.defaultIcon,
      AppIconIds.mascot,
      AppIconIds.mascotColor,
      AppIconIds.alt,
    ]);
    for (final choice in appIconChoices) {
      final state = AppIconState.fromPlatform({
        'supported': true,
        'builtinId': choice.id,
      });
      expect(state.choice, same(choice));
    }
    expect(
      AppIconState.fromPlatform({'builtinId': 'unknown'}).builtinId,
      AppIconIds.defaultIcon,
    );
  });

  testWidgets('窄屏大字号仍能一排显示四款图标并切换新图标', (tester) async {
    tester.view.physicalSize = const Size(640, 1280);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final bridge = _FakeBridge();
    final controller = AppIconController(bridge: bridge);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery.withClampedTextScaling(
          minScaleFactor: 2,
          maxScaleFactor: 2,
          child: child!,
        ),
        home: AppIconPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    final cards = [
      for (final choice in appIconChoices)
        find.byKey(ValueKey('app_icon_choice_${choice.id}')),
    ];
    final first = tester.getRect(cards.first);
    var previousRight = 0.0;
    for (final card in cards) {
      final rect = tester.getRect(card);
      expect(rect.top, first.top);
      expect(rect.bottom, first.bottom);
      expect(rect.left, greaterThan(previousRight));
      expect(rect.right, lessThanOrEqualTo(320));
      previousRight = rect.right;
    }
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('app_icon_choice_alt')));
    await tester.pumpAndSettle();
    expect(bridge.builtinIds, [AppIconIds.alt]);
    expect(controller.state.builtinId, AppIconIds.alt);
    expect(find.text('已切换为「海海」图标'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('已释放控制器拒绝所有操作，不调用原生桥接', () async {
    final bridge = _FakeBridge(state: _state(customIcon: _wideImage()));
    final controller = AppIconController(bridge: bridge);
    await controller.ensureStarted();
    controller.dispose();

    expect(await controller.setBuiltin(AppIconIds.mascot), isFalse);
    expect(await controller.pickImage(), isNull);
    expect(await controller.setCustomIcon(_wideImage()), isFalse);
    expect(await controller.pinCustomIcon(), isFalse);
    expect(bridge.setBuiltinCalls, 0);
    expect(bridge.pickCalls, 0);
    expect(bridge.setCustomCalls, 0);
    expect(bridge.pinCalls, 0);
  });

  test('控制器失败后可用同一实例重试并恢复', () async {
    final bridge = _FakeBridge()
      ..builtinError = const AppIconBridgeException('icon_failed');
    final controller = AppIconController(bridge: bridge);
    addTearDown(controller.dispose);
    await controller.ensureStarted();

    expect(await controller.setBuiltin(AppIconIds.mascot), isFalse);
    expect(controller.error, isTrue);

    bridge.builtinError = null;
    expect(await controller.setBuiltin(AppIconIds.mascot), isTrue);
    expect(controller.error, isFalse);
    expect(controller.state.builtinId, AppIconIds.mascot);
  });

  test('所有平台失败保留原生原因和堆栈，诊断经统一出口脱敏', () async {
    const channel = MethodChannel('nuist/app_icon');
    final bridge = MethodChannelAppIconBridge(channel: channel);
    final records = <Map<String, Object?>>[];
    AppLog.recordListenerForTesting = records.add;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'synthetic_native_code',
            message: '合成存储失败',
            details: {
              'stage': 'custom.save',
              'cause_chain': [
                {
                  'type': 'java.io.IOException',
                  'message': 'No space left on device',
                  'stack_trace': 'synthetic.native.storage.frame',
                },
              ],
              'ticket': 'synthetic-private-ticket',
            },
          );
        });
    addTearDown(() {
      AppLog.recordListenerForTesting = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    for (final (method, invoke) in <(String, Future<Object?> Function())>[
      ('getState', bridge.getState),
      ('setBuiltin', () => bridge.setBuiltin(AppIconIds.mascot)),
      ('pickImage', bridge.pickImage),
      ('setCustomIcon', () => bridge.setCustomIcon(_wideImage())),
      ('pinCustomIcon', bridge.pinCustomIcon),
    ]) {
      await expectLater(
        AppLog.logger('test.app_icon').operation(method, invoke),
        throwsA(
          isA<AppIconBridgeException>()
              .having((error) => error.kind, 'kind', 'platform_error')
              .having((error) => error.method, 'method', method)
              .having((error) => error.cause, 'cause', isA<PlatformException>())
              .having((error) => error.causeStackTrace, '原始通道堆栈', isNotNull)
              .having(
                (error) => error.causeStackTrace.toString(),
                '原始通道堆栈',
                isNotEmpty,
              ),
        ),
      );
      final details = AppLog.formatDetails(records.last);
      expect(details, contains('synthetic_native_code'));
      expect(details, contains('No space left on device'));
      expect(details, contains('synthetic.native.storage.frame'));
      expect(details, isNot(contains('synthetic-private-ticket')));
    }
  });

  test('读取状态和选图成功时保留原生降级诊断，兼容字节回执', () async {
    const channel = MethodChannel('nuist/app_icon');
    final records = <Map<String, Object?>>[];
    AppLog.recordListenerForTesting = records.add;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => {
            'supported': true,
            'builtinId': 'default',
            if (call.method == 'pickImage') 'bytes': _wideImage(),
            'diagnostics': [
              {
                'stage': 'icon.recover',
                'cause_chain': [
                  {
                    'message': 'synthetic recovery failure',
                    'stack_trace': 'synthetic.native.recovery.frame',
                  },
                ],
              },
            ],
          },
        );
    addTearDown(() {
      AppLog.recordListenerForTesting = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final bridge = MethodChannelAppIconBridge(channel: channel);
    final state = await bridge.getState();
    expect(state.supported, isTrue);
    expect(await bridge.pickImage(), orderedEquals(_wideImage()));
    final diagnostics = records.where(
      (record) => record['event'] == 'platform.degraded',
    );
    expect(diagnostics, hasLength(2));
    for (final diagnostic in diagnostics) {
      expect(
        AppLog.formatDetails(diagnostic),
        contains('synthetic recovery failure'),
      );
      expect(
        AppLog.formatDetails(diagnostic),
        contains('synthetic.native.recovery.frame'),
      );
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => _wideImage());
    expect(await bridge.pickImage(), orderedEquals(_wideImage()));
  });
}
