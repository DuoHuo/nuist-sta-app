import 'dart:async';
import 'dart:math';

import 'package:sensors_plus/sensors_plus.dart';

/// 南京一带的磁偏角（度，西偏为负）。罗盘指的是磁北，加上它才是地图上的正北。
const double kCampusMagneticDeclination = -5.6;

/// 设备朝向来源：度数，0 = 正北，顺时针增加，范围 [0, 360)。
abstract interface class HeadingSource {
  Stream<double> watch();
}

/// 由重力 [a] 与地磁 [m]（设备坐标系三轴）算出手机顶部指向的方位角（磁北为 0）。
///
/// 与 Android `SensorManager.getRotationMatrix` + `getOrientation` 相同的算法：
/// 先用 地磁 × 重力 得到「东」，再用 重力 × 东 得到「北」，手机怎么倾斜都成立。
/// 自由落体或磁场过弱时返回 null。
double? azimuthFromSensors(
  double ax,
  double ay,
  double az,
  double mx,
  double my,
  double mz,
) {
  var hx = my * az - mz * ay;
  var hy = mz * ax - mx * az;
  var hz = mx * ay - my * ax;
  final normH = sqrt(hx * hx + hy * hy + hz * hz);
  final normA = sqrt(ax * ax + ay * ay + az * az);
  if (normH < 0.1 || normA < 0.1) return null;
  hx /= normH;
  hy /= normH;
  hz /= normH;
  final gx = ax / normA, gz = az / normA;
  final my2 = gz * hx - gx * hz;
  final degrees = atan2(hy, my2) * 180 / pi;
  return (degrees + 360) % 360;
}

/// 把角度差折到 (-180, 180]，用于平滑与阈值判断。
double headingDelta(double from, double to) {
  final d = (to - from) % 360;
  return d > 180 ? d - 360 : d;
}

/// 手机传感器朝向：重力做低通滤波，方位做角度平滑，再按磁偏角校正到正北。
class DeviceHeading implements HeadingSource {
  const DeviceHeading();

  @override
  Stream<double> watch() {
    late StreamController<double> controller;
    StreamSubscription<AccelerometerEvent>? accel;
    StreamSubscription<MagnetometerEvent>? magnet;
    List<double>? gravity;
    double? smoothed;

    void onMagnet(MagnetometerEvent e) {
      final g = gravity;
      if (g == null) return;
      final azimuth = azimuthFromSensors(g[0], g[1], g[2], e.x, e.y, e.z);
      if (azimuth == null) return;
      final previous = smoothed;
      // 角度平滑：每次只朝新读数走 20%，压住磁力计的抖动。
      final next = previous == null
          ? azimuth
          : (previous + headingDelta(previous, azimuth) * 0.2 + 360) % 360;
      smoothed = next;
      controller.add((next + kCampusMagneticDeclination + 360) % 360);
    }

    controller = StreamController<double>(
      onListen: () {
        accel =
            accelerometerEventStream(samplingPeriod: SensorInterval.uiInterval)
                .listen((e) {
                  final g = gravity;
                  // 低通滤波取重力分量，去掉走路时的晃动。
                  gravity = g == null
                      ? [e.x, e.y, e.z]
                      : [
                          g[0] * 0.8 + e.x * 0.2,
                          g[1] * 0.8 + e.y * 0.2,
                          g[2] * 0.8 + e.z * 0.2,
                        ];
                }, onError: controller.addError);
        magnet = magnetometerEventStream(
          samplingPeriod: SensorInterval.uiInterval,
        ).listen(onMagnet, onError: controller.addError);
      },
      onCancel: () async {
        await accel?.cancel();
        await magnet?.cancel();
      },
    );
    return controller.stream;
  }
}
