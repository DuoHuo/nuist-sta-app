import '../../core/navigation/app_page.dart';
import 'timetable_persistence_feedback.dart';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../core/ui/miuix_dialog.dart';
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
    AppPageRoute(
      // Android 的全屏对话框会禁用预测性返回，其他平台保留原有模态行为。
      fullscreenDialog: Theme.of(context).platform != TargetPlatform.android,
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
  late bool _hasTitle;
  late final TextEditingController _location;
  late final TextEditingController _note;
  late final TextEditingController _courseCode;
  late ScheduleKind _kind;
  late DateTime _date;
  late TimeOfDayMinutes _start;
  late TimeOfDayMinutes _end;
  late final ScheduleKind _initialKind;
  late final String _initialTitle;
  late final String _initialLocation;
  late final String _initialNote;
  late final String _initialCourseCode;
  late final DateTime _initialDate;
  late final TimeOfDayMinutes _initialStart;
  late final TimeOfDayMinutes _initialEnd;
  bool _saving = false;
  bool _triedSave = false;
  bool _wasDirty = false;
  bool _allowPop = false;

  bool get _isEdit => widget.initial != null;

  /// 教务考试：类型固定为考试，课程号只读（覆盖层不记课程号）。
  bool get _isJwxt => widget.initial?.isFromJwxt ?? false;

  bool get _timeValid => _end.compareTo(_start) > 0;

  bool get _dirty =>
      _kind != _initialKind ||
      _title.text != _initialTitle ||
      _location.text != _initialLocation ||
      _note.text != _initialNote ||
      _courseCode.text != _initialCourseCode ||
      _date != _initialDate ||
      _start != _initialStart ||
      _end != _initialEnd;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _kind = i?.kind ?? widget.kind;
    _title = TextEditingController(text: i?.title ?? '')
      ..addListener(_onTitleChanged)
      ..addListener(_onTextEdited);
    _hasTitle = _title.text.trim().isNotEmpty;
    _location = TextEditingController(text: i?.location ?? '')
      ..addListener(_onTextEdited);
    _note = TextEditingController(text: i?.note ?? '')
      ..addListener(_onTextEdited);
    _courseCode = TextEditingController(text: i?.courseCode ?? '')
      ..addListener(_onTextEdited);
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
    _initialKind = _kind;
    _initialTitle = _title.text;
    _initialLocation = _location.text;
    _initialNote = _note.text;
    _initialCourseCode = _courseCode.text;
    _initialDate = _date;
    _initialStart = _start;
    _initialEnd = _end;
  }

  void _onTitleChanged() {
    final hasTitle = _title.text.trim().isNotEmpty;
    // 页面只关心保存按钮是否可用；文字、光标和输入法状态由输入框更新。
    if (hasTitle == _hasTitle) return;
    setState(() => _hasTitle = hasTitle);
  }

  void _onTextEdited() {
    final dirty = _dirty;
    if (dirty == _wasDirty) return;
    setState(() => _wasDirty = dirty);
  }

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

  void _setDate(DateTime picked) {
    setState(() => _date = DateTime(picked.year, picked.month, picked.day));
  }

  void _setTime({required bool start, required int hour, required int minute}) {
    setState(() {
      final value = TimeOfDayMinutes(hour, minute);
      if (start) {
        _start = value;
      } else {
        _end = value;
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
    setState(() => _saving = true);
    final navigator = Navigator.of(context);
    try {
      await widget.controller.deleteScheduleEvent(i.id);
      if (!mounted) return;
      navigator.pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _requestClose() async {
    if (_saving) return;
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    final discard = await showMiuixConfirmDialog(
      context,
      title: '放弃未保存的修改？',
      message: '离开后当前的编辑内容不会保存。',
      confirmLabel: '放弃',
      cancelLabel: '继续编辑',
      destructive: true,
      confirmKey: const Key('schedule_form_discard_confirm'),
      cancelKey: const Key('schedule_form_discard_cancel'),
    );
    if (!discard || !mounted) return;
    setState(() => _allowPop = true);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final canSave = !_saving && _hasTitle;
    return PopScope<Object?>(
      canPop: _allowPop || (!_dirty && !_saving),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestClose();
      },
      child: Scaffold(
        backgroundColor: TimetableTheme.colorsOf(context).pageBg,
        appBar: AppBar(
          leading: IconButton(
            key: const Key('schedule_form_close'),
            tooltip: '关闭',
            onPressed: _saving ? null : _requestClose,
            icon: const Icon(Icons.close),
          ),
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
          // 表单内嵌日历与数字选择器后整体变高；一次性构建所有字段，
          // 避免离屏字段在未滚动时不进入组件树。
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(TimetableTheme.pagePaddingH),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
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
                _FieldLabel(
                  key: const Key('schedule_form_date'),
                  icon: Icons.calendar_today_outlined,
                  label: '日期',
                  value: scheduleDateText(_date),
                ),
                const SizedBox(height: 4),
                MiuixTheme(
                  data: MiuixThemeData.of(Theme.of(context).brightness),
                  child: MiuixDatePicker(
                    initialDate: _date,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100, 12, 31),
                    weekStart: MiuixWeekStart.sunday,
                    onDateChanged: _setDate,
                  ),
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
                _FieldLabel(
                  key: const Key('schedule_form_start'),
                  icon: Icons.access_time,
                  label: '开始时间',
                  value: _start.format(),
                ),
                _TimeNumberPickers(
                  hour: _start.hour,
                  minute: _start.minute,
                  onChanged: (hour, minute) =>
                      _setTime(start: true, hour: hour, minute: minute),
                ),
                _FieldLabel(
                  key: const Key('schedule_form_end'),
                  icon: Icons.access_time_filled_outlined,
                  label: '结束时间',
                  value: _end.format(),
                ),
                _TimeNumberPickers(
                  hour: _end.hour,
                  minute: _end.minute,
                  onChanged: (hour, minute) =>
                      _setTime(start: false, hour: hour, minute: minute),
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
                        foregroundColor: TimetableTheme.colorsOf(context)
                            .danger,
                        shape: const StadiumBorder(),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 字段标题行：图标 + 名称 + 当前值；具体编辑控件放在下方内嵌展示。
class _FieldLabel extends StatelessWidget {
  const _FieldLabel({
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
    final colors = TimetableTheme.colorsOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Row(
        children: [
          Icon(icon, size: 20, color: colors.hint),
          const SizedBox(width: 8),
          Text(label, style: TimetableTheme.bodyStyle(color: colors.labelText)),
          const Spacer(),
          Text(value, style: TimetableTheme.bodyStyle(color: colors.titleText)),
        ],
      ),
    );
  }
}

/// 内嵌的时、分两列数字选择器。
class _TimeNumberPickers extends StatelessWidget {
  const _TimeNumberPickers({
    required this.hour,
    required this.minute,
    required this.onChanged,
  });

  final int hour;
  final int minute;
  final void Function(int hour, int minute) onChanged;

  @override
  Widget build(BuildContext context) {
    return MiuixTheme(
      data: MiuixThemeData.of(Theme.of(context).brightness),
      child: SizedBox(
        height: 135,
        child: Row(
          children: [
            Expanded(
              child: MiuixNumberPicker(
                value: hour,
                min: 0,
                max: 23,
                wrapAround: true,
                visibleItemCount: 3,
                label: (value) => '$value 时',
                onValueChanged: (value) => onChanged(value, minute),
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
                label: (value) => '$value 分',
                onValueChanged: (value) => onChanged(hour, value),
              ),
            ),
          ],
        ),
      ),
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
