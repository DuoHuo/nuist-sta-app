import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:nuist_sta_app/core/app_select.dart';
import 'package:nuist_sta_app/core/schedule/weekly_classes.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_building_model.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_building_model_page.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_api.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_canvas.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_data.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_heading.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_location.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_native.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_navigation.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_page.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_panels.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_source.dart';
// Use the existing plugin's platform boundary without adding production hooks.
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

// Fixtures exercise the repository boundary; no fixture is shipped in the app.
const testFloors = [
  CampusFloor(id: 'lower', label: 'L1', number: 1),
  CampusFloor(id: 'upper', label: 'L2', number: 2),
];
const testPlace = CampusPlace(
  id: 'test-building',
  name: '测试楼宇',
  category: PlaceCategory.study,
  hasIndoor: true,
  floors: testFloors,
);

class TestSource implements CampusMapSource {
  @override
  bool get isConfigured => true;
  Completer<CampusFloorSnapshot>? slowFloor;
  @override
  Future<CampusMapSnapshot> loadCampus() async =>
      const CampusMapSnapshot(places: [testPlace]);
  @override
  Future<CampusFloorSnapshot> loadFloor(
    String buildingId,
    String floorId,
  ) async {
    if (floorId == 'lower' && slowFloor != null) return slowFloor!.future;
    return CampusFloorSnapshot(
      rooms: [
        CampusRoom(id: '$floorId-room', name: '$floorId 房间', floorId: floorId),
      ],
    );
  }

  @override
  Future<CampusRouteResult?> planRoute(CampusRouteRequest request) async =>
      null;
}

