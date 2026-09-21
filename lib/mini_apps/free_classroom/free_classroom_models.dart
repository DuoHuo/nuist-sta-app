/// 空教室查询的数据模型：教学楼、校历、大节、教室占用。
///
/// 占用信息来自教务 EMAP 的 kxjas 模块（`cxjsqk.do`），每间教室一行，
/// `JC1`~`JC11` 每小节一个字段：null / 空 = 空闲，否则形如 `1_01,0_04`，
/// 逗号分隔的 `<是否占用>_<占用类型代码>`，只有 `1_` 开头的才算占用。
library;

/// 占用类型代码 → 名称的内置兜底（2026-09 实测字典）；接口字典拉到后覆盖。
const Map<String, String> kOccupationNames = {
  '01': '教学',
  '02': '考试',
  '03': '调课（待审核）',
  '04': '借用',
  '05': '屏蔽',
  '06': '实验教学',
  '07': '实验借用',
};

/// 教务给的房间类型里，这些从来不对学生开放，「全部类型」视图下默认不算作
/// 空教室；用户在类型筛选里点名选它们时仍能看到。
const List<String> kNonClassroomTypeKeywords = ['办公室', '休息室'];

const List<String> kWeekdayNames = ['一', '二', '三', '四', '五', '六', '日'];

String _two(int n) => n.toString().padLeft(2, '0');

/// `yyyy-MM-dd`，接口参数与缓存键都用它。
String dateKeyOf(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

/// 教学楼。
class Building {
  const Building({required this.code, required this.name});

  /// JXLDM，如 `1-120`。
  final String code;

  /// JXLMC，如「文德楼」。
  final String name;

  factory Building.fromJson(Map<String, dynamic> json) => Building(
    code: (json['code'] ?? json['JXLDM'] ?? '').toString(),
    name: (json['name'] ?? json['JXLMC'] ?? '').toString(),
  );

  Map<String, dynamic> toJson() => {'code': code, 'name': name};

  @override
  bool operator ==(Object other) => other is Building && other.code == code;

  @override
  int get hashCode => code.hashCode;
}

/// 教务定义的一个大节（`cxjcqk.do`）：1-2、3-4、5-6、7-8、9-11，带起止时间。
class PeriodGroup {
  const PeriodGroup({
    required this.start,
    required this.end,
    required this.startTime,
    required this.endTime,
  });

  /// 起止小节号（含）。
  final int start;
  final int end;

  /// 「08:00」「09:40」。
  final String startTime;
  final String endTime;

  String get label => start == end ? '$start' : '$start-$end';

  /// 「08:00–09:40」。
  String get timeRange => '$startTime–$endTime';

  Iterable<int> get periods =>
      Iterable.generate(end - start + 1, (i) => start + i);

  /// 到 [now] 这个大节是否已经结束；时间解析不了就当没结束。
  bool isOver(DateTime now) {
    final end = _minutes(endTime);
    return end != null && now.hour * 60 + now.minute >= end;
  }

  static int? _minutes(String hhmm) {
    final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(hhmm.trim());
    if (m == null) return null;
    return int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!);
  }

  /// 接口没返回大节时的兜底（2026-09 实测值）。
  static const List<PeriodGroup> defaults = [
    PeriodGroup(start: 1, end: 2, startTime: '08:00', endTime: '09:40'),
    PeriodGroup(start: 3, end: 4, startTime: '10:10', endTime: '11:50'),
    PeriodGroup(start: 5, end: 6, startTime: '13:45', endTime: '15:25'),
    PeriodGroup(start: 7, end: 8, startTime: '15:55', endTime: '17:35'),
    PeriodGroup(start: 9, end: 11, startTime: '18:45', endTime: '21:20'),
  ];

  /// 从 `cxjcqk` 的行构建，按起始节次排序；解析不出任何一行就用 [defaults]。
  static List<PeriodGroup> fromRows(List<Map<String, dynamic>> rows) {
    final groups = <PeriodGroup>[];
    for (final row in rows) {
      final start = int.tryParse('${row['KSJC']}');
      final end = int.tryParse('${row['JSJC']}');
      if (start == null || end == null || end < start) continue;
      groups.add(
        PeriodGroup(
          start: start,
          end: end,
          startTime: (row['KSSJ'] ?? '').toString(),
          endTime: (row['JSSJ'] ?? '').toString(),
        ),
      );
    }
    if (groups.isEmpty) return defaults;
    groups.sort((a, b) => a.start - b.start);
    return groups;
  }
}

/// 某个日期在校历上的位置：学期、周次、星期，以及该学期的大节定义。
class TermCalendar {
  const TermCalendar({
    required this.termCode,
    required this.week,
    required this.weekday,
    required this.groups,
  });

