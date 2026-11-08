import 'timetable_persistence_feedback.dart';

import 'package:flutter/material.dart';

import '../../core/app_snack_bar.dart';
import 'timetable_change_format.dart';
import 'timetable_color_picker.dart';
import 'timetable_course_color.dart';
import 'timetable_delete_scope_sheet.dart';
import 'timetable_course_edit_page.dart';
import 'timetable_controller.dart';
import 'timetable_models.dart';
import 'timetable_theme.dart';
import 'timetable_manual_course_form.dart';
import 'timetable_week_format.dart';

/// 课程详情底部弹层（对照 spec §4）。
Future<void> showCourseDetailSheet(
  BuildContext context, {
  required GridCell cell,
  required TimetableController controller,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (context) => CourseDetailSheet(cell: cell, controller: controller),
  );
}

/// 课程详情：紧凑信息、颜色预览与编辑操作。
class CourseDetailSheet extends StatefulWidget {
  const CourseDetailSheet({
    super.key,
    required this.cell,
    required this.controller,
  });

  final GridCell cell;
  final TimetableController controller;

  @override
  State<CourseDetailSheet> createState() => _CourseDetailSheetState();
}

class _CourseDetailSheetState extends State<CourseDetailSheet> {
  GridCell get _cell {
    final initial = widget.cell;
    final date = initial.date;
    if (date == null) return initial;
    for (final cell in widget.controller.cellsForDay(
      widget.controller.weekOfDate(date),
      date.weekday,
    )) {
      if (cell.course.id == initial.course.id &&
          cell.slot.startNode == initial.slot.startNode &&
          cell.slot.endNode == initial.slot.endNode &&
          cell.activeThisWeek == initial.activeThisWeek) {
        return cell;
      }
    }
    return initial;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => _buildDetail(context),
  );

