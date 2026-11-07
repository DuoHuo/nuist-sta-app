import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/app_select.dart';
import 'timetable_api.dart';
import 'timetable_color_picker.dart';
import 'timetable_colors.dart';
import 'timetable_controller.dart';
import 'timetable_course_form_sheets.dart';
import 'timetable_models.dart';
import 'timetable_persistence_feedback.dart';
import 'timetable_theme.dart';
import 'timetable_timing.dart';
import 'timetable_week_format.dart';

const _dayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

/// 添加、手动编辑和教务课程编辑共用的平铺表单。
class TimetableCourseForm extends StatefulWidget {
  const TimetableCourseForm({
    super.key,
    required this.controller,
    this.initial,
    this.initialSlot,
    this.cell,
    this.autofocusNote = false,
    this.returnSavedFlag = false,
  });

  final TimetableController controller;
  final Course? initial;
  final CourseSlot? initialSlot;
  final GridCell? cell;
  final bool autofocusNote;

  /// 教务编辑入口返回保存成功标志，手动课程入口返回课程。
  final bool returnSavedFlag;

  @override
  State<TimetableCourseForm> createState() => _TimetableCourseFormState();
}

class _TimetableCourseFormState extends State<TimetableCourseForm> {
  final _formKey = GlobalKey<FormState>();
  final _nameAnchor = GlobalKey();
  final _weeksAnchor = GlobalKey();
  final _noteAnchor = GlobalKey();
  final _nameFocus = FocusNode();
  final _teacherFocus = FocusNode();
  final _locationFocus = FocusNode();
  final _noteFocus = FocusNode();
  late final TextEditingController _name;
  late final TextEditingController _teacher;
  late final TextEditingController _location;
  late final TextEditingController _note;
  late (String, String, String, String) _lastText;
  late (bool, int?) _lastBuiltTextState;
  Object? _conflictInputs;
  String? _conflictDescription;
  late final Course? _entryCourse;
  late final CourseSlot? _entrySlot;
  late final int _totalWeeks;
  late final List<int> _nodes;
  late final Set<int> _initialWeeks;
  late Set<int> _weeks;
  late CourseKind _kind;
  late int _day;
  late int _start;
  late int _end;
  late int _requestedSpan;
  int? _userArgb;
  bool _resetLegacyColor = false;
  bool _saving = false;
  bool _choosingScope = false;
  bool _pickingColor = false;
  bool _confirmingExit = false;
  bool _allowPop = false;
  bool _weeksError = false;
  bool _triedSave = false;

  late final ({
    String name,
    String teacher,
    String location,
    String note,
    CourseKind kind,
    int day,
    int start,
    int end,
    int? userArgb,
  })
  _initial;

  bool get _isEdit => _entryCourse != null;
  bool get _isExam => _kind == CourseKind.exam;
  bool get _busy => _saving || _choosingScope || _pickingColor;
  String get _prefix =>
      widget.returnSavedFlag ? 'jwxt_edit_' : 'manual_course_';
  bool get _weeksChanged => !setEquals(_weeks, _initialWeeks);
  bool get _colorChanged => _userArgb != _initial.userArgb || _resetLegacyColor;
  bool get _hasLegacyColor =>
      _entryCourse?.colorIndex != null &&
      _entryCourse?.useDefaultColor != true &&
      _entrySlot?.useDefaultColor != true;
  bool get _dirty =>
      _name.text.trim() != _initial.name ||
      _teacher.text.trim() != _initial.teacher ||
      _location.text.trim() != _initial.location ||
      _note.text.trim() != _initial.note ||
      _kind != _initial.kind ||
      _day != _initial.day ||
      _start != _initial.start ||
      _end != _initial.end ||
      _weeksChanged ||
      _colorChanged;

