/// 上课提醒与桌面小组件的纯计算部分（不依赖平台，便于单测）。
///
/// 时间一律用本地「墙上时间」字符串交给原生端（`yyyy-MM-ddTHH:mm`），
/// 原生端按当前时区换算成绝对时间；这样改时区 / 改系统时间后重排即可，
/// 不会因为提前算好的 epoch 而错位。
library;

import 'package:flutter/foundation.dart' show immutable;

/// 某天的一节（或连堂）课，已套用调课 / 单日修改 / 删除。
class NotifyClass {
  const NotifyClass({
    required this.name,
    required this.location,
    required this.start,
    required this.end,
    this.courseId = '',
    this.teachers = const [],
    this.startNode = 0,
    this.endNode = 0,
    this.barColor = 0xFF2196F3,
    this.barColorDark = 0xFF2196F3,
  });

  final String name;
  final String location;

  /// 教师原始列表（来自教务 SKJS，按分隔符拆开）；无则空。
  final List<String> teachers;

  /// 课程 id（小组件点击课程行深链用）。
  final String courseId;

  /// 起止节次；0 表示未知。
  final int startNode;
  final int endNode;

  /// 竖条色（ARGB），来自 coursePairFor 底色，浅 / 深各一份。
  final int barColor;
  final int barColorDark;

  /// `第3-4节 10:10-11:50`：节次 + 时段（小组件副行，永不省略）。
  String get periodTime => [
    nodesLabel,
    '${formatHm(start)}-${formatHm(end)}',
  ].where((s) => s.isNotEmpty).join(' ');

  /// `10:10-11:50`
  String get timeRange => '${formatHm(start)}-${formatHm(end)}';

  /// `第3-4节` / `第3节`；节次未知为空串。
  String get nodesLabel => startNode <= 0
      ? ''
      : (endNode > startNode ? '第$startNode-$endNode节' : '第$startNode节');

  /// 本地时间。
  final DateTime start;
  final DateTime end;
}

/// 返回某天（本地日期，时分秒为 0）要上的课。
typedef NotifyClassesOn = List<NotifyClass> Function(DateTime date);

/// 一条提醒闹钟：同一开始时间的多门课合并成一条。
class ReminderAlarm {
  const ReminderAlarm({
    required this.fireAt,
    required this.classStart,
    required this.names,
    required this.locations,
  });

  final DateTime fireAt;
  final DateTime classStart;
  final List<String> names;
  final List<String> locations;

  /// 通知标题。
  String get title =>
      names.length == 1 ? '${names.first} 即将上课' : '${names.length} 门课即将上课';

  /// 通知正文：`08:00 开始 · 教室`。
  String get body {
    final locs = locations.where((l) => l.isNotEmpty).toSet().join(' / ');
    final time = formatHm(classStart);
    final head = names.length == 1 ? '$time 开始' : '$time 开始：${names.join('、')}';
    return locs.isEmpty ? head : '$head · $locs';
  }

  Map<String, Object?> toJson() => {
    'fireAt': formatLocal(fireAt),
    'classStart': formatLocal(classStart),
    'title': title,
    'body': body,
  };
}

/// 提醒提前量可选值（分钟）。
const List<int> kReminderLeadOptions = [5, 10, 15, 30];

/// 提醒排程窗口：今天起 7 天。
const int kReminderWindowDays = 7;

