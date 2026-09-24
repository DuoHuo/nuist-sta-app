import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_data.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_location.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_page.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_source.dart';

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
  final boundary = GlobalKey();
  Future<void> mount(
    WidgetTester tester, {
    CampusMapSource source = const UnconfiguredCampusMapSource(),
    UserLocationSource location = const DeviceUserLocation(),
    Size size = const Size(390, 844),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'MapTestFont'),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: RepaintBoundary(
          key: boundary,
          child: CampusMapPage(
            source: source,
            location: location,
            useNativeMap: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('MAP_CAPTURE')) return;
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await render.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/map-previews/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.pump();
  }

  setUpAll(() async {
    if (const bool.fromEnvironment('MAP_CAPTURE')) {
      final icons = File(
        'C:/dev/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      );
      if (icons.existsSync()) {
        final loader = FontLoader(
          'MaterialIcons',
        )..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
        await loader.load();
      }
      final font = File('C:/Windows/Fonts/msyh.ttc');
      if (font.existsSync()) {
        final loader = FontLoader('MapTestFont')
          ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
        await loader.load();
      }
    }
  });

  testWidgets('unconfigured UI has no invented places and exposes layers', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('底图服务尚未配置'), findsOneWidget);
    await capture(tester, 'map-phone');
    await tester.tap(find.byTooltip('地图图层'));
    await tester.pumpAndSettle();
    expect(find.text('标准地图'), findsOneWidget);
    // 街景现在是图层模式里的一张缩略图卡片，不再是独立开关
    await tester.tap(find.text('街景地图'));
    await tester.pumpAndSettle();
    expect(find.text('街景暂未开放'), findsOneWidget);
    await capture(tester, 'map-layers');
    expect(find.byTooltip('街景覆盖'), findsNothing); // 右上角不再有街景图标
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'backend floors switch and stale response cannot replace selected floor',
    (tester) async {
      final source = TestSource()..slowFloor = Completer<CampusFloorSnapshot>();
      await mount(tester, source: source, size: const Size(1000, 800));
      await tester.tap(find.text('测试楼宇'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('室内'));
      await tester.pump();
      await tester.tap(find.text('L2'));
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
      await tester.tap(find.byTooltip('查看街景'));
      await tester.pumpAndSettle();
      expect(find.text('街景暂未开放'), findsOneWidget);
      await tester.tap(find.byTooltip('返回地图'));
      await tester.pumpAndSettle();
      expect(find.text('L2  楼层导览'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('search and route keep missing backend data empty', (
    tester,
  ) async {
    await mount(tester, source: TestSource(), size: const Size(1000, 800));
    await tester.enterText(find.byType(TextField), '不存在');
    await tester.pumpAndSettle();
    expect(find.text('没有找到相关地点'), findsOneWidget);
    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试楼宇'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('路线'));
    await tester.pumpAndSettle();
    expect(find.text('搜索起点'), findsOneWidget); // 起终点卡片里的起点栏
    expect(find.text('导航'), findsOneWidget); // 面板标题
    expect(tester.takeException(), isNull);
  });

  testWidgets('locate button surfaces permission errors', (tester) async {
    await mount(tester, location: _FailingLocation());
    await tester.tap(find.byTooltip('定位到我的位置'));
    await tester.pumpAndSettle();
    expect(find.text('未获得定位权限，无法显示你的位置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('locate success keeps page usable', (tester) async {
    await mount(tester, location: _FixedLocation());
    await tester.tap(find.byTooltip('定位到我的位置'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(375, 667),
    const Size(844, 390),
    const Size(1280, 800),
  ]) {
    testWidgets('responsive empty UI ${size.width}x${size.height}', (
      tester,
    ) async {
      await mount(tester, size: size);
      await capture(tester, 'map-${size.width.toInt()}');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('large text and reduced motion remain usable', (tester) async {
    await mount(tester, textScale: 2);
    await tester.tap(find.byTooltip('地图图层'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

class _FailingLocation implements UserLocationSource {
  @override
  Future<GeoPoint> current() async =>
      throw const CampusLocationException('未获得定位权限，无法显示你的位置');
}

class _FixedLocation implements UserLocationSource {
  @override
  Future<GeoPoint> current() async =>
      const GeoPoint(longitude: 118.70695, latitude: 32.20275);
}
