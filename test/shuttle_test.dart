import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/config/campus_config.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_data.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_page.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/shuttle_api.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/shuttle_controller.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/shuttle_map_layer.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/shuttle_models.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/shuttle_stations.dart';

import 'campus_map_api_test.dart' show FakeAdapter, response;
import 'campus_map_test.dart' show TestSource;

Map<String, dynamic> row(String id, {int online = 1}) => {
  'vid': id, 'ol': online, 'mlng': '118.72422', 'mlat': 32.203814, 'hx': 0,
  // 定位时间不参与网页的在线状态判定。
  'gt': '2000-01-01 00:00:00',
};

class FakeShuttleSource implements ShuttleSource {
  final pending = <Completer<List<ShuttleVehicle>>>[];
  bool closed = false;
  @override
  Future<List<ShuttleVehicle>> load() {
    final result = Completer<List<ShuttleVehicle>>();
    pending.add(result);
    return result.future;
  }

  @override
  void close() => closed = true;
}

void main() {
  test('坐标逆变换匹配校准工具，在线状态只看 ol', () {
    final v = ShuttleVehicle.parse(row('bus-a'))!;
    expect(v.point.longitude, closeTo(118.71900271346217, 1e-9));
    expect(v.point.latitude, closeTo(32.205896754242346, 1e-9));
    expect(v.online, isTrue);
    expect(ShuttleVehicle.parse(row('bus-a', online: 0))!.online, isFalse);
    expect(ShuttleVehicle.parse({...row('bus-a'), 'mlng': 'NaN'}), isNull);
  });

  test('四向初值和跨界五度迟滞', () {
    for (final entry in <double, ShuttleDirection>{
      0: ShuttleDirection.north,
      44.99: ShuttleDirection.north,
      45: ShuttleDirection.east,
      135: ShuttleDirection.south,
      225: ShuttleDirection.west,
      315: ShuttleDirection.north,
    }.entries) {
      expect(ShuttleDirection.fromHeading(entry.key), entry.value);
    }
    expect(
      ShuttleDirection.fromHeading(49.99, ShuttleDirection.north),
      ShuttleDirection.north,
    );
    expect(
      ShuttleDirection.fromHeading(50, ShuttleDirection.north),
      ShuttleDirection.east,
    );
    expect(
      ShuttleDirection.fromHeading(40.01, ShuttleDirection.east),
      ShuttleDirection.east,
    );
    expect(
      ShuttleDirection.fromHeading(40, ShuttleDirection.east),
      ShuttleDirection.north,
    );
    expect(
      ShuttleDirection.fromHeading(310.01, ShuttleDirection.north),
      ShuttleDirection.north,
    );
    expect(
      ShuttleDirection.fromHeading(310, ShuttleDirection.north),
      ShuttleDirection.west,
    );
  });

  test('站点在24逻辑像素拆分，每组只生成一个名称', () {
    expect(shuttleStations, hasLength(13));
    expect(shuttleStations.map((s) => s.id).toSet(), hasLength(13));
    expect(
      shuttleStations.map((s) => s.id),
      everyElement(startsWith('nuist-bus-stop-')),
    );
    final merged = ShuttleMapLayer.stations(List.filled(13, 23.99));
    final split = ShuttleMapLayer.stations(List.filled(13, 24));
    final mergedFeatures = merged['features'] as List;
    final splitFeatures = split['features'] as List;
    expect(mergedFeatures, hasLength(13));
    expect(splitFeatures, hasLength(26));
    expect(
      splitFeatures.where((f) => f['properties']['name'] != ''),
      hasLength(13),
    );
    final station = shuttleStations.first;
    expect(
      station.unifiedPoint().longitude,
      (station.first.longitude + station.second.longitude) / 2,
    );
    expect(
      station.unifiedPoint().latitude,
      (station.first.latitude + station.second.latitude) / 2,
    );
    expect(splitFeatures.first['geometry']['coordinates'], [
      station.first.longitude,
      station.first.latitude,
    ]);
  });

  test('车辆GeoJSON按当前列表生成，颜色由ol决定，动画不外推', () {
    final v = ShuttleVehicle.parse(row('a', online: 0))!;
    final data = ShuttleMapLayer.vehicles([v], {'a': ShuttleDirection.west}, {
      'a': const GeoPoint(longitude: 118, latitude: 32),
    }, .5);
    final f = (data['features'] as List).single;
    expect(f['id'], 'a');
    expect(f['properties'], {'icon': 'shuttle-offline', 'heading': 270.0});
    expect(
      f['geometry']['coordinates'][0],
      closeTo((118 + v.point.longitude) / 2, 1e-10),
    );
    expect(ShuttleMapLayer.vehicles([], {}, {}, 1)['features'], isEmpty);
  });

  test('接口动态发现会话、失效重登、按vid去重且保留离线车辆', () async {
    final dio = Dio();
    var loginCount = 0;
    var statusCount = 0;
    final adapter = FakeAdapter((request) {
      if (request.uri.host == Uri.parse(kCampusShuttlePageUrl).host) {
        return ResponseBody.fromString(
          'var url = "http://${CampusHosts.shuttleApi}:8080/StandardApiAction_login.action?account=synthetic";',
          200,
        );
      }
      if (request.uri.path.endsWith('login.action')) {
        loginCount++;
        return response({'jsession': 'synthetic-$loginCount'});
      }
      statusCount++;
      if (statusCount == 1) return response({'result': 1});
      return response({
        'result': 0,
        'status': [row('NXD4'), row('NXD40', online: 0), row('NXD4')],
      });
    });
    dio.httpClientAdapter = adapter;
    final api = ShuttleApi(dio: dio);
    final vehicles = await api.load();
    expect(loginCount, 2);
    expect(vehicles.map((v) => v.id), ['NXD4', 'NXD40']);
    expect(vehicles.last.online, isFalse);
    expect(adapter.requests.last.uri.queryParameters['toMap'], '1');
    api.close();
    expect(adapter.closed, isFalse);
    dio.close();
  });

  test('批量查询全部一位两位NXD编号，筛选完整编号并按vid去重', () async {
    final dio = Dio();
    final adapter = FakeAdapter((request) {
      if (request.uri.host == Uri.parse(kCampusShuttlePageUrl).host) {
        return ResponseBody.fromString(
          'var url = "http://${CampusHosts.shuttleApi}:8080/StandardApiAction_login.action?account=synthetic";',
          200,
        );
      }
      if (request.uri.path.endsWith('login.action')) {
        return response({'jsession': 'synthetic'});
      }
      return response({
        'result': 0,
        'status': [
          row('NXD4'),
          row('NXD40', online: 0),
          row('NXD99'),
          row('NXD0'),
          row('NXD01'),
          row('NXD4'),
          row('NXD100'),
          row('NXD'),
          row('NXD4extra'),
          row('otherNXD4'),
          row('nxd4'),
          row('NXD-1'),
          row('NXD１'),
        ],
      });
    });
    dio.httpClientAdapter = adapter;
    final api = ShuttleApi(dio: dio);
    try {
      final vehicles = await api.load();
      final requests = adapter.requests
          .where((r) => r.uri.path.endsWith('getDeviceStatus.action'))
          .toList();
      expect(requests, hasLength(1));
      final ids = requests.single.uri.queryParameters['vehiIdno']!.split(',');
      expect(ids, containsAll(['NXD0', 'NXD4', 'NXD40', 'NXD99', 'NXD01']));
      expect(ids, hasLength(110));
      expect(ids.toSet(), hasLength(ids.length));
      expect(ids, everyElement(matches(RegExp(r'^NXD[0-9]{1,2}$'))));
      expect(vehicles.map((v) => v.id), [
        'NXD4',
        'NXD40',
        'NXD99',
        'NXD0',
        'NXD01',
      ]);
      expect(vehicles.firstWhere((v) => v.id == 'NXD40').online, isFalse);
      await api.load();
      expect(
        adapter.requests.where((r) => r.uri.path.endsWith('login.action')),
        hasLength(1),
      );
      expect(
        adapter.requests.where(
          (r) => r.uri.path.endsWith('getDeviceStatus.action'),
        ),
        hasLength(2),
      );
    } finally {
      api.close();
      dio.close();
    }
  });

  test('网页不能引入新的接口主机', () async {
    final dio = Dio()
      ..httpClientAdapter = FakeAdapter(
        (_) => ResponseBody.fromString(
          'var url = "http://unexpected.example/StandardApiAction_login.action";',
          200,
        ),
      );
    final api = ShuttleApi(dio: dio);
    await expectLater(api.load(), throwsFormatException);
    api.close();
    dio.close();
  });

  testWidgets('失败只提示一次，继续轮询；成功缺失车辆移除，后台停止', (tester) async {
    final source = FakeShuttleSource();
    final controller = ShuttleController(source);
    var errors = 0;
    controller.onFirstFailure = () => errors++;
    controller.setActive(true);
    source.pending.last.completeError(StateError('synthetic'));
    await tester.pump();
    expect(errors, 1);
    await tester.pump(const Duration(seconds: 3));
    source.pending.last.complete([
      ShuttleVehicle.parse(row('a'))!,
      ShuttleVehicle.parse(row('b', online: 0))!,
    ]);
    await tester.pump();
    expect(controller.vehicles, hasLength(2));
    await tester.pump(const Duration(seconds: 3));
    source.pending.last.complete([ShuttleVehicle.parse(row('a'))!]);
    await tester.pump();
    expect(controller.vehicles.map((v) => v.id), ['a']);
    await tester.pump(const Duration(seconds: 3));
    source.pending.last.completeError(StateError('synthetic'));
    await tester.pump();
    expect(errors, 1);
    controller.setActive(false);
    final count = source.pending.length;
    await tester.pump(const Duration(seconds: 9));
    expect(source.pending.length, count);
    controller.setActive(true);
    expect(source.pending.length, count + 1);
    controller.setActive(false);
    source.pending.last.complete([]);
    await tester.pump();
    expect(controller.vehicles, hasLength(1));
    controller.dispose();
    expect(source.closed, isTrue);
  });

  testWidgets('页面仅显示一次短toast，前后台及图层切换控制请求', (tester) async {
    final source = FakeShuttleSource();
    await tester.pumpWidget(
      MaterialApp(
        home: CampusMapPage(
          source: TestSource(),
          shuttleSource: source,
          useNativeMap: false,
          styleUrl: 'synthetic-style',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(source.pending, isEmpty);
    await tester.tap(find.byTooltip('地图图层'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('公共交通'));
    await tester.pumpAndSettle();
    expect(source.pending, hasLength(1));
    source.pending.last.completeError(StateError('synthetic'));
    await tester.pump();
    await tester.pump();
    expect(find.text('车辆位置暂时无法更新'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('车辆位置暂时无法更新'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    source.pending.last.completeError(StateError('synthetic'));
    await tester.pump();
    expect(find.text('车辆位置暂时无法更新'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final count = source.pending.length;
    await tester.pump(const Duration(seconds: 6));
    expect(source.pending, hasLength(count));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(source.pending, hasLength(count + 1));
    source.pending.last.complete([]);
    await tester.pump();
    await tester.tap(find.byTooltip('地图图层'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标准地图'));
    await tester.pumpAndSettle();
    final stoppedCount = source.pending.length;
    await tester.pump(const Duration(seconds: 6));
    expect(source.pending, hasLength(stoppedCount));
    await tester.pumpWidget(const SizedBox());
    expect(source.closed, isTrue);
  });

  testWidgets('俯视图标输出高分辨率透明PNG', (tester) async {
    final bytes = await tester.runAsync(
      () => ShuttleMapLayer.icon(const Color(0xFF409CE8), 3),
    );
    expect(bytes!.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    final header = ByteData.sublistView(bytes);
    expect(header.getUint32(16), 288);
    expect(header.getUint32(20), 288);
  });
}
