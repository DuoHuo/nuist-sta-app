import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_data.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_place_detail_page.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_source.dart';

/// 只实现详情页用到的那部分接口：按编号返回固定的地物。
class _FakeSource implements CampusMapSource, CampusMapRemoteSource {
  _FakeSource(this.place, {this.error});
  final CampusPlace place;
  final Object? error;
  int calls = 0;

  @override
  bool get isConfigured => true;
  @override
  Future<CampusPlace> loadPlace(CampusPlace place) async {
    calls++;
    final failure = error;
    if (failure != null) throw failure;
    return this.place;
  }

  @override
  Future<CampusMapSnapshot> loadCampus() async => const CampusMapSnapshot();
  @override
  Future<CampusFloorSnapshot> loadFloor(
    String buildingId,
    String floorId,
  ) async => const CampusFloorSnapshot();
  @override
  Future<CampusRouteResult?> planRoute(CampusRouteRequest request) async =>
      null;
  @override
  Future<List<CampusPlace>> searchPlaces(String query) async => const [];
  @override
  Future<Map<String, dynamic>> locateWifi(
    List<Map<String, dynamic>> observations,
  ) async => const {};
  @override
  Future<Map<String, dynamic>> loadFingerprints({
    String? buildingId,
    String? floorId,
  }) async => const {};
  @override
  Future<Map<String, dynamic>> submitFingerprint(
    Map<String, dynamic> sample, {
    String? collectToken,
  }) async => const {};
}

Future<void> _pump(WidgetTester tester, CampusMapSource source) async {
  await tester.pumpWidget(
    MaterialApp(home: CampusPlaceDetailPage(placeId: 'feature:7', source: source)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('通用地物详情页展示名称、类别、说明与编号', (tester) async {
    final source = _FakeSource(
      const CampusPlace(
        id: 'feature:7',
        name: '南门绿地',
        subtitle: '绿地',
        kind: 'green',
        featureId: 7,
        description: '老图书馆前的草坪，夏天傍晚人多。',
        center: GeoPoint(longitude: 118.7155, latitude: 32.2058),
      ),
    );
    await _pump(tester, source);

    expect(source.calls, 1);
    expect(find.text('南门绿地'), findsWidgets);
    expect(find.text('绿地'), findsWidgets); // 类别标签 + 基本信息里的类别
    expect(find.text('老图书馆前的草坪，夏天傍晚人多。'), findsOneWidget);
    expect(find.text('feature:7'), findsOneWidget);
    expect(find.text('说明'), findsOneWidget);
    // 通用地物没有楼宇资料（模型/照片是建筑专有）。
    expect(find.text('楼宇资料'), findsNothing);
  });

  testWidgets('建筑地物详情页带出楼宇资料模块', (tester) async {
    final source = _FakeSource(
      const CampusPlace(
        id: 'B-DEMO-01',
        name: '示范教学楼',
        buildingId: 'B-DEMO-01',
        description: '',
      ),
    );
    await _pump(tester, source);

    expect(find.text('示范教学楼'), findsWidgets);
    expect(find.text('楼宇资料'), findsOneWidget);
    // 没有说明时不出现空白的说明段。
    expect(find.text('说明'), findsNothing);
    // 无 category 的建筑回退成「建筑」：类别标签与基本信息各一处。
    expect(find.text('建筑'), findsNWidgets(2));
  });

  testWidgets('加载失败时给出错误信息与重试入口', (tester) async {
    final source = _FakeSource(
      const CampusPlace(id: 'feature:9', name: '不存在的地物'),
      error: const CampusMapApiExceptionStub(),
    );
    await _pump(tester, source);

    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(source.calls, 2);
  });
}

/// 详情页把 [CampusMapApiException] 的 message 直接展示，这里用一个等价的异常
/// 覆盖失败路径（避免测试依赖网络层的具体实现）。
class CampusMapApiExceptionStub implements Exception {
  const CampusMapApiExceptionStub();
  @override
  String toString() => '地物详情加载失败，请稍后重试';
}
