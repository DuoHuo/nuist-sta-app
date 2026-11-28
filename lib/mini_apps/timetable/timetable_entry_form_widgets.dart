import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../core/app_select.dart';
import '../../core/ui/app_bottom_sheet.dart';
import '../../core/ui/miuix_dialog.dart';
import 'timetable_controller.dart';
import 'timetable_course_detail_sheet.dart';
import 'timetable_course_form_sheets.dart';
import 'timetable_course_group.dart';
import 'timetable_models.dart';
import 'timetable_schedule_event.dart';
import 'timetable_theme.dart';
import 'timetable_timing.dart';
import 'timetable_week_format.dart';

const kTimetableWeekdayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

/// 日期不在本学期周次内时的提示。
const kOutsideTermHint = '不在本学期，周视图里看不到';

/// [date] 是否落在本学期周视图之外（真实教学周 < 1 或 > [TimetableController.maxWeeks]）。
/// 没有开学日期时无法判断 → false（不提示）。
bool isOutsideTermWeeks(TimetableController c, DateTime date) {
  final w = c.actualWeek(date);
  if (w == null) return false;
  return w < 1 || w > c.maxWeeks;
}

/// 删除日程的二次确认（表单页与详情弹层共用）。返回 true = 确认删除。
Future<bool> confirmDeleteScheduleEvent(
  BuildContext context,
  ScheduleEvent event,
) {
  final String text;
  if (event.isFromJwxt) {
    text = '删除这场考试？同步后也不会恢复，可在设置里一键恢复。';
  } else if (event.isExam) {
    text = '删除这场考试？';
  } else {
    text = '删除这个日程？';
  }
  return showMiuixConfirmDialog(
    context,
    message: text,
    messageKey: const Key('schedule_delete_message'),
    confirmLabel: '删除',
    cancelLabel: '取消',
    destructive: true,
    cancelKey: const Key('schedule_delete_cancel'),
    confirmKey: const Key('schedule_delete_confirm'),
  );
}

/// 表单分组圆角卡片容器，用于承载一组表单行。
class TimetableFormSectionCard extends StatelessWidget {
  const TimetableFormSectionCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.divider.withValues(alpha: 0.65)),
      ),
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

/// 课程/日程表单统一样式的行容器。
class TimetableFormRow extends StatelessWidget {
  const TimetableFormRow({
    super.key,
    required this.label,
    required this.child,
    this.divider = true,
  });

  final String label;
  final Widget child;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final field = Semantics(label: label, child: child);
    final text = ExcludeSemantics(
      child: Text(
        label,
        style: TextStyle(
          color: colors.labelText,
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
    return Container(
      constraints: const BoxConstraints(minHeight: 54),
      decoration: divider
          ? BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: colors.divider.withValues(alpha: 0.75),
                ),
              ),
            )
          : null,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (MediaQuery.textScalerOf(context).scale(16) > 23 ||
              constraints.maxWidth < 250) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [text, field],
              ),
            );
          }
          return Row(
            children: [
              SizedBox(width: 72, child: text),
              const SizedBox(width: 8),
              Expanded(child: field),
            ],
          );
        },
      ),
    );
  }
}

/// 统一平铺文本输入行。
class TimetableFormTextField extends StatelessWidget {
  const TimetableFormTextField({
    super.key,
    this.fieldKey,
    required this.label,
    required this.controller,
    this.focusNode,
    this.nextFocus,
    this.enabled = true,
    this.readOnly = false,
    this.hint,
    this.helperText,
    this.validator,
    this.maxLines = 1,
    this.minLines,
    this.textInputAction = TextInputAction.next,
    this.autovalidateMode = AutovalidateMode.disabled,
    this.divider = true,
  });

