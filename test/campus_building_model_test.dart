import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_building_model.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_building_model_page.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_api.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_data.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_page.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_source.dart';
// Use the existing plugin's platform boundary without adding production hooks.
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

final model = CampusBuildingModel(
  url: Uri.parse('https://campus.test/models/library.glb'),
  floors: List.generate(
    7,
    (i) => CampusModelFloor(levelIndex: i, displayName: '${i + 1}F'),
  ),
);

class ModelSource implements CampusBuildingModelSource, CampusMapSource {
  Future<CampusBuildingModel?> Function(String)? load;
  final requested = <String>[];
  @override
  Future<CampusBuildingModel?> loadBuildingModel(String id) async {
    requested.add(id);
    return load == null ? model : await load!(id);
  }

  @override
  Uri buildingModelViewerUri(String id, {int? levelIndex}) => Uri.https(
    'campus.test',
    '/admin/model-viewer.html',
    {'building_id': id, 'floor': levelIndex?.toString() ?? 'all'},
  );
  @override
  bool get isConfigured => true;
  @override
  Future<CampusMapSnapshot> loadCampus() async => const CampusMapSnapshot(
    places: [
      CampusPlace(
        id: 'library',
        buildingId: 'OSM-Way862952692',
        name: '图书馆',
        hasIndoor: true,
        floors: [
          CampusFloor(id: 'floor-99', label: '7F', number: 99, levelIndex: 6),
        ],
      ),
    ],
  );
  @override
  Future<CampusFloorSnapshot> loadFloor(
    String buildingId,
    String floorId,
  ) async => const CampusFloorSnapshot();
  @override
  Future<CampusRouteResult?> planRoute(CampusRouteRequest request) async =>
      null;
}

class FakeWebViewPlatform extends WebViewPlatform {
  final controllers = <FakeController>[];
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final controller = FakeController(params);
    controllers.add(controller);
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => FakeDelegate(params);
  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => FakeWebViewWidget(params);
}

class FakeController extends PlatformWebViewController {
  FakeController(super.params) : super.implementation();
  late JavaScriptChannelParams channel;
  late FakeDelegate delegate;
  Uri? loaded;
  JavaScriptMode? mode;
  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async =>
      mode = javaScriptMode;
  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async =>
      channel = params;
  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async => delegate = handler as FakeDelegate;
  @override
  Future<void> loadRequest(LoadRequestParams params) async =>
      loaded = params.uri;
  void message(String value) =>
      channel.onMessageReceived(JavaScriptMessage(message: value));
}

class FakeDelegate extends PlatformNavigationDelegate {
  FakeDelegate(super.params) : super.implementation();
  late NavigationRequestCallback navigation;
  late WebResourceErrorCallback resourceError;
  late HttpResponseErrorCallback httpError;
  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback callback,
  ) async => navigation = callback;
  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback callback) async =>
      resourceError = callback;
  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback callback) async =>
      httpError = callback;
}

