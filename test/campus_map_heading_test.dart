import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_heading.dart';

void main() {
  // 手机平放（重力沿 +z），地磁场水平分量指向北、垂直分量朝下（北半球）。
  const g = 9.81;

  test('平放、顶部朝北为 0°', () {
    expect(azimuthFromSensors(0, 0, g, 0, 20, -40), closeTo(0, 0.01));
  });

  test('平放、顶部朝东为 90°，朝西为 270°', () {
    // 顶部朝东时，北在手机左侧（-x）。
    expect(azimuthFromSensors(0, 0, g, -20, 0, -40), closeTo(90, 0.01));
    expect(azimuthFromSensors(0, 0, g, 20, 0, -40), closeTo(270, 0.01));
  });

  test('竖着拿（重力沿 +y）也能算出朝向', () {
    // 竖屏立起、屏幕朝南（顶部朝天，背面朝北）：地磁北在 -z 方向。
    final azimuth = azimuthFromSensors(0, g, 0, 0, -40, -20);
    expect(azimuth, isNotNull);
  });

  test('传感器读数异常时返回 null', () {
    expect(azimuthFromSensors(0, 0, 0, 0, 20, -40), isNull);
    expect(azimuthFromSensors(0, 0, g, 0, 0, 0), isNull);
  });

  test('角度差折到 (-180, 180]', () {
    expect(headingDelta(350, 10), closeTo(20, 1e-9));
    expect(headingDelta(10, 350), closeTo(-20, 1e-9));
    expect(headingDelta(0, 180), closeTo(180, 1e-9));
  });
}
