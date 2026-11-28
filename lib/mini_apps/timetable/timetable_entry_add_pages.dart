import 'package:flutter/material.dart';

import '../../core/app_snack_bar.dart';
import '../../core/navigation/app_page.dart';
import '../../core/ui/miuix_dialog.dart';
import 'timetable_api.dart';
import 'timetable_color_picker.dart';
import 'timetable_controller.dart';
import 'timetable_course_group.dart';
import 'timetable_entry_form_widgets.dart';
import 'timetable_models.dart';
import 'timetable_persistence_feedback.dart';
import 'timetable_schedule_event.dart';
import 'timetable_schedule_event_layout.dart';
import 'timetable_theme.dart';

/// 打开独立「添加课程」页面。
Future<Course?> showAddCoursePage(
  BuildContext context, {
  required TimetableController controller,
}) {
  return Navigator.of(context).push<Course>(
    AppPageRoute(
      fullscreenDialog: Theme.of(context).platform != TargetPlatform.android,
      builder: (_) => TimetableAddCoursePage(controller: controller),
    ),
  );
}

/// 打开独立「添加考试」页面。
Future<ScheduleEvent?> showAddExamPage(
  BuildContext context, {
  required TimetableController controller,
  DateTime? initialDate,
}) {
  return Navigator.of(context).push<ScheduleEvent>(
    AppPageRoute(
      fullscreenDialog: Theme.of(context).platform != TargetPlatform.android,
      builder: (_) => TimetableAddExamPage(
        controller: controller,
        initialDate: initialDate,
      ),
    ),
  );
}

/// 打开独立「添加日程」页面。
Future<ScheduleEvent?> showAddSchedulePage(
  BuildContext context, {
  required TimetableController controller,
  DateTime? initialDate,
}) {
  return Navigator.of(context).push<ScheduleEvent>(
    AppPageRoute(
      fullscreenDialog: Theme.of(context).platform != TargetPlatform.android,
      builder: (_) => TimetableAddSchedulePage(
        controller: controller,
        initialDate: initialDate,
      ),
    ),
  );
}

/// 独立页面 1：添加课程（支持多时段卡片滑动、直接选周次与实验/体育类型）。
class TimetableAddCoursePage extends StatefulWidget {
  const TimetableAddCoursePage({super.key, required this.controller});

  final TimetableController controller;

  @override
  State<TimetableAddCoursePage> createState() => _TimetableAddCoursePageState();
}

class _TimetableAddCoursePageState extends State<TimetableAddCoursePage> {
  final _formKey = GlobalKey<FormState>();
  final _nameFocus = FocusNode();
  final _teacherFocus = FocusNode();
  final _noteFocus = FocusNode();
  final _name = TextEditingController();
  final _teacher = TextEditingController();
  final _globalNote = TextEditingController();
  late List<CourseSlotDraft> _slots;
  int? _userArgb;
  bool _pickingColor = false;
  bool _saving = false;
  bool _triedSave = false;
  bool _allowPop = false;
  bool _confirmingExit = false;

  int get _totalWeeks => widget.controller.totalWeeks;

  List<int> get _defaultWeeks {
    final start = widget.controller.viewingWeek.clamp(1, _totalWeeks);
    return [for (var w = start; w <= _totalWeeks; w++) w];
  }

  @override
  void initState() {
    super.initState();
    final maxNode = widget.controller.lastPeriod > 0
        ? widget.controller.lastPeriod
        : 11;
    _slots = [
      CourseSlotDraft(
        day: 1,
        startNode: 1,
        endNode: 2.clamp(1, maxNode),
        weeks: _defaultWeeks,
      ),
    ];
    _name.addListener(_onFieldChanged);
    _teacher.addListener(_onFieldChanged);
    _globalNote.addListener(_onFieldChanged);
  }

  @override
  void dispose() {
    _name.dispose();
    _teacher.dispose();
    _globalNote.dispose();
    _nameFocus.dispose();
    _teacherFocus.dispose();
    _noteFocus.dispose();
    super.dispose();
  }

