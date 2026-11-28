import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/ui/app_bottom_sheet.dart';
import '../../core/ui/miuix_dialog.dart';
import 'timetable_course_detail_sheet.dart';
import 'timetable_theme.dart';
import 'timetable_week_format.dart';

/// 保存范围；[weeks] 为 null 时修改这一上课安排的全部周次。
class CourseFormSaveScope {
  const CourseFormSaveScope(this.weeks);

  final List<int>? weeks;
}

/// 选择课程本身的上课周次；取消时保留调用方当前值。
Future<List<int>?> showCourseWeeksSheet(
  BuildContext context, {
  required int totalWeeks,
  required Set<int> initial,
}) => showAppModalBottomSheet<List<int>>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  enablePredictiveBackScale: false,
  backgroundColor: Colors.transparent,
  constraints: const BoxConstraints(maxWidth: 500),
  builder: (_) => _CourseWeeksSheet(totalWeeks: totalWeeks, initial: initial),
);

/// 编辑保存前选择生效范围；没有具体日期时直接按全部周次返回。
Future<CourseFormSaveScope?> showCourseFormSaveScopeSheet(
  BuildContext anchorContext, {
  required int totalWeeks,
  required Set<int> courseWeeks,
  int? currentWeek,
  DateTime? date,
}) async {
  final canScope = currentWeek != null && courseWeeks.contains(currentWeek);
  if (!canScope) return const CourseFormSaveScope(null);
  final future = courseWeeks.where((week) => week >= currentWeek).toList()
    ..sort();
  final choice = await showMiuixOptionDialog<_Scope>(
    anchorContext,
    title: '将修改应用到',
    contentKey: const Key('course_form_scope_sheet'),
    cancelKey: const Key('course_form_scope_cancel'),
    items: [
      MiuixOptionItem(
        key: const Key('course_form_scope_once'),
        value: _Scope.once,
        label: '仅这次课',
        description:
            '第 $currentWeek 周'
            '${date == null ? '' : ' · ${date.month}月${date.day}日'}',
      ),
      MiuixOptionItem(
        key: const Key('course_form_scope_future'),
        value: _Scope.future,
        label: '本周及以后',
        description: formatWeeks(future.toSet(), maxSegments: null),
      ),
      MiuixOptionItem(
        key: const Key('course_form_scope_all'),
        value: _Scope.all,
        label: '这一上课安排的所有周',
        description: formatWeeks(courseWeeks, maxSegments: null),
      ),
      const MiuixOptionItem(
        key: Key('course_form_scope_custom'),
        value: _Scope.custom,
        label: '自定义周次',
      ),
    ],
  );
  switch (choice) {
    case null:
      return null;
    case _Scope.once:
      return CourseFormSaveScope([currentWeek]);
    case _Scope.future:
      return CourseFormSaveScope(future);
    case _Scope.all:
      return const CourseFormSaveScope(null);
    case _Scope.custom:
      if (!anchorContext.mounted) return null;
      final weeks = await showCourseWeeksSheet(
        anchorContext,
        totalWeeks: totalWeeks,
        initial: courseWeeks,
      );
      return weeks == null ? null : CourseFormSaveScope(weeks);
  }
}

/// 更改课程重复周次时明确确认新旧安排，不再提供单次修改选项。
Future<bool> confirmCourseWeekChange(
  BuildContext context, {
  required Set<int> before,
  required Set<int> after,
}) async {
  final confirmed = await showAppModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    enablePredictiveBackScale: false,
    backgroundColor: Colors.transparent,
    constraints: const BoxConstraints(maxWidth: 500),
    builder: (context) => _SheetFrame(
      sheetKey: const Key('course_form_repeat_sheet'),
      title: '调整上课周次',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('原来：${formatWeeks(before, maxSegments: null)}'),
          const SizedBox(height: 12),
          Text('调整为：${formatWeeks(after, maxSegments: null)}'),
          const SizedBox(height: 16),
          Text(
            '作用于这一上课安排，其他时间段不变。',
            style: TextStyle(color: TimetableTheme.colorsOf(context).labelText),
          ),
        ],
      ),
      cancelKey: const Key('course_form_repeat_cancel'),
      confirmKey: const Key('course_form_repeat_confirm'),
      confirmLabel: '确认保存',
      onConfirm: () => Navigator.pop(context, true),
    ),
  );
  return confirmed == true;
}

class _CourseWeeksSheet extends StatefulWidget {
  const _CourseWeeksSheet({required this.totalWeeks, required this.initial});

  final int totalWeeks;
  final Set<int> initial;

  @override
  State<_CourseWeeksSheet> createState() => _CourseWeeksSheetState();
}

class _CourseWeeksSheetState extends State<_CourseWeeksSheet> {
  late Set<int> _weeks;
  bool _showError = false;

  @override
  void initState() {
    super.initState();
    _weeks = {...widget.initial};
  }

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final summary = _weeks.isEmpty
        ? '未选择周次'
        : formatWeeks(_weeks, maxSegments: null);
    return _SheetFrame(
      sheetKey: const Key('course_form_weeks_sheet'),
      title: '选择上课周次',
      subtitle: summary,
      subtitleColor: _weeks.isEmpty ? colors.hint : colors.accent,
      content: _WeeksGrid(
        totalWeeks: widget.totalWeeks,
        selected: _weeks,
        showError: _showError,
        onChanged: (weeks) => setState(() {
          _weeks = weeks;
          _showError = false;
        }),
      ),
      cancelKey: const Key('course_form_weeks_cancel'),
      confirmKey: const Key('course_form_weeks_confirm'),
      confirmLabel: '确定',
      onConfirm: () {
        if (_weeks.isEmpty) {
          setState(() => _showError = true);
          return;
        }
        Navigator.pop(context, _weeks.toList()..sort());
      },
    );
  }
}