  final Key? fieldKey;
  final String label;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final FocusNode? nextFocus;
  final bool enabled;
  final bool readOnly;
  final String? hint;
  final String? helperText;
  final FormFieldValidator<String>? validator;
  final int maxLines;
  final int? minLines;
  final TextInputAction textInputAction;
  final AutovalidateMode autovalidateMode;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return TimetableFormRow(
      label: label,
      divider: divider,
      child: TextFormField(
        key: fieldKey,
        controller: controller,
        focusNode: focusNode,
        enabled: enabled,
        readOnly: readOnly,
        maxLines: maxLines,
        minLines: minLines,
        textInputAction: textInputAction,
        autovalidateMode: autovalidateMode,
        onFieldSubmitted: nextFocus == null
            ? null
            : (_) => nextFocus!.requestFocus(),
        style: TextStyle(
          color: readOnly || !enabled ? colors.labelText : colors.titleText,
          fontSize: 16,
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: colors.hint, fontSize: 15),
          helperText: helperText,
          helperStyle: TextStyle(color: colors.hint, fontSize: 12),
          isDense: true,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: colors.accent),
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
        ),
        validator: validator,
      ),
    );
  }
}

/// 统一点击行（用于日期、时间、周次、颜色等选择器入口）。
class TimetableFormTapRow extends StatelessWidget {
  const TimetableFormTapRow({
    super.key,
    required this.label,
    required this.value,
    this.onTap,
    this.leading,
    this.valueColor,
    this.divider = true,
  });

  final String label;
  final String value;
  final VoidCallback? onTap;
  final Widget? leading;
  final Color? valueColor;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return TimetableFormRow(
      label: label,
      divider: divider,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 10)],
              Expanded(
                child: Text(
                  value,
                  style: TextStyle(
                    color: valueColor ?? colors.titleText,
                    fontSize: 16,
                  ),
                ),
              ),
              if (onTap != null)
                Icon(Icons.chevron_right, size: 20, color: colors.chevron),
            ],
          ),
        ),
      ),
    );
  }
}

/// 表单只读展示行（如教务课程号）。
class TimetableFormReadonlyRow extends StatelessWidget {
  const TimetableFormReadonlyRow({
    super.key,
    required this.label,
    required this.value,
    this.hint,
    this.divider = true,
  });

  final String label;
  final String value;
  final String? hint;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return TimetableFormRow(
      label: label,
      divider: divider,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: TextStyle(color: colors.labelText, fontSize: 16),
            ),
            if (hint != null && hint!.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(hint!, style: TextStyle(color: colors.hint, fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 二选一分段按钮（如「考试 / 日程」）。
class TimetableKindSwitch extends StatelessWidget {
  const TimetableKindSwitch({
    super.key,
    required this.kind,
    required this.onChanged,
  });

  final ScheduleKind kind;
  final ValueChanged<ScheduleKind> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return Container(
      key: const Key('schedule_form_kind'),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.divider.withValues(alpha: 0.65)),
      ),
      child: Row(
        children: [
          _segment(
            context,
            itemKey: const Key('schedule_form_kind_exam'),
            label: '考试',
            selected: kind == ScheduleKind.exam,
            onTap: () => onChanged(ScheduleKind.exam),
          ),
          _segment(
            context,
            itemKey: const Key('schedule_form_kind_other'),
            label: '日程',
            selected: kind == ScheduleKind.other,
            onTap: () => onChanged(ScheduleKind.other),
          ),
        ],
      ),
    );
  }

  Widget _segment(
    BuildContext context, {
    required Key itemKey,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final colors = TimetableTheme.colorsOf(context);
    return Expanded(
      child: GestureDetector(
        key: itemKey,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? colors.accentSoft : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? colors.accent : colors.labelText,
            ),
          ),
        ),
      ),
    );
  }
}

/// 横向可左右滑动的上课安排正方感卡片条（含末尾新增卡）。
///
/// 当指定 [currentIndex] 时，首次挂载自动将列表滚动聚焦到对应「当前」卡片。
class CourseSlotHorizontalStrip extends StatefulWidget {
  const CourseSlotHorizontalStrip({
    super.key,
    required this.slots,
    required this.periods,
    required this.slotKeyPrefix,
    required this.addButtonKey,
    this.currentIndex,
    this.onTapSlot,
    this.onDeleteSlot,
    this.onAddSlot,
  });

