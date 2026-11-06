import 'package:flutter/material.dart';

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
}) => showModalBottomSheet<List<int>>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: TimetableTheme.colorsOf(context).surface,
  builder: (_) => _CourseWeeksSheet(totalWeeks: totalWeeks, initial: initial),
);

/// 编辑保存前选择生效范围；没有具体日期时只确认全部周次。
Future<CourseFormSaveScope?> showCourseFormSaveScopeSheet(
  BuildContext context, {
  required int totalWeeks,
  required Set<int> courseWeeks,
  int? currentWeek,
  DateTime? date,
}) => showModalBottomSheet<CourseFormSaveScope>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: TimetableTheme.colorsOf(context).surface,
  builder: (_) => _CourseScopeSheet(
    totalWeeks: totalWeeks,
    courseWeeks: courseWeeks,
    currentWeek: currentWeek,
    date: date,
  ),
);

/// 更改课程重复周次时明确确认新旧安排，不再提供单次修改选项。
Future<bool> confirmCourseWeekChange(
  BuildContext context, {
  required Set<int> before,
  required Set<int> after,
}) async {
  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: TimetableTheme.colorsOf(context).surface,
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
  Widget build(BuildContext context) => _SheetFrame(
    sheetKey: const Key('course_form_weeks_sheet'),
    title: '选择上课周次',
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

enum _Scope { once, future, all, custom }

class _CourseScopeSheet extends StatefulWidget {
  const _CourseScopeSheet({
    required this.totalWeeks,
    required this.courseWeeks,
    required this.currentWeek,
    required this.date,
  });

  final int totalWeeks;
  final Set<int> courseWeeks;
  final int? currentWeek;
  final DateTime? date;

  @override
  State<_CourseScopeSheet> createState() => _CourseScopeSheetState();
}

class _CourseScopeSheetState extends State<_CourseScopeSheet> {
  late _Scope _scope;
  late Set<int> _weeks;
  bool _showError = false;

  bool get _canScope =>
      widget.currentWeek != null &&
      widget.courseWeeks.contains(widget.currentWeek);

  @override
  void initState() {
    super.initState();
    _scope = _canScope ? _Scope.once : _Scope.all;
    _weeks = {if (_canScope) widget.currentWeek!};
  }

  void _confirm() {
    final List<int>? weeks;
    switch (_scope) {
      case _Scope.once:
        weeks = [widget.currentWeek!];
      case _Scope.future:
        weeks =
            widget.courseWeeks
                .where((week) => week >= widget.currentWeek!)
                .toList()
              ..sort();
      case _Scope.all:
        weeks = null;
      case _Scope.custom:
        if (_weeks.isEmpty) {
          setState(() => _showError = true);
          return;
        }
        weeks = _weeks.toList()..sort();
    }
    Navigator.pop(context, CourseFormSaveScope(weeks));
  }

  @override
  Widget build(BuildContext context) {
    final date = widget.date;
    final future = widget.courseWeeks.where(
      (week) => week >= (widget.currentWeek ?? 1),
    );
    return _SheetFrame(
      sheetKey: const Key('course_form_scope_sheet'),
      title: '将修改应用到',
      content: !_canScope
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('应用到这一上课安排的所有周', key: Key('course_form_scope_all')),
                const SizedBox(height: 8),
                Text(formatWeeks(widget.courseWeeks, maxSegments: null)),
              ],
            )
          : RadioGroup<_Scope>(
              groupValue: _scope,
              onChanged: (value) => setState(() {
                _scope = value!;
                _showError = false;
              }),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  RadioListTile<_Scope>(
                    key: const Key('course_form_scope_once'),
                    value: _Scope.once,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('仅这次课'),
                    subtitle: Text(
                      '第 ${widget.currentWeek} 周'
                      '${date == null ? '' : ' · ${date.month}月${date.day}日'}',
                    ),
                  ),
                  RadioListTile<_Scope>(
                    key: const Key('course_form_scope_future'),
                    value: _Scope.future,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('本周及以后'),
                    subtitle: Text(formatWeeks(future, maxSegments: null)),
                  ),
                  RadioListTile<_Scope>(
                    key: const Key('course_form_scope_all'),
                    value: _Scope.all,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('这一上课安排的所有周'),
                    subtitle: Text(
                      formatWeeks(widget.courseWeeks, maxSegments: null),
                    ),
                  ),
                  const RadioListTile<_Scope>(
                    key: Key('course_form_scope_custom'),
                    value: _Scope.custom,
                    contentPadding: EdgeInsets.zero,
                    title: Text('自选周次'),
                  ),
                  if (_scope == _Scope.custom)
                    _WeeksGrid(
                      totalWeeks: widget.totalWeeks,
                      available: widget.courseWeeks,
                      selected: _weeks,
                      showError: _showError,
                      onChanged: (weeks) => setState(() {
                        _weeks = weeks;
                        _showError = false;
                      }),
                    ),
                ],
              ),
            ),
      cancelKey: const Key('course_form_scope_cancel'),
      confirmKey: const Key('course_form_scope_confirm'),
      confirmLabel: '确认保存',
      onConfirm: _confirm,
    );
  }
}

