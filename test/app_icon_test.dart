import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/app.dart';
import 'package:nuist_sta_app/core/colors.dart';
import 'package:nuist_sta_app/core/logging/app_log.dart';
import 'package:nuist_sta_app/core/theme_mode.dart';
import 'package:nuist_sta_app/shell/profile/settings/app_icon_bridge.dart';
import 'package:nuist_sta_app/shell/profile/settings/app_icon_controller.dart';
import 'package:nuist_sta_app/shell/profile/settings/app_icon_crop_page.dart';
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
  _FakeBridge({AppIconState state = _defaultState, this.pickResult})
    : current = state;

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

Future<void> _pumpAppIcon(
  WidgetTester tester,
  AppIconController controller, {
  ThemeMode mode = ThemeMode.light,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.light().copyWith(extensions: [AppPalette.light]),
      darkTheme: ThemeData.dark().copyWith(extensions: [AppPalette.dark]),
      themeMode: mode,
      home: AppIconPage(controller: controller),
    ),
  );
  await tester.pumpAndSettle();
}

Uint8List _wideImage() =>
    File('test/fixtures/app_icon_wide.png').readAsBytesSync();

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

Future<Color> _pixel(ui.Image image, int x, int y) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final offset = (y * image.width + x) * 4;
  return Color.fromARGB(
    255,
    data!.getUint8(offset),
    data.getUint8(offset + 1),
    data.getUint8(offset + 2),
  );
}

