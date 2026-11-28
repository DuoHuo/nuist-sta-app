import 'timetable_persistence_feedback.dart';

import 'package:flutter/material.dart';

import '../../core/app_snack_bar.dart';
import '../../core/ui/app_bottom_sheet.dart';
import '../../core/ui/miuix_dialog.dart';
import 'timetable_api.dart';
import 'timetable_controller.dart';
import 'timetable_course_detail_sheet.dart';
import 'timetable_entry_add_pages.dart';
import 'timetable_entry_edit_page.dart';
import 'timetable_entry_form_widgets.dart';
import 'timetable_schedule_event.dart';
import 'timetable_schedule_event_layout.dart';
import 'timetable_theme.dart';

/// 「+」原地弹出三选一：课程 / 考试 / 日程，分别进入对应独立添加页。
Future<void> showAddEntrySheet(
  BuildContext anchorContext, {
  required TimetableController controller,
}) async {
  final choice = await showMiuixOptionMenu<String>(
    anchorContext,
    anchorBounds: miuixAnchorRect(anchorContext),
    menuKey: const Key('add_entry_sheet'),
    items: const [
      MiuixOptionItem(
        key: Key('add_entry_course'),
        value: 'course',
        label: '课程',
      ),
      MiuixOptionItem(key: Key('add_entry_exam'), value: 'exam', label: '考试'),
      MiuixOptionItem(key: Key('add_entry_other'), value: 'other', label: '日程'),
    ],
  );
  if (choice == null || !anchorContext.mounted) return;
  if (choice == 'course') {
    await showAddCoursePage(anchorContext, controller: controller);
    return;
  }
  // 默认日期：看本周时为今天；看别的周时为该周第一天。
  final DateTime date = controller.isViewingCurrentWeek
      ? TimetableApi.shanghaiToday()
      : controller.dateOfColumn(
          controller.viewingWeek,
          controller.visibleDays(controller.viewingWeek).first,
        );
  if (choice == 'exam') {
    await showAddExamPage(
      anchorContext,
      controller: controller,
      initialDate: date,
    );
    return;
  }
  await showAddSchedulePage(
    anchorContext,
    controller: controller,
    initialDate: date,
  );
}

/// 考试/日程详情底部弹层：与课程详情弹层统一视觉层次，不接入预测性返回手势。
Future<void> showScheduleEventDetailSheet(
  BuildContext context, {
  required ScheduleEvent event,
  required TimetableController controller,
}) {
  // 编辑页键盘升降会更新底部路由约束，复用底层详情而非每帧重新构建。
  final detail = ScheduleEventDetailSheet(
    eventId: event.id,
    controller: controller,
  );
  return showAppModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    enablePredictiveBackScale: false,
    backgroundColor: Colors.transparent,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (_) => detail,
  );
}

class ScheduleEventDetailSheet extends StatefulWidget {
  const ScheduleEventDetailSheet({
    super.key,
    required this.eventId,
    required this.controller,
  });

  final String eventId;
  final TimetableController controller;

  @override
  State<ScheduleEventDetailSheet> createState() =>
      _ScheduleEventDetailSheetState();
}

class _ScheduleEventDetailSheetState extends State<ScheduleEventDetailSheet> {
  bool _busy = false;

  /// 已在关闭（删除后）：避免重复 pop。
  bool _closing = false;

  ScheduleEvent? get _event {
    for (final e in widget.controller.scheduleEvents) {
      if (e.id == widget.eventId) return e;
    }
    return null;
  }

  Future<void> _edit(ScheduleEvent e) async {
    await showScheduleEditPage(
      context,
      controller: widget.controller,
      initial: e,
    );
  }

  Future<void> _delete(ScheduleEvent e) async {
    await withTimetablePersistenceFeedback(context, () => _deleteUnchecked(e));
    if (mounted) _closing = false;
  }

