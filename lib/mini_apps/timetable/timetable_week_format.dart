/// 周次列表 → 展示文案（W01，设计/QA 规则）。
///
/// - 空 → ''（调用方隐藏该行）；单周 →「第 5 周」。
/// - 全单（或全双）、≥3 周且步长 2 连续 →「第 1–9 周（单）」/「第 2–10 周（双）」。
/// - 否则按步长 1 合并：长度 ≥2 的段「a–b」，单个「a」，以「、」连接：
///   「第 1–4、7、9–12 周」；超过 3 段只取前 3 段并在「周」后加「等」。
/// - 只用 en dash（U+2013）与全角括号，不输出半角「-」或「(单)」。
/// [maxSegments] 限制显示的周段数；为 null 时完整展示，适用于变动影响范围。
String formatWeeks(Iterable<int> weeks, {int? maxSegments = 3}) {
  final list = weeks.toSet().toList()..sort();
  if (list.isEmpty) return '';
  if (list.length == 1) return '第 ${list.single} 周';

  if (list.length >= 3) {
    final parity = list.first.isOdd;
    var stepTwo = true;
    for (var i = 0; i < list.length; i++) {
      if (list[i].isOdd != parity || (i > 0 && list[i] - list[i - 1] != 2)) {
        stepTwo = false;
        break;
      }
    }
    if (stepTwo) {
      return '第 ${list.first}–${list.last} 周（${parity ? '单' : '双'}）';
    }
  }

  final segments = <String>[];
  var a = list.first;
  var b = a;
  void flush() => segments.add(a == b ? '$a' : '$a–$b');
  for (final w in list.skip(1)) {
    if (w == b + 1) {
      b = w;
      continue;
    }
    flush();
    a = b = w;
  }
  flush();

  if (maxSegments != null && segments.length > maxSegments) {
    return '第 ${segments.take(maxSegments).join('、')} 周等';
  }
  return '第 ${segments.join('、')} 周';
}

/// 周次位串（下标 0 = 第 1 周，'1' 有课，如教务 SKZC 规范化后的 [CourseSlot.weeks]）→ 周次列表。
List<int> weeksFromBits(String bits) => [
  for (var i = 0; i < bits.length; i++)
    if (bits.codeUnitAt(i) == 0x31) i + 1,
];

/// 位串直接格式化。
String formatWeekBits(String bits) => formatWeeks(weeksFromBits(bits));