enum _Scope { once, future, all, custom }

/// 轻量清爽的周次选择网格：勾选前后单格宽高恒定，用柔和浅底 + 细描边替代满屏高饱和色块。
class _WeeksGrid extends StatelessWidget {
  const _WeeksGrid({
    required this.totalWeeks,
    required this.selected,
    required this.onChanged,
    this.showError = false,
  });

  final int totalWeeks;
  final Set<int> selected;
  final ValueChanged<Set<int>> onChanged;
  final bool showError;

  Set<int> _preset(int parity) => {
    for (var week = 1; week <= totalWeeks; week++)
      if (parity == 0 || (parity == 1 ? week.isOdd : week.isEven)) week,
  };

  bool _matchesPreset(int parity) {
    final target = _preset(parity);
    return target.length == selected.length && selected.containsAll(target);
  }

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final isAll = _matchesPreset(0);
    final isOdd = _matchesPreset(1);
    final isEven = _matchesPreset(2);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            _QuickTag(
              tagKey: const Key('course_form_weeks_all'),
              label: '全部',
              active: isAll,
              onTap: () => onChanged(_preset(0)),
            ),
            _QuickTag(
              tagKey: const Key('course_form_weeks_odd'),
              label: '单周',
              active: isOdd,
              onTap: () => onChanged(_preset(1)),
            ),
            _QuickTag(
              tagKey: const Key('course_form_weeks_even'),
              label: '双周',
              active: isEven,
              onTap: () => onChanged(_preset(2)),
            ),
            _QuickTag(
              tagKey: const Key('course_form_weeks_clear'),
              label: '清空',
              active: false,
              muted: selected.isEmpty,
              onTap: () => onChanged({}),
            ),
          ],
        ),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, constraints) {
            final maxWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : 320.0;
            final columns = maxWidth < 260 ? 4 : 5;
            const spacing = 8.0;
            final cellWidth = math.max(
              44.0,
              (maxWidth - spacing * (columns - 1)) / columns,
            );
            final textHeight = MediaQuery.textScalerOf(context).scale(15);
            final cellHeight = math.max(40.0, textHeight + 18.0);

            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (var week = 1; week <= totalWeeks; week++)
                  SizedBox(
                    width: cellWidth,
                    height: cellHeight,
                    child: _WeekCellButton(
                      key: Key('course_form_week_$week'),
                      week: week,
                      selected: selected.contains(week),
                      onTap: () {
                        final next = {...selected};
                        if (!next.remove(week)) {
                          next.add(week);
                        }
                        onChanged(next);
                      },
                    ),
                  ),
              ],
            );
          },
        ),
        if (showError)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Semantics(
              liveRegion: true,
              child: Text(
                '请至少选择一周',
                key: const Key('course_form_weeks_error'),
                style: TextStyle(color: colors.danger, fontSize: 13),
              ),
            ),
          ),
      ],
    );
  }
}

class _QuickTag extends StatelessWidget {
  const _QuickTag({
    required this.tagKey,
    required this.label,
    required this.active,
    required this.onTap,
    this.muted = false,
  });

  final Key tagKey;
  final String label;
  final bool active;
  final bool muted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return Material(
      color: active ? colors.accentSoft : Colors.transparent,
      shape: StadiumBorder(
        side: BorderSide(
          color: active
              ? colors.accent.withValues(alpha: 0.45)
              : colors.divider.withValues(alpha: 0.8),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: tagKey,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              color: active
                  ? colors.accent
                  : (muted ? colors.hint : colors.labelText),
            ),
          ),
        ),
      ),
    );
  }
}

class _WeekCellButton extends StatelessWidget {
  const _WeekCellButton({
    super.key,
    required this.week,
    required this.selected,
    required this.onTap,
  });

  final int week;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    // 选中态采用柔和浅主色底 + 品牌色细描边与文字，未选中态保持透明净白细描边，避免大面积重色块堆积。
    final bg = selected ? colors.accentSoft : Colors.transparent;
    final borderColor = selected
        ? colors.accent.withValues(alpha: 0.75)
        : colors.divider.withValues(alpha: 0.75);
    final fg = selected ? colors.accent : colors.labelText;

    return Semantics(
      button: true,
      selected: selected,
      label: '第 $week 周',
      excludeSemantics: true,
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: borderColor, width: 1.0),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Center(
            child: Text(
              '$week',
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: fg,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({
    required this.sheetKey,
    required this.title,
    this.subtitle,
    this.subtitleColor,
    required this.content,
    required this.cancelKey,
    required this.confirmKey,
    required this.confirmLabel,
    required this.onConfirm,
  });

  final Key sheetKey;
  final String title;
  final String? subtitle;
  final Color? subtitleColor;
  final Widget content;
  final Key cancelKey;
  final Key confirmKey;
  final String confirmLabel;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return Material(
      color: colors.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .86,
          ),
          child: Padding(
            key: sheetKey,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: SheetDragHandle()),
                const SizedBox(height: 10),
                Row(
                  children: [
                    TextButton(
                      key: cancelKey,
                      onPressed: () => Navigator.pop(context),
                      style: TextButton.styleFrom(
                        foregroundColor: colors.labelText,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        minimumSize: const Size(48, 36),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        confirmLabel,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: subtitleColor ?? colors.labelText,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: content,
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