  bool get _dirty {
    if (_name.text.trim().isNotEmpty ||
        _teacher.text.trim().isNotEmpty ||
        _globalNote.text.trim().isNotEmpty ||
        _userArgb != null) {
      return true;
    }
    if (_slots.length != 1) return true;
    final s = _slots.single;
    final def = _defaultWeeks;
    if (s.day != 1 ||
        s.startNode != 1 ||
        s.endNode != 2.clamp(1, widget.controller.lastPeriod) ||
        s.location.isNotEmpty ||
        s.note.isNotEmpty ||
        s.kind != CourseKind.standard) {
      return true;
    }
    if (s.weeks.length != def.length) return true;
    for (var i = 0; i < def.length; i++) {
      if (s.weeks[i] != def[i]) return true;
    }
    return false;
  }

  bool _wasDirty = false;
  void _onFieldChanged() {
    if (_wasDirty != _dirty) {
      setState(() => _wasDirty = _dirty);
    }
  }

  Future<void> _requestClose() async {
    if (_saving || _pickingColor || _confirmingExit) return;
    if (!_dirty) {
      _leave(null);
      return;
    }
    _confirmingExit = true;
    final discard = await showMiuixConfirmDialog(
      context,
      message: '放弃未保存的修改？',
      confirmLabel: '放弃',
      cancelLabel: '继续编辑',
      destructive: true,
      cancelKey: const Key('add_course_discard_cancel'),
      confirmKey: const Key('add_course_discard_confirm'),
    );
    _confirmingExit = false;
    if (discard && mounted) _leave(null);
  }