  Future<void> _deleteUnchecked(ScheduleEvent e) async {
    if (!await confirmDeleteScheduleEvent(context, e)) return;
    if (!mounted) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    _closing = true;
    await widget.controller.deleteScheduleEvent(e.id);
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

  Future<void> _restore(String key) async {
    await withTimetablePersistenceFeedback(
      context,
      () => _restoreUnchecked(key),
    );
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _restoreUnchecked(String key) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await widget.controller.restoreJwxtExam(key);
    if (!mounted) return;
    setState(() => _busy = false);
    messenger?.showSnackBar(
      AppSnackBar(
        tone: ok ? AppSnackBarTone.success : AppSnackBarTone.error,
        behavior: SnackBarBehavior.floating,
        content: Text(ok ? '已恢复原考试' : '恢复失败'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final e = _event;
        if (e == null) {
          // 已删除（或教务考试被删除覆盖）：关闭弹层。
          // 只在本弹层位于栈顶时关闭（如在编辑页里删除，回到这里后关）；
          // 本弹层自己的「删除」会自行 pop，不重复。
          if (!_closing) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || _closing) return;
              if (ModalRoute.of(context)?.isCurrent ?? false) {
                _closing = true;
                Navigator.of(context).pop();
              }
            });
          }
          return const SizedBox.shrink();
        }
        final c = widget.controller;
        final colors = TimetableTheme.colorsOf(context);
        final accent = scheduleAccentOnWhite(c, e);
        // 原始 examKey（不能用展示事件的 jwxtKey：编辑后日期/时间可能已变）。
        final examKey = e.isFromJwxt ? c.jwxtExamKeyOf(e.id) : null;
        final overridden =
            examKey != null && c.isJwxtOverridden(examKey: examKey);
        final week = c.actualWeek(e.date);
        final dateLine = week != null && week >= 1 && week <= c.maxWeeks
            ? '${scheduleDateText(e.date)} · 第 $week 周'
            : scheduleDateText(e.date);
        final hasNote = e.note.trim().isNotEmpty;

        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.86,
          ),
          child: Material(
            color: colors.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            clipBehavior: Clip.antiAlias,
            child: SafeArea(
              top: false,
              maintainBottomViewPadding: true,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
                child: Column(
                  key: const Key('schedule_detail_sheet'),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(child: SheetDragHandle()),
                    const SizedBox(height: 14),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          width: 5,
                          height: 24,
                          decoration: BoxDecoration(
                            color: accent,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            e.title,
                            style: TimetableTheme.titleStyle(
                              color: colors.titleText,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              key: const Key('schedule_detail_edit'),
                              tooltip: e.isExam ? '编辑考试' : '编辑日程',
                              padding: const EdgeInsets.all(6),
                              onPressed: _busy ? null : () => _edit(e),
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
                            IconButton(
                              key: const Key('schedule_detail_delete'),
                              tooltip: e.isExam ? '删除考试' : '删除日程',
                              padding: const EdgeInsets.all(6),
                              onPressed: _busy ? null : () => _delete(e),
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
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SchedulePill(text: schedulePillLabel(e), color: accent),
                        if (!e.isFromJwxt) const _ScheduleTag(label: '手动添加'),
                        if (e.isExam && (e.courseCode ?? '').isNotEmpty)
                          _ScheduleTag(label: '课程号 ${e.courseCode}'),
                        if (overridden)
                          _ScheduleTag(
                            key: const Key('schedule_detail_modified'),
                            label: '已修改',
                            accent: true,
                          ),
                      ],
                    ),
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
                          _ScheduleInfoRow(
                            icon: Icons.access_time_rounded,
                            text: scheduleTimeText(e),
                            secondaryText: dateLine,
                            emphasized: true,
                          ),
                          Divider(
                            height: 1,
                            color: colors.divider.withValues(alpha: 0.6),
                          ),
                          _ScheduleInfoRow(
                            icon: Icons.place_outlined,
                            text: e.location.isEmpty ? '地点未填写' : e.location,
                            muted: e.location.isEmpty,
                          ),
                        ],
                      ),
                    ),
                    if (overridden) ...[
                      const SizedBox(height: 10),
                      Container(
                        decoration: BoxDecoration(
                          color: colors.pageBg,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
                        child: Row(
                          children: [
                            Icon(
                              Icons.history_rounded,
                              size: 18,
                              color: colors.accent,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '已在本地修改此教务考试',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: colors.labelText,
                                ),
                              ),
                            ),
                            TextButton(
                              key: const Key('schedule_detail_restore'),
                              onPressed: _busy ? null : () => _restore(examKey),
                              style: TextButton.styleFrom(
                                foregroundColor: colors.accent,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                minimumSize: const Size(0, 34),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: const Text(
                                '恢复原考试',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Material(
                      color: colors.pageBg,
                      borderRadius: BorderRadius.circular(16),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: _busy ? null : () => _edit(e),
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
                                  color: hasNote
                                      ? colors.labelText
                                      : colors.hint,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  hasNote ? e.note.trim() : '添加备注…',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: hasNote
                                        ? colors.titleText
                                        : colors.hint,
                                  ),
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
      },
    );
  }
}

class _ScheduleTag extends StatelessWidget {
  const _ScheduleTag({super.key, required this.label, this.accent = false});

  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: accent ? colors.accentSoft : colors.pageBg,
        borderRadius: BorderRadius.circular(6),
        border: accent
            ? Border.all(color: colors.accent.withValues(alpha: 0.35))
            : null,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: accent ? FontWeight.w500 : FontWeight.w400,
          color: accent ? colors.accent : colors.labelText,
        ),
      ),
    );
  }
}

class _ScheduleInfoRow extends StatelessWidget {
  const _ScheduleInfoRow({
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
