import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/app_snack_bar.dart';
import '../../core/navigation/app_page.dart';
import '../../core/ui/miuix_dialog.dart';
import 'timetable_color_picker.dart';
import 'timetable_controller.dart';
import 'timetable_course_group.dart';
import 'timetable_entry_form_widgets.dart';
import 'timetable_models.dart';
import 'timetable_persistence_feedback.dart';
import 'timetable_schedule_event.dart';
import 'timetable_schedule_event_layout.dart';
import 'timetable_theme.dart';
import 'timetable_week_format.dart';

/// 从课程详情进入统一编辑页。返回 true 表示已保存或已转换。
Future<bool?> showCourseEditPage(
  BuildContext context, {
  required TimetableController controller,
  required Course course,
  CourseSlot? initialSlot,
  GridCell? cell,
  bool autofocusNote = false,
  int? openSlotIndex,
}) {
  return Navigator.of(context).push<bool>(
    AppPageRoute(
      fullscreenDialog: Theme.of(context).platform != TargetPlatform.android,
      builder: (_) => TimetableCourseEditPage(
        controller: controller,
        course: course,
        initialSlot: initialSlot,
        cell: cell,
        autofocusNote: autofocusNote,
        openSlotIndex: openSlotIndex,
      ),
    ),
  );
}

/// 从考试/日程详情进入统一编辑页。返回保存后的日程，删除或取消返回 null。
Future<ScheduleEvent?> showScheduleEditPage(
  BuildContext context, {
  required TimetableController controller,
  required ScheduleEvent initial,
}) {
  return Navigator.of(context).push<ScheduleEvent>(
    AppPageRoute(
      fullscreenDialog: Theme.of(context).platform != TargetPlatform.android,
      builder: (_) =>
          TimetableScheduleEditPage(controller: controller, initial: initial),
    ),
  );
}

/// 统一课程编辑页：展示同课吸附并按「同星期 + 同节次 + 同地点」合并后的全部时段卡片，
/// 支持横向滑动、直接选周次、修改全局字段与二级弹窗精细编辑时段。
class TimetableCourseEditPage extends StatefulWidget {
  const TimetableCourseEditPage({
    super.key,
    required this.controller,
    required this.course,
    this.initialSlot,
    this.cell,
    this.autofocusNote = false,
    this.openSlotIndex,
  });

  final TimetableController controller;
  final Course course;
  final CourseSlot? initialSlot;
  final GridCell? cell;
  final bool autofocusNote;
  final int? openSlotIndex;

  @override
  State<TimetableCourseEditPage> createState() =>
      _TimetableCourseEditPageState();
}

