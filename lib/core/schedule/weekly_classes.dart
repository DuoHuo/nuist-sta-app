/// 「本周课程」的跨小程序接口。
///
/// 小程序之间不能互相 import：课表小程序实现 [WeeklyClassSource]，由壳在启动时
/// 登记到 [WeeklyClasses.source]；校园地图等只通过这里读取，不依赖课表的内部实现。
library;

/// 本周一节（一段连续节次的）课。
class WeeklyClass {
  const WeeklyClass({
    required this.courseName,
    required this.location,
    required this.weekday,
    required this.startNode,
    required this.endNode,
    this.date,
  });

  /// 课程名。
  final String courseName;

  /// 教务给的上课地点原文，如「明德楼A101」「揽江楼 N407」。
  final String location;

  /// 星期 1=周一 … 7=周日（已套用调课后的实际上课日）。
  final int weekday;

  /// 起止节次（含）。
  final int startNode;
  final int endNode;

  /// 上课日期；来源给不出时为 null。
  final DateTime? date;
}

/// 提供本周课程的来源（课表小程序实现）。
abstract interface class WeeklyClassSource {
  /// 本教学周、有上课地点的课；没有课表数据时返回空列表。
  Future<List<WeeklyClass>> thisWeek();
}

/// 全局登记点。未登记（例如 widget 测试）时为 null，调用方应当把它当作「没有课表」。
abstract final class WeeklyClasses {
  static WeeklyClassSource? source;
}
