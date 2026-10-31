import 'timetable_persistence_feedback.dart';

import 'package:flutter/material.dart';

import 'timetable_schedule_event.dart';
import 'timetable_schedule_event_layout.dart';
import 'timetable_api.dart';
import 'timetable_controller.dart';
import 'timetable_theme.dart';

/// 打开考试 / 其他日程表单（spec §14.1）。[initial] 非空为编辑模式（含教务考试：
/// 保存走 [TimetableController.updateScheduleEvent]，由 controller 写本地覆盖层）。
/// 返回保存后的日程；取消或删除返回 null。
Future<ScheduleEvent?> showScheduleEventEditPage(
  BuildContext context, {
  required TimetableController controller,
  ScheduleKind kind = ScheduleKind.other,
  ScheduleEvent? initial,
  DateTime? initialDate,
}) {
  return Navigator.of(context).push<ScheduleEvent>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ScheduleEventEditPage(
        controller: controller,
        kind: initial?.kind ?? kind,
        initial: initial,
        initialDate: initialDate,
      ),
    ),
  );
}

/// 删除日程的二次确认（表单页与详情弹层共用）。返回 true = 确认删除。
Future<bool> confirmDeleteScheduleEvent(
  BuildContext context,
  ScheduleEvent event,
) async {
  final String text;
  if (event.isFromJwxt) {
    text = '删除这场考试？同步后也不会恢复，可在设置里一键恢复。';
  } else if (event.isExam) {
    text = '删除这场考试？';
  } else {
    text = '删除这个日程？';
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: Text(text, key: const Key('schedule_delete_message')),
      actions: [
        TextButton(
          key: const Key('schedule_delete_cancel'),
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        TextButton(
          key: const Key('schedule_delete_confirm'),
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(
            foregroundColor: TimetableTheme.colorsOf(context).danger,
          ),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  return ok == true;
}

class ScheduleEventEditPage extends StatefulWidget {
  const ScheduleEventEditPage({
    super.key,
    required this.controller,
    this.kind = ScheduleKind.other,
    this.initial,
    this.initialDate,
  });

  final TimetableController controller;
  final ScheduleKind kind;
  final ScheduleEvent? initial;
  final DateTime? initialDate;

  @override
  State<ScheduleEventEditPage> createState() => _ScheduleEventEditPageState();
}

class _ScheduleEventEditPageState extends State<ScheduleEventEditPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _location;
  late final TextEditingController _note;
  late final TextEditingController _courseCode;
  late ScheduleKind _kind;
  late DateTime _date;
  late TimeOfDayMinutes _start;
  late TimeOfDayMinutes _end;
  bool _saving = false;
  bool _triedSave = false;

  bool get _isEdit => widget.initial != null;

  /// 教务考试：类型固定为考试，课程号只读（覆盖层不记课程号）。
  bool get _isJwxt => widget.initial?.isFromJwxt ?? false;

  bool get _timeValid => _end.compareTo(_start) > 0;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _kind = i?.kind ?? widget.kind;
    _title = TextEditingController(text: i?.title ?? '')
      ..addListener(_onTitleChanged);
    _location = TextEditingController(text: i?.location ?? '');
    _note = TextEditingController(text: i?.note ?? '');
    _courseCode = TextEditingController(text: i?.courseCode ?? '');
    final c = widget.controller;
    final d = i?.date ?? widget.initialDate ?? TimetableApi.shanghaiToday();
    _date = DateTime(d.year, d.month, d.day);
    _start =
        i?.start ??
        TimeOfDayMinutes.tryParse(c.periodStart(1)) ??
        const TimeOfDayMinutes(8, 0);
    _end =
        i?.end ??
        TimeOfDayMinutes.tryParse(c.periodEnd(2)) ??
        const TimeOfDayMinutes(9, 40);
    if (i == null && _end.compareTo(_start) <= 0) {
      final m = (_start.totalMinutes + 60).clamp(0, 23 * 60 + 59);
      _end = TimeOfDayMinutes(m ~/ 60, m % 60);
    }
  }

  void _onTitleChanged() => setState(() {});

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    _note.dispose();
    _courseCode.dispose();
    super.dispose();
  }

  String get _pageTitle {
    final noun = _kind == ScheduleKind.exam ? '考试' : '日程';
    return _isEdit ? '编辑$noun' : '添加$noun';
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12, 31),
      helpText: '选择日期',
      cancelText: '取消',
      confirmText: '确定',
    );
    if (picked == null || !mounted) return;
    setState(() => _date = DateTime(picked.year, picked.month, picked.day));
  }

  Future<void> _pickTime({required bool start}) async {
    final cur = start ? _start : _end;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: cur.hour, minute: cur.minute),
      helpText: start ? '开始时间' : '结束时间',
      cancelText: '取消',
      confirmText: '确定',
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      final v = TimeOfDayMinutes(picked.hour, picked.minute);
      if (start) {
        _start = v;
      } else {
        _end = v;
      }
    });
  }

  Future<void> _save() async {
    try {
      await withTimetablePersistenceFeedback(context, () => _saveUnchecked());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveUnchecked() async {
    setState(() => _triedSave = true);
    final formOk = _formKey.currentState?.validate() ?? false;
    if (!formOk || !_timeValid || _title.text.trim().isEmpty) return;
    setState(() => _saving = true);
    final i = widget.initial;
    final code = _courseCode.text.trim();
    final event = ScheduleEvent(
      id: i?.id ?? '',
      kind: _isJwxt ? ScheduleKind.exam : _kind,
      source: i?.source ?? ScheduleSource.manual,
      title: _title.text.trim(),
      date: _date,
      start: _start,
      end: _end,
      location: _location.text.trim(),
      note: _note.text.trim(),
      courseCode: _isJwxt
          ? i!.courseCode
          : (_kind == ScheduleKind.exam && code.isNotEmpty ? code : null),
    );
    final navigator = Navigator.of(context);
    ScheduleEvent? saved;
    if (i == null) {
      saved = await widget.controller.addScheduleEvent(event);
    } else if (await widget.controller.updateScheduleEvent(event)) {
      saved = event;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    navigator.pop(saved);
  }

  Future<void> _delete() async {
    await withTimetablePersistenceFeedback(context, () => _deleteUnchecked());
  }

  Future<void> _deleteUnchecked() async {
    final i = widget.initial;
    if (i == null) return;
    if (!await confirmDeleteScheduleEvent(context, i)) return;
    if (!mounted) return;
    final navigator = Navigator.of(context);
    await widget.controller.deleteScheduleEvent(i.id);
    if (!mounted) return;
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final canSave = !_saving && _title.text.trim().isNotEmpty;
    return Scaffold(
      backgroundColor: TimetableTheme.colorsOf(context).pageBg,
      appBar: AppBar(
        title: Text(_pageTitle),
        backgroundColor: TimetableTheme.colorsOf(context).surface,
        surfaceTintColor: Colors.transparent,
        actions: [
          TextButton(
            key: const Key('schedule_form_save'),
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
            if (!_isJwxt) ...[
              SegmentedButton<ScheduleKind>(
                key: const Key('schedule_form_kind'),
                segments: const [
                  ButtonSegment(
                    value: ScheduleKind.exam,
                    label: Text('考试', key: Key('schedule_form_kind_exam')),
                  ),
                  ButtonSegment(
                    value: ScheduleKind.other,
                    label: Text('其他', key: Key('schedule_form_kind_other')),
                  ),
                ],
                selected: {_kind},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _kind = s.first),
              ),
              const SizedBox(height: 12),
            ],
            TextFormField(
              key: const Key('schedule_form_title'),
              controller: _title,
              decoration: InputDecoration(
                labelText: _kind == ScheduleKind.exam ? '考试名称' : '名称',
                hintText: '必填',
              ),
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '请填写名称' : null,
            ),
            const SizedBox(height: 8),
            _PickerRow(
              key: const Key('schedule_form_date'),
              icon: Icons.calendar_today_outlined,
              label: '日期',
              value: scheduleDateText(_date),
              onTap: _pickDate,
            ),
            // EV-1：日期不在本学期周次内 → 灰色提示，仍可保存（首页照常显示）。
            if (isOutsideTermWeeks(widget.controller, _date))
              Padding(
                padding: const EdgeInsets.fromLTRB(40, 0, 0, 8),
                child: Text(
                  kOutsideTermHint,
                  key: const Key('schedule_form_outside_term_hint'),
                  style: TimetableTheme.captionStyle(
                    color: TimetableTheme.colorsOf(context).hint,
                  ),
                ),
              ),
            _PickerRow(
              key: const Key('schedule_form_start'),
              icon: Icons.access_time,
              label: '开始时间',
              value: _start.format(),
              onTap: () => _pickTime(start: true),
            ),
            _PickerRow(
              key: const Key('schedule_form_end'),
              icon: Icons.access_time_filled_outlined,
              label: '结束时间',
              value: _end.format(),
              onTap: () => _pickTime(start: false),
            ),
            if (!_timeValid)
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 4),
                child: Text(
                  '结束时间需晚于开始时间',
                  key: const Key('schedule_form_time_error'),
                  style: TimetableTheme.captionStyle(
                    color: _triedSave
                        ? TimetableTheme.colorsOf(context).danger
                        : TimetableTheme.colorsOf(context).warning,
                  ),
                ),
              ),
            const SizedBox(height: 8),
            TextFormField(
              key: const Key('schedule_form_location'),
              controller: _location,
              decoration: const InputDecoration(
                labelText: '地点',
                hintText: '选填',
              ),
            ),
            const SizedBox(height: 8),
            TextFormField(
              key: const Key('schedule_form_note'),
              controller: _note,
              maxLines: 3,
              minLines: 1,
              decoration: const InputDecoration(
                labelText: '备注',
                hintText: '选填',
              ),
            ),
            if (_kind == ScheduleKind.exam || _isJwxt) ...[
              const SizedBox(height: 8),
              TextFormField(
                key: const Key('schedule_form_course_code'),
                controller: _courseCode,
                readOnly: _isJwxt,
                enabled: !_isJwxt,
                decoration: InputDecoration(
                  labelText: '课程号',
                  hintText: _isJwxt ? null : '选填',
                  helperText: _isJwxt ? '来自教务，不可修改' : null,
                ),
              ),
            ],
            if (_isEdit) ...[
              const SizedBox(height: 24),
              SizedBox(
                height: 44,
                child: OutlinedButton.icon(
                  key: const Key('schedule_form_delete'),
                  onPressed: _saving ? null : _delete,
                  icon: const Icon(Icons.delete_outline, size: 20),
                  label: const Text('删除'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: TimetableTheme.colorsOf(context).danger,
                    shape: const StadiumBorder(),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PickerRow extends StatelessWidget {
  const _PickerRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(
        icon,
        size: 20,
        color: TimetableTheme.colorsOf(context).hint,
      ),
      title: Text(
        label,
        style: TimetableTheme.bodyStyle(
          color: TimetableTheme.colorsOf(context).labelText,
        ),
      ),
      trailing: Text(
        value,
        style: TimetableTheme.bodyStyle(
          color: TimetableTheme.colorsOf(context).titleText,
        ),
      ),
      onTap: onTap,
    );
  }
}

/// EV-1 提示文案。
const kOutsideTermHint = '不在本学期，周视图里看不到';

/// [date] 是否落在本学期周视图之外（真实教学周 < 1 或 > [TimetableController.maxWeeks]）。
/// 没有开学日期时无法判断 → false（不提示）。
bool isOutsideTermWeeks(TimetableController c, DateTime date) {
  final w = c.actualWeek(date);
  if (w == null) return false;
  return w < 1 || w > c.maxWeeks;
}