/// 计算 [now] 起 [days] 天内的提醒。
///
/// - 提醒时间 = 开课时间 − [leadMinutes]，可落在前一天（跨日）。
/// - 同一开始时间的课合并为一条。
/// - 已过的提醒不补发（fireAt <= now 丢弃）。
List<ReminderAlarm> planReminders({
  required DateTime now,
  required int leadMinutes,
  required NotifyClassesOn classesOn,
  int days = kReminderWindowDays,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final byStart = <DateTime, List<NotifyClass>>{};
  // 多看一天：明天 0:10 的课提前 30 分钟会落在今天窗口内。
  for (var i = 0; i <= days; i++) {
    final date = DateTime(today.year, today.month, today.day + i);
    for (final c in classesOn(date)) {
      byStart.putIfAbsent(c.start, () => []).add(c);
    }
  }
  final windowEnd = DateTime(today.year, today.month, today.day + days);
  final result = <ReminderAlarm>[];
  final starts = byStart.keys.toList()..sort();
  for (final s in starts) {
    final fireAt = s.subtract(Duration(minutes: leadMinutes));
    if (!fireAt.isAfter(now) || !fireAt.isBefore(windowEnd)) continue;
    final list = byStart[s]!;
    final names = <String>[];
    final locs = <String>[];
    for (final c in list) {
      if (!names.contains(c.name)) names.add(c.name);
      locs.add(c.location);
    }
    result.add(
      ReminderAlarm(
        fireAt: fireAt,
        classStart: s,
        names: names,
        locations: locs,
      ),
    );
  }
  return result;
}

/// 小组件整体状态（原生端在 [WidgetDataState.ok] 时再按时刻细分
/// 上课中 / 课间 / 今日已结束 / 今日无课）。
enum WidgetDataState {
  /// 数据可用。
  ok,

  /// 未登录或数据过期（本周不在缓存 / 超过 7 天未同步）。
  needsUpdate,

  /// 最近一次刷新失败；有历史课程时继续显示课程。
  loadFailed,
}

/// 小组件课程块样式：主块样式（大块，含倒计时或右侧开始时间）/ 紧凑行。
enum WidgetItemStyle { main, compact }

/// 小组件显示开关（默认全开），随 payload 的 `prefs` 交给原生端。
@immutable
class WidgetPrefs {
  const WidgetPrefs({
    this.showTeacher = true,
    this.showLocation = true,
    this.showCountdown = true,
    this.showCount = true,
    this.showPeriod = true,
    this.courseCount = 2,
  });

  /// 主块 / 明天行显示教师；关时 payload 中 teachers=[]、teacherFirst=''。
  final bool showTeacher;

  /// 显示地点；关时 payload 中 location=''。
  final bool showLocation;

  /// 主块倒计时；关时原生显示静态「HH:mm 上课 / 下课」。
  final bool showCountdown;

  /// 表头「+N」表示未展示的课程数量。
  final bool showCount;

  /// 节次标签（「第3-4节」）；关时 payload 中 nodes=''、periodTime 只剩时间。
  final bool showPeriod;

  /// 4×2 最多显示的课程总数 1 / 2 / 3；下一节使用完整块，第三节使用轻量行。
  final int courseCount;

  /// 主课和下一节使用相同的详情层级，第三节按剩余高度显示。
  List<WidgetItemStyle> get slotStyles => [
    WidgetItemStyle.main,
    for (var i = 1; i < courseCount; i++)
      i == 1 ? WidgetItemStyle.main : WidgetItemStyle.compact,
  ];

  Map<String, Object> toJson() => {
    'showTeacher': showTeacher,
    'showLocation': showLocation,
    'showCountdown': showCountdown,
    'showCount': showCount,
    'showPeriod': showPeriod,
    'courseCount': courseCount,
    'slotStyles': [for (final st in slotStyles) st.name],
  };

  @override
  bool operator ==(Object other) =>
      other is WidgetPrefs &&
      other.showTeacher == showTeacher &&
      other.showLocation == showLocation &&
      other.showCountdown == showCountdown &&
      other.showCount == showCount &&
      other.showPeriod == showPeriod &&
      other.courseCount == courseCount;

  @override
  int get hashCode => Object.hash(
    showTeacher,
    showLocation,
    showCountdown,
    showCount,
    showPeriod,
    courseCount,
  );
}

/// 小组件数据窗口：今天起 8 天（今天 + 往后 7 天，用于「下一个有课日」）。
const int kWidgetWindowDays = 8;

/// 构造小组件 payload（JSON 可序列化）。结构见 docs/notify-widget-interface.md。
///
/// [weekOf] 返回某天的教学周（未知为 null）。
/// [tomorrowFirst] 由公共接口注入明天首节；未接线时为 null，不从数据窗口推算。
/// [tomorrowFirstOn] 为窗口内每个日期注入其明天首节，供原生跨零点后离线刷新。
Map<String, Object?> buildWidgetPayload({
  required DateTime now,
  required NotifyClassesOn classesOn,
  int? Function(DateTime date)? weekOf,
  WidgetDataState state = WidgetDataState.ok,
  bool hasCache = true,
  DateTime? lastSyncedAt,
  int days = kWidgetWindowDays,
  WidgetPrefs prefs = const WidgetPrefs(),
  NotifyClass? tomorrowFirst,
  NotifyClass? Function(DateTime date)? tomorrowFirstOn,
}) {
  final today = DateTime(now.year, now.month, now.day);
  // 生成时刻今天各课的显示样式（main / compact；未显示为 null）。原生每次重绘
  // 会按 prefs.slotStyles 和当时时刻重新挑选，这里供布局 / 调试参考。
  final todayList = classesOn(today);
  final sel = selectWidgetRows(todayList, now, prefs: prefs);
  final styleOf = <NotifyClass, WidgetItemStyle>{
    if (sel.main != null) sel.main!: WidgetItemStyle.main,
    for (var i = 0; i < sel.rows.length; i++) sel.rows[i]: sel.styles[i],
  };
  Map<String, Object?> item(NotifyClass c, {WidgetItemStyle? style}) => {
    'name': c.name,
    'location': prefs.showLocation ? c.location : '',
    'teachers': prefs.showTeacher ? c.teachers : const <String>[],
    'teacherFirst': prefs.showTeacher && c.teachers.isNotEmpty
        ? c.teachers.first
        : '',
    'periodTime': prefs.showPeriod ? c.periodTime : c.timeRange,
    // 倒计时关闭时右列的两行静态文字：课前「上课 / 10:10」，上课中「下课 / 11:50」。
    'style': style?.name,
    'staticBefore': {'label': '上课', 'time': formatHm(c.start)},
    'staticDuring': {'label': '下课', 'time': formatHm(c.end)},
    'courseId': c.courseId,
    'startNode': c.startNode,
    'endNode': c.endNode,
    'nodes': prefs.showPeriod ? c.nodesLabel : '',
    'start': formatLocal(c.start),
    'end': formatLocal(c.end),
    'startMs': c.start.millisecondsSinceEpoch,
    'endMs': c.end.millisecondsSinceEpoch,
    'color': c.barColor,
    'colorDark': c.barColorDark,
  };

  Map<String, Object?> day(DateTime d) {
    final isToday = d == today;
    final list = [...(isToday ? todayList : classesOn(d))]
      ..sort((a, b) => a.start.compareTo(b.start));
    final first = tomorrowFirstOn?.call(d) ?? (isToday ? tomorrowFirst : null);
    return {
      if (tomorrowFirstOn != null)
        'tomorrowFirst': first == null ? null : item(first),
      'date': formatDate(d),
      'weekday': d.weekday,
      'week': weekOf?.call(d),
      'items': [
        for (final c in list) item(c, style: isToday ? styleOf[c] : null),
      ],
    };
  }

  return {
    'version': 1,
    'generatedAt': now.millisecondsSinceEpoch,
    'state': state.name,
    'hasCache': hasCache,
    'lastSyncedAt': lastSyncedAt?.millisecondsSinceEpoch,
    'prefs': prefs.toJson(),
    'tomorrowFirst': tomorrowFirst == null ? null : item(tomorrowFirst),
    'days': [
      for (var i = 0; i < days; i++)
        day(DateTime(today.year, today.month, today.day + i)),
    ],
  };
}

/// 标准字号下的主课预算：外边距 20 + 表头 16 + 间距 4 + 主课 56。
/// 原生布局还会按实际 TextView 测量进一步精简，不能用此预算代替原生测量。
const int kWidgetFixedDp = 20 + 16 + 4 + 56;

/// 下一节完整课程块的高度，与原生布局一致，容纳默认字号的三行详情。
const int kWidgetNextCourseDp = 58;

/// 同日课程块之间的固定间距。
const int kWidgetBlockGapDp = 5;

/// 精简课程块预算：内边距 4 + 课程名 21 + 行间距 2 + 时间 15。
const int kWidgetMinimalCourseDp = 42;

/// 小组件标准尺寸下的内容选择；原生按实际字体测量后可以减少后续行。
///
/// - [main]：当前或下一节（今天已无未结束的课为 null），带倒计时。
/// - [rows]：主块之后显示的课，样式见 [styles]（与 rows 等长）。
/// - [more]：保留旧接口字段，新布局恒为 0。
/// - [badge]：头部「+N」的 N（0 = 不显示）。
({
  NotifyClass? main,
  List<NotifyClass> rows,
  List<WidgetItemStyle> styles,
  int more,
  int badge,
})
selectWidgetRows(
  List<NotifyClass> today,
  DateTime now, {
  WidgetPrefs prefs = const WidgetPrefs(),
  int heightDp = 168,
}) {
  final pending = [
    for (final c in today)
      if (c.end.isAfter(now)) c,
  ]..sort((a, b) => a.start.compareTo(b.start));
  if (pending.isEmpty) {
    return (main: null, rows: const [], styles: const [], more: 0, badge: 0);
  }
  final l = widgetLayout(
    remaining: pending.length - 1,
    heightDp: heightDp,
    prefs: prefs,
  );
  return (
    main: pending.first,
    rows: pending.skip(1).take(l.rows).toList(),
    styles: prefs.slotStyles.skip(1).take(l.rows).toList(),
    more: l.more,
    badge: l.badge,
  );
}

/// 2×2 新版布局：主课与之后课程均携带竖条色；无课程时固定文案且无竖条。
/// 不使用剩余数量、倒计时或课程数量偏好；明天首节只读注入值。
({
  NotifyClass? main,
  NotifyClass? after,
  String mainText,
  String afterText,
  String afterDetail,
})
selectWidget2x2(
  List<NotifyClass> today,
  DateTime now, {
  NotifyClass? tomorrowFirst,
}) {
  final pending = [
    for (final c in today)
      if (c.end.isAfter(now)) c,
  ]..sort((a, b) => a.start.compareTo(b.start));
  final main = pending.firstOrNull;
  final tomorrow = DateTime(now.year, now.month, now.day + 1);
  NotifyClass? after;
  if (pending.length > 1) {
    after = pending[1];
  } else if (main == null &&
      tomorrowFirst != null &&
      formatDate(tomorrowFirst.start) == formatDate(tomorrow)) {
    after = tomorrowFirst;
  }
  return (
    main: main,
    after: after,
    mainText: main?.name ?? (today.isEmpty ? '今天没有课程' : '今天的课上完了'),
    afterText: after == null
        ? (main == null ? '明天没课' : '今天最后一节')
        : main == null
        ? '明天 ${formatHm(after.start)} ${after.name}'
        : after.name,
    afterDetail: after == null
        ? ''
        : main == null
        ? after.location
        : [
            formatHm(after.start),
            after.location,
          ].where((s) => s.isNotEmpty).join(' '),
  );
}

/// 统一「之后」行：今天还有课显示下一节，最后一节显示固定文案；
/// 今天已结束时只用注入的 [tomorrowFirst]，不扫描后续日期。
String widgetAfterText(
  List<NotifyClass> today,
  DateTime now, {
  NotifyClass? tomorrowFirst,
}) {
  final pending = [
    for (final c in today)
      if (c.end.isAfter(now)) c,
  ]..sort((a, b) => a.start.compareTo(b.start));
  if (pending.length > 1) {
    final next = pending[1];
    return '${formatHm(next.start)} ${next.name}';
  }
  if (pending.isNotEmpty) return '今天最后一节';
  final tomorrow = DateTime(now.year, now.month, now.day + 1);
  // 缓存跨日后，昨天注入的首节不能继续被称为「明天」。
  if (tomorrowFirst == null ||
      formatDate(tomorrowFirst.start) != formatDate(tomorrow)) {
    return '明天没课';
  }
  return '明天 ${formatHm(tomorrowFirst.start)} ${tomorrowFirst.name}';
}

/// 从课程开始／结束时间计算剩余分钟，向上取整；过期时返回 0。
int widgetCountdownMinutes(DateTime now, DateTime target) {
  final ms = target.difference(now).inMilliseconds;
  return ms <= 0 ? 0 : (ms + 59999) ~/ 60000;
}

/// 下一次重绘：上下课、分钟倒计时变化及次日 00:01。
/// 原生排闹钟时另加 1 秒避开边界；关闭倒计时时不增加分钟刷新。
DateTime nextWidgetRefreshAt(
  DateTime now,
  List<NotifyClass> windowClasses, {
  bool showCountdown = true,
}) {
  var next = DateTime(now.year, now.month, now.day + 1, 0, 1);
  for (final c in windowClasses) {
    for (final t in [
      c.start.subtract(const Duration(hours: 1)),
      c.start,
      c.end.subtract(const Duration(hours: 1)),
      c.end,
    ]) {
      if (t.isAfter(now) && t.isBefore(next)) next = t;
    }
  }
  if (showCountdown) {
    final today = [
      for (final c in windowClasses)
        if (formatDate(c.start) == formatDate(now) && c.end.isAfter(now)) c,
    ]..sort((a, b) => a.start.compareTo(b.start));
    final main = today.firstOrNull;
    if (main != null) {
      final target = main.start.isAfter(now) ? main.start : main.end;
      if (target.difference(now) <= const Duration(hours: 1)) {
        final change = target.subtract(
          Duration(minutes: widgetCountdownMinutes(now, target) - 1),
        );
        if (change.isAfter(now) && change.isBefore(next)) next = change;
      }
    }
  }
  return next;
}

/// 4×2 的标准高度预算：优先保留当前课与下一节，空间不足时先精简详情。
/// [fontScale] 用于预览与边界检查；原生使用 TextView 的真实测量值。
({int rows, int more, int badge}) widgetLayout({
  required int remaining,
  int heightDp = 168,
  int widthDp = 320,
  double fontScale = 1,
  WidgetPrefs prefs = const WidgetPrefs(),
}) {
  final left = remaining < 0 ? 0 : remaining;
  final scale = fontScale.isFinite && fontScale >= 1 ? fontScale : 1.0;
  final fixed = 20 + (16 * scale).ceil() + 4 + (56 * scale).ceil();
  // 同日课程之间不使用分隔线；隔天的上下分区由原生端单独布局。
  final available = heightDp - fixed - kWidgetBlockGapDp;
  var rows = available >= kWidgetNextCourseDp ? 1 : 0;
  if (available >=
      kWidgetNextCourseDp + kWidgetBlockGapDp + (24 * scale).ceil()) {
    rows = 2;
  }
  if (rows == 0 &&
      heightDp >=
          20 +
              kWidgetBlockGapDp +
              2 * (kWidgetMinimalCourseDp * scale).ceil()) {
    rows = 1;
  }
  final wanted = prefs.courseCount.clamp(1, 3) - 1;
  rows = rows.clamp(0, wanted).clamp(0, left);
  return (rows: rows, more: 0, badge: prefs.showCount ? left - rows : 0);
}

String _two(int v) => v.toString().padLeft(2, '0');

/// `HH:mm`
String formatHm(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';

/// `yyyy-MM-dd`
String formatDate(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-${_two(t.day)}';

/// `yyyy-MM-ddTHH:mm`（本地墙上时间，无时区）。
String formatLocal(DateTime t) => '${formatDate(t)}T${formatHm(t)}';

/// 拆分教务 SKJS 教师串：按英文逗号 `,` 和中文逗号 `，` 分隔，逐个去首尾空白，
/// 丢弃空项。只供小组件 / 提醒使用，详情页仍显示原始文本。
List<String> splitTeachers(String raw) => [
  for (final t in raw.split(RegExp('[,，]')))
    if (t.trim().isNotEmpty) t.trim(),
];

/// 小组件不显示的占位教师名。
const String kPlaceholderTeacher = '网络教师';

/// 小组件 payload 用的教师列表：[splitTeachers] 后去掉 [kPlaceholderTeacher]。
List<String> widgetTeachers(String raw) => [
  for (final t in splitTeachers(raw))
    if (t != kPlaceholderTeacher) t,
];

/// 按非空字段用「 · 」拼接（不出现开头 / 结尾 / 连续分隔符）。
String joinDot(Iterable<String> parts) =>
    parts.map((e) => e.trim()).where((e) => e.isNotEmpty).join(' · ');