  /// 学年学期代码，如 `2026-2027-1`。
  final String termCode;

  /// 教学周次。
  final int week;

  /// 星期几，1 = 周一 … 7 = 周日。
  final int weekday;

  final List<PeriodGroup> groups;

  /// 一天最多几小节。
  int get maxPeriod => groups.fold(0, (m, g) => g.end > m ? g.end : m);

  String get weekdayName =>
      weekday >= 1 && weekday <= 7 ? '周${kWeekdayNames[weekday - 1]}' : '';
}

/// 一间教室在某天的占用情况。
class Classroom {
  const Classroom({
    required this.name,
    required this.type,
    required this.seats,
    required this.floor,
    required this.occupancy,
  });

  /// JASMC，如「文德N101A」。
  final String name;

  /// 房间类型 JASLXDM_DISPLAY，如「多媒体教室」；没给时为空串。
  final String type;

  /// 上课座位数 SKZWS，接口没给时为 null。
  final int? seats;

  /// 楼层，接口 LC 优先，缺失时从名称里的首个数字推断；推断不出为 0。
  final int floor;

  /// 第 n 小节（下标 n-1）的占用类型代码，空列表即空闲。
  final List<List<String>> occupancy;

  bool isFree(int period) =>
      period >= 1 &&
      period <= occupancy.length &&
      occupancy[period - 1].isEmpty;

  List<String> occupationOf(int period) =>
      period >= 1 && period <= occupancy.length
      ? occupancy[period - 1]
      : const [];

  int freeCountIn(PeriodGroup group) => group.periods.where(isFree).length;

  /// 类型名里带办公室 / 休息室之类，不算教室。
  bool get isNonClassroom =>
      kNonClassroomTypeKeywords.any((k) => type.contains(k));

  /// 排序用：普通教室 / 自习室排前面，实验室、机房、摄影棚这类靠后——
  /// 找空教室的人多半不是去实验室的。
  int get typeRank =>
      type.isEmpty || type.contains('教室') || type.contains('自习') ? 0 : 1;

  factory Classroom.fromRow(Map<String, dynamic> row, int maxPeriod) {
    final name = (row['JASMC'] ?? '').toString().trim();
    return Classroom(
      name: name,
      type: (row['JASLXDM_DISPLAY'] ?? '').toString().trim(),
      seats: _toInt(row['SKZWS']),
      floor: _toInt(row['LC']) ?? _floorFromName(name),
      occupancy: [
        for (var jc = 1; jc <= maxPeriod; jc++) parseOccupation(row['JC$jc']),
      ],
    );
  }

  /// `1_01,0_04` → `['01']`；null / 空串 / 全是 `0_` → 空闲。
  static List<String> parseOccupation(Object? value) {
    if (value == null) return const [];
    final text = value.toString().trim();
    if (text.isEmpty) return const [];
    return [
      for (final part in text.split(','))
        if (part.trim().startsWith('1_')) part.trim().substring(2),
    ];
  }

  static int? _toInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static int _floorFromName(String name) {
    final m = RegExp(r'\d').firstMatch(name);
    return m == null ? 0 : int.parse(m.group(0)!);
  }
}

/// 一次查询的完整结果：某天某楼所有教室。
class ClassroomDay {
  const ClassroomDay({
    required this.date,
    required this.building,
    required this.calendar,
    required this.rooms,
    required this.fetchedAt,
  });

  final DateTime date;
  final Building building;
  final TermCalendar calendar;
  final List<Classroom> rooms;
  final DateTime fetchedAt;

  List<PeriodGroup> get groups => calendar.groups;

  /// 本楼出现过的楼层，升序；推断不出楼层的 0（「其他」）排最后。
  List<int> get floors {
    final list = {for (final r in rooms) r.floor}.toList()..sort();
    if (list.remove(0)) list.add(0);
    return list;
  }

  /// 本楼出现过的房间类型 → 间数，按间数降序；空类型不列。
  List<MapEntry<String, int>> get types {
    final counts = <String, int>{};
    for (final r in rooms) {
      if (r.type.isEmpty) continue;
      counts[r.type] = (counts[r.type] ?? 0) + 1;
    }
    final list = counts.entries.toList()
      ..sort(
        (a, b) =>
            b.value != a.value ? b.value - a.value : a.key.compareTo(b.key),
      );
    return list;
  }
}

/// 教室对当前筛选（时段 + 楼层 + 类型）的匹配结果，供列表排序与分组。
class RoomMatch {
  const RoomMatch({
    required this.room,
    required this.freeCount,
    required this.totalCount,
  });

  final Classroom room;

  /// 所选时段里空闲的小节数。
  final int freeCount;

  /// 所选时段的小节总数。
  final int totalCount;

  bool get fullyFree => totalCount > 0 && freeCount == totalCount;
}