class _WeeksGrid extends StatelessWidget {
  const _WeeksGrid({
    required this.totalWeeks,
    required this.selected,
    required this.onChanged,
    this.available,
    this.showError = false,
  });

  final int totalWeeks;
  final Set<int> selected;
  final Set<int>? available;
  final ValueChanged<Set<int>> onChanged;
  final bool showError;

  Set<int> _preset(int parity) => {
    for (var week = 1; week <= totalWeeks; week++)
      if ((available?.contains(week) ?? true) &&
          (parity == 0 || (parity == 1 ? week.isOdd : week.isEven)))
        week,
  };

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 4,
          children: [
            TextButton(
              key: const Key('course_form_weeks_all'),
              onPressed: () => onChanged(_preset(0)),
              child: const Text('全部'),
            ),
            TextButton(
              key: const Key('course_form_weeks_odd'),
              onPressed: () => onChanged(_preset(1)),
              child: const Text('单周'),
            ),
            TextButton(
              key: const Key('course_form_weeks_even'),
              onPressed: () => onChanged(_preset(2)),
              child: const Text('双周'),
            ),
            TextButton(
              key: const Key('course_form_weeks_clear'),
              onPressed: () => onChanged({}),
              child: const Text('清空'),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (var week = 1; week <= totalWeeks; week++)
              Semantics(
                label: '第 $week 周',
                child: FilterChip(
                  key: Key('course_form_week_$week'),
                  label: Text('$week'),
                  selected: selected.contains(week),
                  showCheckmark: true,
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  onSelected: available?.contains(week) == false
                      ? null
                      : (value) {
                          final next = {...selected};
                          value ? next.add(week) : next.remove(week);
                          onChanged(next);
                        },
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          selected.isEmpty ? '未选择周次' : formatWeeks(selected, maxSegments: null),
          style: TextStyle(color: colors.labelText, fontSize: 13),
        ),
        if (showError)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Semantics(
              liveRegion: true,
              child: Text(
                '请至少选择一周',
                key: const Key('course_form_weeks_error'),
                style: TextStyle(color: colors.danger),
              ),
            ),
          ),
      ],
    );
  }
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({
    required this.sheetKey,
    required this.title,
    required this.content,
    required this.cancelKey,
    required this.confirmKey,
    required this.confirmLabel,
    required this.onConfirm,
  });

  final Key sheetKey;
  final String title;
  final Widget content;
  final Key cancelKey;
  final Key confirmKey;
  final String confirmLabel;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .88,
      ),
      child: Padding(
        key: sheetKey,
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: TextStyle(
                color: TimetableTheme.colorsOf(context).titleText,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Flexible(child: SingleChildScrollView(child: content)),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: cancelKey,
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: confirmKey,
                    onPressed: onConfirm,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                    child: Text(confirmLabel),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