  final List<CourseSlotDraft> slots;
  final List<PeriodTime> periods;
  final String slotKeyPrefix;
  final Key addButtonKey;
  final int? currentIndex;
  final ValueChanged<int>? onTapSlot;
  final ValueChanged<int>? onDeleteSlot;
  final VoidCallback? onAddSlot;

  @override
  State<CourseSlotHorizontalStrip> createState() =>
      _CourseSlotHorizontalStripState();
}

class _CourseSlotHorizontalStripState extends State<CourseSlotHorizontalStrip> {
  static const double _cardSpacing = 10.0;
  final ScrollController _scrollController = ScrollController();
  bool _initialFocused = false;

  @override
  void initState() {
    super.initState();
    _scheduleInitialFocus();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  double _cardWidthFor(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return math.max(158.0, scaler.scale(148.0)).clamp(158.0, 220.0);
  }

  void _scheduleInitialFocus() {
    final targetIndex = widget.currentIndex;
    if (_initialFocused || targetIndex == null || targetIndex <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _initialFocused || !_scrollController.hasClients) return;
      _initialFocused = true;
      final position = _scrollController.position;
      if (position.maxScrollExtent <= 0) return;
      final cardWidth = _cardWidthFor(context);
      final itemLeft = targetIndex * (cardWidth + _cardSpacing);
      final centered = itemLeft - (position.viewportDimension - cardWidth) / 2;
      _scrollController.jumpTo(centered.clamp(0.0, position.maxScrollExtent));
    });
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final cardWidth = _cardWidthFor(context);
    final cardHeight = math.max(152.0, scaler.scale(144.0)).clamp(152.0, 232.0);
    final canDelete = widget.slots.length > 1 && widget.onDeleteSlot != null;

    return SizedBox(
      height: cardHeight,
      child: ListView.separated(
        key: Key('${widget.slotKeyPrefix}_strip'),
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: widget.slots.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: _cardSpacing),
        itemBuilder: (context, index) {
          if (index == widget.slots.length) {
            return SizedBox(
              width: math.max(122.0, cardWidth * 0.78),
              child: _AddSlotSquareCard(
                key: widget.addButtonKey,
                onTap: widget.onAddSlot,
              ),
            );
          }
          return SizedBox(
            width: cardWidth,
            child: CourseSlotSummaryCard(
              key: Key('${widget.slotKeyPrefix}$index'),
              draft: widget.slots[index],
              periods: widget.periods,
              isCurrent: widget.currentIndex == index,
              onTap: widget.onTapSlot == null
                  ? null
                  : () => widget.onTapSlot!(index),
              onDelete: canDelete ? () => widget.onDeleteSlot!(index) : null,
            ),
          );
        },
      ),
    );
  }
}

