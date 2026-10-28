import '../../core/schedule/weekly_classes.dart';
import 'campus_map_data.dart';

/// 课表地点 ↔ 地图楼宇 / 房间的匹配。
///
/// 只做确定性的字面匹配：地点以楼名开头才算这栋楼，楼名后面的门牌号再去对
/// 房间的 room_code（支持「N101-103」这种合并门牌的区间）。对不上就不跳转，
/// 不按相似度猜。

String _normalize(String value) =>
    value.replaceAll(RegExp(r'\s+'), '').toUpperCase();

const _lou = '楼';

/// 楼名去掉所有「楼」字后的核心名，如「北辰楼」→「北辰」。
String _coreName(String buildingName) =>
    _normalize(buildingName).replaceAll(_lou, '');

/// 地点 [location] 以楼名开头时，返回楼名在地点里结束的位置；否则返回 null。
///
/// 两边都忽略「楼」字：「北辰楼」能对上「北辰N101」「北辰楼N101」。只在楼名这段
/// 前缀里跳过「楼」，后面门牌里的「3楼301」不受影响。
int? _nameEnd(String location, String buildingName) {
  final name = _coreName(buildingName);
  // 单字核心名太容易误配（如「北」），不参与匹配。
  if (name.length < 2) return null;
  var i = 0;
  for (final char in name.split('')) {
    while (i < location.length && location[i] == _lou) {
      i++;
    }
    if (i >= location.length || location[i] != char) return null;
    i++;
  }
  // 楼名后面紧跟的「楼」也算楼名的一部分。
  while (i < location.length && location[i] == _lou) {
    i++;
  }
  return i;
}

/// [location] 是否在名为 [buildingName] 的楼里（地点以楼名开头，忽略「楼」字）。
bool locationInBuilding(String location, String buildingName) =>
    _nameEnd(_normalize(location), buildingName) != null;

/// 从地点里取出楼名后面的门牌号，如「明德楼A101」→「A101」、
/// 「明德N101」→「N101」、「学而楼C303多媒体教室」→「C303」；取不到时返回 null。
String? roomCodeIn(String location, String buildingName) {
  final normalized = _normalize(location);
  final end = _nameEnd(normalized, buildingName);
  if (end == null) return null;
  final match = RegExp(r'^[-_#·]*([A-Z]*\d+)')
      .firstMatch(normalized.substring(end));
  return match?.group(1);
}

final _codePattern = RegExp(r'^([A-Z]*)(\d+)(?:-([A-Z]*)(\d+))?$');

/// 门牌 [code]（如 N102）是否落在房间门牌 [roomCode] 上。
/// [roomCode] 可以是单间「N102」，也可以是合并的区间「N101-103」（后半段省略
/// 字母前缀，位数不够时沿用前半段的高位）。
bool roomCodeMatches(String? roomCode, String code) {
  if (roomCode == null) return false;
  final room = _normalize(roomCode);
  final target = _normalize(code);
  if (room == target) return true;
  final r = _codePattern.firstMatch(room);
  final t = RegExp(r'^([A-Z]*)(\d+)$').firstMatch(target);
  if (r == null || t == null || r.group(4) == null) return false;
  final prefix = r.group(1)!;
  if (t.group(1) != prefix) return false;
  if (r.group(3)!.isNotEmpty && r.group(3) != prefix) return false;
  final startText = r.group(2)!;
  var endText = r.group(4)!;
  if (endText.length < startText.length) {
    endText =
        startText.substring(0, startText.length - endText.length) + endText;
  }
  final start = int.parse(startText);
  final end = int.parse(endText);
  final value = int.parse(t.group(2)!);
  return value >= start && value <= end;
}

/// 本周在 [place] 这栋楼里的课。
List<WeeklyClass> classesInBuilding(
  List<WeeklyClass> classes,
  CampusPlace place,
) => [
  for (final item in classes)
    if (locationInBuilding(item.location, place.name)) item,
];

/// 按门牌号猜一个最可能的楼层先查（N407 → 4 层），其余楼层按顺序排在后面。
/// 只影响查找顺序，结果仍以房间数据为准。
List<CampusFloor> floorsToSearch(List<CampusFloor> floors, String code) {
  final digits = RegExp(r'\d+').firstMatch(code)?.group(0);
  final sorted = [...floors]..sort((a, b) => a.number.compareTo(b.number));
  if (digits == null || digits.length < 3) return sorted;
  final guess = int.tryParse(digits.substring(0, digits.length - 2));
  return [
    ...sorted.where((f) => f.number == guess),
    ...sorted.where((f) => f.number != guess),
  ];
}

/// 「周二 3-4 节」。
String classTimeLabel(WeeklyClass item) {
  const days = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  final day = item.weekday >= 1 && item.weekday <= 7 ? days[item.weekday] : '';
  final nodes = item.startNode == item.endNode
      ? '${item.startNode}'
      : '${item.startNode}-${item.endNode}';
  return '$day $nodes 节';
}
