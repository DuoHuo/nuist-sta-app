import 'timetable_models.dart';

/// 明日课表通知文案；通知仅使用本机保存的课程结果。
class NextDayReminderPayload {
  const NextDayReminderPayload(this.title, this.body, {this.warmLine});

  final String title;
  final String body;
  final String? warmLine;

  /// 原生通知页脚固定标明数据来源。
  Map<String, Object?> toJson() => {
    'title': title,
    'body': body,
    'warmLine': warmLine,
    'footer': '按本机已保存课表',
  };
}

/// 本机自然日键，不经 UTC 转换，避免跨时区改变去重日期。
String nextDayReminderDateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// 当天到达所选时间后可以补推，跨午夜只判断新的一天。
bool nextDayReminderDue({
  required DateTime now,
  required bool enabled,
  required int minuteOfDay,
  String? lastEveNotifyDate,
}) =>
    enabled &&
    now.hour * 60 + now.minute >= minuteOfDay &&
    lastEveNotifyDate != nextDayReminderDateKey(now);

String _short(String value, int limit) {
  final chars = value.replaceAll(RegExp(r'\s+'), ' ').trim().runes.toList();
  return chars.length <= limit
      ? String.fromCharCodes(chars)
      : '${String.fromCharCodes(chars.take(limit - 1))}…';
}

/// 生成明天的通知。优先级：无缓存/未登录、假期、周末、早八、首节节次。
/// 非早八多门课用数量标题，单门采用节次标题；早八优先于数量。
NextDayReminderPayload? buildNextDayReminder({
  required DateTime tomorrow,
  required List<TodayCourseItem> courses,
  required List<PeriodTime> periods,
  required bool loggedIn,
  required bool hasCache,
  bool outsideTerm = false,
  String? Function(TodayCourseItem item)? startTimeOf,
}) {
  if (!loggedIn || !hasCache) return null;
  if (outsideTerm) {
    return const NextDayReminderPayload('明天没课', '假期模式');
  }
  final weekend = tomorrow.weekday >= DateTime.saturday;
  if (courses.isEmpty) {
    return NextDayReminderPayload(
      weekend ? '周末没课' : '明天没课',
      '好好休息',
      warmLine: weekend ? null : '难得轻松一天',
    );
  }
  final sorted = [...courses]
    ..sort((a, b) => a.slot.startNode.compareTo(b.slot.startNode));
  final first = sorted.first;
  final node = first.slot.startNode;
  final early = node <= 2;
  final time = startTimeOf != null
      ? startTimeOf(first)
      : periods.where((p) => p.node == node).firstOrNull?.start;
  final when = early
      ? '第${first.slot.startNode}–${first.slot.endNode}节'
      : (time == null || time.isEmpty ? '第$node节' : time);
  final name = _short(first.course.displayName, 16);
  final location = _short(first.slot.location, 12);
  final body = courses.length > 1 && !early
      ? '首节 ${time ?? when} · $name；还有 ${courses.length - 1} 节'
      : '${weekend ? '首节 ' : ''}$when · $name${location.isEmpty ? '' : ' · $location'}';
  return NextDayReminderPayload(
    weekend
        ? '周末有课'
        : early
        ? '明天早八'
        : courses.length > 1
        ? '明天有 ${courses.length} 节课'
        : '明天第$node节开始',
    body,
    warmLine: early && !weekend ? '记得早睡' : null,
  );
}