  void _leave(Course? saved) {
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(saved);
    });
  }

  void _applyMergedSlots(List<CourseSlotDraft> next) {
    setState(() => _slots = mergeCourseSlotDrafts(next));
  }

  Future<void> _editSlot(int index) async {
    if (_saving || _pickingColor) return;
    final res = await showCourseSlotEditorSheet(
      context,
      controller: widget.controller,
      initial: _slots[index],
    );
    if (res == null || !mounted) return;
    final updated = [..._slots]..[index] = res.draft;
    _applyMergedSlots(updated);
  }

  Future<void> _addSlot() async {
    if (_saving || _pickingColor) return;
    final prev = _slots.last;
    final seed = CourseSlotDraft(
      day: prev.day,
      startNode: prev.startNode,
      endNode: prev.endNode,
      weeks: prev.weeks,
      location: prev.location,
      kind: prev.kind,
    );
    final res = await showCourseSlotEditorSheet(
      context,
      controller: widget.controller,
      initial: seed,
      isNew: true,
    );
    if (res == null || !mounted) return;
    _applyMergedSlots([..._slots, res.draft]);
  }

  Future<void> _pickColor() async {
    if (_saving || _pickingColor) return;
    setState(() => _pickingColor = true);
    try {
      final previewName = _name.text.trim().isEmpty ? '新课程' : _name.text.trim();
      final idx = courseColorIndexForName(previewName);
      final defaultBg = TimetableTheme.autoCoursePair(idx).bg;
      final initialColor = _userArgb == null ? defaultBg : Color(_userArgb!);
      final picked = await showTimetableColorPicker(
        context,
        current: initialColor,
        defaultColor: defaultBg,
        previewTitle: previewName,
        showReset: _userArgb != null,
        opacity: widget.controller.settings.cellOpacity,
      );
      if (picked == null || !mounted) return;
      setState(
        () => _userArgb = picked.reset ? null : picked.color?.toARGB32(),
      );
    } finally {
      if (mounted) setState(() => _pickingColor = false);
    }
  }

  Future<void> _save() async {
    if (_saving || _pickingColor) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _triedSave = true);
    if (!_formKey.currentState!.validate() || _slots.isEmpty) return;

    final existing = findExistingCourseByName(
      widget.controller.courses,
      _name.text,
    );
    setState(() => _saving = true);
    try {
      Course? saved;
      final completed =
          await withTimetablePersistenceFeedback<bool>(context, () async {
            if (existing != null) {
              final group = widget.controller.courseGroupOf(existing);
              final existingDrafts = [
                for (final item in group.slots)
                  CourseSlotDraft(
                    sourceCourse: item.course,
                    sourceSlot: item.slot,
                    sourceSlotIndex: item.slotIndex,
                    day: item.slot.day,
                    startNode: item.slot.startNode,
                    endNode: item.slot.endNode,
                    weeks: item.slot.weeks.isEmpty
                        ? _defaultWeeks
                        : [
                            for (var w = 1; w <= item.slot.weeks.length; w++)
                              if (item.slot.hasClassInWeek(w)) w,
                          ],
                    location: item.slot.location,
                    note: item.slot.note,
                    kind: courseKindOf(course: item.course, slot: item.slot),
                    teacher: item.slot.teacher,
                    color: item.slot.color,
                    useDefaultColor: item.slot.useDefaultColor,
                  ),
              ];
              final teacherText = _teacher.text.trim();
              final mergedGlobalNote = combineCourseNotes(
                group.globalNote,
                _globalNote.text,
              );
              saved = await widget.controller.saveCourseGroupForm(
                group: group,
                name: group.primary.name,
                teacher: teacherText,
                teacherChanged: teacherText.isNotEmpty,
                globalNote: mergedGlobalNote,
                slots: mergeCourseSlotDrafts([
                  ...existingDrafts,
                  for (final s in _slots) s.copyWith(teacher: teacherText),
                ]),
                userArgb: _userArgb,
                colorChanged: _userArgb != null,
              );
            } else {
              saved = await widget.controller.addManualCourseWithDrafts(
                name: _name.text,
                teacher: _teacher.text,
                globalNote: _globalNote.text,
                slots: _slots,
                userArgb: _userArgb,
              );
            }
            return true;
          }) ==
          true;
      if (!mounted) return;
      if (completed && saved != null) {
        _leave(saved);
      } else if (completed) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          AppSnackBar(
            tone: AppSnackBarTone.error,
            content: const Text('保存失败，请检查填写内容'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final previewName = _name.text.trim();
    final matchedExisting = findExistingCourseByName(
      widget.controller.courses,
      previewName,
    );
    final swatch = _userArgb == null
        ? TimetableTheme.autoCoursePair(
            courseColorIndexForName(previewName.isEmpty ? '课程' : previewName),
            dark: colors.isDark,
          ).bg
        : TimetableTheme.userCoursePair(
            Color(_userArgb!),
            dark: colors.isDark,
          ).bg;

    return PopScope<Object?>(
      canPop: _allowPop || (!_dirty && !_saving && !_pickingColor),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestClose();
      },
      child: Scaffold(
        backgroundColor: colors.pageBg,
        resizeToAvoidBottomInset: !_pickingColor,
        appBar: AppBar(
          backgroundColor: colors.pageBg,
          foregroundColor: colors.titleText,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
            key: const Key('add_course_close'),
            icon: const Icon(Icons.close),
            tooltip: '关闭',
            onPressed: _saving ? null : _requestClose,
          ),
          title: const Text('添加课程'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: TextButton(
                key: const Key('add_course_save'),
                onPressed: _saving ? null : _save,
                child: const Text(
                  '保存',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          maintainBottomViewPadding: true,
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                TimetableFormSectionCard(
                  children: [
                    TimetableFormTextField(
                      fieldKey: const Key('add_course_name'),
                      label: '课程名称',
                      controller: _name,
                      focusNode: _nameFocus,
                      nextFocus: _teacherFocus,
                      enabled: !_saving,
                      hint: '例如：高等数学',
                      autovalidateMode: _triedSave
                          ? AutovalidateMode.onUserInteraction
                          : AutovalidateMode.disabled,
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? '请填写课程名称' : null,
                    ),
                    if (matchedExisting != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6, bottom: 6),
                        child: Text(
                          '课表中已有「${matchedExisting.name}」，保存后将合并其上课安排',
                          key: const Key('add_course_merge_hint'),
                          style: TextStyle(color: colors.accent, fontSize: 12),
                        ),
                      ),
                    TimetableFormTextField(
                      fieldKey: const Key('add_course_teacher'),
                      label: '任课教师',
                      controller: _teacher,
                      focusNode: _teacherFocus,
                      nextFocus: _noteFocus,
                      enabled: !_saving,
                      hint: '选填',
                    ),
                    TimetableFormTapRow(
                      key: const Key('add_course_color'),
                      label: '课程颜色',
                      value: _userArgb == null ? '自动配色' : '自选颜色',
                      leading: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: swatch,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: colors.divider.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                      onTap: _saving ? null : _pickColor,
                    ),
                    TimetableFormTextField(
                      fieldKey: const Key('add_course_note'),
                      label: '备注',
                      controller: _globalNote,
                      focusNode: _noteFocus,
                      enabled: !_saving,
                      hint: '选填，如考核方式、教材、网盘链接…',
                      minLines: 1,
                      maxLines: 3,
                      textInputAction: TextInputAction.done,
                      divider: false,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      Text(
                        '上课安排',
                        style: TextStyle(
                          color: colors.titleText,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${_slots.length} 个时段',
                        style: TextStyle(color: colors.hint, fontSize: 13),
                      ),
                      const Spacer(),
                      Text(
                        '点卡片编辑详情',
                        style: TextStyle(color: colors.hint, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                CourseSlotHorizontalStrip(
                  slots: _slots,
                  periods: widget.controller.periods,
                  slotKeyPrefix: 'add_course_slot_',
                  addButtonKey: const Key('add_course_add_slot'),
                  onTapSlot: _saving ? null : _editSlot,
                  onDeleteSlot: _slots.length > 1 && !_saving
                      ? (i) => setState(() {
                          _slots = [..._slots]..removeAt(i);
                        })
                      : null,
                  onAddSlot: _saving ? null : _addSlot,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 独立页面 2：添加考试。
class TimetableAddExamPage extends StatelessWidget {
  const TimetableAddExamPage({
    super.key,
    required this.controller,
    this.initialDate,
  });

  final TimetableController controller;
  final DateTime? initialDate;

  @override
  Widget build(BuildContext context) => _StandaloneEventAddScaffold(
    controller: controller,
    kind: ScheduleKind.exam,
    pageTitle: '添加考试',
    nameLabel: '考试名称',
    nameHint: '例如：高等数学期末考试',
    locationLabel: '考场地点',
    locationHint: '例如：明德楼 S301',
    noteHint: '选填，如座位号、准考证要求…',
    showCourseCode: true,
    initialDate: initialDate,
  );
}

/// 独立页面 3：添加日程。
class TimetableAddSchedulePage extends StatelessWidget {
  const TimetableAddSchedulePage({
    super.key,
    required this.controller,
    this.initialDate,
  });

  final TimetableController controller;
  final DateTime? initialDate;

  @override
  Widget build(BuildContext context) => _StandaloneEventAddScaffold(
    controller: controller,
    kind: ScheduleKind.other,
    pageTitle: '添加日程',
    nameLabel: '日程名称',
    nameHint: '例如：班会、讲座',
    locationLabel: '地点',
    locationHint: '选填',
    noteHint: '选填',
    showCourseCode: false,
    initialDate: initialDate,
  );
}

class _StandaloneEventAddScaffold extends StatefulWidget {
  const _StandaloneEventAddScaffold({
    required this.controller,
    required this.kind,
    required this.pageTitle,
    required this.nameLabel,
    required this.nameHint,
    required this.locationLabel,
    required this.locationHint,
    required this.noteHint,
    required this.showCourseCode,
    this.initialDate,
  });

  final TimetableController controller;
  final ScheduleKind kind;
  final String pageTitle;
  final String nameLabel;
  final String nameHint;
  final String locationLabel;
  final String locationHint;
  final String noteHint;
  final bool showCourseCode;
  final DateTime? initialDate;

  @override
  State<_StandaloneEventAddScaffold> createState() =>
      _StandaloneEventAddScaffoldState();
}

class _StandaloneEventAddScaffoldState
    extends State<_StandaloneEventAddScaffold> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _location = TextEditingController();
  final _note = TextEditingController();
  final _courseCode = TextEditingController();
  final _titleFocus = FocusNode();
  final _locationFocus = FocusNode();
  final _noteFocus = FocusNode();
  final _codeFocus = FocusNode();

  late DateTime _date;
  late TimeOfDayMinutes _start;
  late TimeOfDayMinutes _end;
  late final DateTime _initialDate;
  late final TimeOfDayMinutes _initialStart;
  late final TimeOfDayMinutes _initialEnd;
  bool _saving = false;
  bool _triedSave = false;
  bool _allowPop = false;
  bool _confirmingExit = false;

  bool get _timeValid => _end.compareTo(_start) > 0;

  bool get _dirty =>
      _title.text.isNotEmpty ||
      _location.text.isNotEmpty ||
      _note.text.isNotEmpty ||
      _courseCode.text.isNotEmpty ||
      _date != _initialDate ||
      _start != _initialStart ||
      _end != _initialEnd;

  bool _wasDirty = false;

  @override
  void initState() {
    super.initState();
    final d = widget.initialDate ?? TimetableApi.shanghaiToday();
    _date = DateTime(d.year, d.month, d.day);
    _start = const TimeOfDayMinutes(8, 0);
    _end = const TimeOfDayMinutes(9, 40);
    _initialDate = _date;
    _initialStart = _start;
    _initialEnd = _end;
    _title.addListener(_onEdited);
    _location.addListener(_onEdited);
    _note.addListener(_onEdited);
    _courseCode.addListener(_onEdited);
  }

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    _note.dispose();
    _courseCode.dispose();
    _titleFocus.dispose();
    _locationFocus.dispose();
    _noteFocus.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  void _onEdited() {
    if (_wasDirty != _dirty) {
      setState(() => _wasDirty = _dirty);
    }
  }

  Future<void> _pickDate() async {
    final picked = await showScheduleDatePickerSheet(
      context,
      initialDate: _date,
    );
    if (picked != null && mounted) {
      setState(() => _date = picked);
    }
  }

  Future<void> _pickTime({required bool start}) async {
    final picked = await showScheduleTimePickerSheet(
      context,
      title: start ? '开始时间' : '结束时间',
      initial: start ? _start : _end,
    );
    if (picked != null && mounted) {
      setState(() {
        if (start) {
          _start = picked;
        } else {
          _end = picked;
        }
      });
    }
  }

  Future<void> _requestClose() async {
    if (_saving || _confirmingExit) return;
    if (!_dirty) {
      _leave(null);
      return;
    }
    _confirmingExit = true;
    final discard = await showMiuixConfirmDialog(
      context,
      message: '放弃未保存的修改？',
      confirmLabel: '放弃',
      cancelLabel: '继续编辑',
      destructive: true,
      cancelKey: const Key('schedule_form_discard_cancel'),
      confirmKey: const Key('schedule_form_discard_confirm'),
    );
    _confirmingExit = false;
    if (discard && mounted) _leave(null);
  }

  void _leave(ScheduleEvent? event) {
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(event);
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _triedSave = true);
    if (!_formKey.currentState!.validate() || !_timeValid) return;

    setState(() => _saving = true);
    try {
      final code = _courseCode.text.trim();
      final event = ScheduleEvent(
        id: '',
        kind: widget.kind,
        source: ScheduleSource.manual,
        title: _title.text.trim(),
        date: _date,
        start: _start,
        end: _end,
        location: _location.text.trim(),
        note: _note.text.trim(),
        courseCode: widget.showCourseCode && code.isNotEmpty ? code : null,
      );
      ScheduleEvent? saved;
      final ok =
          await withTimetablePersistenceFeedback<bool>(context, () async {
            saved = await widget.controller.addScheduleEvent(event);
            return true;
          }) ==
          true;
      if (!mounted || !ok) return;
      _leave(saved);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final w = widget.controller.actualWeek(_date);
    final dateValue = w != null && w >= 1 && w <= widget.controller.maxWeeks
        ? '${scheduleDateText(_date)} · 第 $w 周'
        : scheduleDateText(_date);

    return PopScope<Object?>(
      canPop: _allowPop || (!_dirty && !_saving),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestClose();
      },
      child: Scaffold(
        backgroundColor: colors.pageBg,
        appBar: AppBar(
          backgroundColor: colors.pageBg,
          foregroundColor: colors.titleText,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
            key: const Key('schedule_form_close'),
            icon: const Icon(Icons.close),
            tooltip: '关闭',
            onPressed: _saving ? null : _requestClose,
          ),
          title: Text(widget.pageTitle),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: TextButton(
                key: const Key('schedule_form_save'),
                onPressed: _saving ? null : _save,
                child: const Text(
                  '保存',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                TimetableFormSectionCard(
                  children: [
                    TimetableFormTextField(
                      fieldKey: const Key('schedule_form_title'),
                      label: widget.nameLabel,
                      controller: _title,
                      focusNode: _titleFocus,
                      nextFocus: _locationFocus,
                      enabled: !_saving,
                      hint: widget.nameHint,
                      autovalidateMode: _triedSave
                          ? AutovalidateMode.onUserInteraction
                          : AutovalidateMode.disabled,
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? '请填写名称' : null,
                    ),
                    TimetableFormTapRow(
                      key: const Key('schedule_form_date'),
                      label: '日期',
                      value: dateValue,
                      onTap: _saving ? null : _pickDate,
                    ),
                    if (isOutsideTermWeeks(widget.controller, _date))
                      Padding(
                        padding: const EdgeInsets.only(top: 6, bottom: 2),
                        child: Text(
                          kOutsideTermHint,
                          key: const Key('schedule_form_outside_term_hint'),
                          style: TextStyle(color: colors.hint, fontSize: 12),
                        ),
                      ),
                    TimetableFormTapRow(
                      key: const Key('schedule_form_start'),
                      label: '开始时间',
                      value: _start.format(),
                      onTap: _saving ? null : () => _pickTime(start: true),
                    ),
                    TimetableFormTapRow(
                      key: const Key('schedule_form_end'),
                      label: '结束时间',
                      value: _end.format(),
                      valueColor: _timeValid ? null : colors.danger,
                      onTap: _saving ? null : () => _pickTime(start: false),
                    ),
                    if (!_timeValid)
                      Padding(
                        padding: const EdgeInsets.only(top: 6, bottom: 2),
                        child: Text(
                          '结束时间需晚于开始时间',
                          key: const Key('schedule_form_time_error'),
                          style: TextStyle(color: colors.danger, fontSize: 12),
                        ),
                      ),
                    TimetableFormTextField(
                      fieldKey: const Key('schedule_form_location'),
                      label: widget.locationLabel,
                      controller: _location,
                      focusNode: _locationFocus,
                      nextFocus: _noteFocus,
                      enabled: !_saving,
                      hint: widget.locationHint,
                    ),
                    TimetableFormTextField(
                      fieldKey: const Key('schedule_form_note'),
                      label: '备注',
                      controller: _note,
                      focusNode: _noteFocus,
                      nextFocus: widget.showCourseCode ? _codeFocus : null,
                      enabled: !_saving,
                      hint: widget.noteHint,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: widget.showCourseCode
                          ? TextInputAction.next
                          : TextInputAction.done,
                      divider: widget.showCourseCode,
                    ),
                    if (widget.showCourseCode)
                      TimetableFormTextField(
                        fieldKey: const Key('schedule_form_course_code'),
                        label: '课程号',
                        controller: _courseCode,
                        focusNode: _codeFocus,
                        enabled: !_saving,
                        hint: '选填',
                        textInputAction: TextInputAction.done,
                        divider: false,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
