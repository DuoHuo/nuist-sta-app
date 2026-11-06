import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/auth/portal_exceptions.dart';
import 'package:nuist_sta_app/mini_apps/electricity/electricity_controller.dart';
import 'package:nuist_sta_app/mini_apps/electricity/electricity_models.dart';

const _room = ElecRoom(
  campus: ElecOption(name: '测试校区', value: 'campus'),
  building: ElecOption(name: '测试楼栋', value: 'building'),
  room: ElecOption(name: '测试房间', value: 'room'),
);
final _cached = ElecReading(time: DateTime(2026, 11, 6), kwh: 20);

class _Harness {
  _Harness({this.storedRoom, this.cached}) {
    addTearDown(controller.dispose);
  }

  bool bound = false;
  ElecRoom? storedRoom;
  ElecReading? cached;
  Future<bool> Function()? checkBinding;
  Future<double> Function()? query;
  int roomReads = 0;
  int queries = 0;
  final readings = <ElecReading>[];

  late final controller = ElectricityController.forTesting(
    bindingCheck: () async =>
        checkBinding == null ? bound : await checkBinding!(),
    readRoom: () async {
      roomReads++;
      return storedRoom;
    },
    readLatest: (_) async => cached,
    queryBalance: (_) async {
      queries++;
      return query == null ? 30 : await query!();
    },
    appendReading: (_, reading) async => readings.add(reading),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('未绑定宿舍时绑定和解绑都立即更新门户状态，不查询余额', () async {
    final h = _Harness();
    await h.controller.ensureStarted();
    expect(h.controller.portalBound, isFalse);

    await h.controller.onPortalBindingChanged(true);
    expect(h.controller.portalBound, isTrue);
    expect(h.controller.room, isNull);

    await h.controller.onPortalBindingChanged(false);
    expect(h.controller.portalBound, isFalse);
    expect(h.queries, 0);
    expect(h.roomReads, 1);
  });

  test('未绑定宿舍时普通刷新也会重读门户绑定状态', () async {
    final h = _Harness();
    await h.controller.ensureStarted();
    h.bound = true;

    await h.controller.refresh();

    expect(h.controller.portalBound, isTrue);
    expect(h.queries, 0);
  });

  test('首次挂载前绑定先恢复宿舍再刷新，解绑保留宿舍和余额', () async {
    final h = _Harness(storedRoom: _room, cached: _cached);

    await h.controller.onPortalBindingChanged(true);
    await h.controller.ensureStarted();

    expect(h.controller.portalBound, isTrue);
    expect(h.controller.room, same(_room));
    expect(h.controller.latest?.kwh, 30);
    expect(h.queries, 1);
    expect(h.roomReads, 1);

    final latest = h.controller.latest;
    await h.controller.onPortalBindingChanged(false);

    expect(h.controller.portalBound, isFalse);
    expect(h.controller.room, same(_room));
    expect(h.controller.latest, same(latest));
    expect(h.readings, [latest]);
  });

  test('初始化中的旧绑定检查不能覆盖新绑定事件', () async {
    final h = _Harness(storedRoom: _room, cached: _cached);
    final checking = Completer<void>();
    final oldBinding = Completer<bool>();
    h.checkBinding = () {
      checking.complete();
      return oldBinding.future;
    };
    final starting = h.controller.ensureStarted();
    await checking.future;

    final binding = h.controller.onPortalBindingChanged(true);
    expect(h.controller.portalBound, isTrue);
    oldBinding.complete(false);
    await Future.wait([starting, binding]);

    expect(h.controller.portalBound, isTrue);
    expect(h.controller.latest?.kwh, 30);
    expect(h.queries, 1);
  });

  for (final fails in [false, true]) {
    test('解绑后忽略仍在返回的旧请求${fails ? '错误' : '余额'}', () async {
      final h = _Harness(storedRoom: _room, cached: _cached);
      await h.controller.ensureStarted();
      h.bound = true;
      final requested = Completer<void>();
      final response = Completer<double>();
      h.query = () {
        requested.complete();
        return response.future;
      };
      final refreshing = h.controller.refresh();
      await requested.future;

      await h.controller.onPortalBindingChanged(false);
      expect(h.controller.portalBound, isFalse);
      if (fails) {
        response.completeError(const PortalLoginError('合成旧会话错误'));
      } else {
        response.complete(10);
      }
      await refreshing;

      expect(h.controller.portalBound, isFalse);
      expect(h.controller.room, same(_room));
      expect(h.controller.latest, same(_cached));
      expect(h.controller.error, isNull);
      expect(h.controller.loading, isFalse);
      expect(h.readings, isEmpty);
    });
  }

  test('刷新合流，重新绑定等待旧请求结束后仅用新请求更新余额', () async {
    final h = _Harness(storedRoom: _room, cached: _cached);
    await h.controller.ensureStarted();
    h.bound = true;
    final oldRequested = Completer<void>();
    final oldResponse = Completer<double>();
    final newRequested = Completer<void>();
    final newResponse = Completer<double>();
    h.query = () {
      if (h.queries == 1) {
        oldRequested.complete();
        return oldResponse.future;
      }
      newRequested.complete();
      return newResponse.future;
    };
    final refreshing = h.controller.refresh();
    expect(h.controller.refresh(), same(refreshing));
    await oldRequested.future;

    final binding = h.controller.onPortalBindingChanged(true);
    oldResponse.complete(10);
    await newRequested.future;
    expect(h.controller.latest, same(_cached));
    expect(h.readings, isEmpty);
    newResponse.complete(40);
    await Future.wait([refreshing, binding]);

    expect(h.controller.portalBound, isTrue);
    expect(h.controller.latest?.kwh, 40);
    expect(h.queries, 2);
    expect(h.readings.map((reading) => reading.kwh), [40]);
  });

  test('等待旧刷新期间再次解绑，不补发已经过时的绑定刷新', () async {
    final h = _Harness(storedRoom: _room, cached: _cached);
    await h.controller.ensureStarted();
    h.bound = true;
    final requested = Completer<void>();
    final response = Completer<double>();
    h.query = () {
      requested.complete();
      return response.future;
    };
    final refreshing = h.controller.refresh();
    await requested.future;

    final binding = h.controller.onPortalBindingChanged(true);
    await h.controller.onPortalBindingChanged(false);
    response.complete(10);
    await Future.wait([refreshing, binding]);

    expect(h.controller.portalBound, isFalse);
    expect(h.controller.latest, same(_cached));
    expect(h.queries, 1);
    expect(h.readings, isEmpty);
  });
}
