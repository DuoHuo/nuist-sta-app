import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_next_day_reminder.dart';

TodayCourseItem course(
  int node, {
  String name = '测试课程',
  String location = '',
}) => TodayCourseItem(
  course: Course(id: 'mock-$node', name: name),
  slot: CourseSlot(
    day: 2,
    startNode: node,
    endNode: node + 1,
    weeks: '1',
    location: location,
  ),
  status: TodayCourseStatus.upcoming,
);

void main() {
  const periods = [
    PeriodTime(node: 1, start: '08:00', end: '08:45'),
    PeriodTime(node: 3, start: '10:10', end: '10:55'),
    PeriodTime(node: 5, start: '13:45', end: '14:30'),
    PeriodTime(node: 7, start: '15:25', end: '16:10'),
  ];
  final weekday = DateTime(2026, 10, 27);
  final saturday = DateTime(2026, 10, 31);

  NextDayReminderPayload? payload(
    List<TodayCourseItem> courses, {
    DateTime? date,
    bool loggedIn = true,
    bool hasCache = true,
    bool outsideTerm = false,
  }) => buildNextDayReminder(
    tomorrow: date ?? weekday,
    courses: courses,
    periods: periods,
    loggedIn: loggedIn,
    hasCache: hasCache,
    outsideTerm: outsideTerm,
  );

  test('旧设置默认开启明日提醒，22:00；课前提醒仍默认关闭', () {
    for (final s in [
      const TimetableSettings(),
      TimetableSettings.fromJson({}),
    ]) {
      expect(s.nextDayReminderEnabled, isTrue);
      expect(s.nextDayReminderMinute, 1320);
      expect(s.reminderEnabled, isFalse);
    }
  });

  test('设置 JSON、copyWith 和缓存偏好合并保留独立开关与时间', () {
    final s = const TimetableSettings().copyWith(
      nextDayReminderEnabled: false,
      nextDayReminderMinute: 1410,
      reminderEnabled: true,
    );
    final decoded = TimetableSettings.fromJson(s.toJson());
    expect(decoded.toJson(), s.toJson());
    final merged = const TimetableSettings(termCode: 'mock')
        .withDisplayPrefsFrom(decoded);
    expect(merged.termCode, 'mock');
    expect(merged.nextDayReminderEnabled, isFalse);
    expect(merged.nextDayReminderMinute, 1410);
    expect(merged.reminderEnabled, isTrue);
  });

  test('提醒时间仅接受21:00至23:30的半小时档位', () {
    for (final v in TimetableSettings.nextDayReminderOptions) {
      expect(
        TimetableSettings.fromJson({'nextDayReminderMinute': v})
            .nextDayReminderMinute,
        v,
      );
    }
    for (final v in [null, '22:00', 1259, 1261, 1440, 1320.5]) {
      expect(
        TimetableSettings.fromJson({'nextDayReminderMinute': v})
            .nextDayReminderMinute,
        1320,
      );
    }
  });

  test('未登录或无缓存不推；有缓存的空课表仍推无课文案', () {
    expect(payload([], loggedIn: false), isNull);
    expect(payload([], hasCache: false), isNull);
    expect(payload([])!.title, '明天没课');
    expect(payload([])!.body, '好好休息');
    expect(payload([])!.warmLine, '难得轻松一天');
  });

  test('周末与假期文案；假期优先，不把未知数据当假期', () {
    expect(payload([], date: saturday)!.title, '周末没课');
    expect(payload([], date: saturday)!.warmLine, isNull);
    expect(payload([course(1)], date: saturday)!.title, '周末有课');
    expect(payload([course(1)], date: saturday)!.warmLine, isNull);
    expect(payload([], outsideTerm: true)!.body, '假期模式');
    expect(payload([], outsideTerm: true)!.warmLine, isNull);
    expect(payload([], hasCache: false, outsideTerm: true), isNull);
  });

  test('早八、非早八首节、作息时间与缺失地点', () {
    final early = payload([course(1, location: '测试教室')])!;
    expect(early.title, '明天早八');
    expect(early.body, '第1–2节 · 测试课程 · 测试教室');
    expect(early.warmLine, '记得早睡');
    expect(payload([course(2)])!.title, '明天早八');
    for (final node in [3, 5, 7]) {
      final p = payload([course(node)])!;
      expect(p.title, '明天第$node节开始');
      expect(
        p.body,
        '${periods.firstWhere((p) => p.node == node).start} · 测试课程',
      );
      expect(p.warmLine, isNull);
    }
    expect(payload([course(9)])!.body, '第9节 · 测试课程');
  });

  test('多门课按修改后的节次排序，正文带剩余数量且不输出教师', () {
    final p = payload([course(7), course(1, name: '第一门')])!;
    expect(p.title, '明天早八');
    expect(p.body, '第1–2节 · 第一门');
    expect(p.toJson()['footer'], '按本机已保存课表');
    expect(payload([course(7), course(3)])!.title, '明天有 2 节课');
    expect(payload([course(7), course(3)])!.body, '首节 10:10 · 测试课程；还有 1 节');
  });

  test('标题随次日首节与周末变化，页脚始终是本机已保存课表', () {
    final cases = [
      (payload([course(1), course(5)])!, '明天早八', '记得早睡'),
      (payload([course(3)])!, '明天第3节开始', null),
      (payload([course(5)])!, '明天第5节开始', null),
      (payload([course(7)])!, '明天第7节开始', null),
      (payload([course(3), course(7)])!, '明天有 2 节课', null),
      (payload([])!, '明天没课', '难得轻松一天'),
      (payload([], date: saturday)!, '周末没课', null),
      (payload([course(3)], date: saturday)!, '周末有课', null),
      (payload([], outsideTerm: true)!, '明天没课', null),
    ];
    for (final (p, title, warm) in cases) {
      expect(p.title, title);
      expect(p.title.runes.length, lessThanOrEqualTo(8));
      expect(p.warmLine, warm);
      expect(p.toJson()['footer'], '按本机已保存课表');
    }
  });

  test('多门课含早八仍显示首节节次和地点，和设计稿早八行一致', () {
    final p = payload([course(5), course(1, location: '测试教室')])!;
    expect(p.title, '明天早八');
    expect(p.body, '第1–2节 · 测试课程 · 测试教室');
  });

  test('体育项目推送共用去序号显示名，项目为空保留原课名', () {
    final item = course(3, name: '体育（3）');
    final pe = item.course.copyWith(projectName: '射箭');
    final named = TodayCourseItem(
      course: pe,
      slot: item.slot,
      status: item.status,
    );
    expect(payload([named])!.body, '10:10 · 体育·射箭');
    expect(payload([item])!.body, '10:10 · 体育（3）');
    expect(pe.name, '体育（3）');
  });

  test('长课名截断、换行折叠，通知正文保持单行', () {
    final p = payload([
      course(3, name: '${'长' * 30}\n课程', location: '测试\n教室'),
    ])!;
    expect(p.body, contains('…'));
    expect(p.body, isNot(contains('\n')));
  });

  test('所选时间起至23:59补推，同一自然日去重，午夜不补昨天', () {
    bool due(
      DateTime now, {
      String? last,
      bool enabled = true,
      int minute = 1320,
    }) => nextDayReminderDue(
      now: now,
      enabled: enabled,
      minuteOfDay: minute,
      lastEveNotifyDate: last,
    );
    expect(due(DateTime(2026, 10, 27, 21, 59)), isFalse);
    expect(due(DateTime(2026, 10, 27, 22)), isTrue);
    expect(due(DateTime(2026, 10, 27, 23, 59, 59)), isTrue);
    expect(due(DateTime(2026, 10, 27, 23), last: '2026-10-27'), isFalse);
    expect(due(DateTime(2026, 10, 27, 23), enabled: false), isFalse);
    expect(due(DateTime(2026, 10, 28), last: '2026-10-27'), isFalse);
    expect(due(DateTime(2026, 10, 28, 22), last: '2026-10-27'), isTrue);
    expect(due(DateTime(2026, 10, 27, 21), minute: 1260), isTrue);
    expect(nextDayReminderDateKey(DateTime(2026, 1, 2, 23)), '2026-01-02');
  });
}
