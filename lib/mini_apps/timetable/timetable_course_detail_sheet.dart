import 'package:flutter/material.dart';

import 'timetable_color_picker.dart';
import 'timetable_delete_scope_sheet.dart';
import 'timetable_course_edit_page.dart';
import 'timetable_controller.dart';
import 'timetable_models.dart';
import 'timetable_overrides.dart';
import 'timetable_theme.dart';
import 'timetable_course_color.dart';
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
    builder: (context) => CourseDetailSheet(cell: cell, controller: controller),
  );
}

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
  @override
  Widget build(BuildContext context) {
    final course = widget.cell.course;
    // 教务课不走手动课表单：底部改为 [JwxtCourseDetailActions]（§13.15 编辑 / 删除 /
    // 已修改 + 恢复原课程，只写本地覆盖层）。
    final readOnly = course.source == CourseSource.jwxt;
    final slot = widget.cell.slot;
    // 4dp 色条在面色上用该色号文字色（A 柔和底色太浅，白底上看不出）；深色下取
    // 深色格的浅字色（item 12），在深色面上才看得见。
    final color = coursePairFor(
      widget.controller,
      course,
      dark: TimetableTheme.colorsOf(context).isDark,
    ).fg;
    // 调过的教务课：「已调课：原 周X 第 a–b 节」+「恢复原位置」（spec §13.2）。
    final slotIndex = _slotIndexOf(course, slot);
    final overrideInfo = slotIndex < 0
        ? null
        : widget.controller.overrideInfoFor(course, slotIndex);
    final start = widget.controller.periodStart(slot.startNode) ?? '';
    final end = widget.controller.periodEnd(slot.endNode) ?? '';
    final timeText = slot.startNode == slot.endNode
        ? '第 ${slot.startNode} 节 $start–$end'
        : '第 ${slot.startNode}–${slot.endNode} 节 $start–$end';

    return Container(
      decoration: BoxDecoration(
        color: TimetableTheme.colorsOf(context).surface,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(TimetableTheme.sheetTopRadius),
        ),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.paddingOf(context).bottom + 12,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          const SheetDragHandle(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Container(
                  width: 4,
                  height: 22,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    course.classId.isEmpty
                        ? course.name
                        : '${course.name}[${course.classId}]',
                    style: TimetableTheme.titleStyle(
                      color: TimetableTheme.colorsOf(context).titleText,
                    ),
                  ),
                ),
                if (course.isManual) ...[
                  const _ManualTag(),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          // 周次统一由位串（教务 SKZC / 手动选择）格式化，不展示 ZCMC 原文；
          // 无位串时（未排课）才退回原始描述；都没有则隐藏该行。
          if (_weeksText(slot).isNotEmpty)
            _InfoRow(
              icon: Icons.calendar_today_outlined,
              text: _weeksText(slot),
            ),
          _InfoRow(icon: Icons.access_time, text: timeText),
          if (overrideInfo != null)
            Padding(
              key: const Key('course_detail_override'),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Icon(
                    Icons.swap_horiz,
                    size: 20,
                    color: TimetableTheme.colorsOf(context).hint,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _overrideText(overrideInfo),
                      style: TimetableTheme.bodyStyle(
                        color: TimetableTheme.colorsOf(context).labelText,
                      ),
                    ),
                  ),
                  TextButton(
                    key: const Key('course_detail_restore'),
                    onPressed: _restoring
                        ? null
                        : () => _restore(course, slotIndex),
                    style: TextButton.styleFrom(
                      foregroundColor: TimetableTheme.colorsOf(context).accent,
                    ),
                    child: const Text('恢复原位置'),
                  ),
                ],
              ),
            ),
          if (widget.cell.dateEdit != null)
            Padding(
              key: const Key('course_detail_date_edit'),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Icon(
                    Icons.edit_calendar_outlined,
                    size: 20,
                    color: TimetableTheme.colorsOf(context).hint,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.cell.dateEdit?.isWeeksScoped == true
                          ? '已按周修改'
                          : '这一天已单独修改',
                      style: TimetableTheme.bodyStyle(
                        color: TimetableTheme.colorsOf(context).labelText,
                      ),
                    ),
                  ),
                  TextButton(
                    key: const Key('course_detail_restore_day'),
                    onPressed: _restoring ? null : _restoreDay,
                    style: TextButton.styleFrom(
                      foregroundColor: TimetableTheme.colorsOf(context).accent,
                    ),
                    child: Text(
                      widget.cell.dateEdit?.isWeeksScoped == true
                          ? '恢复'
                          : '恢复这一天',
                    ),
                  ),
                ],
              ),
            ),
          _InfoRow(
            icon: Icons.place_outlined,
            text: slot.location.isEmpty ? '地点未填写' : slot.location,
          ),
          _InfoRow(
            icon: Icons.person_outline,
            text: slot.teacher.isEmpty ? '教师未填写' : slot.teacher,
          ),
          // 手动课总显示备注行；教务课只在填过备注（本地编辑）时显示。
          if (!readOnly || slot.note.isNotEmpty)
            _InfoRow(
              icon: Icons.notes_outlined,
              text: slot.note.isEmpty ? '备注（选填）' : slot.note,
              muted: slot.note.isEmpty,
            ),
          // item 9：课程颜色（12 预设 + 自定义 HSV + 恢复默认）。
          CourseColorRow(controller: widget.controller, course: course),
          if (course.credit != null)
            _InfoRow(
              icon: Icons.school_outlined,
              text: '${_formatCredit(course.credit!)} 学分',
            ),
          if (readOnly)
            JwxtCourseDetailActions(
              controller: widget.controller,
              cell: widget.cell,
            ),
          if (!readOnly)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: FilledButton(
                        onPressed: () => _edit(course),
                        style: FilledButton.styleFrom(
                          backgroundColor: TimetableTheme.colorsOf(context)
                              .chipBg,
                          foregroundColor: TimetableTheme.colorsOf(context)
                              .titleText,
                          elevation: 0,
                          shape: const StadiumBorder(),
                        ),
                        child: const Text('编辑'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 44,
                    child: OutlinedButton.icon(
                      key: const Key('course_detail_delete'),
                      onPressed: () => _delete(course),
                      icon: const Icon(Icons.delete_outline, size: 20),
                      label: const Text('删除'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: TimetableTheme.colorsOf(context)
                            .danger,
                        shape: const StadiumBorder(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 第 1 条：撤销这一格的单日修改。
  Future<void> _restoreDay() async {
    final id = widget.cell.dateEdit?.id;
    if (id == null) return;
    setState(() => _restoring = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await widget.controller.restoreDateEdit(id);
    if (!mounted) return;
    setState(() => _restoring = false);
    if (navigator.canPop()) navigator.pop();
    messenger?.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(ok ? '已恢复这一天' : '恢复失败'),
      ),
    );
  }

  bool _restoring = false;

  static const _weekdayCn = ['一', '二', '三', '四', '五', '六', '日'];

  static String _overrideText(SlotOverrideInfo info) {
    final wd = _weekdayCn[(info.originalDay - 1).clamp(0, 6)];
    final range = info.originalStart == info.originalEnd
        ? '第 ${info.originalStart} 节'
        : '第 ${info.originalStart}–${info.originalEnd} 节';
    return '已调课：原 周$wd $range';
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
    setState(() => _restoring = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await widget.controller.restoreOverride(course, slotIndex);
    if (!mounted) return;
    setState(() => _restoring = false);
    if (navigator.canPop()) navigator.pop();
    messenger?.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(ok ? '已恢复原位置' : '恢复失败'),
      ),
    );
  }

  Future<void> _edit(Course course) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final saved = await showManualCourseForm(
      context,
      controller: widget.controller,
      initial: course,
      initialSlot: widget.cell.slot,
      cell: widget.cell,
    );
    if (saved == null || !mounted) return;
    if (navigator.canPop()) navigator.pop();
    messenger?.showSnackBar(
      const SnackBar(behavior: SnackBarBehavior.floating, content: Text('已保存')),
    );
  }

  Future<void> _delete(Course course) async {
    final cell = widget.cell;
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
            SnackBar(
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
            SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text(rec == null ? '删除失败' : '已删除同星期匹配的课'),
            ),
          );
          return;
        case DeleteScope.wholeCourse:
          break;
      }
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除课程'),
        content: Text('确定删除「${course.name}」吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('course_delete_confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.controller.deleteManualCourse(course.id);
    if (!mounted) return;
    if (navigator.canPop()) navigator.pop();
    messenger?.showSnackBar(
      const SnackBar(behavior: SnackBarBehavior.floating, content: Text('已删除')),
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

class _ManualTag extends StatelessWidget {
  const _ManualTag();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.transparent,
        border: Border.all(color: TimetableTheme.colorsOf(context).hint),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '手动添加',
        style: TextStyle(
          fontSize: 11,
          color: TimetableTheme.colorsOf(context).hint,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.text, this.muted = false});

  final IconData icon;
  final String text;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Icon(icon, size: 20, color: TimetableTheme.colorsOf(context).hint),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: TimetableTheme.bodyStyle(
                  color: muted
                      ? TimetableTheme.colorsOf(context).hint
                      : TimetableTheme.colorsOf(context).labelText,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