  @override
  void initState() {
    super.initState();
    final controller = widget.controller;
    _entryCourse = widget.cell?.course ?? widget.initial;
    _entrySlot =
        widget.cell?.slot ??
        widget.initialSlot ??
        (_entryCourse?.slots.isNotEmpty == true
            ? _entryCourse!.slots.first
            : null);
    final slot = _entrySlot;
    final base = widget.cell == null
        ? null
        : controller.baseOccurrenceOf(widget.cell!);
    // 单次覆盖的时段可能只有一周；重复安排仍取底层时段的完整周次。
    final repeatSlot = base == null ? slot : base.course.slots[base.slotIndex];
    final originalWeeks = repeatSlot == null
        ? const <int>[]
        : weeksFromBits(repeatSlot.weeks);
    _totalWeeks = math.max(
      controller.totalWeeks,
      originalWeeks.isEmpty ? 1 : originalWeeks.last,
    );
    _nodes = {
      for (final period in controller.periods)
        if (period.node >= 1) period.node,
    }.toList()..sort();
    if (_nodes.isEmpty) {
      _nodes.addAll([
        for (
          var node = 1;
          node <= math.max(1, controller.settings.nodesPerDay);
          node++
        )
          node,
      ]);
    }
    _day = slot != null && slot.day >= 1 && slot.day <= 7
        ? slot.day
        : TimetableApi.shanghaiToday().weekday;
    _start = slot != null && _nodes.contains(slot.startNode)
        ? slot.startNode
        : _nodes.first;
    _end = slot != null && _nodes.contains(slot.endNode)
        ? math.max(_start, slot.endNode)
        : _nodes[math.min(_nodes.indexOf(_start) + 1, _nodes.length - 1)];
    _requestedSpan = _end - _start;
    final firstWeek = controller.viewingWeek.clamp(1, _totalWeeks);
    _weeks = repeatSlot != null
        ? originalWeeks.toSet()
        : {for (var week = firstWeek; week <= _totalWeeks; week++) week};
    _initialWeeks = {..._weeks};
    _kind = _entryCourse != null && slot != null
        ? courseKindOf(course: _entryCourse, slot: slot)
        : CourseKind.standard;
    _name = TextEditingController(
      text: slot?.nameOverride ?? _entryCourse?.name ?? '',
    );
    _teacher = TextEditingController(text: slot?.teacher ?? '');
    _location = TextEditingController(text: slot?.location ?? '');
    _note = TextEditingController(text: slot?.note ?? '');
    if (_entryCourse != null) {
      _userArgb = controller.userColorOf(
        widget.cell == null && slot != null
            ? _entryCourse.forSlot(slot)
            : _entryCourse,
      );
    }
    _initial = (
      name: _name.text.trim(),
      teacher: _teacher.text.trim(),
      location: _location.text.trim(),
      note: _note.text.trim(),
      kind: _kind,
      day: _day,
      start: _start,
      end: _end,
      userArgb: _userArgb,
    );
    _lastText = (_name.text, _teacher.text, _location.text, _note.text);
    for (final field in [_name, _teacher, _location, _note]) {
      field.addListener(_changed);
    }
    if (widget.autofocusNote) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final target = _noteAnchor.currentContext;
        // 先定位备注再打开键盘，避免额外的滚动动画与 IME 逐帧避让同时抢位置。
        if (target != null) Scrollable.ensureVisible(target, alignment: .25);
        _noteFocus.requestFocus();
      });
    }
  }

  void _changed() {
    final text = (_name.text, _teacher.text, _location.text, _note.text);
    // 光标、选区和输入法 composing 由输入框自己处理，不必重算表单冲突。
    if (!mounted || text == _lastText) return;
    _lastText = text;
    // 文本本身由输入框更新；只有未保存状态或自动配色变化才影响其余表单。
    if (_textState == _lastBuiltTextState) return;
    setState(() {});
  }

  (bool, int?) get _textState => (_dirty, _isExam ? null : _defaultColorIndex);

  String? _describeConflicts(CourseSlot candidate) {
    final inputs = (
      widget.controller.combinedCourses,
      candidate.day,
      candidate.startNode,
      candidate.endNode,
      candidate.weeks,
    );
    // 输入课程名称、教师或备注不会改变时段冲突；数据或上课安排改变后再重算。
    if (_conflictInputs != inputs) {
      _conflictInputs = inputs;
      _conflictDescription = describeManualConflicts(
        candidate,
        widget.controller.conflictsFor(candidate, excludeId: _entryCourse?.id),
      );
    }
    return _conflictDescription;
  }

  @override
  void dispose() {
    for (final field in [_name, _teacher, _location, _note]) {
      field.dispose();
    }
    for (final focus in [
      _nameFocus,
      _teacherFocus,
      _locationFocus,
      _noteFocus,
    ]) {
      focus.dispose();
    }
    super.dispose();
  }

  void _reveal(GlobalKey anchor) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = anchor.currentContext;
      if (!mounted || target == null) return;
      Scrollable.ensureVisible(
        target,
        alignment: .25,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
      );
    });
  }

  void _leave([Course? saved, bool? changed]) {
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pop(widget.returnSavedFlag ? changed : saved);
    });
  }

  Future<void> _requestClose() async {
    if (_busy || _confirmingExit) return;
    if (!_dirty) {
      _leave();
      return;
    }
    _confirmingExit = true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('放弃未保存的修改？'),
        content: const Text('离开后，这次填写的内容不会保存。'),
        actions: [
          TextButton(
            key: const Key('course_form_discard_cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续编辑'),
          ),
          TextButton(
            key: const Key('course_form_discard_confirm'),
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: TimetableTheme.colorsOf(context).danger,
            ),
            child: const Text('放弃修改'),
          ),
        ],
      ),
    );
    _confirmingExit = false;
    if (mounted && discard == true) _leave();
  }

  Future<void> _pickWeeks() async {
    FocusScope.of(context).unfocus();
    final picked = await showCourseWeeksSheet(
      context,
      totalWeeks: _totalWeeks,
      initial: _weeks,
    );
    if (!mounted || picked == null) return;
    setState(() {
      _weeks = picked.toSet();
      _weeksError = false;
    });
  }

  int get _defaultColorIndex => _entryCourse == null
      ? coursePresetIndexForName(_name.text.trim())
      : coursePresetIndexForCourse(
          _entryCourse,
          colorName: widget.controller.colorNameOf(_entryCourse),
        );

  Future<void> _pickColor() async {
    FocusScope.of(context).unfocus();
    final defaultColor = TimetableTheme.autoCoursePair(
      _defaultColorIndex,
      dark: TimetableTheme.colorsOf(context).isDark,
    ).bg;
    setState(() => _pickingColor = true);
    try {
      final picked = await showTimetableColorPicker(
        context,
        current: _userArgb == null ? defaultColor : Color(_userArgb!),
        defaultColor: defaultColor,
        showReset: _userArgb != null || _hasLegacyColor,
        previewTitle: _name.text.trim().isEmpty ? '课程名称' : _name.text.trim(),
        opacity: widget.controller.settings.cellOpacity,
        textColorMode: widget.controller.settings.cellTextColor,
      );
      if (!mounted || picked == null) return;
      setState(() {
        _userArgb = picked.reset ? null : picked.color!.toARGB32() | 0xFF000000;
        _resetLegacyColor = picked.reset && _hasLegacyColor;
      });
    } finally {
      if (mounted) setState(() => _pickingColor = false);
    }
  }

  void _changeStart(int value) {
    // 末节截断只改变当前结束节；往前移时仍恢复用户选择的连堂跨度。
    final desiredEnd = math.min(value + _requestedSpan, _nodes.last);
    setState(() {
      _start = value;
      _end = _nodes.lastWhere((node) => node <= desiredEnd);
    });
  }

  void _changeEnd(int value) {
    setState(() {
      _end = value;
      _requestedSpan = _end - _start;
    });
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _triedSave = true);
    if (!(_formKey.currentState?.validate() ?? false)) {
      _nameFocus.requestFocus();
      _reveal(_nameAnchor);
      return;
    }
    if (_isExam) {
      await _saveAsExam();
      return;
    }
    if (_weeks.isEmpty) {
      setState(() => _weeksError = true);
      _reveal(_weeksAnchor);
      return;
    }
    if (_isEdit && !_dirty) {
      _leave(_entryCourse, false);
      return;
    }
    FocusScope.of(context).unfocus();
    List<int>? applyWeeks;
    if (_isEdit) {
      setState(() => _choosingScope = true);
      try {
        if (_weeksChanged) {
          final confirmed = await confirmCourseWeekChange(
            context,
            before: _initialWeeks,
            after: _weeks,
          );
          if (!mounted || !confirmed) return;
        } else {
          final cell = widget.cell;
          final base = cell == null
              ? null
              : widget.controller.baseOccurrenceOf(cell);
          final currentWeek = cell?.date != null && cell!.activeThisWeek
              ? base?.week ?? widget.controller.weekOfDate(cell.date!)
              : null;
          final picked = await showCourseFormSaveScopeSheet(
            context,
            totalWeeks: _totalWeeks,
            courseWeeks: _initialWeeks,
            currentWeek: currentWeek,
            date: cell?.date,
          );
          if (!mounted || picked == null) return;
          applyWeeks = picked.weeks;
        }
      } finally {
        if (mounted) setState(() => _choosingScope = false);
      }
    }
    if (!mounted) return;
    setState(() => _saving = true);
    try {
      var completed = false;
      final saved = await withTimetablePersistenceFeedback(context, () async {
        final value = await widget.controller.saveCourseForm(
          initial: widget.initial ?? _entryCourse,
          initialSlot: widget.initialSlot ?? _entrySlot,
          cell: widget.cell,
          name: _name.text.trim(),
          teacher: _teacher.text.trim(),
          location: _location.text.trim(),
          note: _note.text.trim(),
          kind: _kind,
          day: _day,
          startNode: _start,
          endNode: _end,
          courseWeeks: _weeks.toList()..sort(),
          applyWeeks: applyWeeks,
          userArgb: _userArgb,
          colorChanged: _colorChanged,
        );
        completed = true;
        return value;
      });
      if (!mounted) return;
      if (saved != null) {
        _leave(saved, true);
      } else if (completed) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('课程未能保存，请检查上课安排后重试。')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveAsExam() async {
    final cell = widget.cell;
    if (cell == null || !cell.activeThisWeek || cell.date == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('仅支持改单周单节课，请从对应周的课程详情进入修改。')),
      );
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _choosingScope = true);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('改为考试'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('仅修改本周这节课'),
            SizedBox(height: 12),
            Text('其他周次和时段保持不变。'),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('course_form_exam_cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('course_form_exam_confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认保存'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => _choosingScope = false);
    if (confirmed != true) return;
    setState(() => _saving = true);
    try {
      var completed = false;
      final saved = await withTimetablePersistenceFeedback(context, () async {
        final exam = await widget.controller.convertCourseOccurrenceToExam(
          cell: cell,
          title: _name.text.trim(),
          location: _location.text.trim(),
          note: _note.text.trim(),
          day: _day,
          startNode: _start,
          endNode: _end,
        );
        completed = true;
        return exam;
      });
      if (!mounted) return;
      if (saved != null) {
        _leave(_entryCourse, true);
      } else if (completed) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('课程未能转为考试，请重新打开这次课程后重试。')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String get _clockText {
    final segments = resolveTimingSegments(
      periods: widget.controller.periods,
      startNode: _start,
      endNode: _end,
      kind: switch (_kind) {
        CourseKind.standard || CourseKind.exam => CourseTimingKind.standard,
        CourseKind.lab => CourseTimingKind.lab,
        CourseKind.pe => CourseTimingKind.pe,
      },
    );
    return segments.isEmpty
        ? '暂无对应作息时间'
        : segments
              .map((segment) => '${segment.start}–${segment.end}')
              .join('、');
  }

  InputDecoration _decoration({String? hint}) => InputDecoration(
    hintText: hint,
    isDense: true,
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: UnderlineInputBorder(
      borderSide: BorderSide(color: TimetableTheme.colorsOf(context).accent),
    ),
    contentPadding: const EdgeInsets.symmetric(vertical: 12),
  );

  Widget _row(String label, Widget child, {bool divider = true}) {
    final colors = TimetableTheme.colorsOf(context);
    final field = Semantics(label: label, child: child);
    final text = ExcludeSemantics(
      child: Text(
        label,
        style: TextStyle(color: colors.titleText, fontSize: 15),
      ),
    );
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      decoration: divider
          ? BoxDecoration(
              border: Border(bottom: BorderSide(color: colors.divider)),
            )
          : null,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (MediaQuery.textScalerOf(context).scale(16) > 23 ||
              constraints.maxWidth < 250) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [text, field],
              ),
            );
          }
          return Row(
            children: [
              SizedBox(width: 84, child: text),
              const SizedBox(width: 8),
              Expanded(child: field),
            ],
          );
        },
      ),
    );
  }

  Widget _textField({
    required String name,
    required String label,
    required TextEditingController controller,
    required FocusNode focus,
    FocusNode? nextFocus,
    GlobalKey? anchor,
    bool required = false,
    String? hint,
  }) => KeyedSubtree(
    key: anchor,
    child: _row(
      label,
      TextFormField(
        key: Key('$_prefix$name'),
        controller: controller,
        focusNode: focus,
        enabled: !_saving,
        style: TextStyle(
          color: TimetableTheme.colorsOf(context).titleText,
          fontSize: 16,
        ),
        textInputAction: TextInputAction.next,
        autovalidateMode: _triedSave
            ? AutovalidateMode.onUserInteraction
            : AutovalidateMode.disabled,
        onFieldSubmitted: (_) => nextFocus?.requestFocus(),
        decoration: _decoration(hint: hint),
        validator: required
            ? (value) => value == null || value.trim().isEmpty
                  ? (_isExam ? '请填写考试名称' : '请填写课程名称')
                  : null
            : null,
      ),
    ),
  );

  Widget _dropdown<T>({
    required Key key,
    required String label,
    required T value,
    required List<AppSelectOption<T>> options,
    required ValueChanged<T> onChanged,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: AppSelectFormField<T>(
      key: key,
      label: label,
      initialValue: value,
      textStyle: const TextStyle(fontSize: 16),
      options: options,
      onChanged: _saving ? null : onChanged,
    ),
  );

  Widget _periodFields() => LayoutBuilder(
    builder: (context, constraints) {
      final start = KeyedSubtree(
        key: const Key('course_form_start'),
        child: _dropdown<int>(
          key: Key('${_prefix}start'),
          label: '开始节次',
          value: _start,
          options: [
            for (final node in _nodes)
              AppSelectOption(value: node, label: '第 $node 节'),
          ],
          onChanged: _changeStart,
        ),
      );
      final end = KeyedSubtree(
        key: const Key('course_form_end'),
        child: _dropdown<int>(
          key: Key('${_prefix}end_$_start'),
          label: '结束节次',
          value: _end,
          options: [
            for (final node in _nodes.where((node) => node >= _start))
              AppSelectOption(value: node, label: '第 $node 节'),
          ],
          onChanged: _changeEnd,
        ),
      );
      final text = TextPainter(
        text: TextSpan(
          text: '第 ${_nodes.last} 节',
          style: DefaultTextStyle.of(context).style.copyWith(fontSize: 16),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      // 两侧内边距、箭头及其间距也要计入，防止窄屏把节次拆成多行。
      final requiredWidth = (text.width + 64) * 2 + 40;
      text.dispose();
      if (constraints.maxWidth < requiredWidth) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [start, const Text('至'), end],
        );
      }
      return Row(
        children: [
          Expanded(child: start),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text('至'),
          ),
          Expanded(child: end),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    _lastBuiltTextState = _textState;
    final colors = TimetableTheme.colorsOf(context);
    final examWeek = _isExam && widget.cell?.date != null
        ? widget.controller.weekOfDate(widget.cell!.date!)
        : null;
    final candidate = CourseSlot(
      day: _day,
      startNode: _start,
      endNode: _end,
      weeks: List.generate(
        _totalWeeks,
        (index) =>
            (examWeek == null
                ? _weeks.contains(index + 1)
                : examWeek == index + 1)
            ? '1'
            : '0',
      ).join(),
    );
    final conflict = _describeConflicts(candidate);
    final swatch = _userArgb == null
        ? TimetableTheme.autoCoursePair(
            _defaultColorIndex,
            dark: colors.isDark,
          ).bg
        : TimetableTheme.userCoursePair(
            Color(_userArgb!),
            dark: colors.isDark,
          ).bg;
    return PopScope<Object?>(
      canPop: _allowPop || (!_dirty && !_busy),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _requestClose();
      },
      child: Scaffold(
        backgroundColor: colors.surface,
        resizeToAvoidBottomInset: !_pickingColor,
        appBar: AppBar(
          title: Text(_isEdit ? '编辑课程' : '添加课程'),
          backgroundColor: colors.surface,
          surfaceTintColor: Colors.transparent,
          leading: IconButton(
            key: const Key('course_form_close'),
            tooltip: '关闭',
            onPressed: _busy ? null : _requestClose,
            icon: const Icon(Icons.close),
          ),
        ),
        body: SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                children: [
                  Expanded(
                    child: Form(
                      key: _formKey,
                      child: SingleChildScrollView(
                        key: const Key('course_form_scroll'),
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        // 键盘推动视口和光标滚动时复用表单绘制，不重画屏外控件。
                        child: RepaintBoundary(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _textField(
                                name: 'name',
                                label: _isExam ? '考试名称' : '课程名称',
                                controller: _name,
                                focus: _nameFocus,
                                nextFocus: _isExam
                                    ? _locationFocus
                                    : _teacherFocus,
                                anchor: _nameAnchor,
                                required: true,
                                hint: '必填',
                              ),
                              _row(
                                '课程类型',
                                _dropdown<CourseKind>(
                                  key: const Key('course_form_kind'),
                                  label: '课程类型',
                                  value: _kind,
                                  options: [
                                    const AppSelectOption(
                                      value: CourseKind.standard,
                                      label: '普通课',
                                    ),
                                    const AppSelectOption(
                                      value: CourseKind.lab,
                                      label: '实验课',
                                    ),
                                    const AppSelectOption(
                                      value: CourseKind.pe,
                                      label: '体育课',
                                    ),
                                    if (_isEdit)
                                      const AppSelectOption(
                                        value: CourseKind.exam,
                                        label: '考试',
                                      ),
                                  ],
                                  onChanged: (value) =>
                                      setState(() => _kind = value),
                                ),
                              ),
                              if (!_isExam)
                                _textField(
                                  name: 'teacher',
                                  label: '任课教师',
                                  controller: _teacher,
                                  focus: _teacherFocus,
                                  nextFocus: _locationFocus,
                                  hint: '选填',
                                ),
                              _textField(
                                name: 'location',
                                label: _isExam ? '考试地点' : '上课地点',
                                controller: _location,
                                focus: _locationFocus,
                                nextFocus: _noteFocus,
                                hint: '教室、实验室或场地',
                              ),
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: 24,
                                  bottom: 4,
                                ),
                                child: Text(
                                  _isExam ? '考试安排' : '上课安排',
                                  style: TextStyle(
                                    color: colors.labelText,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                              _row(
                                '星期',
                                _dropdown<int>(
                                  key: Key('${_prefix}day'),
                                  label: '星期',
                                  value: _day,
                                  options: [
                                    for (var day = 1; day <= 7; day++)
                                      AppSelectOption(
                                        value: day,
                                        label: _dayLabels[day - 1],
                                      ),
                                  ],
                                  onChanged: (value) =>
                                      setState(() => _day = value),
                                ),
                              ),
                              _row('节次', _periodFields()),
                              _row(
                                '实际时间',
                                Semantics(
                                  liveRegion: true,
                                  child: Text(
                                    _clockText,
                                    key: const Key('course_form_clock'),
                                    style: TextStyle(
                                      color: colors.labelText,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ),
                              KeyedSubtree(
                                key: _weeksAnchor,
                                child: KeyedSubtree(
                                  key: const Key('course_form_weeks'),
                                  child: _row(
                                    _isExam ? '考试周次' : '上课周次',
                                    _isExam
                                        ? Text(
                                            widget.cell?.date == null
                                                ? '请从对应周的课程详情进入'
                                                : '第 ${widget.controller.weekOfDate(widget.cell!.date!)} 周（仅这次课）',
                                          )
                                        : InkWell(
                                            key: Key('${_prefix}weeks'),
                                            onTap: _busy ? null : _pickWeeks,
                                            child: ConstrainedBox(
                                              constraints: const BoxConstraints(
                                                minHeight: 52,
                                              ),
                                              child: Row(
                                                children: [
                                                  Expanded(
                                                    child: Text(
                                                      _weeks.isEmpty
                                                          ? '请选择周次'
                                                          : formatWeeks(_weeks),
                                                    ),
                                                  ),
                                                  Icon(
                                                    Icons.chevron_right,
                                                    size: 20,
                                                    color: colors.chevron,
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                  ),
                                ),
                              ),
                              if (_weeksError && !_isExam)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(
                                    '请至少选择一周',
                                    style: TextStyle(color: colors.danger),
                                  ),
                                ),
                              if (conflict != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Icon(
                                        Icons.info_outline,
                                        size: 20,
                                        color: colors.warning,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          '$conflict，仍可保存。',
                                          key: Key('${_prefix}conflict'),
                                          style: TextStyle(
                                            color: colors.labelText,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              Padding(
                                key: _noteAnchor,
                                padding: const EdgeInsets.only(top: 20),
                                child: TextFormField(
                                  key: Key('${_prefix}note'),
                                  controller: _note,
                                  focusNode: _noteFocus,
                                  enabled: !_saving,
                                  minLines: 2,
                                  maxLines: 5,
                                  style: TextStyle(
                                    color: colors.titleText,
                                    fontSize: 16,
                                  ),
                                  decoration: InputDecoration(
                                    labelText: '备注（选填）',
                                    hintText: '例如：记得带实验报告',
                                    alignLabelWithHint: true,
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    contentPadding: const EdgeInsets.all(12),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              if (!_isExam)
                                _row(
                                  '课程颜色',
                                  InkWell(
                                    key: Key('${_prefix}color'),
                                    onTap: _busy ? null : _pickColor,
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        minHeight: 52,
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 14,
                                            height: 14,
                                            decoration: BoxDecoration(
                                              color: swatch,
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: colors.divider,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              _userArgb == null ? '自动' : '自选颜色',
                                            ),
                                          ),
                                          Icon(
                                            Icons.chevron_right,
                                            size: 20,
                                            color: colors.chevron,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  divider: false,
                                ),
                              const SizedBox(height: 12),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        key: Key('${_prefix}save'),
                        onPressed: _busy ? null : _save,
                        style: FilledButton.styleFrom(
                          backgroundColor: colors.accent,
                          // 实心品牌色按钮上的白字在明暗主题下保持一致。
                          foregroundColor: Colors.white,
                          minimumSize: const Size(0, 48),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: _saving
                            ? const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  ),
                                  SizedBox(width: 10),
                                  Text('保存中…'),
                                ],
                              )
                            : Text(_isEdit ? '保存修改' : '添加课程'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 描述与候选时段重叠的课程；提示不阻止用户保存。
String? describeManualConflicts(CourseSlot candidate, List<Course> conflicts) {
  if (conflicts.isEmpty) return null;
  if (conflicts.length > 1) return '与 ${conflicts.length} 门课冲突';
  final course = conflicts.single;
  final common = <int>{};
  for (final slot in course.slots) {
    if (!slotsConflict(slot, candidate)) continue;
    for (var week = 1; week <= candidate.weeks.length; week++) {
      if (slot.hasClassInWeek(week) && candidate.hasClassInWeek(week)) {
        common.add(week);
      }
    }
  }
  if (common.isEmpty) return '与「${course.name}」冲突';
  return '与「${course.name}」${formatWeeks(common)}冲突';
}
