import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/schedule/weekly_classes.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_canvas.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_data.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_navigation.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_page.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_panels.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_source.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/shuttle_api.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/shuttle_models.dart';

class _PerfTestSource implements CampusMapSource {
  _PerfTestSource({required this.places, this.rooms = const []});

  final List<CampusPlace> places;
  final List<CampusRoom> rooms;

  @override
  bool get isConfigured => true;

  @override
  Future<CampusMapSnapshot> loadCampus() async =>
      CampusMapSnapshot(places: places);

  @override
  Future<CampusFloorSnapshot> loadFloor(
    String buildingId,
    String floorId,
  ) async => CampusFloorSnapshot(rooms: rooms);

  @override
  Future<CampusRouteResult?> planRoute(CampusRouteRequest request) async =>
      null;
}

class _PerfShuttleSource implements ShuttleSource {
  final pending = <Completer<List<ShuttleVehicle>>>[];
  bool closed = false;

  @override
  Future<List<ShuttleVehicle>> load() {
    final completer = Completer<List<ShuttleVehicle>>();
    pending.add(completer);
    return completer.future;
  }

  @override
  void close() {
    closed = true;
  }
}

WeeklyClass _lesson(String location, {String name = '课程'}) => WeeklyClass(
  courseName: name,
  location: location,
  weekday: 1,
  startNode: 1,
  endNode: 2,
);

NavRoute _sampleRoute() {
  List<double> at(double east, double north) => [
    118.7 + east / (111320 * 0.8462),
    32.2 + north / 111320,
  ];
  return NavRoute.fromResult(
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
      instructions: const ['沿校园道路步行', '左转', '到达目的地'],
    ),
  );
}