Future<void> _waitForImageWork(
  WidgetTester tester,
  bool Function() ready,
) async {
  for (var attempt = 0; attempt < 100 && !ready(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(ready(), isTrue, reason: '图片解码或导出应当完成');
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('切换内置图标失败可重试，且提交期间防重复', (tester) async {
    final bridge = _FakeBridge();
    final gate = Completer<AppIconState>();
    bridge.builtinGate = gate;
    final controller = AppIconController(bridge: bridge);
    addTearDown(controller.dispose);
    await _pumpAppIcon(tester, controller);

    await tester.tap(find.byKey(const Key('app_icon_choice_mascot')));
    await tester.pump();
    expect(controller.busy, isTrue);
    await tester.tap(find.byKey(const Key('app_icon_choice_default')));
    await tester.pump();
    expect(bridge.setBuiltinCalls, 1);
    gate.completeError(const AppIconBridgeException('icon_failed'));
    await tester.pumpAndSettle();
    expect(controller.busy, isFalse);
    expect(controller.state.builtinId, AppIconIds.defaultIcon);
    expect(find.text('图标保存失败，请稍后重试'), findsWidgets);
    expect(find.text('重试'), findsWidgets);

    bridge.builtinGate = null;
    await tester.tap(find.byKey(const Key('app_icon_choice_mascot')));
    await tester.pumpAndSettle();
    expect(bridge.builtinIds, [AppIconIds.mascot, AppIconIds.mascot]);
    expect(controller.state.builtinId, AppIconIds.mascot);
    expect(find.text('已切换为「信小龙」图标'), findsOneWidget);
  });

  testWidgets('选择相册图片取消时不改变图标，也不阻塞返回', (tester) async {
    final bridge = _FakeBridge(pickResult: null);
    final controller = AppIconController(bridge: bridge);
    addTearDown(controller.dispose);
    await _pumpAppIcon(tester, controller);

    await tester.tap(find.byKey(const Key('app_icon_choose_image')));
    await tester.pump();
    expect(controller.picking, isFalse);
    expect(controller.state.builtinId, AppIconIds.defaultIcon);
    expect(find.byType(AppIconCropPage), findsNothing);

    bridge.pickGate = Completer<Uint8List?>();
    await tester.tap(find.byKey(const Key('app_icon_choose_image')));
    await tester.pump();
    expect(controller.picking, isTrue);
    final popScope = tester.widget<PopScope<Object?>>(
      find.byType(PopScope<Object?>).first,
    );
    expect(popScope.canPop, isTrue);
    bridge.pickGate!.complete(null);
    await tester.pumpAndSettle();
    expect(controller.picking, isFalse);
    expect(controller.state.builtinId, AppIconIds.defaultIcon);
  });

  testWidgets('不支持平台时禁用自定义且保留内置不可操作状态', (tester) async {
    final bridge = _FakeBridge(state: _state(supported: false, canPin: false));
    final controller = AppIconController(bridge: bridge);
    addTearDown(controller.dispose);
    await _pumpAppIcon(tester, controller);

    expect(controller.unsupported, isTrue);
    expect(find.text('当前系统暂不支持切换应用图标。'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('app_icon_choose_image')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('app_icon_choice_mascot')));
    await tester.pump();
    expect(bridge.setBuiltinCalls, 0);
  });

  testWidgets('控制器失败后可用同一实例重试并恢复', (tester) async {
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

  test('通道添加方法无参数，并解析返回状态与失败', () async {
    final channel = const MethodChannel('nuist/app_icon');
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          if (call.method == 'pinCustomIcon') {
            return {
              'supported': true,
              'builtinId': 'mascot',
              'canPin': true,
              'customPinned': true,
              'pending': true,
              'customIcon': Uint8List.fromList([1, 2, 3]),
            };
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final bridge = MethodChannelAppIconBridge(channel: channel);
    final state = await bridge.pinCustomIcon();
    expect(received?.method, 'pinCustomIcon');
    expect(received?.arguments, isNull);
    expect(state.builtinId, AppIconIds.mascot);
    expect(state.customPinned, isTrue);
    expect(state.pending, isTrue);
    expect(state.customIcon, orderedEquals([1, 2, 3]));

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'shortcut_failed');
        });
    await expectLater(
      bridge.pinCustomIcon(),
      throwsA(
        isA<AppIconBridgeException>().having(
          (error) => error.kind,
          'kind',
          'shortcut_failed',
        ),
      ),
    );
  });

  testWidgets('没有保存图片时禁用添加到桌面', (tester) async {
    final bridge = _FakeBridge();
    final controller = AppIconController(bridge: bridge);
    addTearDown(controller.dispose);
    await _pumpAppIcon(tester, controller);

    final button = tester.widget<OutlinedButton>(
      find.byKey(const Key('app_icon_pin_custom')),
    );
    expect(button.onPressed, isNull);
    expect(find.text('请先保存一张图片，再添加到桌面。'), findsOneWidget);
    await tester.tap(find.byKey(const Key('app_icon_pin_custom')));
    await tester.pump();
    expect(bridge.pinCalls, 0);
  });

  testWidgets('等待选图期间禁用添加到桌面，但仍允许返回', (tester) async {
    final saved = _wideImage();
    final bridge = _FakeBridge(state: _state(customIcon: saved));
    bridge.pickGate = Completer<Uint8List?>();
    final controller = AppIconController(bridge: bridge);
    addTearDown(controller.dispose);
    await _pumpAppIcon(tester, controller);

    await tester.tap(find.byKey(const Key('app_icon_choose_image')));
    await tester.pump();
    expect(controller.picking, isTrue);
    await tester.tap(find.byKey(const Key('app_icon_choice_mascot')));
    await tester.pump();
    expect(bridge.setBuiltinCalls, 0);
    expect(controller.error, isFalse);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('app_icon_pin_custom')))
          .onPressed,
      isNull,
    );
    final popScope = tester.widget<PopScope<Object?>>(
      find.byType(PopScope<Object?>).first,
    );
    expect(popScope.canPop, isTrue);

    bridge.pickGate!.complete(null);
    await tester.pumpAndSettle();
  });

  testWidgets('保存过图片后可反复添加，且不会再次选图或保存', (tester) async {
    final saved = _wideImage();
    final bridge = _FakeBridge(state: _state(customIcon: saved));
    final controller = AppIconController(bridge: bridge);
    addTearDown(controller.dispose);
    await _pumpAppIcon(tester, controller);

    for (var attempt = 0; attempt < 2; attempt++) {
      await tester.ensureVisible(find.byKey(const Key('app_icon_pin_custom')));
      await tester.tap(find.byKey(const Key('app_icon_pin_custom')));
      await tester.pumpAndSettle();
      expect(find.text('请在系统提示中确认添加到桌面'), findsOneWidget);
    }
    expect(bridge.pinCalls, 2);
    expect(bridge.pickCalls, 0);
    expect(bridge.setCustomCalls, 0);

    bridge.current = _state(customIcon: saved, customPinned: true);
    await tester.ensureVisible(find.byKey(const Key('app_icon_pin_custom')));
    await tester.tap(find.byKey(const Key('app_icon_pin_custom')));
    await tester.pumpAndSettle();
    expect(bridge.pinCalls, 3);
    expect(bridge.pickCalls, 0);
    expect(bridge.setCustomCalls, 0);
  });

  testWidgets('添加过程中防重复，取消后可重试且无需重新选图', (tester) async {
    final saved = _wideImage();
    final bridge = _FakeBridge(state: _state(customIcon: saved));
    final controller = AppIconController(bridge: bridge);
    addTearDown(controller.dispose);
    await _pumpAppIcon(tester, controller);

    final gate = Completer<AppIconState>();
    bridge.pinGate = gate;
    await tester.tap(find.byKey(const Key('app_icon_pin_custom')));
    await tester.pump();
    expect(controller.busy, isTrue);
    expect(find.byKey(const Key('app_icon_busy')), findsOneWidget);
    await tester.tap(find.byKey(const Key('app_icon_pin_custom')));
    await tester.pump();
    expect(bridge.pinCalls, 1);
    final popScope = tester.widget<PopScope<Object?>>(
      find.byType(PopScope<Object?>).first,
    );
    expect(popScope.canPop, isFalse);

    gate.completeError(const AppIconBridgeException('shortcut_failed'));
    await tester.pumpAndSettle();
    expect(controller.busy, isFalse);
    expect(find.text('未能创建桌面快捷方式，请检查桌面空间后重试'), findsWidgets);
    expect(
      tester
          .widget<PopScope<Object?>>(find.byType(PopScope<Object?>).first)
          .canPop,
      isTrue,
    );

    bridge.pinGate = null;
    await tester.ensureVisible(find.byKey(const Key('app_icon_pin_custom')));
    ScaffoldMessenger.of(
      tester.element(find.byKey(const Key('app_icon_pin_custom'))),
    ).hideCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('app_icon_pin_custom')));
    await tester.pumpAndSettle();
    expect(bridge.pinCalls, 2);
    expect(bridge.pickCalls, 0);
    expect(bridge.setCustomCalls, 0);
    expect(find.text('请在系统提示中确认添加到桌面'), findsOneWidget);
  });

  testWidgets('等待系统确认时优先显示 pending，图片仍可直接添加', (tester) async {
    final saved = _wideImage();
    final bridge = _FakeBridge(
      state: _state(customIcon: saved, customPinned: true, pending: true),
    );
    final controller = AppIconController(bridge: bridge);
    addTearDown(controller.dispose);
    await _pumpAppIcon(tester, controller);

    expect(find.text('等待系统确认。如果系统提示已关闭，可再次点击“添加到桌面”。'), findsOneWidget);
    expect(find.text('已添加到桌面；仍可继续添加新的快捷方式。'), findsNothing);
    final button = tester.widget<OutlinedButton>(
      find.byKey(const Key('app_icon_pin_custom')),
    );
    expect(button.onPressed, isNotNull);
  });
  testWidgets(
    '真实设置入口打开图标页并返回，浅深色均支持取消手势',
    timeout: const Timeout(Duration(seconds: 30)),
    (tester) async {
      final channel = const MethodChannel('nuist/app_icon');
      Uint8List? submitted;
      Completer<void>? builtinGate;
      Completer<void>? pinGate;
      var pinCalls = 0;
      var pickCalls = 0;
      var saveCalls = 0;
      var builtinCalls = 0;
      var failBuiltin = false;
      var builtin = 'default';
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'pickImage') {
          pickCalls++;
          return _wideImage();
        }
        if (call.method == 'setCustomIcon') {
          saveCalls++;
          submitted = (call.arguments as Map)['bytes'] as Uint8List;
        }
        if (call.method == 'pinCustomIcon') {
          pinCalls++;
          expect(call.arguments, isNull);
          await pinGate?.future;
        }
        if (call.method == 'setBuiltin') {
          builtinCalls++;
          if (failBuiltin) throw PlatformException(code: 'icon_failed');
          await builtinGate?.future;
          builtin = (call.arguments as Map)['id'] as String;
        }
        if (call.method == 'getState' ||
            call.method == 'setCustomIcon' ||
            call.method == 'pinCustomIcon' ||
            call.method == 'setBuiltin') {
          return {
            'supported': true,
            'builtinId': builtin,
            'canPin': true,
            'customPinned': submitted != null,
            'pending': false,
            'customIcon': submitted,
          };
        }
        return null;
      });
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      });

      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        submitted = null;
        builtin = 'default';
        pinCalls = 0;
        pickCalls = 0;
        saveCalls = 0;
        builtinCalls = 0;
        failBuiltin = false;
        addTearDown(() => AppThemeMode.instance.value = ThemeMode.system);
        AppThemeMode.instance.value = mode;
        await tester.pumpWidget(const NuistApp());
        await tester.tap(find.text('我的'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('设置'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const Key('settings_app_icon')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.byKey(const Key('settings_app_icon')));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(AppBar, '应用图标'), findsOneWidget);
        expect(find.byType(BottomNavigationBar), findsNothing);
        final context = tester.element(find.text('内置图标'));
        final route = ModalRoute.of(context)! as PageRoute;
        expect(route.popGestureEnabled, isTrue);
        final navigator = Navigator.of(context);
        final edge = mode == ThemeMode.light ? 0 : 1;
        Future<void> gesture(String method, {double progress = 0}) async {
          ByteData? response;
          await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            'flutter/backgesture',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(method, {
                'touchOffset': [edge == 0 ? 5.0 : 795.0, 300.0],
                'progress': progress,
                'swipeEdge': edge,
              }),
            ),
            (data) => response = data,
          );
          expect(response, isNotNull, reason: method);
          await tester.pumpAndSettle();
        }

        await gesture('startBackGesture');
        await gesture('updateBackGestureProgress', progress: 0.4);
        expect(navigator.userGestureInProgress, isTrue);
        await gesture('cancelBackGesture');
        expect(find.text('内置图标'), findsOneWidget);
        Future<void> openCrop() async {
          await tester.ensureVisible(
            find.byKey(const Key('app_icon_choose_image')),
          );
          await tester.tap(find.byKey(const Key('app_icon_choose_image')));
          await _waitForImageWork(
            tester,
            () => find.byType(InteractiveViewer).evaluate().isNotEmpty,
          );
          final cropContext = tester.element(find.text('裁剪图标'));
          expect(
            (ModalRoute.of(cropContext)! as PageRoute).popGestureEnabled,
            isTrue,
          );
        }

        await openCrop();
        await gesture('startBackGesture');
        await gesture('updateBackGestureProgress', progress: 0.4);
        await gesture('cancelBackGesture');
        expect(find.text('裁剪图标'), findsOneWidget);
        await gesture('startBackGesture');
        await gesture('updateBackGestureProgress', progress: 0.4);
        await gesture('commitBackGesture');
        expect(find.text('裁剪图标'), findsNothing);
        expect(submitted, isNull);
        await openCrop();
        await tester.tap(find.text('完成'));
        await _waitForImageWork(
          tester,
          () => submitted != null && find.text('裁剪图标').evaluate().isEmpty,
        );
        expect(find.text('自定义图标已添加到桌面'), findsOneWidget);
        await tester.ensureVisible(
          find.byKey(const Key('app_icon_pin_custom')),
        );
        pinGate = Completer<void>();
        await tester.tap(find.byKey(const Key('app_icon_pin_custom')));
        await tester.pump();
        expect(pinCalls, 1);
        expect(saveCalls, 1);
        expect(route.popGestureEnabled, isFalse);
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(find.widgetWithText(AppBar, '应用图标'), findsOneWidget);
        pinGate.complete();
        await tester.pumpAndSettle();
        expect(route.popGestureEnabled, isTrue);
        expect(find.text('请在系统提示中确认添加到桌面'), findsOneWidget);
        await tester.ensureVisible(
          find.byKey(const Key('app_icon_pin_custom')),
        );
        await tester.tap(find.byKey(const Key('app_icon_pin_custom')));
        await tester.pumpAndSettle();
        expect(pinCalls, 2);
        expect(pickCalls, 2);
        expect(saveCalls, 1);
        await tester.ensureVisible(
          find.byKey(const Key('app_icon_choice_mascot_color')),
        );
        builtinGate = Completer<void>();
        await tester.tap(find.byKey(const Key('app_icon_choice_mascot_color')));
        await tester.pump();
        expect(route.popGestureEnabled, isFalse);
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(find.widgetWithText(AppBar, '应用图标'), findsOneWidget);
        builtinGate.complete();
        await tester.pumpAndSettle();
        expect(route.popGestureEnabled, isTrue);
        failBuiltin = true;
        await tester.tap(find.byKey(const Key('app_icon_choice_mascot')));
        await tester.pumpAndSettle();
        expect(find.text('刷新状态'), findsOneWidget);
        final oldRetry = tester
            .widget<SnackBarAction>(find.byType(SnackBarAction))
            .onPressed;
        final writesBeforeLeaving = builtinCalls;
        await gesture('startBackGesture');
        await gesture('updateBackGestureProgress', progress: 0.4);
        await gesture('commitBackGesture');
        expect(find.widgetWithText(AppBar, '应用图标'), findsNothing);
        expect(find.text('深色模式'), findsOneWidget);
        expect(find.text('当前：派龙'), findsOneWidget);
        expect(find.byType(SnackBarAction), findsNothing);
        expect(find.text('图标保存失败，请稍后重试'), findsNothing);
        oldRetry();
        await tester.pumpAndSettle();
        expect(builtinCalls, writesBeforeLeaving);
        expect(find.text('当前：派龙'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    '宽图在横屏、大字号和旋转后保持方形预览与导出一致，含浅深色',
    timeout: const Timeout(Duration(seconds: 30)),
    (tester) async {
      final bytes = _wideImage();
      for (final (mode, physicalSize, pixelRatio, textScale) in [
        (ThemeMode.light, const Size(1080, 2400), 2.625, 1.0),
        (ThemeMode.dark, const Size(1080, 2400), 2.625, 1.0),
        (ThemeMode.light, const Size(900, 540), 1.5, 2.0),
        (ThemeMode.dark, const Size(900, 540), 1.5, 2.0),
        (ThemeMode.light, const Size(480, 640), 2.0, 3.0),
        (ThemeMode.dark, const Size(480, 640), 2.0, 3.0),
      ]) {
        final result = ValueNotifier<Uint8List?>(null);
        tester.view.physicalSize = physicalSize;
        tester.view.devicePixelRatio = pixelRatio;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.light().copyWith(extensions: [AppPalette.light]),
            darkTheme: ThemeData.dark().copyWith(extensions: [AppPalette.dark]),
            themeMode: mode,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () async {
                      final cropped = await Navigator.of(context)
                          .push<Uint8List>(
                            MaterialPageRoute(
                              builder: (_) =>
                                  AppIconCropPage(imageBytes: bytes),
                            ),
                          );
                      result.value = cropped;
                    },
                    child: const Text('裁剪'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('裁剪'));
        await _waitForImageWork(
          tester,
          () => find.byType(InteractiveViewer).evaluate().isNotEmpty,
        );
        expect(find.byType(InteractiveViewer), findsOneWidget);
        final controller = tester
            .widget<InteractiveViewer>(find.byType(InteractiveViewer))
            .transformationController!;
        expect(controller.value.storage[0], 1);
        expect(controller.value.storage[5], 1);
        final viewportSize = tester.getSize(find.byType(InteractiveViewer));
        final viewport = viewportSize.width;
        expect(viewportSize.height, closeTo(viewport, 0.01));
        expect(tester.takeException(), isNull);
        final shownWidth = tester.getSize(find.byType(RawImage)).width;
        expect(shownWidth, greaterThan(viewport));
        final cropLeft = tester.getTopLeft(find.byType(InteractiveViewer));
        final childLeft = tester.getTopLeft(find.byType(RawImage));
        expect(childLeft.dx, lessThan(cropLeft.dx));
        expect(childLeft.dy, closeTo(cropLeft.dy, 0.5));

        // 先缩放平移再旋转；源图采样位置与范围必须保持一致。
        controller.value = Matrix4.identity()
          ..setEntry(0, 0, 2)
          ..setEntry(1, 1, 2)
          ..setTranslationRaw(-viewport * 0.75, -viewport * 0.25, 0);
        tester.view.physicalSize = Size(
          physicalSize.height,
          physicalSize.width,
        );
        await tester.pumpAndSettle();
        final rotatedSize = tester.getSize(find.byType(InteractiveViewer));
        expect(rotatedSize.height, closeTo(rotatedSize.width, 0.01));
        expect(controller.value.storage[0], closeTo(2, 0.001));
        expect(
          controller.value.storage[12] / rotatedSize.width,
          closeTo(-0.75, 0.001),
        );
        expect(
          controller.value.storage[13] / rotatedSize.width,
          closeTo(-0.25, 0.001),
        );
        expect(tester.takeException(), isNull);

        // child 已是 cover 尺寸；直接平移到最左侧，验证原图左侧进入方框。
        controller.value = Matrix4.identity();
        await tester.pumpAndSettle();
        await tester.tap(find.text('完成'));
        await _waitForImageWork(tester, () => result.value != null);
        final output = result.value;
        expect(output, isNotNull);
        final image = await tester.runAsync(() => _decode(output!));
        expect(image, isNotNull);
        expect(image!.width, 512);
        expect(image.height, 512);
        final pixel = await tester.runAsync(() => _pixel(image, 40, 256));
        expect(pixel, isNotNull);
        expect(pixel!.r, greaterThan(0.6));
        expect(pixel.g, lessThan(0.4));
        expect(pixel.b, lessThan(0.4));
        image.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