class FakeWebViewWidget extends PlatformWebViewWidget {
  FakeWebViewWidget(super.params) : super.implementation();
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void modelTestWidgets(String description, WidgetTesterCallback callback) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await callback(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  late ModelSource source;
  late FakeWebViewPlatform platform;
  WebViewPlatform? previousPlatform;

  setUp(() {
    source = ModelSource();
    previousPlatform = WebViewPlatform.instance;
    platform = FakeWebViewPlatform();
    WebViewPlatform.instance = platform;
  });
  tearDown(() {
    if (previousPlatform != null) WebViewPlatform.instance = previousPlatform;
  });

  Widget page({int? level}) => CampusBuildingModelPage(
    source: source,
    buildingId: 'OSM-Way862952692',
    buildingName: '图书馆',
    model: model,
    initialLevelIndex: level,
  );
  Widget entry({String id = 'library'}) => MaterialApp(
    home: Scaffold(
      body: CampusBuildingModelEntry(
        source: source,
        buildingId: id,
        buildingName: '图书馆',
      ),
    ),
  );
  Future<void> select(WidgetTester tester, String label) async {
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(label).last);
    await tester.tap(find.text(label).last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  modelTestWidgets(
    'metadata loading, error retry, absent model and available entry',
    (tester) async {
      final pending = Completer<CampusBuildingModel?>();
      source.load = (_) => pending.future;
      await tester.pumpWidget(entry());
      expect(find.text('正在检测模型…'), findsOneWidget);
      pending.completeError(const CampusMapApiException('网络故障'));
      await tester.pumpAndSettle();
      expect(find.text('网络故障'), findsOneWidget);
      source.load = (_) async => null;
      await tester.tap(find.byTooltip('重新检测三维模型'));
      await tester.pumpAndSettle();
      expect(find.text('该建筑尚未上传 GLB 模型'), findsOneWidget);
      expect(tester.widget<ListTile>(find.byType(ListTile)).onTap, isNull);
      source.load = (_) async => model;
      await tester.tap(find.byTooltip('重新检测三维模型'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('三维模型'));
      await tester.pumpAndSettle();
      expect(find.text('图书馆 · 三维模型'), findsOneWidget);
    },
  );

  modelTestWidgets(
    'changed building ignores stale metadata and disposed requests',
    (tester) async {
      final old = Completer<CampusBuildingModel?>();
      final current = Completer<CampusBuildingModel?>();
      source.load = (id) => id == 'old' ? old.future : current.future;
      await tester.pumpWidget(entry(id: 'old'));
      await tester.pumpWidget(entry(id: 'current'));
      current.complete(model);
      await tester.pumpAndSettle();
      old.complete(null);
      await tester.pumpAndSettle();
      expect(find.text('查看完整模型 · 7 个楼层'), findsOneWidget);
      final disposed = Completer<CampusBuildingModel?>();
      source.load = (_) => disposed.future;
      await tester.pumpWidget(entry(id: 'disposed'));
      await tester.pumpWidget(const SizedBox());
      disposed.completeError(Exception('late'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  modelTestWidgets(
    'desktop fallback switches all seven floors and copies exact link',
    (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(MaterialApp(home: page(level: 99)));
      await tester.pumpAndSettle();
      expect(find.text('当前平台暂不支持内嵌三维查看'), findsOneWidget);
      for (final level in [0, 1, 2, 3, 4, 5, 6, null]) {
        await select(tester, level == null ? '完整模型' : '${level + 1}F');
        final uri = source.buildingModelViewerUri(
          'OSM-Way862952692',
          levelIndex: level,
        );
        expect(find.text(uri.toString()), findsOneWidget);
        await tester.tap(find.text('复制查看链接'));
        await tester.pump();
        expect(copied, uri.toString());
      }
      expect(platform.controllers, isEmpty);
    },
  );

  modelTestWidgets(
    'building and indoor entries open all and actual level_index',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(home: CampusMapPage(source: source, useNativeMap: false)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('图书馆'));
      await tester.pumpAndSettle();
      // 详情卡片里的媒体入口已改为实拍图片：地图页不再请求三维模型元数据。
      expect(source.requested, isEmpty);
      expect(find.text('实拍图片'), findsOneWidget);
      expect(find.text('三维模型'), findsNothing);
      expect(find.text('当前地图服务未提供实拍图片'), findsOneWidget);
      await tester.tap(find.text('室内'));
      await tester.pumpAndSettle();
      expect(find.text('实拍图片'), findsOneWidget);
      expect(source.requested, isEmpty);
    },
  );

  for (final target in [TargetPlatform.android, TargetPlatform.iOS]) {
    modelTestWidgets(
      '$target waits for ready, handles errors and retries selected floor',
      (tester) async {
        debugDefaultTargetPlatformOverride = target;
        await tester.pumpWidget(MaterialApp(home: page(level: 6)));
        await tester.pump();
        final first = platform.controllers.single;
        expect(first.mode, JavaScriptMode.unrestricted);
        expect(first.channel.name, 'CampusModelViewer');
        expect(first.loaded!.queryParameters['floor'], '6');
        expect(find.text('正在加载三维模型…'), findsOneWidget);
        first.message('not json');
        first.message('[]');
        first.message('{"type":"unrelated"}');
        await tester.pump();
        expect(find.text('正在加载三维模型…'), findsOneWidget);
        first.message('{"type":"ready"}');
        await tester.pumpAndSettle();
        expect(find.text('正在加载三维模型…'), findsNothing);
        await tester.pump(const Duration(seconds: 91));
        expect(find.text('模型加载失败'), findsNothing);
        await select(tester, '1F');
        final second = platform.controllers.last;
        expect(second.loaded!.queryParameters['floor'], '0');
        first.message('{"type":"error","message":"旧楼层失败"}');
        await tester.pump();
        expect(find.text('旧楼层失败'), findsNothing);
        second.message('{"type":"error","message":"GLB 文件损坏"}');
        await tester.pumpAndSettle();
        expect(find.text('GLB 文件损坏'), findsOneWidget);
        await tester.tap(find.text('重试'));
        await tester.pump();
        expect(platform.controllers.length, 3);
        expect(platform.controllers.last.loaded!.queryParameters['floor'], '0');
        platform.controllers.last.message('{"type":"ready"}');
        await tester.pumpAndSettle();
        expect(find.text('模型加载失败'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  modelTestWidgets(
    'timeout and main frame failures are retryable; invalid navigation is blocked',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.pumpWidget(MaterialApp(home: page()));
      await tester.pump();
      final controller = platform.controllers.single;
      for (final url in [
        'about:blank',
        'javascript:alert(1)',
        'https://other.test/',
        'https://campus.test/admin/',
      ]) {
        expect(
          await controller.delegate.navigation(
            NavigationRequest(url: url, isMainFrame: true),
          ),
          NavigationDecision.prevent,
        );
      }
      expect(
        await controller.delegate.navigation(
          NavigationRequest(
            url: controller.loaded.toString(),
            isMainFrame: true,
          ),
        ),
        NavigationDecision.navigate,
      );
      controller.delegate.resourceError(
        const WebResourceError(
          errorCode: -1,
          description: 'subresource',
          isForMainFrame: false,
        ),
      );
      await tester.pump();
      expect(find.text('模型加载失败'), findsNothing);
      await tester.pump(const Duration(seconds: 91));
      expect(find.text('模型加载超时，请检查网络后重试'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pump();
      platform.controllers.last.delegate.resourceError(
        const WebResourceError(
          errorCode: -1,
          description: 'offline',
          isForMainFrame: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('三维查看页面加载失败，请检查网络后重试'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pump();
      final last = platform.controllers.last;
      last.delegate.httpError(
        HttpResponseError(
          request: WebResourceRequest(uri: last.loaded!),
          response: WebResourceResponse(uri: last.loaded!, statusCode: 503),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('三维查看页面请求失败（HTTP 503）'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      last.message('{"type":"ready"}');
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(375, 667), const Size(844, 390)]) {
    modelTestWidgets('fallback fits $size with large text and reduced motion', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: page(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('复制查看链接'));
      expect(tester.takeException(), isNull);
    });
  }
}