  Widget _buildDetail(BuildContext context) {
    final cell = _cell;
    final course = cell.course;
    final slot = cell.slot;
    final colors = TimetableTheme.colorsOf(context);
    final slotIndex = _slotIndexOf(course, slot);
    final overrideInfo = slotIndex < 0
        ? null
        : widget.controller.overrideInfoFor(course, slotIndex);
    final courseModified =
        course.source == CourseSource.jwxt &&
        widget.controller.isJwxtOverridden(courseId: course.id);
    final time = widget.controller.timeForSlot(course, slot, date: cell.date);
    final range = slot.startNode == slot.endNode
        ? '第 ${slot.startNode} 节'
        : '第 ${slot.startNode}–${slot.endNode} 节';
    final clock = time.start == null || time.end == null
        ? range
        : '${time.start}–${time.end}';
    final date = cell.date;
    final dateText = date == null
        ? ''
        : '${date.month}月${date.day}日 周${_weekdayCn[date.weekday - 1]}';
    final weeks = _weeksText(slot);

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      child: Material(
        color: colors.surface,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(TimetableTheme.sheetTopRadius),
        ),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            key: const Key('course_detail_scroll'),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: SheetDragHandle()),
                const SizedBox(height: 12),
                Row(
                  key: const Key('course_detail_header'),
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      key: const Key('course_detail_color_bar'),
                      width: 4,
                      height: 22,
                      decoration: BoxDecoration(
                        color: coursePairFor(
                          widget.controller,
                          course,
                          dark: colors.isDark,
                        ).bg,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _courseTitle(
                        courseDisplayName(course: course, slot: slot),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Row(
                      key: const Key('course_detail_actions'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CourseColorRow(
                          controller: widget.controller,
                          course: course,
                          cell: cell,
                          controlHeight: 32,
                        ),
                        IconButton(
                          key: Key(
                            course.isManual
                                ? 'course_detail_edit'
                                : 'course_detail_jwxt_edit',
                          ),
                          tooltip: '编辑课程',
                          padding: const EdgeInsets.all(6),
                          onPressed: _restoring ? null : () => _edit(course),
                          constraints: const BoxConstraints.tightFor(
                            width: 48,
                            height: 32,
                          ),
                          style: IconButton.styleFrom(
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          icon: Icon(
                            Icons.edit_outlined,
                            size: 20,
                            color: colors.labelText,
                          ),
                        ),
                        IconButton(
                          key: Key(
                            course.isManual
                                ? 'course_detail_delete'
                                : 'course_detail_jwxt_delete',
                          ),
                          tooltip: '删除课程',
                          padding: const EdgeInsets.all(6),
                          onPressed: _restoring ? null : () => _delete(course),
                          constraints: const BoxConstraints.tightFor(
                            width: 48,
                            height: 32,
                          ),
                          style: IconButton.styleFrom(
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          icon: Icon(
                            Icons.delete_outline,
                            size: 20,
                            color: colors.danger,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                Wrap(
                  key: const Key('course_detail_metadata'),
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (course.classId.isNotEmpty || course.credit != null)
                      Text(
                        [
                          if (course.classId.isNotEmpty) '课序 ${course.classId}',
                          if (course.credit != null)
                            '${_formatCredit(course.credit!)} 学分',
                        ].join(' · '),
                        style: TextStyle(fontSize: 12, color: colors.labelText),
                      ),
                    if (course.isManual) const _DetailTag(label: '手动添加'),
                    if (courseKindOf(course: course, slot: slot) ==
                            CourseKind.lab &&
                        (slot.kind != null || !course.isPe))
                      const _DetailTag(
                        key: Key('course_detail_lab_label'),
                        label: '实验课',
                      ),
                    if (cell.dateEdit != null)
                      _DetailTag(
                        key: const Key('course_detail_date_edit'),
                        label: cell.dateEdit!.isWeeksScoped ? '按周已修改' : '本节已修改',
                        onTap: _restoring ? null : _showChanges,
                      ),
                    if (cell.dateEdit == null && overrideInfo != null)
                      _DetailTag(
                        key: const Key('course_detail_override'),
                        label: '已调课',
                        onTap: _restoring ? null : _showChanges,
                      ),
                    if (cell.dateEdit == null &&
                        overrideInfo == null &&
                        courseModified)
                      _DetailTag(
                        key: const Key('course_detail_modified'),
                        label: '课程已修改',
                        onTap: _restoring ? null : _showChanges,
                      ),
                  ],
                ),
                _InfoRow(
                  key: const Key('course_detail_time'),
                  icon: Icons.access_time,
                  text: clock,
                  secondaryText: [
                    if (dateText.isNotEmpty) dateText,
                    if (clock != range) range,
                  ].join(' · '),
                  emphasized: true,
                  verticalPadding: 4,
                ),
                _InfoRow(
                  icon: Icons.place_outlined,
                  text: slot.location.isEmpty ? '地点未填写' : slot.location,
                ),
                _InfoRow(
                  icon: Icons.person_outline,
                  text: slot.teacher.isEmpty ? '教师未填写' : slot.teacher,
                ),
                if (weeks.isNotEmpty)
                  _InfoRow(icon: Icons.calendar_today_outlined, text: weeks),
                _InfoRow(
                  key: const Key('course_detail_note'),
                  icon: Icons.notes_outlined,
                  text: slot.note.isEmpty ? '添加备注…' : slot.note,
                  onTap: _restoring
                      ? null
                      : () => _edit(course, autofocusNote: true),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 末行过短时稍收窄标题宽度，在不增加行数的前提下均衡自然换行。
  Widget _courseTitle(String name) {
    final style = TimetableTheme.titleStyle(
      color: TimetableTheme.colorsOf(context).titleText,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaler = MediaQuery.textScalerOf(context);
        final painter = TextPainter(
          text: TextSpan(
            text: name,
            style: DefaultTextStyle.of(context).style.merge(style),
          ),
          textDirection: Directionality.of(context),
          textScaler: scaler,
        )..layout(maxWidth: constraints.maxWidth);
        final lines = painter.computeLineMetrics();
        var width = constraints.maxWidth;
        if (lines.length > 1 &&
            lines.length <= 3 &&
            lines.last.width < width * 0.45 &&
            !name.contains('\n')) {
          final balanced =
              painter.maxIntrinsicWidth / lines.length +
              scaler.scale(style.fontSize!);
          if (balanced < width) {
            painter.layout(maxWidth: balanced);
            if (painter.computeLineMetrics().length <= lines.length) {
              width = balanced;
            }
          }
        }
        painter.dispose();
        return Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: width,
            child: Text(
              name,
              key: const Key('course_detail_title'),
              style: style,
            ),
          ),
        );
      },
    );
  }

  /// 展开当前课程的本地修改，按原有范围分别提供恢复入口。
  Future<void> _showChanges() async {
    final cell = _cell;
    final course = cell.course;
    final base = widget.controller.baseOccurrenceOf(cell);
    final changes = widget.controller.courseDetailChanges(cell);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: TimetableTheme.colorsOf(context).surface,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '课程修改',
                style: TimetableTheme.titleStyle(
                  color: TimetableTheme.colorsOf(sheetContext).titleText,
                ),
              ),
              const SizedBox(height: 12),
              for (final group in changes)
                _CourseChangeSection(
                  group: group,
                  restoreKey: Key(switch (group.scope) {
                    CourseDetailChangeScope.occurrence =>
                      'course_detail_restore_day',
                    CourseDetailChangeScope.position => 'course_detail_restore',
                    CourseDetailChangeScope.course =>
                      'course_detail_restore_course',
                  }),
                  restoreLabel: switch (group.scope) {
                    CourseDetailChangeScope.occurrence =>
                      cell.dateEdit!.isWeeksScoped ? '恢复' : '恢复这一天',
                    CourseDetailChangeScope.position => '恢复原位置',
                    CourseDetailChangeScope.course => '恢复原课程',
                  },
                  onRestore: () {
                    Navigator.pop(sheetContext);
                    switch (group.scope) {
                      case CourseDetailChangeScope.occurrence:
                        _restoreDay();
                      case CourseDetailChangeScope.position:
                        _restore(base!.course, base.slotIndex);
                      case CourseDetailChangeScope.course:
                        _restoreCourse(course);
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 撤销这一格对应的单日或按周修改记录。
  Future<void> _restoreDay() async {
    await withTimetablePersistenceFeedback(
      context,
      () => _restoreDayUnchecked(),
    );
    if (mounted) setState(() => _restoring = false);
  }

  Future<void> _restoreDayUnchecked() async {
    final edit = _cell.dateEdit;
    final id = edit?.id;
    if (id == null) return;
    setState(() => _restoring = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await widget.controller.restoreDateEdit(id);
    if (!mounted) return;
    setState(() => _restoring = false);
    if (navigator.canPop()) navigator.pop();
    messenger?.showSnackBar(
      AppSnackBar(
        tone: ok ? AppSnackBarTone.success : AppSnackBarTone.error,
        behavior: SnackBarBehavior.floating,
        content: Text(
          ok ? (edit!.isWeeksScoped ? '已恢复按周修改' : '已恢复这一天') : '恢复失败',
        ),
      ),
    );
  }

  bool _restoring = false;

  static const _weekdayCn = ['一', '二', '三', '四', '五', '六', '日'];

  static int _slotIndexOf(Course course, CourseSlot slot) {
    final i = course.slots.indexWhere((s) => identical(s, slot));
    if (i >= 0) return i;
    return course.slots.indexWhere(
      (s) =>
          s.day == slot.day &&
          s.startNode == slot.startNode &&
          s.endNode == slot.endNode &&
          s.weeks == slot.weeks,
    );
  }

  /// 「恢复原位置」：删掉该时段的全部调课记录，关闭详情（网格随 controller 刷新）。
  Future<void> _restore(Course course, int slotIndex) async {
    await withTimetablePersistenceFeedback(
      context,
      () => _restoreUnchecked(course, slotIndex),
    );
    if (mounted) setState(() => _restoring = false);
  }

  Future<void> _restoreUnchecked(Course course, int slotIndex) async {
    setState(() => _restoring = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await widget.controller.restoreOverride(course, slotIndex);
    if (!mounted) return;
    setState(() => _restoring = false);
    if (navigator.canPop()) navigator.pop();
    messenger?.showSnackBar(
      AppSnackBar(
        tone: ok ? AppSnackBarTone.success : AppSnackBarTone.error,
        behavior: SnackBarBehavior.floating,
        content: Text(ok ? '已恢复原位置' : '恢复失败'),
      ),
    );
  }

  Future<void> _restoreCourse(Course course) async {
    await withTimetablePersistenceFeedback(
      context,
      () => _restoreCourseUnchecked(course),
    );
    if (mounted) setState(() => _restoring = false);
  }

  Future<void> _restoreCourseUnchecked(Course course) async {
    setState(() => _restoring = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await widget.controller.restoreJwxtCourse(course.id);
    if (!mounted) return;
    setState(() => _restoring = false);
    if (navigator.canPop()) navigator.pop();
    messenger?.showSnackBar(
      AppSnackBar(
        tone: ok ? AppSnackBarTone.success : AppSnackBarTone.error,
        behavior: SnackBarBehavior.floating,
        content: Text(ok ? '已恢复原课程' : '恢复失败'),
      ),
    );
  }

  Future<void> _edit(Course course, {bool autofocusNote = false}) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final saved = course.source == CourseSource.jwxt
        ? await showJwxtCourseEditPage(
                context,
                controller: widget.controller,
                cell: _cell,
                autofocusNote: autofocusNote,
              ) ==
              true
        : await showManualCourseForm(
                context,
                controller: widget.controller,
                initial: course,
                initialSlot: _cell.slot,
                cell: _cell,
                autofocusNote: autofocusNote,
              ) !=
              null;
    if (!saved || !mounted) return;
    if (navigator.canPop()) navigator.pop();
    messenger?.showSnackBar(
      AppSnackBar(
        tone: AppSnackBarTone.success,
        behavior: SnackBarBehavior.floating,
        content: Text('已保存'),
      ),
    );
  }

  Future<void> _delete(Course course) async {
    await withTimetablePersistenceFeedback(
      context,
      () => _deleteUnchecked(course),
    );
  }

  Future<void> _deleteUnchecked(Course course) async {
    final cell = _cell;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final date = cell.date;
    if (date != null && cell.activeThisWeek) {
      final week = widget.controller.weekOfDate(date);
      final scope = await showDeleteScopeSheet(
        context,
        week: week,
        weekday: date.weekday,
        teacherOrLocationEmpty:
            cell.slot.teacher.isEmpty || cell.slot.location.isEmpty,
      );
      if (scope == null || !mounted) return;
      switch (scope) {
        case DeleteScope.oneDay:
          final rec = await widget.controller.deleteOccurrence(cell);
          if (!mounted) return;
          if (navigator.canPop()) navigator.pop();
          messenger?.showSnackBar(
            AppSnackBar(
              tone: rec == null
                  ? AppSnackBarTone.error
                  : AppSnackBarTone.success,
              behavior: SnackBarBehavior.floating,
              content: Text(rec == null ? '删除失败' : '已删除这一天的课'),
            ),
          );
          return;
        case DeleteScope.weekdayMatch:
          final rec = await widget.controller.deleteWeekdayMatch(cell);
          if (!mounted) return;
          if (navigator.canPop()) navigator.pop();
          messenger?.showSnackBar(
            AppSnackBar(
              tone: rec == null
                  ? AppSnackBarTone.error
                  : AppSnackBarTone.success,
              behavior: SnackBarBehavior.floating,
              content: Text(rec == null ? '删除失败' : '已删除同星期匹配的课'),
            ),
          );
          return;
        case DeleteScope.wholeCourse:
          break;
      }
    }
    final readOnly = course.source == CourseSource.jwxt;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除课程'),
        content: readOnly
            ? const Text(
                kJwxtCourseDeleteMessage,
                key: Key('jwxt_delete_message'),
              )
            : Text(
                '确定删除「${courseDisplayName(course: course, slot: cell.slot)}」吗？此操作不可撤销。',
              ),
        actions: [
          TextButton(
            key: readOnly ? const Key('jwxt_delete_cancel') : null,
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            key: Key(
              readOnly ? 'jwxt_delete_confirm' : 'course_delete_confirm',
            ),
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: TimetableTheme.colorsOf(context).danger,
            ),
            child: Text(readOnly ? '删除' : '确认删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (readOnly) {
      await widget.controller.deleteJwxtCourse(course.id);
    } else {
      await widget.controller.deleteManualCourse(course.id);
    }
    if (!mounted) return;
    if (navigator.canPop()) navigator.pop();
    messenger?.showSnackBar(
      AppSnackBar(
        tone: AppSnackBarTone.success,
        behavior: SnackBarBehavior.floating,
        content: Text('已删除'),
      ),
    );
  }

  String _formatCredit(double credit) {
    if (credit == credit.roundToDouble()) {
      return credit.toInt().toString();
    }
    return credit.toString();
  }

  String _weeksText(CourseSlot slot) {
    final text = formatWeekBits(slot.weeks);
    return text.isNotEmpty ? text : slot.weeksLabel;
  }
}

/// 底部弹层顶部的拖动条（课程详情、调课范围面板共用）。
class SheetDragHandle extends StatelessWidget {
  const SheetDragHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('sheet_drag_handle'),
      width: 36,
      height: 4,
      decoration: BoxDecoration(
        color: TimetableTheme.colorsOf(context).divider,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

class _DetailTag extends StatelessWidget {
  const _DetailTag({super.key, required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final tag = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: colors.divider),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, color: colors.labelText),
      ),
    );
    if (onTap == null) return tag;
    return Semantics(
      button: true,
      label: '$label，查看修改与恢复',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48),
          child: tag,
        ),
      ),
    );
  }
}

/// 按恢复范围展示字段差异，长文本上下排列以适配窄屏和大字体。
class _CourseChangeSection extends StatelessWidget {
  const _CourseChangeSection({
    required this.group,
    required this.restoreKey,
    required this.restoreLabel,
    required this.onRestore,
  });

  final CourseDetailChangeGroup group;
  final Key restoreKey;
  final String restoreLabel;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return Padding(
      key: Key('course_detail_diff_${group.scope.name}'),
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            group.title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: colors.titleText,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '影响范围：${group.affectedScope}',
            style: TextStyle(fontSize: 12, color: colors.labelText),
          ),
          if (group.changes.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '当前没有生效的字段差异',
                style: TextStyle(fontSize: 14, color: colors.labelText),
              ),
            ),
          for (final change in group.changes)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    change.field,
                    style: TextStyle(fontSize: 13, color: colors.labelText),
                  ),
                  const SizedBox(height: 4),
                  _changeValue(
                    context,
                    '修改前',
                    change.before,
                    change.beforeColor,
                  ),
                  const SizedBox(height: 4),
                  _changeValue(context, '修改后', change.after, change.afterColor),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: restoreKey,
              onPressed: onRestore,
              child: Text(restoreLabel),
            ),
          ),
          Divider(height: 1, color: colors.divider),
        ],
      ),
    );
  }

