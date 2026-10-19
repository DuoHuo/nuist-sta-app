import 'package:flutter/material.dart';

import 'timetable_theme.dart';
import 'timetable_week_format.dart';

/// 「应用周数」摘要：全部 →「全部 N 周」；否则 [formatWeeks]。
String applyWeeksSummary(Iterable<int> weeks, int totalWeeks) {
  final list = weeks.toSet().toList()..sort();
  if (list.isEmpty) return '请选择周次';
  if (totalWeeks > 0 &&
      list.length == totalWeeks &&
      list.first == 1 &&
      list.last == totalWeeks) {
    return '全部 $totalWeeks 周';
  }
  return formatWeeks(list);
}

/// 是否等于「全部 1..totalWeeks」。
bool isAllSemesterWeeks(Iterable<int> weeks, int totalWeeks) {
  if (totalWeeks <= 0) return false;
  final s = weeks.toSet();
  return s.length == totalWeeks &&
      s.contains(1) &&
      s.contains(totalWeeks) &&
      s.every((w) => w >= 1 && w <= totalWeeks);
}

/// 编辑页「应用周数」底部面板：学期周次多选 + 全选/单周/双周/清空。
/// 返回去重升序的周列表；点遮罩关闭返回 null（不改当前选择）。
Future<List<int>?> showApplyWeeksSheet(
  BuildContext context, {
  required int totalWeeks,
  required Set<int> initial,
}) {
  return showModalBottomSheet<List<int>>(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    builder: (sheetContext) =>
        _ApplyWeeksSheet(totalWeeks: totalWeeks, initial: initial),
  );
}

class _ApplyWeeksSheet extends StatefulWidget {
  const _ApplyWeeksSheet({required this.totalWeeks, required this.initial});

  final int totalWeeks;
  final Set<int> initial;

  @override
  State<_ApplyWeeksSheet> createState() => _ApplyWeeksSheetState();
}

class _ApplyWeeksSheetState extends State<_ApplyWeeksSheet> {
  late Set<int> _weeks;

  @override
  void initState() {
    super.initState();
    _weeks = {
      for (final w in widget.initial)
        if (w >= 1 && w <= widget.totalWeeks) w,
    };
  }

  void _quick(int mode) {
    setState(() {
      _weeks = {
        for (var w = 1; w <= widget.totalWeeks; w++)
          if (mode == 0 || (mode == 1 && w.isOdd) || (mode == 2 && w.isEven)) w,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return SafeArea(
      child: Padding(
        key: const Key('apply_weeks_sheet'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '应用周数',
              style: TimetableTheme.titleStyle(color: colors.titleText),
            ),
            const SizedBox(height: 4),
            Text(
              '保存后只在勾选的周生效',
              style: TimetableTheme.captionStyle(color: colors.hint),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(
                  key: const Key('apply_weeks_all'),
                  onPressed: () => _quick(0),
                  child: const Text('全选'),
                ),
                TextButton(
                  key: const Key('apply_weeks_odd'),
                  onPressed: () => _quick(1),
                  child: const Text('单周'),
                ),
                TextButton(
                  key: const Key('apply_weeks_even'),
                  onPressed: () => _quick(2),
                  child: const Text('双周'),
                ),
                TextButton(
                  key: const Key('apply_weeks_clear'),
                  onPressed: () => setState(() => _weeks.clear()),
                  child: const Text('清空'),
                ),
              ],
            ),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.4,
              ),
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (var w = 1; w <= widget.totalWeeks; w++)
                      FilterChip(
                        key: Key('apply_weeks_chip_$w'),
                        label: Text('$w'),
                        selected: _weeks.contains(w),
                        showCheckmark: false,
                        selectedColor: colors.accent,
                        backgroundColor: colors.chipBg,
                        side: BorderSide.none,
                        labelStyle: TextStyle(
                          color: _weeks.contains(w)
                              ? Colors.white
                              : colors.labelText,
                        ),
                        onSelected: (sel) => setState(() {
                          sel ? _weeks.add(w) : _weeks.remove(w);
                        }),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 48,
              child: FilledButton(
                key: const Key('apply_weeks_done'),
                onPressed: () {
                  final sorted = _weeks.toList()..sort();
                  Navigator.pop(context, sorted);
                },
                child: const Text('确定'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