class _TimetableCourseEditPageState extends State<TimetableCourseEditPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameFocus = FocusNode();
  final _teacherFocus = FocusNode();
  final _noteFocus = FocusNode();

  late final CourseGroup _group;
  late final TextEditingController _name;
  late final TextEditingController _teacher;
  late final TextEditingController _globalNote;

  late final String _initialName;
  late final String _initialTeacher;
  late final String _initialGlobalNote;
  late final int? _initialUserArgb;
  late final List<CourseSlotDraft> _initialSlots;
  late List<CourseSlotDraft> _slots;
  late int _currentDraftIndex;

  int? _userArgb;
  bool _colorChanged = false;
  bool _pickingColor = false;
  bool _saving = false;
  bool _triedSave = false;
  bool _allowPop = false;
  bool _confirmingExit = false;
  bool _wasDirty = false;

  int get _totalWeeks => widget.controller.totalWeeks;

  @override
  void initState() {
    super.initState();
    _group = widget.controller.courseGroupOf(widget.course);
    final primary = _group.primary;
    _initialName = primary.name.trim();
    _initialGlobalNote = _group.globalNote;

    final teachers = _group.distinctTeachers;
    _initialTeacher = teachers.length == 1
        ? teachers.single
        : (teachers.isEmpty ? '' : '');

    _initialUserArgb = widget.controller.userColorOf(primary);
    _userArgb = _initialUserArgb;

    final rawDrafts = <CourseSlotDraft>[];
    final targetSlot = widget.cell?.slot ?? widget.initialSlot;
    for (final item in _group.slots) {
      final slot = item.slot;
      rawDrafts.add(
        CourseSlotDraft(
          sourceCourse: item.course,
          sourceSlot: slot,
          sourceSlotIndex: item.slotIndex,
          day: slot.day,
          startNode: slot.startNode,
          endNode: slot.endNode,
          weeks: weeksFromBits(slot.weeks),
          location: slot.location,
          note: slot.note,
          kind: courseKindOf(course: item.course, slot: slot),
          teacher: slot.teacher,
          color: slot.color,
          useDefaultColor: slot.useDefaultColor,
        ),
      );
    }

    final merged = mergeCourseSlotDrafts(rawDrafts);
    if (merged.isEmpty) {
      merged.add(
        CourseSlotDraft(
          sourceCourse: primary,
          day: 1,
          startNode: 1,
          endNode: 2.clamp(1, widget.controller.lastPeriod),
          weeks: [for (var w = 1; w <= _totalWeeks; w++) w],
        ),
      );
    }

    var matchedCurrent = -1;
    if (targetSlot != null) {
      for (var i = 0; i < merged.length; i++) {
        final d = merged[i];
        final matchesPrimary =
            d.sourceCourse?.id == widget.course.id &&
            d.sourceSlot?.day == targetSlot.day &&
            d.sourceSlot?.startNode == targetSlot.startNode &&
            d.sourceSlot?.endNode == targetSlot.endNode &&
            d.sourceSlot?.weeks == targetSlot.weeks;
        final matchesExtra = d.extraSources.any(
          (e) =>
              e.course.id == widget.course.id &&
              e.slot.day == targetSlot.day &&
              e.slot.startNode == targetSlot.startNode &&
              e.slot.endNode == targetSlot.endNode &&
              e.slot.weeks == targetSlot.weeks,
        );
        if (matchesPrimary || matchesExtra) {
          matchedCurrent = i;
          break;
        }
      }
      if (matchedCurrent < 0) {
        matchedCurrent = merged.indexWhere(
          (d) =>
              d.day == targetSlot.day &&
              d.startNode == targetSlot.startNode &&
              d.endNode == targetSlot.endNode,
        );
      }
    }

    _initialSlots = List<CourseSlotDraft>.unmodifiable(merged);
    _slots = List<CourseSlotDraft>.of(merged);
    _currentDraftIndex = matchedCurrent >= 0 ? matchedCurrent : 0;

    _name = TextEditingController(text: _initialName);
    _teacher = TextEditingController(text: _initialTeacher);
    _globalNote = TextEditingController(text: _initialGlobalNote);
    _name.addListener(_onTextChanged);
    _teacher.addListener(_onTextChanged);
    _globalNote.addListener(_onTextChanged);

    int? autoIndex;
    if (widget.openSlotIndex != null) {
      final req = widget.openSlotIndex!;
      if (req >= 0 && req < _slots.length) {
        autoIndex = req;
      } else if (req >= 0 && req < _group.slots.length) {
        final target = _group.slots[req];
        autoIndex = _slots.indexWhere(
          (d) =>
              (d.sourceCourse?.id == target.course.id &&
                  d.sourceSlotIndex == target.slotIndex) ||
              d.extraSources.any(
                (e) =>
                    e.course.id == target.course.id &&
                    e.slotIndex == target.slotIndex,
              ),
        );
      }
    } else if (widget.autofocusNote) {
      autoIndex = _currentDraftIndex;
    }
    if (autoIndex != null && autoIndex >= 0 && autoIndex < _slots.length) {
      final targetAuto = autoIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _editSlot(targetAuto, autofocusNote: widget.autofocusNote);
        }
      });
    }
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

  bool get _teacherEdited => _teacher.text.trim() != _initialTeacher;

  bool get _dirty {
    if (_name.text.trim() != _initialName ||
        _teacherEdited ||
        _globalNote.text.trim() != _initialGlobalNote ||
        _colorChanged) {
      return true;
    }
    if (_slots.length != _initialSlots.length) return true;
    for (var i = 0; i < _slots.length; i++) {
      final a = _slots[i];
      final b = _initialSlots[i];
      if (a.day != b.day ||
          a.startNode != b.startNode ||
          a.endNode != b.endNode ||
          a.location != b.location ||
          a.note != b.note ||
          a.kind != b.kind ||
          !listEquals(a.weeks, b.weeks)) {
        return true;
      }
    }
    return false;
  }

  void _onTextChanged() {
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
      cancelKey: const Key('course_form_discard_cancel'),
      confirmKey: const Key('course_form_discard_confirm'),
    );
    _confirmingExit = false;
    if (discard && mounted) _leave(null);
  }

  void _leave(bool? result) {
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(result);
    });
  }

  bool _canConvertSlotToExam(int index) {
    final cell = widget.cell;
    if (cell == null || cell.date == null || !cell.activeThisWeek) return false;
    return index == _currentDraftIndex && !_dirty;
  }

  void _applyMergedSlots(List<CourseSlotDraft> next) {
    final merged = mergeCourseSlotDrafts(next);
    setState(() {
      _slots = merged;
      if (_currentDraftIndex >= _slots.length) {
        _currentDraftIndex = _slots.length - 1;
      }
    });
  }

  Future<void> _editSlot(int index, {bool autofocusNote = false}) async {
    if (_saving || _pickingColor) return;
    final res = await showCourseSlotEditorSheet(
      context,
      controller: widget.controller,
      initial: _slots[index],
      excludeCourseIds: _group.courseIds,
      allowConvertToExam: _canConvertSlotToExam(index),
      autofocusNote: autofocusNote,
    );
    if (res == null || !mounted) return;
    if (res.convertToExam) {
      await _convertToExam(res.draft);
      return;
    }
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
      teacher: _teacher.text.trim().isNotEmpty
          ? _teacher.text.trim()
          : prev.teacher,
    );
    final res = await showCourseSlotEditorSheet(
      context,
      controller: widget.controller,
      initial: seed,
      excludeCourseIds: _group.courseIds,
      isNew: true,
    );
    if (res == null || !mounted) return;
    _applyMergedSlots([..._slots, res.draft]);
  }

  Future<void> _convertToExam(CourseSlotDraft draft) async {
    final cell = widget.cell;
    if (cell == null || cell.date == null || !cell.activeThisWeek) return;
    final week = widget.controller.weekOfDate(cell.date!);
    final confirmed = await showMiuixConfirmDialog(
      context,
      title: '将本次课转为考试',
      message: '仅将第 $week 周这次课移为独立考试，其他周次与其他时段不变。',
      confirmLabel: '转为考试',
      cancelLabel: '取消',
      cancelKey: const Key('course_form_exam_cancel'),
      confirmKey: const Key('course_form_exam_confirm'),
    );
    if (!confirmed || !mounted) return;
    setState(() => _saving = true);
    try {
      ScheduleEvent? exam;
      final completed =
          await withTimetablePersistenceFeedback<bool>(context, () async {
            final mergedNote = combineCourseNotes(_globalNote.text, draft.note);
            exam = await widget.controller.convertCourseOccurrenceToExam(
              cell: cell,
              title: _name.text.trim().isEmpty
                  ? _initialName
                  : _name.text.trim(),
              location: draft.location,
              note: mergedNote,
              day: draft.day,
              startNode: draft.startNode,
              endNode: draft.endNode,
            );
            return true;
          }) ==
          true;
      if (!mounted) return;
      if (completed && exam != null) {
        _leave(true);
      } else if (completed) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          AppSnackBar(
            tone: AppSnackBarTone.error,
            content: const Text('未能转为考试，请重新打开这次课后重试'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickColor() async {
    if (_saving || _pickingColor) return;
    setState(() => _pickingColor = true);
    try {
      final previewName = _name.text.trim().isEmpty
          ? _initialName
          : _name.text.trim();
      final idx = widget.controller.colorIndexOf(_group.primary);
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
      setState(() {
        _userArgb = picked.reset ? null : picked.color?.toARGB32();
        _colorChanged = _userArgb != _initialUserArgb;
      });
    } finally {
      if (mounted) setState(() => _pickingColor = false);
    }
  }

  Future<void> _save() async {
    if (_saving || _pickingColor) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _triedSave = true);
    if (!_formKey.currentState!.validate() || _slots.isEmpty) return;

    setState(() => _saving = true);
    try {
      Course? saved;
      final completed =
          await withTimetablePersistenceFeedback<bool>(context, () async {
            saved = await widget.controller.saveCourseGroupForm(
              group: _group,
              name: _name.text,
              teacher: _teacher.text,
              teacherChanged: _teacherEdited,
              globalNote: _globalNote.text,
              slots: _slots,
              userArgb: _userArgb,
              colorChanged: _colorChanged,
            );
            return true;
          }) ==
          true;
      if (!mounted) return;
      if (completed && saved != null) {
        _leave(true);
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
    final distinctTeachers = _group.distinctTeachers;
    final mixedTeachersHint = !_teacherEdited && distinctTeachers.length > 1
        ? '各时段任课教师不同：${distinctTeachers.join('、')}（留空各自保留）'
        : null;
    final swatch = _userArgb == null
        ? TimetableTheme.autoCoursePair(
            widget.controller.colorIndexOf(_group.primary),
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
            key: const Key('course_form_close'),
            icon: const Icon(Icons.close),
            tooltip: '关闭',
            onPressed: _saving ? null : _requestClose,
          ),
          title: const Text('编辑课程'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: TextButton(
                key: const Key('course_form_save'),
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
                      fieldKey: const Key('course_form_name'),
                      label: '课程名称',
                      controller: _name,
                      focusNode: _nameFocus,
                      nextFocus: _teacherFocus,
                      enabled: !_saving,
                      hint: '请填写课程名称',
                      autovalidateMode: _triedSave
                          ? AutovalidateMode.onUserInteraction
                          : AutovalidateMode.disabled,
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? '请填写课程名称' : null,
                    ),
                    if (_group.code.isNotEmpty)
                      TimetableFormReadonlyRow(
                        label: '课程号',
                        value: _group.code,
                      ),
                    TimetableFormTextField(
                      fieldKey: const Key('course_form_teacher'),
                      label: '任课教师',
                      controller: _teacher,
                      focusNode: _teacherFocus,
                      nextFocus: _noteFocus,
                      enabled: !_saving,
                      hint: distinctTeachers.length > 1 ? '留空保留各时段原教师' : '选填',
                      helperText: mixedTeachersHint,
                    ),
                    TimetableFormTapRow(
                      key: const Key('course_form_color'),
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
                      fieldKey: const Key('course_form_note'),
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
                  slotKeyPrefix: 'course_edit_slot_',
                  addButtonKey: const Key('course_edit_add_slot'),
                  currentIndex:
                      (widget.cell != null || widget.initialSlot != null)
                      ? _currentDraftIndex
                      : null,
                  onTapSlot: _saving ? null : _editSlot,
                  onDeleteSlot: _slots.length > 1 && !_saving
                      ? (i) => setState(() {
                          _slots = [..._slots]..removeAt(i);
                          if (_currentDraftIndex >= _slots.length) {
                            _currentDraftIndex = _slots.length - 1;
                          }
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

/// 统一编辑页中的考试/日程模式（圆角分组卡片视觉统一）。
class TimetableScheduleEditPage extends StatefulWidget {
  const TimetableScheduleEditPage({
    super.key,
    required this.controller,
    required this.initial,
  });

  final TimetableController controller;
  final ScheduleEvent initial;

  @override
  State<TimetableScheduleEditPage> createState() =>
      _TimetableScheduleEditPageState();
}

class _TimetableScheduleEditPageState extends State<TimetableScheduleEditPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _location;
  late final TextEditingController _note;
  late final TextEditingController _courseCode;
  final _titleFocus = FocusNode();
  final _locationFocus = FocusNode();
  final _noteFocus = FocusNode();
  final _codeFocus = FocusNode();

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
  bool _allowPop = false;
  bool _confirmingExit = false;
  bool _wasDirty = false;

  bool get _isJwxt => widget.initial.isFromJwxt;
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
    _kind = i.kind;
    _date = DateTime(i.date.year, i.date.month, i.date.day);
    _start = i.start;
    _end = i.end;
    _initialKind = _kind;
    _initialDate = _date;
    _initialStart = _start;
    _initialEnd = _end;
    _initialTitle = i.title;
    _initialLocation = i.location;
    _initialNote = i.note;
    _initialCourseCode = i.courseCode ?? '';

    _title = TextEditingController(text: _initialTitle);
    _location = TextEditingController(text: _initialLocation);
    _note = TextEditingController(text: _initialNote);
    _courseCode = TextEditingController(text: _initialCourseCode);
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

  void _leave(ScheduleEvent? result) {
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(result);
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
      final event = widget.initial.copyWith(
        kind: _isJwxt ? ScheduleKind.exam : _kind,
        title: _title.text.trim(),
        date: _date,
        start: _start,
        end: _end,
        location: _location.text.trim(),
        note: _note.text.trim(),
        courseCode: _kind == ScheduleKind.exam && code.isNotEmpty ? code : null,
      );
      var updated = false;
      final ok =
          await withTimetablePersistenceFeedback<bool>(context, () async {
            updated = await widget.controller.updateScheduleEvent(event);
            return true;
          }) ==
          true;
      if (!mounted || !ok || !updated) return;
      _leave(event);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    if (_saving) return;
    final confirmed = await confirmDeleteScheduleEvent(context, widget.initial);
    if (!confirmed || !mounted) return;
    setState(() => _saving = true);
    try {
      var deleted = false;
      final ok =
          await withTimetablePersistenceFeedback<bool>(context, () async {
            deleted = await widget.controller.deleteScheduleEvent(
              widget.initial.id,
            );
            return true;
          }) ==
          true;
      if (!mounted || !ok || !deleted) return;
      _leave(null);
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
          title: Text(_kind == ScheduleKind.exam ? '编辑考试' : '编辑日程'),
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
                if (!_isJwxt) ...[
                  TimetableKindSwitch(
                    kind: _kind,
                    onChanged: (value) => setState(() => _kind = value),
                  ),
                  const SizedBox(height: 12),
                ],
                TimetableFormSectionCard(
                  children: [
                    TimetableFormTextField(
                      fieldKey: const Key('schedule_form_title'),
                      label: _kind == ScheduleKind.exam ? '考试名称' : '日程名称',
                      controller: _title,
                      focusNode: _titleFocus,
                      nextFocus: _locationFocus,
                      enabled: !_saving,
                      hint: _kind == ScheduleKind.exam ? '请填写考试名称' : '请填写日程名称',
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
                      label: _kind == ScheduleKind.exam ? '考场地点' : '地点',
                      controller: _location,
                      focusNode: _locationFocus,
                      nextFocus: _noteFocus,
                      enabled: !_saving,
                      hint: '选填',
                    ),
                    TimetableFormTextField(
                      fieldKey: const Key('schedule_form_note'),
                      label: '备注',
                      controller: _note,
                      focusNode: _noteFocus,
                      nextFocus: _kind == ScheduleKind.exam && !_isJwxt
                          ? _codeFocus
                          : null,
                      enabled: !_saving,
                      hint: _kind == ScheduleKind.exam
                          ? '选填，如座位号、准考证要求…'
                          : '选填',
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: _kind == ScheduleKind.exam && !_isJwxt
                          ? TextInputAction.next
                          : TextInputAction.done,
                      divider: _kind == ScheduleKind.exam,
                    ),
                    if (_kind == ScheduleKind.exam)
                      _isJwxt
                          ? TimetableFormReadonlyRow(
                              label: '课程号',
                              value: _courseCode.text.trim().isEmpty
                                  ? '未填写'
                                  : _courseCode.text.trim(),
                              hint: '来自教务，不可修改',
                              divider: false,
                            )
                          : TimetableFormTextField(
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
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  key: const Key('schedule_form_delete'),
                  onPressed: _saving ? null : _delete,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('删除'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colors.danger,
                    side: BorderSide(
                      color: colors.danger.withValues(alpha: 0.4),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    minimumSize: const Size(0, 48),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
