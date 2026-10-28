import 'package:flutter/material.dart';

import 'timetable_controller.dart';
import 'timetable_apply_weeks_sheet.dart';
import 'timetable_models.dart';
import 'timetable_theme.dart';
import 'timetable_week_format.dart';

const _weekdayCn = ['一', '二', '三', '四', '五', '六', '日'];

/// 删除教务课的二次确认文案（spec §13.15，逐字）。
const String kJwxtCourseDeleteMessage = '删除这门课？同步后也不会恢复，可在设置里一键恢复。';

/// 打开教务课编辑页（spec §13.15）。保存成功返回 true。
Future<bool?> showJwxtCourseEditPage(
  BuildContext context, {
  required TimetableController controller,
  required GridCell cell,
  bool autofocusNote = false,
}) {
  return Navigator.of(context).push<bool>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => JwxtCourseEditPage(
        controller: controller,
        cell: cell,
        autofocusNote: autofocusNote,
      ),
    ),
  );
}

/// 教务课编辑页：课名、老师、地点、备注可改；时间（星期/节次）与周次只读，
/// 下方灰字「拖动课程可调整时间」。保存调用 [TimetableController.editJwxtCourse]
/// （只传改过的字段，未改的传 null 保持原样）。改课名/老师不重新配色（由 controller 保证）。
class JwxtCourseEditPage extends StatefulWidget {
  const JwxtCourseEditPage({
    super.key,
    required this.controller,
    required this.cell,
    this.autofocusNote = false,
  });

  final TimetableController controller;

  /// 详情页里的这一格（已套用编辑/调课的生效课程与时段）。
  final GridCell cell;

  /// 从详情备注入口进入时自动聚焦备注。
  final bool autofocusNote;

  @override
  State<JwxtCourseEditPage> createState() => _JwxtCourseEditPageState();
}

class _JwxtCourseEditPageState extends State<JwxtCourseEditPage> {
  final _formKey = GlobalKey<FormState>();
  late final String _initName;
  late final String _initTeacher;
  late final String _initLocation;
  late final String _initNote;
  late final TextEditingController _name;
  late final TextEditingController _teacher;
  late final TextEditingController _location;
  late final TextEditingController _note;
  bool _saving = false;

  /// 应用周数：默认当前格所在周；空则保存时提示。
  late Set<int> _applyWeeks;

  @override
  void initState() {
    super.initState();
    final course = widget.cell.course;
    final slot = widget.cell.slot;
    // 有单日修改的格：预填这一天显示的值（格子已套用课程编辑 + 单日修改）。
    final edit = widget.cell.dateEdit != null
        ? null
        : widget.controller.courseEditOf(course.id);
    _initName = edit?.name ?? course.name;
    _initTeacher = edit?.teacher ?? slot.teacher;
    _initLocation = edit?.location ?? slot.location;
    _initNote = edit?.note ?? slot.note;
    _name = TextEditingController(text: _initName)..addListener(_changed);
    _teacher = TextEditingController(text: _initTeacher);
    _location = TextEditingController(text: _initLocation);
    _note = TextEditingController(text: _initNote);
    final d = widget.cell.date;
    if (d != null && widget.cell.activeThisWeek) {
      final w = widget.controller.weekOfDate(d);
      _applyWeeks = {if (w >= 1) w};
    } else {
      final total = widget.controller.totalWeeks;
      _applyWeeks = {for (var w = 1; w <= total; w++) w};
    }
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _name.dispose();
    _teacher.dispose();
    _location.dispose();
    _note.dispose();
    super.dispose();
  }

  String? _ifChanged(TextEditingController c, String initial) {
    final v = c.text.trim();
    return v == initial.trim() ? null : v;
  }

