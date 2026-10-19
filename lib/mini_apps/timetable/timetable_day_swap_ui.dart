import 'package:flutter/material.dart';

import 'timetable_controller.dart';
import 'timetable_date_edits.dart';
import 'timetable_theme.dart';

// 第 8 条：整天调课的界面（表头长按面板、调课记录页）。
//
// 稳定 key：
// - day_swap_sheet：长按表头弹出的面板
// - day_swap_start：「整天调课」（未调课的日期）
// - day_swap_undo：「撤销调课」（已调课的日期）
// - day_swap_confirm_dialog / day_swap_confirm / day_swap_cancel：确认对话框
// - day_swaps_page / day_swaps_empty / day_swap_item_<id> / day_swap_restore_<id>

/// 「10月25日」。
String daySwapDateLabel(DateTime d) => '${d.month}月${d.day}日';

/// 调课记录的一行文字：「10月25日与10月27日的课程互换」。
String daySwapDescription(DaySwap s) {
  final a = s.dateA.isBefore(s.dateB) ? s.dateA : s.dateB;
  final b = identical(a, s.dateA) ? s.dateB : s.dateA;
  return '${daySwapDateLabel(a)}与${daySwapDateLabel(b)}的课程互换';
}

/// 本学期可调课的日期范围：第 1 周周一 .. 最后一周周日。
({DateTime first, DateTime last}) semesterRangeOf(TimetableController c) {
  final first = c.weekStartDate(1);
  final lastMonday = c.weekStartDate(c.totalWeeks);
  final last = DateTime(lastMonday.year, lastMonday.month, lastMonday.day + 6);
  return (first: first, last: last);
}

/// 选日期；测试可替换。返回 null 表示取消。
typedef DaySwapDatePicker = Future<DateTime?> Function(
  BuildContext context, {
  required DateTime initial,
  required DateTime first,
  required DateTime last,
});

Future<DateTime?> _defaultPicker(
  BuildContext context, {
  required DateTime initial,
  required DateTime first,
  required DateTime last,
}) => showDatePicker(
  context: context,
  initialDate: initial,
  firstDate: first,
  lastDate: last,
  helpText: '选择要互换的日期',
);

/// 仅测试用：替换日期选择器。
@visibleForTesting
DaySwapDatePicker? debugDaySwapDatePicker;

/// 调课失败原因；null 表示可以调。
String? daySwapErrorFor(TimetableController c, DateTime a, DateTime b) {
  if (isSameDate(a, b)) return '不能和同一天互换';
  final r = semesterRangeOf(c);
  bool out(DateTime d) {
    final x = DateTime(d.year, d.month, d.day);
    return x.isBefore(r.first) || x.isAfter(r.last);
  }

  if (out(a) || out(b)) return '日期不在本学期内';
  if (c.isSwappedDate(a)) return '${daySwapDateLabel(a)}已调过课，请先撤销';
  if (c.isSwappedDate(b)) return '${daySwapDateLabel(b)}已调过课，请先撤销';
  return null;
}

void _snack(ScaffoldMessengerState? m, String text) => m?.showSnackBar(
  SnackBar(behavior: SnackBarBehavior.floating, content: Text(text)),
);

/// 长按日期表头：已调课的日期给「撤销调课」，否则给「整天调课」。
Future<void> showDaySwapSheet(
  BuildContext context,
  TimetableController c,
  DateTime date,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final existing = c.daySwapOn(date);
  final colors = TimetableTheme.colorsOf(context);
  final action = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: colors.surface,
    builder: (sheetContext) => SafeArea(
      child: Column(
        key: const Key('day_swap_sheet'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              existing == null
                  ? daySwapDateLabel(date)
                  : '${daySwapDateLabel(date)}已与'
                        '${daySwapDateLabel(existing.partnerOf(date)!)}互换课程',
              style: TimetableTheme.titleStyle(color: colors.titleText),
            ),
          ),
          if (existing == null)
            ListTile(
              key: const Key('day_swap_start'),
              leading: Icon(Icons.swap_horiz, color: colors.accent),
              title: Text('整天调课', style: TextStyle(color: colors.titleText)),
              subtitle: Text(
                '把这一天的课和另一天整天互换',
                style: TextStyle(color: colors.hint),
              ),
              onTap: () => Navigator.pop(sheetContext, 'start'),
            )
          else
            ListTile(
              key: const Key('day_swap_undo'),
              leading: Icon(Icons.undo, color: colors.danger),
              title: Text('撤销调课', style: TextStyle(color: colors.danger)),
              onTap: () => Navigator.pop(sheetContext, 'undo'),
            ),
        ],
      ),
    ),
  );
  if (!context.mounted || action == null) return;
  if (action == 'undo' && existing != null) {
    final ok = await c.removeDaySwap(existing.id);
    _snack(messenger, ok ? '已撤销调课' : '撤销失败');
    return;
  }
  final r = semesterRangeOf(c);
  final d0 = DateTime(date.year, date.month, date.day);
  final initial = d0.isBefore(r.first)
      ? r.first
      : (d0.isAfter(r.last) ? r.last : d0);
  final picker = debugDaySwapDatePicker ?? _defaultPicker;
  final other = await picker(
    context,
    initial: initial,
    first: r.first,
    last: r.last,
  );
  if (!context.mounted || other == null) return;
  final err = daySwapErrorFor(c, date, other);
  if (err != null) {
    _snack(messenger, err);
    return;
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const Key('day_swap_confirm_dialog'),
      title: const Text('整天调课'),
      content: Text(
        '${daySwapDateLabel(date)}和${daySwapDateLabel(other)}的课程将整天互换，'
        '可随时在「调课记录」里恢复。',
      ),
      actions: [
        TextButton(
          key: const Key('day_swap_cancel'),
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('day_swap_confirm'),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text('与${daySwapDateLabel(other)}互换'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  final swap = await c.addDaySwap(date, other);
  _snack(messenger, swap == null ? '调课失败' : '已与${daySwapDateLabel(other)}互换');
}

/// 设置 → 调课记录。
class TimetableDaySwapsPage extends StatelessWidget {
  const TimetableDaySwapsPage({super.key, this.controller});

  final TimetableController? controller;

  @override
  Widget build(BuildContext context) {
    final c = controller ?? TimetableController.instance;
    final colors = TimetableTheme.colorsOf(context);
    return Scaffold(
      key: const Key('day_swaps_page'),
      backgroundColor: colors.pageBg,
      appBar: AppBar(title: const Text('调课记录')),
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final list = [...c.daySwaps]
            ..sort((x, y) => x.dateA.compareTo(y.dateA));
          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '还没有调课记录。\n在周视图长按日期即可整天调课。',
                  key: const Key('day_swaps_empty'),
                  textAlign: TextAlign.center,
                  style: TimetableTheme.bodyStyle(color: colors.hint),
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              for (final s in list)
                Material(
                  color: colors.surface,
                  child: ListTile(
                    key: Key('day_swap_item_${s.id}'),
                    leading: Icon(Icons.swap_horiz, color: colors.accent),
                    title: Text(
                      daySwapDescription(s),
                      style: TimetableTheme.bodyStyle(color: colors.titleText),
                    ),
                    trailing: TextButton(
                      key: Key('day_swap_restore_${s.id}'),
                      style: TextButton.styleFrom(
                        foregroundColor: colors.accent,
                      ),
                      onPressed: () async {
                        final m = ScaffoldMessenger.maybeOf(context);
                        final ok = await c.removeDaySwap(s.id);
                        _snack(m, ok ? '已恢复' : '恢复失败');
                      },
                      child: const Text('恢复'),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
