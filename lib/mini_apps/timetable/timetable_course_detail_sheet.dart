import 'timetable_persistence_feedback.dart';

import 'package:flutter/material.dart';

import '../../core/app_snack_bar.dart';
import '../../core/ui/app_bottom_sheet.dart';
import '../../core/ui/miuix_dialog.dart';
import 'timetable_change_format.dart';
import 'timetable_color_picker.dart';
import 'timetable_controller.dart';
import 'timetable_course_color.dart';
import 'timetable_course_group.dart';
import 'timetable_delete_scope_sheet.dart';
import 'timetable_entry_edit_page.dart';
import 'timetable_models.dart';
import 'timetable_theme.dart';
import 'timetable_week_format.dart';

/// 课程详情底部弹层（不启用跟手缩放变形，侧滑或下滑直接走标准底部收起退场）。
Future<void> showCourseDetailSheet(
  BuildContext context, {
  required GridCell cell,
  required TimetableController controller,
}) {
  // 叠加选色/备注入口时键盘每帧更新弹层约束，复用详情避免重建底层文字。
  final detail = CourseDetailSheet(cell: cell, controller: controller);
  return showAppModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    enablePredictiveBackScale: false,
    backgroundColor: Colors.transparent,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (_) => detail,
  );
}

/// 课程详情：紧凑层次化信息卡片、颜色预览与编辑操作。
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
    final group = widget.controller.courseGroupOf(course);
    final progress = widget.controller.courseProgressOf(course);
    final globalNote = group.globalNote;
    final slotNote = slot.note.trim();
    final noteDisplay = _buildNoteDisplay(globalNote, slotNote);
    final hasAnyMeta =
        course.classId.isNotEmpty ||
        course.credit != null ||
        course.isManual ||
        courseKindOf(course: course, slot: slot) == CourseKind.lab ||
        courseKindOf(course: course, slot: slot) == CourseKind.pe ||
        cell.swappedFrom != null ||
        cell.dateEdit != null ||
        overrideInfo != null ||
        courseModified;

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.86,
      ),
      child: Material(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        clipBehavior: Clip.antiAlias,
        // 叠加的选色面板唤起键盘时，详情保持原高度，不随底部内边距归零而重排。
        child: SafeArea(
          top: false,
          maintainBottomViewPadding: true,
          child: SingleChildScrollView(
            key: const Key('course_detail_scroll'),
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: SheetDragHandle()),
                const SizedBox(height: 14),
                Row(
                  key: const Key('course_detail_header'),
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      key: const Key('course_detail_color_bar'),
                      width: 5,
                      height: 24,
                      decoration: BoxDecoration(
                        color: coursePairFor(
                          widget.controller,
                          course,
                          dark: colors.isDark,
                        ).bg,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 10),
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
                          controlHeight: 36,
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
                            width: 44,
                            height: 36,
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
                        Builder(
                          builder: (buttonContext) => IconButton(
                            key: Key(
                              course.isManual
                                  ? 'course_detail_delete'
                                  : 'course_detail_jwxt_delete',
                            ),
                            tooltip: '删除课程',
                            padding: const EdgeInsets.all(6),
                            onPressed: _restoring
                                ? null
                                : () => _delete(buttonContext, course),
                            constraints: const BoxConstraints.tightFor(
                              width: 44,
                              height: 36,
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
                        ),
                      ],
                    ),
                  ],
                ),
                if (hasAnyMeta) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    key: const Key('course_detail_metadata'),
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (course.classId.isNotEmpty || course.credit != null)
                        _DetailTag(
                          label: [
                            if (course.classId.isNotEmpty)
                              '课序 ${course.classId}',
                            if (course.credit != null)
                              '${_formatCredit(course.credit!)} 学分',
                          ].join(' · '),
                        ),
                      if (course.isManual) const _DetailTag(label: '手动添加'),
                      if (courseKindOf(course: course, slot: slot) ==
                          CourseKind.lab)
                        const _DetailTag(
                          key: Key('course_detail_lab_label'),
                          label: '实验课',
                        ),
                      if (courseKindOf(course: course, slot: slot) ==
                          CourseKind.pe)
                        const _DetailTag(label: '体育课'),
                      if (cell.swappedFrom case final swappedFrom?)
                        _DetailTag(
                          key: const Key('course_detail_swapped_from'),
                          label:
                              '由 ${swappedFrom.month}月${swappedFrom.day}日 调入',
                          accent: true,
                        ),
                      if (cell.dateEdit != null)
                        _DetailTag(
                          key: const Key('course_detail_date_edit'),
                          label: cell.dateEdit!.isWeeksScoped
                              ? '按周已修改'
                              : '本节已修改',
                          accent: true,
                          onTap: _restoring ? null : _showChanges,
                        ),
                      if (cell.dateEdit == null && overrideInfo != null)
                        _DetailTag(
                          key: const Key('course_detail_override'),
                          label: '已调课',
                          accent: true,
                          onTap: _restoring ? null : _showChanges,
                        ),
                      if (cell.dateEdit == null &&
                          overrideInfo == null &&
                          courseModified)
                        _DetailTag(
                          key: const Key('course_detail_modified'),
                          label: '课程已修改',
                          accent: true,
                          onTap: _restoring ? null : _showChanges,
                        ),
                    ],
                  ),
                ] else
                  const SizedBox(key: Key('course_detail_metadata'), height: 0),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: colors.pageBg,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _InfoRow(
                        key: const Key('course_detail_time'),
                        icon: Icons.access_time_rounded,
                        text: clock,
                        secondaryText: [
                          if (dateText.isNotEmpty) dateText,
                          if (clock != range) range,
                        ].join(' · '),
                        emphasized: true,
                      ),
                      Divider(
                        height: 1,
                        color: colors.divider.withValues(alpha: 0.6),
                      ),
                      _InfoRow(
                        icon: Icons.place_outlined,
                        text: slot.location.isEmpty ? '地点未填写' : slot.location,
                        muted: slot.location.isEmpty,
                      ),
                      Divider(
                        height: 1,
                        color: colors.divider.withValues(alpha: 0.6),
                      ),
                      _InfoRow(
                        icon: Icons.person_outline,
                        text: slot.teacher.isEmpty ? '教师未填写' : slot.teacher,
                        muted: slot.teacher.isEmpty,
                      ),
                    ],
                  ),
                ),
                if (group.slots.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Container(
                    decoration: BoxDecoration(
                      color: colors.pageBg,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: _ScheduleSummarySection(
                      group: group,
                      currentCourse: course,
                      currentSlot: slot,
                      progress: progress,
                      expanded: _schedulesExpanded,
                      onToggleExpand: () => setState(
                        () => _schedulesExpanded = !_schedulesExpanded,
                      ),
                      onTapSlot: _restoring
                          ? null
                          : (index) => _edit(course, openSlotIndex: index),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Material(
                  color: colors.pageBg,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    key: const Key('course_detail_note'),
                    onTap: _restoring
                        ? null
                        : () => _edit(course, autofocusNote: true),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Icon(
                              Icons.notes_rounded,
                              size: 18,
                              color: noteDisplay.isEmpty
                                  ? colors.hint
                                  : colors.labelText,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  noteDisplay.primary,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: noteDisplay.isEmpty
                                        ? colors.hint
                                        : colors.titleText,
                                  ),
                                ),
                                if (noteDisplay.secondary.isNotEmpty) ...[
                                  const SizedBox(height: 3),
                                  Text(
                                    noteDisplay.secondary,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: colors.labelText,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          Icon(
                            Icons.chevron_right,
                            size: 18,
                            color: colors.chevron,
                          ),
                        ],
                      ),
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
    await showAppModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      enablePredictiveBackScale: false,
      backgroundColor: Colors.transparent,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (sheetContext) {
        final colors = TimetableTheme.colorsOf(sheetContext);
        return Material(
          color: colors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: SheetDragHandle()),
                  const SizedBox(height: 14),
                  Text(
                    '课程修改',
                    style: TimetableTheme.titleStyle(color: colors.titleText),
                  ),
                  const SizedBox(height: 12),
                  for (final group in changes)
                    _CourseChangeSection(
                      group: group,
                      restoreKey: Key(switch (group.scope) {
                        CourseDetailChangeScope.occurrence =>
                          'course_detail_restore_day',
                        CourseDetailChangeScope.position =>
                          'course_detail_restore',
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
      },
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
  bool _schedulesExpanded = false;

  static const _weekdayCn = ['一', '二', '三', '四', '五', '六', '日'];

  static ({String primary, String secondary, bool isEmpty}) _buildNoteDisplay(
    String globalNote,
    String slotNote,
  ) {
    if (globalNote.isEmpty && slotNote.isEmpty) {
      return (primary: '添加备注…', secondary: '', isEmpty: true);
    }
    if (globalNote.isEmpty) {
      return (primary: slotNote, secondary: '', isEmpty: false);
    }
    if (slotNote.isEmpty || slotNote == globalNote) {
      return (primary: globalNote, secondary: '', isEmpty: false);
    }
    return (primary: globalNote, secondary: '本节备注：$slotNote', isEmpty: false);
  }

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

  Future<void> _edit(
    Course course, {
    bool autofocusNote = false,
    int? openSlotIndex,
  }) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final saved =
        await showCourseEditPage(
          context,
          controller: widget.controller,
          course: course,
          initialSlot: _cell.slot,
          cell: _cell,
          autofocusNote: autofocusNote,
          openSlotIndex: openSlotIndex,
        ) ==
        true;
    if (!saved || !mounted) return;
    if (navigator.canPop()) navigator.pop();
    messenger?.showSnackBar(
      AppSnackBar(
        tone: AppSnackBarTone.success,
        behavior: SnackBarBehavior.floating,
        content: const Text('已保存'),
      ),
    );
  }

  Future<void> _delete(BuildContext anchorContext, Course course) async {
    await withTimetablePersistenceFeedback(
      context,
      () => _deleteUnchecked(anchorContext, course),
    );
  }

  Future<void> _deleteUnchecked(
    BuildContext anchorContext,
    Course course,
  ) async {
    final cell = _cell;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final date = cell.date;
    if (date != null && cell.activeThisWeek) {
      final week = widget.controller.weekOfDate(date);
      final scope = await showDeleteScopeSheet(
        anchorContext,
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
    final confirmed = await showMiuixConfirmDialog(
      context,
      title: '删除课程',
      message: readOnly
          ? '删除这门课？同步后也不会恢复，可在设置里一键恢复。'
          : '确定删除「${courseDisplayName(course: course, slot: cell.slot)}」吗？此操作不可撤销。',
      messageKey: readOnly ? const Key('jwxt_delete_message') : null,
      confirmLabel: readOnly ? '删除' : '确认删除',
      cancelLabel: '取消',
      destructive: true,
      cancelKey: readOnly ? const Key('jwxt_delete_cancel') : null,
      confirmKey: Key(
        readOnly ? 'jwxt_delete_confirm' : 'course_delete_confirm',
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
        content: const Text('已删除'),
      ),
    );
  }

  String _formatCredit(double credit) {
    if (credit == credit.roundToDouble()) {
      return credit.toInt().toString();
    }
    return credit.toString();
  }
}

/// 同课程按「同星期 + 同节次 + 同地点」合并后的上课安排展示（周数在前、星期节次在后）。
class _ScheduleSummarySection extends StatelessWidget {
  const _ScheduleSummarySection({
    required this.group,
    required this.currentCourse,
    required this.currentSlot,
    required this.progress,
    required this.expanded,
    required this.onToggleExpand,
    this.onTapSlot,
  });

  final CourseGroup group;
  final Course currentCourse;
  final CourseSlot currentSlot;
  final CourseGroupProgress progress;
  final bool expanded;
  final VoidCallback onToggleExpand;
  final ValueChanged<int>? onTapSlot;

  static const _weekdayCn = ['一', '二', '三', '四', '五', '六', '日'];
  static const _collapsedLimit = 3;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final items = group.mergedSchedules;
    final currentIndex = _findCurrentIndex(items);
    final progressText = progress.label;
    final visibleIndices = _visibleIndices(items.length, currentIndex);
    final hasOverflow = !expanded && items.length > _collapsedLimit;

    return Column(
      key: const Key('course_detail_schedules'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              Icons.calendar_today_outlined,
              size: 17,
              color: colors.labelText,
            ),
            const SizedBox(width: 10),
            Text(
              items.length > 1 ? '上课安排（${items.length} 个时段）' : '上课安排',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colors.labelText,
              ),
            ),
            if (progressText.isNotEmpty) ...[
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: colors.accentSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  progressText,
                  key: const Key('course_detail_progress'),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: colors.accent,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        for (final idx in visibleIndices)
          _buildScheduleLine(
            context,
            items[idx],
            idx,
            isCurrent: items.length > 1 && idx == currentIndex,
          ),
        if (items.length > _collapsedLimit)
          Padding(
            padding: const EdgeInsets.only(top: 2, left: 27),
            child: InkWell(
              key: const Key('course_detail_schedules_toggle'),
              onTap: onToggleExpand,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  hasOverflow ? '展开全部 ${items.length} 个时段' : '收起时段',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: colors.accent,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildScheduleLine(
    BuildContext context,
    MergedCourseScheduleItem item,
    int index, {
    required bool isCurrent,
  }) {
    final colors = TimetableTheme.colorsOf(context);
    final dayText = '周${_weekdayCn[(item.day - 1).clamp(0, 6)]}';
    final rangeText = item.startNode == item.endNode
        ? '第 ${item.startNode} 节'
        : '第 ${item.startNode}–${item.endNode} 节';
    final weeksText = _mergedWeeksText(item);
    // 周数放在前面，星期与节次放在后面。
    final mainParts = [
      if (weeksText.isNotEmpty) weeksText,
      '$dayText $rangeText',
    ];
    final diffParts = <String>[
      if (item.location.isNotEmpty &&
          item.location != currentSlot.location.trim())
        item.location,
      if (item.teachers.isNotEmpty &&
          item.teachers.join('、') != currentSlot.teacher.trim())
        item.teachers.join('、'),
    ];
    return InkWell(
      key: Key('course_detail_slot_$index'),
      onTap: onTapSlot == null ? null : () => onTapSlot!(index),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(27, 4, 2, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    mainParts.join(' · '),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
                      color: isCurrent ? colors.titleText : colors.labelText,
                    ),
                  ),
                ),
                if (isCurrent)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1.5,
                    ),
                    decoration: BoxDecoration(
                      color: colors.accentSoft,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      '当前',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: colors.accent,
                      ),
                    ),
                  ),
              ],
            ),
            if (diffParts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  diffParts.join(' · '),
                  style: TextStyle(fontSize: 12, color: colors.hint),
                ),
              ),
          ],
        ),
      ),
    );
  }

  int _findCurrentIndex(List<MergedCourseScheduleItem> items) {
    for (var i = 0; i < items.length; i++) {
      if (items[i].containsSlot(currentCourse, currentSlot)) return i;
    }
    return 0;
  }

  List<int> _visibleIndices(int total, int currentIndex) {
    if (expanded || total <= _collapsedLimit) {
      return [for (var i = 0; i < total; i++) i];
    }
    final result = [for (var i = 0; i < _collapsedLimit; i++) i];
    if (!result.contains(currentIndex) && currentIndex < total) {
      result[_collapsedLimit - 1] = currentIndex;
      result.sort();
    }
    return result;
  }

  static String _mergedWeeksText(MergedCourseScheduleItem item) {
    final text = formatWeeks(item.weeks, maxSegments: null);
    if (text.isNotEmpty) return text;
    for (final m in item.members) {
      if (m.slot.weeksLabel.trim().isNotEmpty) return m.slot.weeksLabel.trim();
    }
    return '';
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
  const _DetailTag({
    super.key,
    required this.label,
    this.accent = false,
    this.onTap,
  });

  final String label;
  final bool accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final tag = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: accent ? colors.accentSoft : colors.pageBg,
        borderRadius: BorderRadius.circular(6),
        border: accent
            ? Border.all(color: colors.accent.withValues(alpha: 0.35))
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: accent ? FontWeight.w500 : FontWeight.w400,
              color: accent ? colors.accent : colors.labelText,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 2),
            Icon(
              Icons.chevron_right,
              size: 14,
              color: accent ? colors.accent : colors.labelText,
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return tag;
    return Semantics(
      button: true,
      label: '$label，查看修改与恢复',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
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
              fontWeight: FontWeight.w600,
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
    this.muted = false,
  });

  final IconData icon;
  final String text;
  final String secondaryText;
  final bool emphasized;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              icon,
              size: 18,
              color: muted ? colors.hint : colors.labelText,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text,
                  style: TextStyle(
                    fontSize: emphasized ? 15 : 14,
                    fontWeight: emphasized ? FontWeight.w600 : FontWeight.w400,
                    color: muted
                        ? colors.hint
                        : (emphasized ? colors.titleText : colors.labelText),
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
  }
}
