/// 周次列表 → 展示文案（W01）。
///
/// - 空 → ''（调用方隐藏该行）；单周 →「第 5 周」。
/// - 全单（或全双）、≥2 周且步长 2 连续 →「第 3–7 周单周」/「第 2–10 周双周」
///   （两周仅一步间隔仍输出「第 2、4 周」，≥3 周输出「第 3–7 周单周」）。
/// - 混合包含局部单双周循环段（≥3 周步长 2）与连续段时，同样分段格式化后再以「、」合并。
/// - 否则按步长 1 合并：长度 ≥2 的段「a–b」，单个「a」，以「、」连接：
///   「第 1–4、7、9–12 周」；超过 [maxSegments] 段只取前 [maxSegments] 段并在「周」后加「等」。
/// - 只用 en dash（U+2013）与全角括号，不输出半角「-」或「(单)」。
/// [maxSegments] 限制显示的周段数；为 null 时完整展示，适用于详情/表单与变动影响范围。
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
  var i = 0;
  while (i < list.length) {
    // 优先检查连续段（步长 1，长度 ≥ 2）
    var contEnd = i;
    while (contEnd + 1 < list.length &&
        list[contEnd + 1] == list[contEnd] + 1) {
      contEnd++;
    }
    if (contEnd > i) {
      segments.add('${list[i]}–${list[contEnd]}');
      i = contEnd + 1;
      continue;
    }

    // 检查局部单双周循环段（步长 2，长度 ≥ 3，且末尾不紧挨连续后继）
    var step2End = i;
    while (step2End + 1 < list.length &&
        list[step2End + 1] == list[step2End] + 2) {
      step2End++;
    }
    // 若最后一项紧跟 +1（如 [1, 3, 5, 6, 7] 中 5 后面是 6），把 5 留给后面的 5–7 连续段
    if (step2End - i >= 2 &&
        step2End + 1 < list.length &&
        list[step2End + 1] == list[step2End] + 1) {
      step2End--;
    }
    if (step2End - i >= 2) {
      final parityLabel = list[i].isOdd ? '单' : '双';
      segments.add('${list[i]}–${list[step2End]}（$parityLabel）');
      i = step2End + 1;
      continue;
    }

    segments.add('${list[i]}');
    i++;
  }

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
String formatWeekBits(String bits, {int? maxSegments = 3}) =>
    formatWeeks(weeksFromBits(bits), maxSegments: maxSegments);