void main() {
  Future<void> mount(
    WidgetTester tester, {
    CampusMapSource source = const UnconfiguredCampusMapSource(),
    UserLocationSource location = const DeviceUserLocation(),
    HeadingSource heading = const DeviceHeading(),
    String styleUrl = '',
    Size size = const Size(390, 844),
    double textScale = 1,
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? appLightTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: CampusMapPage(
          source: source,
          location: location,
          heading: heading,
          styleUrl: styleUrl,
          useNativeMap: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('前后台和街景路由覆盖释放定位及朝向监听，后台权限回调不重启传感器', (tester) async {
    final location = _TrackingLocation();
    final heading = _TestHeading();
    addTearDown(location.values.close);
    addTearDown(heading.values.close);
    await mount(
      tester,
      source: TestSource(),
      location: location,
      heading: heading,
      theme: appDarkTheme(),
    );
    expect(location.watches, 1);
    expect(location.values.hasListener, isTrue);
    expect(heading.values.hasListener, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(location.values.hasListener, isFalse);
    expect(heading.values.hasListener, isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(location.watches, 2);
    expect(location.values.hasListener, isTrue);
    expect(heading.values.hasListener, isTrue);

    await tester.enterText(find.byType(TextField), '测试楼宇');
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试楼宇').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('查看街景'));
    await tester.pumpAndSettle();
    expect(location.values.hasListener, isFalse);
    expect(heading.values.hasListener, isFalse);
    await tester.tap(find.byTooltip('返回地图'));
    await tester.pumpAndSettle();
    expect(location.watches, 3);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(location.values.hasListener, isFalse);
    expect(heading.values.hasListener, isFalse);

    final ready = Completer<bool>();
    final gatedLocation = _TrackingLocation(ready.future);
    final gatedHeading = _TestHeading();
    addTearDown(gatedLocation.values.close);
    addTearDown(gatedHeading.values.close);
    await mount(tester, location: gatedLocation, heading: gatedHeading);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    ready.complete(true);
    await tester.pumpAndSettle();
    expect(gatedLocation.watches, 0);
    expect(gatedHeading.values.hasListener, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('未配置底图提示、图层切换、定位权限错误及两倍字号不溢出', (tester) async {
    await mount(tester, location: _FailingLocation());
    expect(find.text('底图服务尚未配置'), findsOneWidget);
    await tester.tap(find.byTooltip('定位到我的位置'));
    await tester.pumpAndSettle();
    expect(find.text('未获得定位权限，无法显示你的位置'), findsOneWidget);
    await tester.tap(find.byTooltip('地图图层'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('街景地图'));
    await tester.pumpAndSettle();
    expect(find.text('街景暂未开放'), findsOneWidget);
    await mount(tester, location: _FailingLocation(), textScale: 2);
    await tester.tap(find.byTooltip('地图图层'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索与路线防空、楼宇周课程展示、楼层切换忽略过期响应以及路线导航引导操作', (tester) async {
    WeeklyClasses.source = const _FixedWeek([
      WeeklyClass(
        courseName: '高等数学',
        location: '测试楼宇A101',
        weekday: 2,
        startNode: 3,
        endNode: 4,
      ),
      WeeklyClass(
        courseName: '大学英语',
        location: '其他楼B202',
        weekday: 3,
        startNode: 1,
        endNode: 2,
      ),
    ]);
    addTearDown(() => WeeklyClasses.source = null);
    final source = TestSource()..slowFloor = Completer<CampusFloorSnapshot>();
    await mount(tester, source: source, size: const Size(1000, 800));
    expect(find.text('测试楼宇 · 1 节'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '不存在');
    await tester.pumpAndSettle();
    expect(find.text('没有找到相关地点'), findsOneWidget);
    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('测试楼宇'));
    await tester.pumpAndSettle();
    expect(find.text('本周在这里有 1 节课'), findsOneWidget);
    expect(find.text('高等数学'), findsOneWidget);
    expect(find.text('A101'), findsOneWidget);
    expect(find.text('大学英语'), findsNothing);

    await tester.tap(find.text('室内'));
    await tester.pump();
    await tester.tap(find.text('L2').last);
    await tester.pumpAndSettle();
    expect(find.text('upper 房间'), findsOneWidget);
    source.slowFloor!.complete(
      const CampusFloorSnapshot(
        rooms: [CampusRoom(id: 'stale', name: '过期房间', floorId: 'lower')],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('过期房间'), findsNothing);
    expect(find.text('L2  楼层导览'), findsOneWidget);

    await tester.tap(find.text('路线'));
    await tester.pumpAndSettle();
    expect(find.text('搜索起点'), findsOneWidget);
    expect(find.text('导航'), findsOneWidget);

    List<double> at(double east, double north) => [
      118.7 + east / (111320 * 0.8462),
      32.2 + north / 111320,
    ];
    final route = NavRoute.fromResult(
      CampusRouteResult(
        geoJson: {
          'type': 'FeatureCollection',
          'features': [
            {
              'type': 'Feature',
              'geometry': {
                'type': 'LineString',
                'coordinates': [at(0, 0), at(100, 0), at(100, 100)],
              },
              'properties': const <String, dynamic>{},
            },
          ],
        },
        instructions: const ['沿校园道路步行', '到达目的地'],
      ),
    );
    var started = 0, exited = 0, simulated = 0;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(800, 1200);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              CampusRoutePreview(
                route: route,
                originLabel: '我的位置',
                destinationLabel: '北辰楼',
                via: const ['文德楼'],
                now: DateTime(2026, 10, 24, 16, 0),
                onStart: () => started++,
                onSimulate: () => simulated++,
              ),
              CampusNavBanner(progress: route.progressAt(40)),
              CampusNavStatusBar(
                progress: route.progressAt(40),
                destinationLabel: '北辰楼',
                now: DateTime(2026, 10, 24, 16, 0),
                onExit: () => exited++,
                onFinish: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始导航'));
    await tester.tap(find.text('模拟导航'));
    await tester.tap(find.text('退出'));
    expect((started, simulated, exited), (1, 1, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换无几何楼层与清除选中时清理旧室内图层与数据源', (tester) async {
    final origFactory = MapLibrePlatform.createInstance;
    MapLibrePlatform.createInstance = _FakeMapLibrePlatform.new;
    late _TrackingBridge bridge;
    CampusMapNative.debugBridgeOverride = (_) => bridge = _TrackingBridge();
    addTearDown(() {
      MapLibrePlatform.createInstance = origFactory;
      CampusMapNative.debugBridgeOverride = null;
    });

    CampusMapCanvas floorCanvas(CampusFloor? floor) => CampusMapCanvas(
      styleUrl: '{"version":8,"sources":{},"layers":[]}',
      selectedPlace: const CampusPlace(id: 'b1', name: '明德楼', hasIndoor: true),
      floor: floor,
      selectedRoom: null,
      onPlaceSelected: (_) {},
      onRoomSelected: (_) {},
      floorGeoJson: floor == null
          ? null
          : {
              'type': 'FeatureCollection',
              'features': [
                {
                  'type': 'Feature',
                  'geometry': {
                    'type': 'Polygon',
                    'coordinates': [
                      [
                        [118.7, 32.2],
                        [118.701, 32.2],
                        [118.701, 32.201],
                        [118.7, 32.2],
                      ],
                    ],
                  },
                  'properties': {
                    'room_id': 'r1',
                    'building_id': 'b1',
                    'floor_id': floor.id,
                    'kind': 'room',
                  },
                },
              ],
            },
    );

    const f1 = CampusFloor(id: 'f1', label: '1F', number: 1, levelIndex: 0);
    await tester.pumpWidget(
      MaterialApp(home: CampusMapNative(configuration: floorCanvas(f1))),
    );
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    map.onMapCreated!(
      MapLibreMapController(
        maplibrePlatform: MapLibrePlatform.createInstance(),
        annotationOrder: const [],
        annotationConsumeTapEvents: const [],
        initialCameraPosition: const CameraPosition(
          target: LatLng(32.2, 118.7),
          zoom: 17,
        ),
      ),
    );
    map.onStyleLoadedCallback!();
    await tester.pumpAndSettle();
    expect(bridge.sources, contains('campus-floor'));

    await tester.pumpWidget(
      MaterialApp(home: CampusMapNative(configuration: floorCanvas(null))),
    );
    await tester.pumpAndSettle();
    expect(bridge.sources, isNot(contains('campus-floor')));
    expect(bridge.layers.where((l) => l.contains('floor')), isEmpty);
  });

  testWidgets('建筑三维模型入口检测、切层加载、外域拦截与窄屏两倍字号兜底不溢出', (tester) async {
    final modelSource = _ModelSource();
    final previousPlatform = WebViewPlatform.instance;
    final webPlatform = _FakeWebViewPlatform();
    WebViewPlatform.instance = webPlatform;
    addTearDown(() {
      if (previousPlatform != null) WebViewPlatform.instance = previousPlatform;
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      Widget modelPage({int? level}) => CampusBuildingModelPage(
        source: modelSource,
        buildingId: 'OSM-Way862952692',
        buildingName: '图书馆',
        model: _buildingModel,
        initialLevelIndex: level,
      );

      final pending = Completer<CampusBuildingModel?>();
      modelSource.load = (_) => pending.future;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CampusBuildingModelEntry(
              source: modelSource,
              buildingId: 'library',
              buildingName: '图书馆',
            ),
          ),
        ),
      );
      expect(find.text('正在检测模型…'), findsOneWidget);
      pending.completeError(const CampusMapApiException('网络故障'));
      await tester.pumpAndSettle();
      expect(find.text('网络故障'), findsOneWidget);
      modelSource.load = (_) async => null;
      await tester.tap(find.byTooltip('重新检测三维模型'));
      await tester.pumpAndSettle();
      expect(find.text('该建筑尚未上传 GLB 模型'), findsOneWidget);
      modelSource.load = (_) async => _buildingModel;
      await tester.tap(find.byTooltip('重新检测三维模型'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('三维模型'));
      await tester.pumpAndSettle();
      expect(find.text('图书馆 · 三维模型'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      webPlatform.controllers.clear();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.pumpWidget(MaterialApp(home: modelPage(level: 6)));
      await tester.pump();
      final first = webPlatform.controllers.single;
      expect(
        first.channels.keys,
        containsAll(['CampusModelViewer', 'NuistDiagnostics']),
      );
      expect(first.loaded!.queryParameters['floor'], '6');
      first.message('not json');
      first.message('{"type":"ready"}');
      await tester.pumpAndSettle();
      expect(find.text('正在加载三维模型…'), findsNothing);

      await tester.tap(find.byType(AppSelectField<int>));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              (widget.decoration?.hintText?.startsWith('搜索') ?? false),
        ),
        '1F',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(
              of: find.byType(MiuixPopupHost),
              matching: find.text('1F'),
            )
            .last,
      );
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final second = webPlatform.controllers.last;
      expect(second.loaded!.queryParameters['floor'], '0');
      second.message('{"type":"error","message":"GLB 文件损坏"}');
      await tester.pumpAndSettle();
      expect(find.text('GLB 文件损坏'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(webPlatform.controllers.length, 3);
      for (final url in [
        'about:blank',
        'javascript:alert(1)',
        'https://other.test/',
        'https://campus.test/admin/',
      ]) {
        expect(
          await second.delegate.navigation(
            NavigationRequest(url: url, isMainFrame: true),
          ),
          NavigationDecision.prevent,
        );
      }
      expect(
        await second.delegate.navigation(
          NavigationRequest(url: second.loaded.toString(), isMainFrame: true),
        ),
        NavigationDecision.navigate,
      );
      webPlatform.controllers.last.delegate.resourceError(
        const WebResourceError(
          errorCode: -1,
          description: 'offline',
          isForMainFrame: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('三维查看页面加载失败，请检查网络后重试'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: modelPage(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('复制查看链接'));
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

class _FakeMapLibrePlatform extends MapLibrePlatform {
  @override
  Widget buildView(
    Map<String, dynamic> creationParams,
    OnPlatformViewCreatedCallback onPlatformViewCreated,
    Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers,
  ) => const SizedBox();

  @override
  Future<void> initPlatform(int id) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<dynamic>.value();
}

class _TrackingBridge implements CampusMapBridge {
  final sources = <String>{};
  final layers = <String>[];

  @override
  Future<void> addGeoJsonSource(String id, Map<String, dynamic> _) async =>
      sources.add(id);

  @override
  Future<void> removeSource(String id) async => sources.remove(id);

  @override
  Future<void> removeLayer(String id) async => layers.remove(id);

  @override
  Future<void> addFillLayer(
    String s,
    String l,
    FillLayerProperties p, {
    String? belowLayerId,
    dynamic filter,
    bool enableInteraction = true,
  }) async => layers.add(l);

  @override
  Future<void> addLineLayer(
    String s,
    String l,
    LineLayerProperties p, {
    String? belowLayerId,
    dynamic filter,
    bool enableInteraction = true,
  }) async => layers.add(l);

  @override
  Future<void> addSymbolLayer(
    String s,
    String l,
    SymbolLayerProperties p, {
    String? belowLayerId,
    dynamic filter,
    bool enableInteraction = true,
  }) async => layers.add(l);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FixedWeek implements WeeklyClassSource {
  const _FixedWeek(this.classes);
  final List<WeeklyClass> classes;
  @override
  Future<List<WeeklyClass>> thisWeek() async => classes;
}

class _FailingLocation implements UserLocationSource {
  @override
  Future<GeoPoint> current() async =>
      throw const CampusLocationException('未获得定位权限，无法显示你的位置');
}

class _TestHeading implements HeadingSource {
  final values = StreamController<double>.broadcast();

  @override
  Stream<double> watch() => values.stream;
}

class _LiveLocation implements LiveUserLocationSource {
  static const _fix = LocationFix(
    point: GeoPoint(longitude: 118.70695, latitude: 32.20275),
    accuracyM: 5,
  );

  @override
  Future<bool> ready() async => true;

  @override
  Future<LocationFix?> lastKnown() async => _fix;

  @override
  Future<LocationFix> currentFix() async => _fix;

  @override
  Future<GeoPoint> current() async => _fix.point;

  @override
  Stream<LocationFix> watch() => const Stream.empty();
}

class _TrackingLocation extends _LiveLocation {
  _TrackingLocation([this._ready]);
  final Future<bool>? _ready;
  final values = StreamController<LocationFix>.broadcast();
  int watches = 0;

  @override
  Future<bool> ready() => _ready ?? Future.value(true);

  @override
  Stream<LocationFix> watch() {
    watches++;
    return values.stream;
  }
}

final _buildingModel = CampusBuildingModel(
  url: Uri.parse('https://campus.test/models/library.glb'),
  floors: List.generate(
    7,
    (i) => CampusModelFloor(levelIndex: i, displayName: '${i + 1}F'),
  ),
);

class _ModelSource implements CampusBuildingModelSource, CampusMapSource {
  Future<CampusBuildingModel?> Function(String)? load;
  @override
  Future<CampusBuildingModel?> loadBuildingModel(String id) async =>
      load == null ? _buildingModel : await load!(id);

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

class _FakeWebViewPlatform extends WebViewPlatform {
  final controllers = <_FakeWebViewController>[];
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final controller = _FakeWebViewController(params);
    controllers.add(controller);
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _FakeNavigationDelegate(params);
  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _FakeWebViewWidget(params);
}

class _FakeWebViewController extends PlatformWebViewController {
  _FakeWebViewController(super.params) : super.implementation();
  final channels = <String, JavaScriptChannelParams>{};
  late _FakeNavigationDelegate delegate;
  Uri? loaded;
  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}
  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async =>
      channels[params.name] = params;
  @override
  Future<void> runJavaScript(String javaScript) async {}
  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async => delegate = handler as _FakeNavigationDelegate;
  @override
  Future<void> loadRequest(LoadRequestParams params) async =>
      loaded = params.uri;
  void message(String value) => channels['CampusModelViewer']!
      .onMessageReceived(JavaScriptMessage(message: value));
}

class _FakeNavigationDelegate extends PlatformNavigationDelegate {
  _FakeNavigationDelegate(super.params) : super.implementation();
  late NavigationRequestCallback navigation;
  late WebResourceErrorCallback resourceError;
  @override
  Future<void> setOnPageStarted(PageEventCallback callback) async {}
  @override
  Future<void> setOnPageFinished(PageEventCallback callback) async {}
  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback callback,
  ) async => navigation = callback;
  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback callback) async =>
      resourceError = callback;
  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback callback) async {}
}

class _FakeWebViewWidget extends PlatformWebViewWidget {
  _FakeWebViewWidget(super.params) : super.implementation();
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