void main() {
  testWidgets('校车刷新仅局部重建 CampusMapCanvas，不触发整页和面板重建，且错误提示保留', (tester) async {
    final shuttleSource = _PerfShuttleSource();
    final places = [
      const CampusPlace(
        id: 'b1',
        name: '明德楼',
        buildingId: 'b1',
        category: PlaceCategory.study,
        center: GeoPoint(longitude: 118.71, latitude: 32.20),
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: CampusMapPage(
          source: _PerfTestSource(places: places),
          shuttleSource: shuttleSource,
          useNativeMap: false,
          styleUrl: 'synthetic-style',
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 切换到公共交通图层以激活校车轮询。
    await tester.tap(find.byTooltip('地图图层'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('公共交通'));
    await tester.pumpAndSettle();
    expect(shuttleSource.pending, hasLength(1));

    final scaffoldBefore = tester.widget<Scaffold>(find.byType(Scaffold));
    final searchFieldBefore = tester.widget<TextField>(find.byType(TextField));

    // 首次失败仍触发一次轻提示，并在 2 秒后自动收起，同时不整页重建。
    shuttleSource.pending.last.completeError(StateError('network'));
    await tester.pump();
    await tester.pump();
    expect(find.text('车辆位置暂时无法更新'), findsOneWidget);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)),
      same(scaffoldBefore),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('车辆位置暂时无法更新'), findsNothing);

    // 3 秒周期拉取车辆成功：先让第一批进入状态。
    await tester.pump(const Duration(seconds: 1));
    expect(shuttleSource.pending, hasLength(2));
    shuttleSource.pending.last.complete([
      const ShuttleVehicle(
        id: 'NXD1',
        point: GeoPoint(longitude: 118.71, latitude: 32.20),
        heading: 90,
        online: true,
      ),
    ]);
    await tester.pumpAndSettle();

    // 记录下一次常规车辆更新期间的重建组件类型。
    final builds = <String, int>{};
    final previous = debugOnRebuildDirtyWidget;
    addTearDown(() => debugOnRebuildDirtyWidget = previous);
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previous?.call(element, builtOnce);
      final name = element.widget.runtimeType.toString();
      builds[name] = (builds[name] ?? 0) + 1;
    };

    await tester.pump(const Duration(seconds: 3));
    expect(shuttleSource.pending, hasLength(3));
    shuttleSource.pending.last.complete([
      const ShuttleVehicle(
        id: 'NXD1',
        point: GeoPoint(longitude: 118.72, latitude: 32.21),
        heading: 180,
        online: true,
      ),
      const ShuttleVehicle(
        id: 'NXD2',
        point: GeoPoint(longitude: 118.73, latitude: 32.22),
        heading: 0,
        online: false,
      ),
    ]);
    await tester.pumpAndSettle();

    final canvas = tester.widget<CampusMapCanvas>(find.byType(CampusMapCanvas));
    expect(canvas.shuttleVehicles, hasLength(2));
    expect(canvas.shuttleVehicles.first.point.longitude, 118.72);
    expect(builds['CampusMapCanvas'], 1);
    expect(builds['CampusMapPage'], isNull);
    expect(builds['Scaffold'], isNull);
    expect(builds['CampusExplorePanel'], isNull);
    expect(builds['TextField'], isNull);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)),
      same(scaffoldBefore),
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)),
      same(searchFieldBefore),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    expect(shuttleSource.closed, isTrue);
    expect(tester.takeException(), isNull);
  });

  test('filterPlaces / weekBuildings / nearestPlaces 复用缓存并在输入变化时失效', () {
    const p1 = CampusPlace(
      id: 'b1',
      name: '明德楼',
      subtitle: '教学区',
      category: PlaceCategory.study,
      center: GeoPoint(longitude: 118.700, latitude: 32.200),
    );
    const p2 = CampusPlace(
      id: 'b2',
      name: '理科楼',
      subtitle: '实验楼',
      category: PlaceCategory.study,
      center: GeoPoint(longitude: 118.705, latitude: 32.200),
    );
    const p3 = CampusPlace(
      id: 'b3',
      name: '理科楼东',
      subtitle: '教学楼',
      category: PlaceCategory.study,
      center: GeoPoint(longitude: 118.710, latitude: 32.200),
    );
    const p4 = CampusPlace(
      id: 'f1',
      name: '中苑食堂',
      subtitle: '餐饮',
      category: PlaceCategory.food,
      center: GeoPoint(longitude: 118.720, latitude: 32.200),
    );

    // 1. filterPlaces 缓存命中与失效。
    final places = [p1, p2, p3, p4];
    final f1 = filterPlaces(places, PlaceCategory.study, '  理科 ');
    final f2 = filterPlaces(places, PlaceCategory.study, '理科');
    expect(identical(f1, f2), isTrue);
    expect(f1.map((p) => p.id), ['b2', 'b3']);

    // query 或 category 变化时失效。
    final fQueryChanged = filterPlaces(places, PlaceCategory.study, '明德');
    expect(identical(f1, fQueryChanged), isFalse);
    expect(fQueryChanged.map((p) => p.id), ['b1']);

    final fCatChanged = filterPlaces(places, PlaceCategory.food, '');
    expect(fCatChanged.map((p) => p.id), ['f1']);

    // 原地修改输入列表时不能返回脏缓存。
    places.add(
      const CampusPlace(id: 'b4', name: '理科楼北', category: PlaceCategory.study),
    );
    final fMutated = filterPlaces(places, PlaceCategory.study, '理科');
    expect(identical(f1, fMutated), isFalse);
    expect(fMutated.map((p) => p.id), ['b2', 'b3', 'b4']);

    // 2. weekBuildings 缓存命中与失效。
    final classes = [_lesson('明德楼N101'), _lesson('理科楼东202')];
    final w1 = weekBuildings(classes, places);
    final w2 = weekBuildings(classes, places);
    expect(identical(w1, w2), isTrue);
    expect(w1.map((e) => (e.place.id, e.count)), [('b1', 1), ('b3', 1)]);

    // 课表位置不变的新对象列表同样命中。
    final classesCopy = [_lesson('明德楼N101'), _lesson('理科楼东202')];
    final w3 = weekBuildings(classesCopy, places);
    expect(identical(w1, w3), isTrue);

    // 课表或地点改变后立即更新。
    classes.add(_lesson('明德楼N205'));
    final wUpdated = weekBuildings(classes, places);
    expect(identical(w1, wUpdated), isFalse);
    expect(wUpdated.map((e) => (e.place.id, e.count)), [('b1', 2), ('b3', 1)]);

    // 3. nearestPlaces 缓存命中与失效。
    const pointA = GeoPoint(longitude: 118.701, latitude: 32.200);
    const pointASameValue = GeoPoint(longitude: 118.701, latitude: 32.200);
    const pointB = GeoPoint(longitude: 118.719, latitude: 32.200);

    final n1 = nearestPlaces(places, pointA);
    final n2 = nearestPlaces(places, pointASameValue);
    expect(identical(n1, n2), isTrue);
    expect(n1.map((p) => p.id), ['b1', 'b2', 'b3', 'f1']);

    // 切换 userPoint 立即重算排序。
    final nMoved = nearestPlaces(places, pointB);
    expect(identical(n1, nMoved), isFalse);
    expect(nMoved.map((p) => p.id), ['f1', 'b3', 'b2', 'b1']);

    // limit 变化也参与缓存键区分。
    final nLimited = nearestPlaces(places, pointA, limit: 2);
    expect(nLimited.map((p) => p.id), ['b1', 'b2']);

    // 超出 LRU 容量后仍能正确返回，不产生陈旧结果。
    for (var i = 0; i < 12; i++) {
      final res = filterPlaces(places, null, i.isEven ? '明德' : '食堂');
      expect(res.single.id, i.isEven ? 'b1' : 'f1');
    }
  });

  testWidgets('长分类列表与大房间网格均按需懒构建，且不嵌套 shrinkWrap ListView', (tester) async {
    final manyPlaces = [
      for (var i = 0; i < 180; i++)
        CampusPlace(
          id: 'p-$i',
          name: '教学建筑 ${i.toString().padLeft(3, '0')}',
          buildingId: 'p-$i',
          category: PlaceCategory.study,
          hasIndoor: i == 0,
          floors: i == 0
              ? const [CampusFloor(id: 'f1', label: '1F', number: 1)]
              : const [],
        ),
    ];
    final manyRooms = [
      for (var i = 0; i < 72; i++)
        CampusRoom(
          id: 'r-$i',
          name: '教室 ${i.toString().padLeft(3, '0')}',
          roomCode: 'R${i.toString().padLeft(3, '0')}',
          floorId: 'f1',
          category: 'classroom',
        ),
      const CampusRoom(
        id: 'wc-1',
        name: '一层东卫生间',
        floorId: 'f1',
        isFacility: true,
        category: 'toilet',
      ),
    ];

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: CampusMapPage(
          source: _PerfTestSource(places: manyPlaces, rooms: manyRooms),
          useNativeMap: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 选中「教学」分类后，只有可视范围内的列表项会被实例化。
    await tester.tap(find.text('教学').first);
    await tester.pumpAndSettle();
    expect(find.text('教学建筑 000'), findsOneWidget);
    expect(find.text('教学建筑 179'), findsNothing);
    expect(tester.widgetList(find.byType(ListTile)).length, lessThan(40));

    // 确保面板使用 CustomScrollView，而非把 shrinkWrap ListView 嵌套进滚动体。
    final nestedShrinkWraps = tester
        .widgetList<ListView>(find.byType(ListView))
        .where((lv) => lv.shrinkWrap);
    expect(nestedShrinkWraps, isEmpty);

    final sheetScrollable = find.descendant(
      of: find.byKey(const ValueKey('campus-map-sheet')),
      matching: find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
      ),
    );

    // 滚动列表确认尾部条目可懒加载到达。
    await tester.scrollUntilVisible(
      find.text('教学建筑 179'),
      400,
      scrollable: sheetScrollable,
    );
    expect(find.text('教学建筑 179'), findsOneWidget);

    // 回到顶部点击首栋教学楼并进入室内，验证房间网格同样按需懒构建。
    tester.state<ScrollableState>(sheetScrollable).position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.tap(find.text('教学建筑 000'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('室内'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('展开地图面板'));
    await tester.pumpAndSettle();

    expect(find.text('R000'), findsOneWidget);
    expect(find.text('R071'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('一层东卫生间'),
      300,
      scrollable: sheetScrollable,
    );
    expect(find.text('一层东卫生间'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('移除 IntrinsicHeight 与大阴影模糊，在窄屏/宽屏与大字号下无溢出', (tester) async {
    const place = CampusPlace(
      id: 'b1',
      name: '北辰楼超长测试名称用来检验窄屏换行与不溢出',
      buildingId: 'b1',
      category: PlaceCategory.study,
      hasIndoor: true,
      floors: [CampusFloor(id: 'f1', label: '1F', number: 1)],
    );
    final route = _sampleRoute();
    final progress = route.progressAt(30);

    for (final config in [
      (size: const Size(320, 568), scale: 1.0, dark: false),
      (size: const Size(320, 568), scale: 2.0, dark: false),
      (size: const Size(390, 844), scale: 2.0, dark: true),
      (size: const Size(1000, 800), scale: 1.0, dark: false),
    ]) {
      tester.view.physicalSize = config.size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          theme: config.dark ? appDarkTheme() : appLightTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(config.scale)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CampusPlacePanel(
                    place: place,
                    floor: null,
                    room: null,
                    floorData: const CampusFloorSnapshot(),
                    floorLoading: false,
                    floorError: null,
                    route: null,
                    routing: false,
                    onDetail: () {},
                    onClose: () {},
                    onRoute: () {},
                    onIndoor: () {},
                    onStreet: () {},
                    onRetryFloor: () {},
                    onRoom: (_) {},
                    onCloseRoute: () {},
                  ),
                  const SizedBox(height: 16),
                  CampusNavBanner(progress: progress),
                  const SizedBox(height: 16),
                  CampusRoutePreview(
                    route: route,
                    originLabel: '我的位置',
                    destinationLabel: '北辰楼',
                    onStart: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.byType(IntrinsicHeight), findsNothing);

      // 默认字号下主操作与次要操作方块保持 56px 等高对齐。
      if (config.scale == 1.0) {
        final routeHeight = tester.getSize(find.text('路线').first).height;
        final streetBox = tester.getSize(
          find.ancestor(of: find.text('街景'), matching: find.byType(InkWell)),
        );
        expect(streetBox.height, 56.0);
        expect(routeHeight, greaterThan(0));
      }

      // 导航横幅阴影已收紧，保持层次同时避免过大的模糊半径。
      final bannerDecorations = tester
          .widgetList<Container>(
            find.descendant(
              of: find.byType(CampusNavBanner),
              matching: find.byType(Container),
            ),
          )
          .map((c) => c.decoration)
          .whereType<BoxDecoration>()
          .expand((d) => d.boxShadow ?? const <BoxShadow>[]);
      expect(bannerDecorations, isNotEmpty);
      for (final shadow in bannerDecorations) {
        expect(shadow.blurRadius, lessThanOrEqualTo(16));
      }

      expect(tester.takeException(), isNull);
    }

    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
