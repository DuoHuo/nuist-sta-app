import 'timetable_persistence_feedback.dart';

import 'package:flutter/material.dart';

import 'timetable_controller.dart';
import 'timetable_date_edits.dart';
import 'timetable_theme.dart';

// 第 5 条：整天调课独立页（互换 + 调课记录）。
//
// 稳定 key：
// - day_swaps_page / day_swap_from / day_swap_to / day_swap_submit
// - day_swaps_empty / day_swap_item_<id> / day_swap_restore_<id>
// - day_swap_confirm_dialog / day_swap_confirm / day_swap_cancel
// 兼容旧测试：day_swap_sheet 不再作为长按入口（改走本页）。

/// 「10月25日」。
String daySwapDateLabel(DateTime d) => '${d.month}月${d.day}日';

/// 调课记录的一行文字：「10月25日与10月27日的课程互换」。
String daySwapDescription(DaySwap s) {
  final a = s.dateA.isBefore(s.dateB) ? s.dateA : s.dateB;
  final b = isSameDate(a, s.dateA) ? s.dateB : s.dateA;
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
  helpText: '选择日期',
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

/// 打开整天调课页；[initialFrom] 为长按表头带入的「原日期」。
Future<void> openDaySwapPage(
  BuildContext context,
  TimetableController c, {
  DateTime? initialFrom,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) =>
          TimetableDaySwapsPage(controller: c, initialFrom: initialFrom),
    ),
  );
}

/// 长按日期表头：进入整天调课页，原日期预填为该日。
Future<void> showDaySwapSheet(
  BuildContext context,
  TimetableController c,
  DateTime date,
) => openDaySwapPage(context, c, initialFrom: date);

/// 整天调课页：上半互换，下半调课记录。
class TimetableDaySwapsPage extends StatefulWidget {
  const TimetableDaySwapsPage({super.key, this.controller, this.initialFrom});

  final TimetableController? controller;
  final DateTime? initialFrom;

  @override
  State<TimetableDaySwapsPage> createState() => _TimetableDaySwapsPageState();
}

class _TimetableDaySwapsPageState extends State<TimetableDaySwapsPage> {
  DateTime? _from;
  DateTime? _to;

  TimetableController get _c =>
      widget.controller ?? TimetableController.instance;

  @override
  void initState() {
    super.initState();
    final r = semesterRangeOf(_c);
    DateTime clamp(DateTime d) {
      final x = DateTime(d.year, d.month, d.day);
      if (x.isBefore(r.first)) return r.first;
      if (x.isAfter(r.last)) return r.last;
      return x;
    }

    if (widget.initialFrom != null) {
      _from = clamp(widget.initialFrom!);
    }
  }

  Future<void> _pick({required bool from}) async {
    final r = semesterRangeOf(_c);
    final current = from ? _from : _to;
    final now = DateTime.now();
    final initial =
        current ??
        (from ? widget.initialFrom : null) ??
        DateTime(now.year, now.month, now.day);
    final clamped = initial.isBefore(r.first)
        ? r.first
        : (initial.isAfter(r.last) ? r.last : initial);
    final picker = debugDaySwapDatePicker ?? _defaultPicker;
    final picked = await picker(
      context,
      initial: clamped,
      first: r.first,
      last: r.last,
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (from) {
        _from = DateTime(picked.year, picked.month, picked.day);
      } else {
        _to = DateTime(picked.year, picked.month, picked.day);
      }
    });
  }

  Future<void> _submit() async {
    await withTimetablePersistenceFeedback(context, () => _submitUnchecked());
  }

  Future<void> _submitUnchecked() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final a = _from;
    final b = _to;
    if (a == null || b == null) {
      _snack(messenger, '请选择原日期和目标日期');
      return;
    }
    final err = daySwapErrorFor(_c, a, b);
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
          '${daySwapDateLabel(a)}和${daySwapDateLabel(b)}的课程将整天互换，'
          '可随时在下方「调课记录」里恢复。',
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
            child: Text('与${daySwapDateLabel(b)}互换'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final swap = await _c.addDaySwap(a, b);
    if (!mounted) return;
    _snack(messenger, swap == null ? '调课失败' : '已与${daySwapDateLabel(b)}互换');
    if (swap != null) setState(() => _to = null);
  }

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return Scaffold(
      key: const Key('day_swaps_page'),
      backgroundColor: colors.pageBg,
      appBar: AppBar(title: const Text('整天调课')),
      body: ListenableBuilder(
        listenable: _c,
        builder: (context, _) {
          final list = [..._c.daySwaps]
            ..sort((x, y) => x.dateA.compareTo(y.dateA));
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              Material(
                color: colors.surface,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '两天课程互换',
                        style: TimetableTheme.captionStyle(color: colors.hint),
                      ),
                      const SizedBox(height: 12),
                      _DateBlock(
                        key: const Key('day_swap_from'),
                        label: '原日期',
                        value: _from == null
                            ? '选择日期'
                            : daySwapDateLabel(_from!),
                        onTap: () => _pick(from: true),
                      ),
                      const SizedBox(height: 8),
                      _DateBlock(
                        key: const Key('day_swap_to'),
                        label: '目标日期',
                        value: _to == null ? '选择日期' : daySwapDateLabel(_to!),
                        onTap: () => _pick(from: false),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        height: 48,
                        child: FilledButton(
                          key: const Key('day_swap_submit'),
                          onPressed: _submit,
                          child: const Text('互换'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                child: Text(
                  '调课记录',
                  style: TimetableTheme.titleStyle(color: colors.titleText),
                ),
              ),
              if (list.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    '还没有调课记录。\n在周视图长按日期或在上方选择两天互换。',
                    key: const Key('day_swaps_empty'),
                    textAlign: TextAlign.center,
                    style: TimetableTheme.bodyStyle(color: colors.hint),
                  ),
                )
              else
                for (final s in list)
                  Material(
                    color: colors.surface,
                    child: ListTile(
                      key: Key('day_swap_item_${s.id}'),
                      leading: Icon(Icons.swap_horiz, color: colors.accent),
                      title: Text(
                        daySwapDescription(s),
                        style: TimetableTheme.bodyStyle(
                          color: colors.titleText,
                        ),
                      ),
                      trailing: TextButton(
                        key: Key('day_swap_restore_${s.id}'),
                        style: TextButton.styleFrom(
                          foregroundColor: colors.accent,
                        ),
                        onPressed: () async {
                          final m = ScaffoldMessenger.maybeOf(context);
                          await withTimetablePersistenceFeedback(
                            context,
                            () async {
                              final ok = await _c.removeDaySwap(s.id);
                              _snack(m, ok ? '已恢复' : '恢复失败');
                            },
                          );
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

class _DateBlock extends StatelessWidget {
  const _DateBlock({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: colors.divider),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Text(label, style: TimetableTheme.bodyStyle(color: colors.hint)),
            const Spacer(),
            Text(
              value,
              style: TimetableTheme.bodyStyle(color: colors.titleText),
            ),
            Icon(Icons.chevron_right, color: colors.hint),
          ],
        ),
      ),
    );
  }
}
