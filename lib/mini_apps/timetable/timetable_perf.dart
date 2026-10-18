import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// 课表页首帧性能打点（仅 debug/profile）。
///
/// 测量「进入课表页 → 首帧课程网格绘制完成（缓存数据）」耗时。
/// release 下所有方法因 `kReleaseMode` 为 const 而成为空操作，可被编译器移除；
/// 文字日志（debugPrint / developer.log）只在 `kDebugMode` 输出。
class TimetablePerf {
  TimetablePerf._();

  static final Stopwatch _sw = Stopwatch();
  static bool _armed = false;

  /// 是否已 start 且尚未上报（每次打开页面只上报一次）。
  static bool get armed => !kReleaseMode && _armed;

  /// 页面打开时调用：重置计时并武装一次上报。
  static void start() {
    if (kReleaseMode) return;
    _sw
      ..reset()
      ..start();
    _armed = true;
    developer.Timeline.instantSync('timetable_open');
  }

  /// 首帧网格绘制后调用；每次 [start] 后仅第一次生效，返回毫秒数，否则 null。
  static int? markGridFirstFrame({required int courses}) {
    if (kReleaseMode || !_armed) return null;
    _armed = false;
    _sw.stop();
    final ms = _sw.elapsedMilliseconds;
    final msg = '[PERF] timetable_first_grid_frame=${ms}ms courses=$courses';
    if (kDebugMode) {
      debugPrint(msg);
      developer.log(msg, name: 'perf');
    }
    developer.Timeline.instantSync(
      'timetable_first_grid_frame',
      arguments: {'ms': ms, 'courses': courses},
    );
    return ms;
  }

  @visibleForTesting
  static void resetForTest() {
    _armed = false;
    _sw
      ..stop()
      ..reset();
  }
}
