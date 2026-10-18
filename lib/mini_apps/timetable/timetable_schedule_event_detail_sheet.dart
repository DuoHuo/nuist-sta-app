import 'package:flutter/material.dart';

import 'timetable_schedule_event.dart';
import 'timetable_schedule_event_edit_page.dart';
import 'timetable_schedule_event_layout.dart';
import 'timetable_api.dart';
import 'timetable_controller.dart';
import 'timetable_theme.dart';
import 'timetable_manual_course_form.dart';

/// 「+」底部面板三选一（spec §14.1）：课程（现有每周重复的手动课）/ 考试 / 其他。
Future<void> showAddEntrySheet(
  BuildContext context, {
  required TimetableController controller,
}) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: TimetableTheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(TimetableTheme.sheetTopRadius),
      ),
    ),
    builder: (ctx) => SafeArea(
      child: Column(
        key: const Key('add_entry_sheet'),
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: TimetableTheme.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            key: const Key('add_entry_course'),
            leading: const Icon(Icons.repeat),
            title: const Text('课程'),
            subtitle: const Text('每周重复'),
            onTap: () => Navigator.pop(ctx, 'course'),
          ),
          ListTile(
            key: const Key('add_entry_exam'),
            leading: const Icon(Icons.edit_note),
            title: const Text('考试'),
            onTap: () => Navigator.pop(ctx, 'exam'),
          ),
          ListTile(
            key: const Key('add_entry_other'),
            leading: const Icon(Icons.event_outlined),
            title: const Text('其他'),
            onTap: () => Navigator.pop(ctx, 'other'),
          ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  if (choice == 'course') {
    await showManualCourseForm(context, controller: controller);
    return;
  }
  // 默认日期：看本周时为今天；看别的周时为该周第一天。
  final DateTime date = controller.isViewingCurrentWeek
      ? TimetableApi.shanghaiToday()
      : controller.dateOfColumn(
          controller.viewingWeek,
          controller.visibleDays(controller.viewingWeek).first,
        );
  await showScheduleEventEditPage(
    context,
    controller: controller,
    kind: choice == 'exam' ? ScheduleKind.exam : ScheduleKind.other,
    initialDate: date,
  );
}

/// 日程详情弹层（spec §14.2）：日期、时间、地点、备注；底部「编辑」「删除」。
/// 改过的教务考试显示「已修改」+「恢复原考试」（§14.3）。
Future<void> showScheduleEventDetailSheet(
  BuildContext context, {
  required ScheduleEvent event,
  required TimetableController controller,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) =>
        ScheduleEventDetailSheet(eventId: event.id, controller: controller),
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
    await showScheduleEventEditPage(
      context,
      controller: widget.controller,
      initial: e,
    );
  }

  Future<void> _delete(ScheduleEvent e) async {
    if (!await confirmDeleteScheduleEvent(context, e)) return;
    if (!mounted) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    _closing = true;
    await widget.controller.deleteScheduleEvent(e.id);
    if (!mounted) return;
    if (navigator.canPop()) navigator.pop();
    messenger?.showSnackBar(
      const SnackBar(behavior: SnackBarBehavior.floating, content: Text('已删除')),
    );
  }

  Future<void> _restore(String key) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await widget.controller.restoreJwxtExam(key);
    if (!mounted) return;
    setState(() => _busy = false);
    messenger?.showSnackBar(
      SnackBar(
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
        final accent = scheduleAccentOnWhite(c, e);
        // 原始 examKey（不能用展示事件的 jwxtKey：编辑后日期/时间可能已变）。
        final examKey = e.isFromJwxt ? c.jwxtExamKeyOf(e.id) : null;
        final overridden =
            examKey != null && c.isJwxtOverridden(examKey: examKey);
        return Container(
          decoration: const BoxDecoration(
            color: TimetableTheme.surface,
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(TimetableTheme.sheetTopRadius),
            ),
          ),
          padding: EdgeInsets.only(
            bottom: MediaQuery.paddingOf(context).bottom + 12,
          ),
          child: Column(
            key: const Key('schedule_detail_sheet'),
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: TimetableTheme.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    Container(
                      width: 4,
                      height: 22,
                      decoration: BoxDecoration(
                        color: accent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(e.title, style: TimetableTheme.titleStyle()),
                    ),
                    SchedulePill(text: schedulePillLabel(e), color: accent),
                  ],
                ),
              ),
              _Row(
                icon: Icons.calendar_today_outlined,
                text: scheduleDateText(e.date),
              ),
              _Row(icon: Icons.access_time, text: scheduleTimeText(e)),
              _Row(
                icon: Icons.place_outlined,
                text: e.location.isEmpty ? '地点未填写' : e.location,
                muted: e.location.isEmpty,
              ),
              _Row(
                icon: Icons.notes_outlined,
                text: e.note.isEmpty ? '无备注' : e.note,
                muted: e.note.isEmpty,
              ),
              if (e.isExam && (e.courseCode ?? '').isNotEmpty)
                _Row(icon: Icons.tag, text: '课程号 ${e.courseCode}'),
              if (overridden)
                Padding(
                  key: const Key('schedule_detail_modified'),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.edit_outlined,
                        size: 20,
                        color: TimetableTheme.hint,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text('已修改', style: TimetableTheme.bodyStyle()),
                      ),
                      TextButton(
                        key: const Key('schedule_detail_restore'),
                        onPressed: _busy ? null : () => _restore(examKey),
                        style: TextButton.styleFrom(
                          foregroundColor: TimetableTheme.accent,
                        ),
                        child: const Text('恢复原考试'),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 44,
                        child: FilledButton(
                          key: const Key('schedule_detail_edit'),
                          onPressed: _busy ? null : () => _edit(e),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFF0F1F3),
                            foregroundColor: TimetableTheme.titleText,
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
                        key: const Key('schedule_detail_delete'),
                        onPressed: _busy ? null : () => _delete(e),
                        icon: const Icon(Icons.delete_outline, size: 20),
                        label: const Text('删除'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red.shade600,
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
      },
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.text, this.muted = false});

  final IconData icon;
  final String text;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            Icon(icon, size: 20, color: TimetableTheme.hint),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: TimetableTheme.bodyStyle(
                  color: muted ? TimetableTheme.hint : TimetableTheme.labelText,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