class _AddSlotSquareCard extends StatelessWidget {
  const _AddSlotSquareCard({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: colors.accentSoft,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.add, size: 20, color: colors.accent),
              ),
              const SizedBox(height: 8),
              Text(
                '添加时段',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colors.accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 课程时段偏正方形小卡片（横向列表中展示，点击整卡或周次区域均打开完整时段编辑浮窗）。
class CourseSlotSummaryCard extends StatelessWidget {
  const CourseSlotSummaryCard({
    super.key,
    required this.draft,
    required this.periods,
    this.isCurrent = false,
    this.onTap,
    this.onDelete,
  });

  final CourseSlotDraft draft;
  final List<PeriodTime> periods;
  final bool isCurrent;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final dayLabel = kTimetableWeekdayLabels[(draft.day - 1).clamp(0, 6)];
    final range = draft.startNode == draft.endNode
        ? '第 ${draft.startNode} 节'
        : '第 ${draft.startNode}–${draft.endNode} 节';
    final weeksText = formatWeeks(draft.weeks, maxSegments: 2);
    final kindLabel = switch (draft.kind) {
      CourseKind.lab => '实验',
      CourseKind.pe => '体育',
      CourseKind.standard || CourseKind.exam => '',
    };
    final locText = draft.location.trim();
    final hasNote = draft.note.trim().isNotEmpty;

    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isCurrent
              ? colors.accent.withValues(alpha: 0.7)
              : colors.divider.withValues(alpha: 0.8),
          width: isCurrent ? 1.4 : 1.0,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (isCurrent)
                          _MiniTag(
                            label: '当前',
                            color: colors.accent,
                            bgColor: colors.accentSoft,
                          ),
                        if (kindLabel.isNotEmpty)
                          _MiniTag(
                            label: kindLabel,
                            color: colors.labelText,
                            bgColor: colors.chipBg,
                          ),
                        if (!isCurrent && kindLabel.isEmpty)
                          Text(
                            dayLabel,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: colors.accent,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (onDelete != null)
                    SizedBox(
                      width: 28,
                      height: 28,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        tooltip: '移除时段',
                        onPressed: onDelete,
                        icon: Icon(
                          Icons.close_rounded,
                          size: 17,
                          color: colors.hint,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              if (isCurrent || kindLabel.isNotEmpty)
                Text(
                  dayLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colors.accent,
                  ),
                ),
              Text(
                range,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.titleText,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Row(
                children: [
                  Icon(
                    Icons.place_outlined,
                    size: 13,
                    color: locText.isEmpty ? colors.hint : colors.labelText,
                  ),
                  const SizedBox(width: 3),
                  Expanded(
                    child: Text(
                      locText.isEmpty ? '地点未填写' : locText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: locText.isEmpty ? colors.hint : colors.labelText,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  if (hasNote) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.notes_rounded, size: 13, color: colors.accent),
                  ],
                ],
              ),
              const Spacer(),
              Container(
                decoration: BoxDecoration(
                  color: colors.pageBg,
                  borderRadius: BorderRadius.circular(9),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        weeksText.isEmpty ? '选周次' : weeksText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: weeksText.isEmpty
                              ? colors.danger
                              : colors.titleText,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Icon(Icons.tune_rounded, size: 13, color: colors.labelText),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniTag extends StatelessWidget {
  const _MiniTag({
    required this.label,
    required this.color,
    required this.bgColor,
  });

  final String label;
  final Color color;
  final Color bgColor;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: bgColor,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
    ),
  );
}

/// 二级底部抽屉：选择日期（MiuixDatePicker）。
Future<DateTime?> showScheduleDatePickerSheet(
  BuildContext context, {
  required DateTime initialDate,
}) {
  var selected = DateTime(initialDate.year, initialDate.month, initialDate.day);
  return showAppModalBottomSheet<DateTime>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    enablePredictiveBackScale: false,
    backgroundColor: Colors.transparent,
    constraints: const BoxConstraints(maxWidth: 520),
    builder: (sheetContext) {
      final colors = TimetableTheme.colorsOf(sheetContext);
      return Material(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: Padding(
            key: const Key('schedule_date_picker_sheet'),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: SheetDragHandle()),
                const SizedBox(height: 10),
                _PickerSheetHeader(
                  title: '选择日期',
                  onCancel: () => Navigator.pop(sheetContext),
                  confirmKey: const Key('schedule_date_picker_confirm'),
                  confirmLabel: '确定',
                  onConfirm: () => Navigator.pop(sheetContext, selected),
                ),
                const SizedBox(height: 6),
                MiuixTheme(
                  data: MiuixThemeData.of(Theme.of(sheetContext).brightness),
                  child: MiuixDatePicker(
                    initialDate: selected,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100, 12, 31),
                    weekStart: MiuixWeekStart.sunday,
                    onDateChanged: (date) => selected = date,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// 二级底部抽屉：选择时刻（MiuixNumberPicker）。
Future<TimeOfDayMinutes?> showScheduleTimePickerSheet(
  BuildContext context, {
  required String title,
  required TimeOfDayMinutes initial,
}) {
  var hour = initial.hour;
  var minute = initial.minute;
  return showAppModalBottomSheet<TimeOfDayMinutes>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    enablePredictiveBackScale: false,
    backgroundColor: Colors.transparent,
    constraints: const BoxConstraints(maxWidth: 520),
    builder: (sheetContext) {
      final colors = TimetableTheme.colorsOf(sheetContext);
      return Material(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: Padding(
            key: const Key('schedule_time_picker_sheet'),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: SheetDragHandle()),
                const SizedBox(height: 10),
                _PickerSheetHeader(
                  title: title,
                  onCancel: () => Navigator.pop(sheetContext),
                  confirmKey: const Key('schedule_time_picker_confirm'),
                  confirmLabel: '确定',
                  onConfirm: () => Navigator.pop(
                    sheetContext,
                    TimeOfDayMinutes(hour, minute),
                  ),
                ),
                const SizedBox(height: 8),
                MiuixTheme(
                  data: MiuixThemeData.of(Theme.of(sheetContext).brightness),
                  child: SizedBox(
                    height: 150,
                    child: Row(
                      children: [
                        Expanded(
                          child: MiuixNumberPicker(
                            value: hour,
                            min: 0,
                            max: 23,
                            wrapAround: true,
                            visibleItemCount: 3,
                            label: (v) => '$v 时',
                            onValueChanged: (v) => hour = v,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: MiuixNumberPicker(
                            value: minute,
                            min: 0,
                            max: 59,
                            wrapAround: true,
                            visibleItemCount: 3,
                            label: (v) => '$v 分',
                            onValueChanged: (v) => minute = v,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// 二级底部抽屉返回结果：更新后的草稿，或触发「转为考试」。
class CourseSlotEditorResult {
  const CourseSlotEditorResult.updated(this.draft) : convertToExam = false;
  const CourseSlotEditorResult.toExam(this.draft) : convertToExam = true;

  final CourseSlotDraft draft;
  final bool convertToExam;
}

/// 二级底部抽屉：编辑单个上课时段（课程类型置顶，支持星期、节次、周次、地点、备注与转为考试）。
Future<CourseSlotEditorResult?> showCourseSlotEditorSheet(
  BuildContext context, {
  required TimetableController controller,
  required CourseSlotDraft initial,
  Set<String> excludeCourseIds = const {},
  bool allowConvertToExam = false,
  bool autofocusNote = false,
  bool isNew = false,
}) => showAppModalBottomSheet<CourseSlotEditorResult>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  enablePredictiveBackScale: false,
  backgroundColor: Colors.transparent,
  constraints: const BoxConstraints(maxWidth: 540),
  builder: (_) => _CourseSlotEditorSheet(
    controller: controller,
    initial: initial,
    excludeCourseIds: excludeCourseIds,
    allowConvertToExam: allowConvertToExam,
    autofocusNote: autofocusNote,
    isNew: isNew,
  ),
);

class _CourseSlotEditorSheet extends StatefulWidget {
  const _CourseSlotEditorSheet({
    required this.controller,
    required this.initial,
    required this.excludeCourseIds,
    required this.allowConvertToExam,
    required this.autofocusNote,
    required this.isNew,
  });

  final TimetableController controller;
  final CourseSlotDraft initial;
  final Set<String> excludeCourseIds;
  final bool allowConvertToExam;
  final bool autofocusNote;
  final bool isNew;

  @override
  State<_CourseSlotEditorSheet> createState() => _CourseSlotEditorSheetState();
}

class _CourseSlotEditorSheetState extends State<_CourseSlotEditorSheet> {
  late int _day;
  late int _start;
  late int _end;
  late int _requestedSpan;
  late List<int> _weeks;
  late CourseKind _kind;
  late final TextEditingController _location;
  late final TextEditingController _note;
  late final FocusNode _noteFocus;

  int get _totalWeeks => widget.controller.totalWeeks;

  List<int> get _nodes {
    final maxNode = widget.controller.lastPeriod > 0
        ? widget.controller.lastPeriod
        : 11;
    return [for (var i = 1; i <= maxNode; i++) i];
  }

  @override
  void initState() {
    super.initState();
    _day = widget.initial.day.clamp(1, 7);
    final maxNode = _nodes.last;
    _start = widget.initial.startNode.clamp(1, maxNode);
    _end = widget.initial.endNode.clamp(_start, maxNode);
    _requestedSpan = (_end - _start + 1).clamp(1, maxNode);
    _weeks = [...widget.initial.weeks]..sort();
    _kind = widget.initial.kind == CourseKind.exam
        ? CourseKind.standard
        : widget.initial.kind;
    _location = TextEditingController(text: widget.initial.location);
    _note = TextEditingController(text: widget.initial.note);
    _noteFocus = FocusNode();
    if (widget.autofocusNote) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _noteFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _location.dispose();
    _note.dispose();
    _noteFocus.dispose();
    super.dispose();
  }

  void _changeStart(int value) {
    final maxNode = _nodes.last;
    setState(() {
      _start = value;
      _end = (_start + _requestedSpan - 1).clamp(_start, maxNode);
    });
  }

  void _changeEnd(int value) {
    setState(() {
      _end = value < _start ? _start : value;
      _requestedSpan = _end - _start + 1;
    });
  }

  Future<void> _pickWeeks() async {
    final picked = await showCourseWeeksSheet(
      context,
      totalWeeks: _totalWeeks,
      initial: _weeks.toSet(),
    );
    if (picked != null && mounted) {
      setState(() => _weeks = picked);
    }
  }

  CourseSlotDraft _buildDraft() => widget.initial.copyWith(
    day: _day,
    startNode: _start,
    endNode: _end,
    weeks: _weeks,
    location: _location.text.trim(),
    note: _note.text.trim(),
    kind: _kind,
  );

  String get _clockText {
    final segments = resolveTimingSegments(
      periods: widget.controller.periods,
      startNode: _start,
      endNode: _end,
      kind: switch (_kind) {
        CourseKind.standard || CourseKind.exam => CourseTimingKind.standard,
        CourseKind.lab => CourseTimingKind.lab,
        CourseKind.pe => CourseTimingKind.pe,
      },
    );
    return segments.isEmpty
        ? '暂无对应作息时间'
        : segments.map((s) => '${s.start}–${s.end}').join('、');
  }

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final candidate = _buildDraft().toPreviewSlot(_totalWeeks);
    final conflicts = widget.controller.conflictsFor(
      candidate,
      excludeIds: widget.excludeCourseIds,
    );
    final conflictText = describeManualConflicts(candidate, conflicts);
    return Material(
      color: colors.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .88,
          ),
          child: Padding(
            key: const Key('course_slot_editor_sheet'),
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              16 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: SheetDragHandle()),
                const SizedBox(height: 10),
                _PickerSheetHeader(
                  title: widget.isNew ? '添加上课时段' : '编辑上课时段',
                  cancelKey: const Key('slot_editor_cancel'),
                  onCancel: () => Navigator.pop(context),
                  confirmKey: const Key('slot_editor_confirm'),
                  confirmLabel: '完成',
                  onConfirm: _weeks.isEmpty
                      ? null
                      : () => Navigator.pop(
                          context,
                          CourseSlotEditorResult.updated(_buildDraft()),
                        ),
                ),
                const SizedBox(height: 6),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TimetableFormRow(
                          label: '课程类型',
                          child: AppSelectFormField<CourseKind>(
                            key: const Key('slot_editor_kind'),
                            label: '课程类型',
                            initialValue: _kind,
                            singleLine: true,
                            textStyle: const TextStyle(fontSize: 15),
                            options: const [
                              AppSelectOption(
                                value: CourseKind.standard,
                                label: '普通课',
                              ),
                              AppSelectOption(
                                value: CourseKind.lab,
                                label: '实验课',
                              ),
                              AppSelectOption(
                                value: CourseKind.pe,
                                label: '体育课',
                              ),
                            ],
                            onChanged: (v) => setState(() => _kind = v),
                          ),
                        ),
                        TimetableFormRow(
                          label: '星期',
                          child: AppSelectFormField<int>(
                            key: const Key('slot_editor_day'),
                            label: '星期',
                            initialValue: _day,
                            singleLine: true,
                            textStyle: const TextStyle(fontSize: 15),
                            options: [
                              for (var i = 0; i < 7; i++)
                                AppSelectOption(
                                  value: i + 1,
                                  label: kTimetableWeekdayLabels[i],
                                ),
                            ],
                            onChanged: (v) => setState(() => _day = v),
                          ),
                        ),
                        TimetableFormRow(
                          label: '节次',
                          child: Row(
                            children: [
                              Expanded(
                                child: AppSelectFormField<int>(
                                  key: const Key('slot_editor_start'),
                                  label: '开始节次',
                                  initialValue: _start,
                                  singleLine: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 8,
                                  ),
                                  textStyle: const TextStyle(fontSize: 14),
                                  options: [
                                    for (final n in _nodes)
                                      AppSelectOption(
                                        value: n,
                                        label: '第 $n 节',
                                      ),
                                  ],
                                  onChanged: _changeStart,
                                ),
                              ),
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 4),
                                child: Text('至'),
                              ),
                              Expanded(
                                child: AppSelectFormField<int>(
                                  key: Key('slot_editor_end_$_start'),
                                  label: '结束节次',
                                  initialValue: _end,
                                  singleLine: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 8,
                                  ),
                                  textStyle: const TextStyle(fontSize: 14),
                                  options: [
                                    for (final n in _nodes.where(
                                      (n) => n >= _start,
                                    ))
                                      AppSelectOption(
                                        value: n,
                                        label: '第 $n 节',
                                      ),
                                  ],
                                  onChanged: _changeEnd,
                                ),
                              ),
                            ],
                          ),
                        ),
                        TimetableFormReadonlyRow(
                          label: '上课时间',
                          value: _clockText,
                        ),
                        TimetableFormTapRow(
                          key: const Key('slot_editor_weeks'),
                          label: '上课周次',
                          value: _weeks.isEmpty
                              ? '请选择周次'
                              : formatWeeks(_weeks, maxSegments: null),
                          valueColor: _weeks.isEmpty ? colors.danger : null,
                          onTap: _pickWeeks,
                        ),
                        TimetableFormTextField(
                          fieldKey: const Key('slot_editor_location'),
                          label: '上课地点',
                          controller: _location,
                          hint: '例如：明德楼 S301',
                        ),
                        TimetableFormTextField(
                          fieldKey: const Key('slot_editor_note'),
                          label: '本节备注',
                          controller: _note,
                          focusNode: _noteFocus,
                          hint: '选填，如带实验报告、签到要求…',
                          minLines: 1,
                          maxLines: 3,
                          textInputAction: TextInputAction.done,
                          divider: false,
                        ),
                        if (conflictText != null)
                          Container(
                            margin: const EdgeInsets.only(top: 10),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: colors.warning.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.warning_amber_rounded,
                                  size: 16,
                                  color: colors.warning,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    conflictText,
                                    key: const Key('slot_editor_conflict'),
                                    style: TextStyle(
                                      color: colors.warning,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (widget.allowConvertToExam)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: OutlinedButton.icon(
                              key: const Key('slot_editor_to_exam'),
                              onPressed: () => Navigator.pop(
                                context,
                                CourseSlotEditorResult.toExam(_buildDraft()),
                              ),
                              icon: const Icon(Icons.event_available_outlined),
                              label: const Text('将本次课转为考试'),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(0, 44),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PickerSheetHeader extends StatelessWidget {
  const _PickerSheetHeader({
    required this.title,
    this.cancelKey,
    required this.onCancel,
    this.confirmKey,
    required this.confirmLabel,
    required this.onConfirm,
  });

  final String title;
  final Key? cancelKey;
  final VoidCallback onCancel;
  final Key? confirmKey;
  final String confirmLabel;
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return Row(
      children: [
        TextButton(
          key: cancelKey,
          onPressed: onCancel,
          style: TextButton.styleFrom(
            foregroundColor: colors.labelText,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            minimumSize: const Size(48, 36),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('取消', style: TextStyle(fontSize: 15)),
        ),
        Expanded(
          child: Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colors.titleText,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        TextButton(
          key: confirmKey,
          onPressed: onConfirm,
          style: TextButton.styleFrom(
            foregroundColor: colors.accent,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            minimumSize: const Size(48, 36),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            confirmLabel,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