  Future<void> _pickApplyWeeks() async {
    final total = widget.controller.totalWeeks;
    final picked = await showApplyWeeksSheet(
      context,
      totalWeeks: total,
      initial: _applyWeeks,
    );
    if (picked == null || !mounted) return;
    setState(() => _applyWeeks = picked.toSet());
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final name = _ifChanged(_name, _initName);
    final teacher = _ifChanged(_teacher, _initTeacher);
    final location = _ifChanged(_location, _initLocation);
    final note = _ifChanged(_note, _initNote);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (name == null && teacher == null && location == null && note == null) {
      navigator.pop(false);
      return;
    }
    final date = widget.cell.date;
    final canScope = date != null && widget.cell.activeThisWeek;
    final total = widget.controller.totalWeeks;
    if (canScope && _applyWeeks.isEmpty) {
      messenger?.showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('请至少选择一周，或在「应用周数」里选「全选」'),
        ),
      );
      return;
    }
    setState(() => _saving = true);
    final c = widget.controller;
    final bool ok;
    if (!canScope || isAllSemesterWeeks(_applyWeeks, total)) {
      final id =
          c.baseOccurrenceOf(widget.cell)?.course.id ?? widget.cell.course.id;
      ok = await c.editJwxtCourse(
        id,
        name: name,
        teacher: teacher,
        location: location,
        note: note,
      );
      final de = widget.cell.dateEdit;
      if (ok && de != null) {
        await c.clearDateEditFields(
          de.id,
          name: name != null,
          teacher: teacher != null,
          location: location != null,
          note: note != null,
        );
      }
    } else {
      final sorted = _applyWeeks.toList()..sort();
      ok =
          await c.editOccurrenceWeeks(
            widget.cell,
            weeks: sorted,
            name: name,
            teacher: teacher,
            location: location,
            note: note,
          ) !=
          null;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    navigator.pop(ok);
  }

  String get _timeText {
    final slot = widget.cell.slot;
    final c = widget.controller;
    final wd = _weekdayCn[(slot.day - 1).clamp(0, 6)];
    final range = slot.startNode == slot.endNode
        ? '第 ${slot.startNode} 节'
        : '第 ${slot.startNode}–${slot.endNode} 节';
    final time = c.timeForSlot(
      widget.cell.course,
      slot,
      date: widget.cell.date,
    );
    final s = time.start;
    final e = time.end;
    final clock = (s == null || e == null) ? '' : ' $s–$e';
    return '周$wd $range$clock';
  }

  String get _weeksText {
    final slot = widget.cell.slot;
    final t = formatWeekBits(slot.weeks);
    return t.isNotEmpty ? t : slot.weeksLabel;
  }

  @override
  Widget build(BuildContext context) {
    final canSave = !_saving && _name.text.trim().isNotEmpty;
    return Scaffold(
      backgroundColor: TimetableTheme.colorsOf(context).pageBg,
      appBar: AppBar(
        title: const Text('编辑课程'),
        backgroundColor: TimetableTheme.colorsOf(context).surface,
        surfaceTintColor: Colors.transparent,
        actions: [
          TextButton(
            key: const Key('jwxt_edit_save'),
            onPressed: canSave ? _save : null,
            child: const Text('保存'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(TimetableTheme.pagePaddingH),
          children: [
            TextFormField(
              key: const Key('jwxt_edit_name'),
              controller: _name,
              decoration: const InputDecoration(labelText: '课程名称'),
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '请填写课程名称' : null,
            ),
            const SizedBox(height: 8),
            TextFormField(
              key: const Key('jwxt_edit_teacher'),
              controller: _teacher,
              decoration: const InputDecoration(labelText: '老师'),
            ),
            const SizedBox(height: 8),
            TextFormField(
              key: const Key('jwxt_edit_location'),
              controller: _location,
              decoration: const InputDecoration(labelText: '地点'),
            ),
            const SizedBox(height: 8),
            TextFormField(
              key: const Key('jwxt_edit_note'),
              autofocus: widget.autofocusNote,
              controller: _note,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '备注',
                hintText: '选填',
              ),
            ),
            if (widget.cell.date != null && widget.cell.activeThisWeek) ...[
              const SizedBox(height: 8),
              _ApplyWeeksRow(
                key: const Key('jwxt_edit_apply_weeks'),
                summary: applyWeeksSummary(
                  _applyWeeks,
                  widget.controller.totalWeeks,
                ),
                onTap: _saving ? null : _pickApplyWeeks,
              ),
            ],
            const SizedBox(height: 16),
            // 只读：不可点、不弹键盘或选择器（JE22）。
            _ReadOnlyRow(
              key: const Key('jwxt_edit_time'),
              icon: Icons.access_time,
              label: '时间',
              value: _timeText,
            ),
            if (_weeksText.isNotEmpty)
              _ReadOnlyRow(
                key: const Key('jwxt_edit_weeks'),
                icon: Icons.calendar_today_outlined,
                label: '周次',
                value: _weeksText,
              ),
            Padding(
              padding: const EdgeInsets.only(left: 36, top: 2),
              child: Text(
                '拖动课程可调整时间',
                key: const Key('jwxt_edit_time_hint'),
                style: TimetableTheme.captionStyle(
                  color: TimetableTheme.colorsOf(context).hint,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ApplyWeeksRow extends StatelessWidget {
  const _ApplyWeeksRow({super.key, required this.summary, this.onTap});

  final String summary;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          children: [
            Icon(Icons.date_range_outlined, size: 20, color: colors.hint),
            const SizedBox(width: 16),
            Text(
              '应用周数',
              style: TimetableTheme.bodyStyle(color: colors.labelText),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                summary,
                key: const Key('jwxt_edit_apply_weeks_summary'),
                textAlign: TextAlign.end,
                style: TimetableTheme.bodyStyle(color: colors.hint),
              ),
            ),
            Icon(Icons.chevron_right, color: colors.hint),
          ],
        ),
      ),
    );
  }
}

class _ReadOnlyRow extends StatelessWidget {
  const _ReadOnlyRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        children: [
          Icon(icon, size: 20, color: TimetableTheme.colorsOf(context).hint),
          const SizedBox(width: 16),
          Text(
            label,
            style: TimetableTheme.bodyStyle(
              color: TimetableTheme.colorsOf(context).hint,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: TimetableTheme.bodyStyle(
                color: TimetableTheme.colorsOf(context).hint,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
