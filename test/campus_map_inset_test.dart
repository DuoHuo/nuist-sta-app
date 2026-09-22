import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_data.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_native.dart';

void main() {
  const latitude = 32.20275;

  test('bottom panel shifts the camera south so the target sits in the visible strip', () {
    // 面板遮住下半屏 400px：目标要显示在「面板顶部→屏幕顶部」中心，
    // 也就是比屏幕中心高 200px，等价于相机中心向南移 200px。
    final offset = cameraInsetOffset(
      latitude: latitude,
      zoom: 17,
      insets: const EdgeInsets.only(bottom: 400),
    );
    final worldPx = 512.0 * 131072.0; // zoom 17
    final expected =
        -360.0 * math.cos(latitude * math.pi / 180.0) * 200 / worldPx;
    expect(offset.latitude, closeTo(expected, 1e-9));
    expect(offset.latitude, lessThan(0));
    expect(offset.longitude, 0);
  });

  test('left panel shifts the camera west so the target moves right', () {
    final offset = cameraInsetOffset(
      latitude: latitude,
      zoom: 17,
      insets: const EdgeInsets.only(left: 384),
    );
    expect(offset.longitude, lessThan(0));
    expect(offset.latitude, 0);
  });

  test('top and bottom insets partially cancel out', () {
    final offset = cameraInsetOffset(
      latitude: latitude,
      zoom: 15,
      insets: const EdgeInsets.only(top: 100, bottom: 300),
    );
    final symmetric = cameraInsetOffset(
      latitude: latitude,
      zoom: 15,
      insets: const EdgeInsets.only(bottom: 200),
    );
    expect(offset.latitude, closeTo(symmetric.latitude, 1e-12));
  });

  test('no insets or invalid zoom leaves the camera untouched', () {
    expect(
      cameraInsetOffset(latitude: latitude, zoom: 17, insets: EdgeInsets.zero),
      (latitude: 0.0, longitude: 0.0),
    );
    expect(
      cameraInsetOffset(
        latitude: latitude,
        zoom: 0,
        insets: const EdgeInsets.only(bottom: 400),
      ),
      (latitude: 0.0, longitude: 0.0),
    );
  });

  test('offset scales with zoom: halving detail doubles degrees per pixel', () {
    final coarse = cameraInsetOffset(
      latitude: latitude,
      zoom: 16,
      insets: const EdgeInsets.only(bottom: 400),
    );
    final fine = cameraInsetOffset(
      latitude: latitude,
      zoom: 17,
      insets: const EdgeInsets.only(bottom: 400),
    );
    expect(coarse.latitude, closeTo(fine.latitude * 2, 1e-12));
  });

  test(
    'tilt stretches the vertical offset so the target stays in the strip',
    () {
      final flat = cameraInsetOffset(
        latitude: latitude,
        zoom: 18,
        insets: const EdgeInsets.only(bottom: 600),
      );
      final tilted = cameraInsetOffset(
        latitude: latitude,
        zoom: 18,
        insets: const EdgeInsets.only(bottom: 600),
        tilt: 52,
      );
      // 倾斜后同样的像素遮挡对应更远的地面距离。
      expect(tilted.latitude.abs(), greaterThan(flat.latitude.abs()));
      expect(
        tilted.latitude.abs() / flat.latitude.abs(),
        closeTo(1 / math.cos(52 * math.pi / 180), 1e-6),
      );
    },
  );

  test('bearing rotates the offset direction', () {
    final north = cameraInsetOffset(
      latitude: latitude,
      zoom: 18,
      insets: const EdgeInsets.only(bottom: 600),
    );
    final south = cameraInsetOffset(
      latitude: latitude,
      zoom: 18,
      insets: const EdgeInsets.only(bottom: 600),
      bearing: 180,
    );
    expect(south.latitude, closeTo(-north.latitude, 1e-12));
    final east = cameraInsetOffset(
      latitude: latitude,
      zoom: 18,
      insets: const EdgeInsets.only(bottom: 600),
      bearing: 90,
    );
    expect(east.longitude, lessThan(0));
  });

  test(
    'floor base elevation prefers backend elevation and falls back by level',
    () {
      const withElevation = CampusFloor(
        id: '1',
        label: '3F',
        number: 3,
        levelIndex: 2,
        elevationM: 7.2,
      );
      const withoutElevation = CampusFloor(
        id: '2',
        label: '3F',
        number: 3,
        levelIndex: 2,
      );
      const basement = CampusFloor(
        id: '3',
        label: 'B1',
        number: 0,
        levelIndex: -1,
      );
      expect(floorBaseElevation(withElevation), 7.2);
      expect(floorBaseElevation(withoutElevation), 2 * kDisplayFloorHeightM);
      expect(floorBaseElevation(basement), -kDisplayFloorHeightM);
    },
  );
}
