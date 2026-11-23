import '../../core/navigation/app_page.dart';
import 'timetable_persistence_feedback.dart';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../core/app_snack_bar.dart';
import '../../core/ui/miuix_dialog.dart';
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
  AppSnackBar(behavior: SnackBarBehavior.floating, content: Text(text)),
);

/// 打开整天调课页；[initialFrom] 为长按表头带入的「原日期」。
Future<void> openDaySwapPage(
  BuildContext context,
  TimetableController c, {
  DateTime? initialFrom,
}) {
  return Navigator.of(context).push<void>(
    AppPageRoute<void>(
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
  bool _editingFrom = true;

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

    // 进入调课页默认选中当天；长按表头进入时用带入的日期。
    _from = clamp(widget.initialFrom ?? DateTime.now());
  }

  Future<void> _pick({required bool from}) async {
    if (_editingFrom != from) setState(() => _editingFrom = from);
  }

  /// 内嵌日历选中某一天后填入当前编辑的日期块。
  void _setDate(DateTime picked) {
    setState(() {
      final date = DateTime(picked.year, picked.month, picked.day);
      if (_editingFrom) {
        _from = date;
      } else {
        _to = date;
      }
    });
  }

  /// 内嵌日历当前应显示的日期：优先当前编辑的日期块，其次原日期或学期首日。
  DateTime _calendarSeed() {
    final range = semesterRangeOf(_c);
    final seed = (_editingFrom ? _from : _to) ?? _from ?? DateTime.now();
    final date = DateTime(seed.year, seed.month, seed.day);
    if (date.isBefore(range.first)) return range.first;
    if (date.isAfter(range.last)) return range.last;
    return date;
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
    final ok = await showMiuixConfirmDialog(
      context,
      title: '整天调课',
      message:
          '${daySwapDateLabel(a)}和${daySwapDateLabel(b)}的课程将整天互换，'
          '可随时在下方「调课记录」里恢复。',
      contentKey: const Key('day_swap_confirm_dialog'),
      confirmLabel: '与${daySwapDateLabel(b)}互换',
      cancelLabel: '取消',
      cancelKey: const Key('day_swap_cancel'),
      confirmKey: const Key('day_swap_confirm'),
    );
    if (!ok) return;
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
                        selected: _editingFrom,
                        onTap: () => _pick(from: true),
                      ),
                      const SizedBox(height: 8),
                      _DateBlock(
                        key: const Key('day_swap_to'),
                        label: '目标日期',
                        value: _to == null ? '选择日期' : daySwapDateLabel(_to!),
                        selected: !_editingFrom,
                        onTap: () => _pick(from: false),
                      ),
                      const SizedBox(height: 12),
                      _DaySwapCalendar(
                        key: ValueKey('day_swap_calendar_$_editingFrom'),
                        initial: _calendarSeed(),
                        first: semesterRangeOf(_c).first,
                        last: semesterRangeOf(_c).last,
                        onChanged: _setDate,
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
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String value;
  final bool selected;
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
          border: Border.all(
            color: selected ? colors.accent : colors.divider,
            width: selected ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Text(label, style: TimetableTheme.bodyStyle(color: colors.hint)),
            const Spacer(),
            Text(
              value,
              style: TimetableTheme.bodyStyle(
                color: selected ? colors.accent : colors.titleText,
              ),
            ),
            Icon(
              selected ? Icons.edit_calendar_outlined : Icons.chevron_right,
              size: 18,
              color: selected ? colors.accent : colors.hint,
            ),
          ],
        ),
      ),
    );
  }
}

/// 调课页内嵌日历；跟随明暗主题，不再弹出系统日期选择器。
class _DaySwapCalendar extends StatelessWidget {
  const _DaySwapCalendar({
    super.key,
    required this.initial,
    required this.first,
    required this.last,
    required this.onChanged,
  });

  final DateTime initial;
  final DateTime first;
  final DateTime last;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    return MiuixTheme(
      data: MiuixThemeData.of(Theme.of(context).brightness),
      child: MiuixDatePicker(
        initialDate: initial,
        firstDate: first,
        lastDate: last,
        weekStart: MiuixWeekStart.sunday,
        onDateChanged: onChanged,
      ),
    );
  }
}