  Widget _changeValue(
    BuildContext context,
    String label,
    String value,
    int? color,
  ) {
    final colors = TimetableTheme.colorsOf(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (color != null) ...[
          Container(
            width: 16,
            height: 16,
            margin: const EdgeInsets.only(top: 2),
            decoration: BoxDecoration(
              color: Color(color),
              border: Border.all(color: colors.labelText),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(
            '$label：$value',
            style: TextStyle(fontSize: 14, color: colors.titleText),
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    super.key,
    required this.icon,
    required this.text,
    this.secondaryText = '',
    this.emphasized = false,
    this.verticalPadding = 7,
    this.onTap,
  });

  final IconData icon;
  final String text;
  final String secondaryText;
  final bool emphasized;
  final double verticalPadding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final row = Padding(
      padding: EdgeInsets.symmetric(vertical: verticalPadding),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: colors.labelText),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text,
                  style: TextStyle(
                    fontSize: emphasized ? 15 : 14,
                    fontWeight: emphasized ? FontWeight.w500 : FontWeight.w400,
                    color: emphasized ? colors.titleText : colors.labelText,
                  ),
                ),
                if (secondaryText.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    secondaryText,
                    style: TextStyle(fontSize: 12, color: colors.labelText),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: row,
      ),
    );
  }
}
