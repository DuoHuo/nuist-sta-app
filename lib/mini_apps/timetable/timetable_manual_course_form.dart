import 'package:flutter/material.dart';

import 'timetable_color_picker.dart';
import 'timetable_colors.dart';
import 'timetable_controller.dart';
import 'timetable_date_edits.dart';
import 'timetable_apply_weeks_sheet.dart';
import 'timetable_models.dart';
import 'timetable_theme.dart';
import 'timetable_course_color.dart';
import 'timetable_week_format.dart';

/// 打开手动课程表单。[initial] 非空时为编辑模式（[initialSlot] 指定编辑哪一段时段）。
/// 返回保存后的课程；取消返回 null。
Future<Course?> showManualCourseForm(
  BuildContext context, {
  required TimetableController controller,
  Course? initial,
  CourseSlot? initialSlot,
  GridCell? cell,
}) {
  return Navigator.of(context).push<Course>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ManualCourseForm(
        controller: controller,
        initial: initial,
        initialSlot: initialSlot,
        cell: cell,
      ),
    ),
  );
}

const _dayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

class ManualCourseForm extends StatefulWidget {
  const ManualCourseForm({
    super.key,
    required this.controller,
    this.initial,
    this.initialSlot,
    this.cell,
  });

  final TimetableController controller;
  final Course? initial;
  final CourseSlot? initialSlot;

  /// 从周视图某一格进来编辑时传入（第 1 条：保存时可选「只改这一天」）。
  /// 为空时（如从列表进来）按所有周保存，与以前一致。
  final GridCell? cell;

  @override
  State<ManualCourseForm> createState() => _ManualCourseFormState();
}

class _ManualCourseFormState extends State<ManualCourseForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _location;
  late final TextEditingController _teacher;
  late final TextEditingController _note;
  late int _day;
  late int _start;
  late int _end;
  late Set<int> _weeks;

  /// 编辑应用周数（与课程「周次」分开）；仅从格子进来时有意义。
  late Set<int> _applyWeeks;

  /// 旧色号字段（仍写入 Course.colorIndex，兼容旧数据）。
  int? _colorIndex;

  /// 用户自选原始 ARGB；null 表示使用默认色。
  int? _userArgb;
  int? _initialUserArgb;
  EditScope _colorScope = EditScope.allWeeks;
  bool _userArgbCleared = false;
  bool _saving = false;
  bool _pickingColor = false;
  String? _weeksError;

  bool get _isEdit => widget.initial != null;

  /// 周次选择范围：max(学期总周数, 20)。
  int get _totalWeeks {
    final t = widget.controller.totalWeeks;
    return t > 20 ? t : 20;
  }

  /// 可选节次：优先取课表已启用的节次，否则按设置的每日节数。
  List<int> get _nodes {
    final periods = widget.controller.periods;
    if (periods.isNotEmpty) {
      return [for (final p in periods) p.node]..sort();
    }
    final n = widget.controller.settings.nodesPerDay;
    return [for (var i = 1; i <= (n < 1 ? 12 : n); i++) i];
  }

  @override
  void initState() {
    super.initState();
    final c = widget.initial;
    final slot =
        widget.initialSlot ??
        (c != null && c.slots.isNotEmpty ? c.slots.first : null);
    _name = TextEditingController(text: c?.name ?? '')
      ..addListener(_onNameChanged);
    _colorIndex = c?.colorIndex;
    if (c != null) {
      _userArgb = widget.controller.userColorOf(c);
      _initialUserArgb = _userArgb;
    }
    _location = TextEditingController(text: slot?.location ?? '');
    _teacher = TextEditingController(text: slot?.teacher ?? '');
    _note = TextEditingController(text: slot?.note ?? '');
    final nodes = _nodes;
    _day = (slot != null && slot.day >= 1 && slot.day <= 7) ? slot.day : 1;
    _start = slot != null && nodes.contains(slot.startNode)
        ? slot.startNode
        : nodes.first;
    _end =
        slot != null && nodes.contains(slot.endNode) && slot.endNode >= _start
        ? slot.endNode
        : _start;
    if (slot != null) {
      _weeks = {
        for (var w = 1; w <= _totalWeeks; w++)
          if (slot.hasClassInWeek(w)) w,
      };
    } else {
      _weeks = {for (var w = 1; w <= _totalWeeks; w++) w};
    }
    _init = (
      name: _name.text,
      location: _location.text,
      teacher: _teacher.text,
      note: _note.text,
      day: _day,
      start: _start,
      end: _end,
      weeks: {..._weeks},
      color: _colorIndex,
    );
    final cell = widget.cell;
    if (cell?.date != null && cell!.activeThisWeek) {
      final w = widget.controller.weekOfDate(cell.date!);
      _applyWeeks = {if (w >= 1) w};
    } else {
      final total = widget.controller.totalWeeks;
      _applyWeeks = {for (var w = 1; w <= total; w++) w};
    }
  }

  /// 打开表单时的值（第 1 条：判断改了哪些、只改这一天时只记改过的字段）。
  late final ({
    String name,
    String location,
    String teacher,
    String note,
    int day,
    int start,
    int end,
    Set<int> weeks,
    int? color,
  })
  _init;

  Future<void> _persistUserColor(TimetableController c, String courseId) async {
    if (_userArgb == _initialUserArgb && !_userArgbCleared) return;
    if (_colorScope == EditScope.thisDay && widget.cell != null) {
      await c.setOccurrenceColor(
        widget.cell!,
        _userArgbCleared ? null : _userArgb,
      );
      return;
    }
    if (_userArgbCleared) {
      await c.setUserCourseColor(courseId, null);
      return;
    }
    if (_userArgb != null) {
      await c.setUserCourseColor(courseId, _userArgb);
    }
  }

  void _onNameChanged() {
    // 默认色随课名变化；冲突提示也会重算。
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _name.removeListener(_onNameChanged);
    _name.dispose();
    _location.dispose();
    _teacher.dispose();
    _note.dispose();
    super.dispose();
  }

  void _quickPick(int mode) {
    setState(() {
      _weeksError = null;
      _weeks = {
        for (var w = 1; w <= _totalWeeks; w++)
          if (mode == 0 || (mode == 1 && w.isOdd) || (mode == 2 && w.isEven)) w,
      };
    });
  }

  static String weeksLabelOf(List<int> weeks) => formatWeeks(weeks);

  Future<void> _save() async {
    final ok = _formKey.currentState!.validate();
    if (_weeks.isEmpty) {
      setState(() => _weeksError = '请至少选择一周');
      return;
    }
    if (!ok || _saving) return;
    final colorCell = widget.cell;
    if ((_userArgb != _initialUserArgb || _userArgbCleared) &&
        colorCell?.date != null &&
        colorCell!.activeThisWeek) {
      final scope = await showCourseColorScopeSheet(context, cell: colorCell);
      if (scope == null || !mounted) return;
      _colorScope = scope;
    }
    setState(() => _saving = true);
    // 只调整颜色时不重写课程字段，避免把这次课的局部改名、备注扩散到全学期。
    if (_isEdit &&
        (_userArgb != _initialUserArgb || _userArgbCleared) &&
        _name.text.trim() == _init.name.trim() &&
        _teacher.text.trim() == _init.teacher.trim() &&
        _location.text.trim() == _init.location.trim() &&
        _note.text.trim() == _init.note.trim() &&
        _day == _init.day &&
        _start == _init.start &&
        _end == _init.end &&
        _weeks.length == _init.weeks.length &&
        _weeks.containsAll(_init.weeks)) {
      await _persistUserColor(widget.controller, widget.initial!.id);
      if (!mounted) return;
      Navigator.of(context).pop(widget.initial);
      return;
    }
    final sorted = _weeks.toList()..sort();
    final bits = _weekBits;
    final slot = CourseSlot(
      day: _day,
      startNode: _start,
      endNode: _end,
      weeks: bits,
      weeksLabel: weeksLabelOf(sorted),
      teacher: _teacher.text.trim(),
      location: _location.text.trim(),
      note: _note.text.trim(),
    );
    final navigator = Navigator.of(context);
    Course saved;
    var initial = widget.initial;
    // 第 1 条：从周视图格子编辑、周次没改、且改了这次课的字段 / 时间 → 先选范围。
    final cell = widget.cell;
    CourseSlot? baseSlot = widget.initialSlot;
    if (initial != null && cell != null && cell.date != null) {
      final base = widget.controller.baseOccurrenceOf(cell);
      if (base != null) {
        initial = widget.controller.manualCourseById(base.course.id) ?? initial;
        baseSlot = base.course.slots[base.slotIndex];
      }
      final weeksChanged =
          _weeks.length != _init.weeks.length ||
          !_weeks.containsAll(_init.weeks);
      final occurrenceChanged =
          _name.text.trim() != _init.name.trim() ||
          _teacher.text.trim() != _init.teacher.trim() ||
          _location.text.trim() != _init.location.trim() ||
          _note.text.trim() != _init.note.trim() ||
          _day != _init.day ||
          _start != _init.start ||
          _end != _init.end;
      if (!weeksChanged && occurrenceChanged && cell.activeThisWeek) {
        final total = widget.controller.totalWeeks;
        if (_applyWeeks.isEmpty) {
          if (mounted) {
            setState(() => _saving = false);
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              const SnackBar(
                behavior: SnackBarBehavior.floating,
                content: Text('请至少选择一周，或在「应用周数」里选「全选」'),
              ),
            );
          }
          return;
        }
        if (!isAllSemesterWeeks(_applyWeeks, total)) {
          final sorted = _applyWeeks.toList()..sort();
          String? changed(TextEditingController x, String init) =>
              x.text.trim() == init.trim() ? null : x.text.trim();
          final timeChanged =
              _day != _init.day || _start != _init.start || _end != _init.end;
          await widget.controller.editOccurrenceWeeks(
            cell,
            weeks: sorted,
            name: changed(_name, _init.name),
            teacher: changed(_teacher, _init.teacher),
            location: changed(_location, _init.location),
            note: changed(_note, _init.note),
            toDay: timeChanged ? _day : null,
            toStart: timeChanged ? _start : null,
            toEnd: timeChanged ? _end : null,
          );
          final base = widget.controller.manualCourseById(initial.id);
          if (base != null && _colorIndex != _init.color) {
            await widget.controller.updateManualCourse(
              base.copyWith(
                colorIndex: _colorIndex,
                clearColor: _colorIndex == null,
              ),
            );
          }
          await _persistUserColor(widget.controller, initial.id);
          if (!mounted) return;
          navigator.pop(
            widget.controller.manualCourseById(initial.id) ?? initial,
          );
          return;
        }
        // 所有周：这一天的单日修改里改过的字段让位给课程本身的新值。
        final de = cell.dateEdit;
        if (de != null) {
          await widget.controller.clearDateEditFields(
            de.id,
            name: _name.text.trim() != _init.name.trim(),
            teacher: _teacher.text.trim() != _init.teacher.trim(),
            location: _location.text.trim() != _init.location.trim(),
            note: _note.text.trim() != _init.note.trim(),
            move:
                _day != _init.day || _start != _init.start || _end != _init.end,
          );
        }
      }
    }
    if (initial != null) {
      final slots = [...initial.slots];
      final idx = baseSlot == null ? -1 : slots.indexOf(baseSlot);
      if (idx >= 0) {
        slots[idx] = slot;
      } else if (slots.isNotEmpty) {
        slots[0] = slot;
      } else {
        slots.add(slot);
      }
      saved = await widget.controller.updateManualCourse(
        initial.copyWith(
          name: _name.text.trim(),
          slots: slots,
          colorIndex: _colorIndex,
          clearColor: _colorIndex == null,
        ),
      );
    } else {
      saved = await widget.controller.addManualCourse(
        Course(
          id: '',
          name: _name.text.trim(),
          colorIndex: _colorIndex,
          slots: [slot],
        ),
      );
    }
    await _persistUserColor(widget.controller, saved.id);
    if (!mounted) return;
    navigator.pop(saved);
  }

  /// 当前表单对应的周次位串（下标 0 = 第 1 周）。
  String get _weekBits => List.generate(
    _totalWeeks,
    (i) => _weeks.contains(i + 1) ? '1' : '0',
  ).join();

  /// 预览自动色下标：与 [coursePairFor] 一致（已有课优先 id，新建按课名）。
  int get _previewColorIndex {
    final existing = widget.initial ?? widget.cell?.course;
    if (existing != null && existing.id.trim().isNotEmpty) {
      return coursePresetIndexForCourse(existing);
    }
    final name = _name.text.trim();
    if (name.isEmpty) return 0;
    return coursePresetIndexForName(name);
  }

  Future<void> _pickColor() async {
    final defaultColor = TimetableTheme.autoCoursePair(
      _previewColorIndex,
      dark: TimetableTheme.colorsOf(context).isDark,
    ).bg;
    final current = _userArgb == null ? defaultColor : Color(_userArgb!);
    setState(() => _pickingColor = true);
    final pick = await showTimetableColorPicker(
      context,
      current: current,
      defaultColor: defaultColor,
      showReset: _userArgb != null || _colorIndex != null,
      title: '颜色',
      previewTitle: _name.text.trim().isEmpty ? '课程名称' : _name.text.trim(),
      opacity: widget.controller.settings.cellOpacity,
      textColorMode: widget.controller.settings.cellTextColor,
    );
    if (!mounted) return;
    setState(() => _pickingColor = false);
    if (pick == null) return;
    setState(() {
      if (pick.reset) {
        _userArgb = null;
        _userArgbCleared = true;
        _colorIndex = null;
      } else {
        _userArgb = pick.color!.toARGB32() | 0xFF000000;
        _userArgbCleared = false;
        _colorIndex = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final nodes = _nodes;
    final colors = TimetableTheme.colorsOf(context);
    // 表单目前只有一个时段卡片：用它构造候选时段，交给 controller 判冲突。
    final candidate = CourseSlot(
      day: _day,
      startNode: _start,
      endNode: _end,
      weeks: _weekBits,
    );
    final conflict = describeManualConflicts(
      candidate,
      widget.controller.conflictsFor(candidate, excludeId: widget.initial?.id),
    );
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        colorScheme: theme.colorScheme.copyWith(
          primary: colors.accent,
          onPrimary: Colors.white,
        ),
      ),
      child: _buildScaffold(context, nodes, colors, conflict),
    );
  }

  Widget _buildScaffold(
    BuildContext context,
    List<int> nodes,
    TimetableColors colors,
    String? conflict,
  ) {
    return Scaffold(
      resizeToAvoidBottomInset: !_pickingColor,
      backgroundColor: colors.surface,
      appBar: AppBar(
        title: Text(_isEdit ? '编辑课程' : '添加课程'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: FilledButton(
                key: const Key('manual_course_save'),
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(
                  backgroundColor: colors.accent,
                  // accent 实心按钮上的白字，明暗都不变。
                  foregroundColor: Colors.white,
                  shape: const StadiumBorder(),
                  minimumSize: const Size(64, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                ),
                child: const Text('保存'),
              ),
            ),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              key: const Key('manual_course_name'),
              controller: _name,
              decoration: const InputDecoration(labelText: '课程名'),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '请输入课程名' : null,
            ),
            ListTile(
              key: const Key('manual_course_color'),
              contentPadding: EdgeInsets.zero,
              title: const Text('颜色'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _pickColor,
            ),
            DropdownButtonFormField<int>(
              key: const Key('manual_course_day'),
              initialValue: _day,
              decoration: const InputDecoration(labelText: '星期'),
              items: [
                for (var d = 1; d <= 7; d++)
                  DropdownMenuItem(value: d, child: Text(_dayLabels[d - 1])),
              ],
              onChanged: (v) => setState(() => _day = v ?? _day),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    key: const Key('manual_course_start'),
                    initialValue: _start,
                    decoration: const InputDecoration(labelText: '开始节'),
                    items: [
                      for (final n in nodes)
                        DropdownMenuItem(value: n, child: Text('第 $n 节')),
                    ],
                    onChanged: (v) => setState(() {
                      _start = v ?? _start;
                      if (_end < _start) _end = _start;
                    }),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    key: ValueKey('manual_course_end_$_start'),
                    initialValue: _end,
                    decoration: const InputDecoration(labelText: '结束节'),
                    items: [
                      for (final n in nodes.where((n) => n >= _start))
                        DropdownMenuItem(value: n, child: Text('第 $n 节')),
                    ],
                    onChanged: (v) => setState(() => _end = v ?? _end),
                  ),
                ),
              ],
            ),
            if (conflict != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  conflict,
                  key: const Key('manual_course_conflict'),
                  style: TextStyle(fontSize: 12, color: colors.warning),
                ),
              ),
            if (widget.cell?.date != null && widget.cell!.activeThisWeek) ...[
              const SizedBox(height: 8),
              ListTile(
                key: const Key('manual_edit_apply_weeks'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.date_range_outlined, color: colors.hint),
                title: Text(
                  '应用周数',
                  style: TimetableTheme.bodyStyle(color: colors.labelText),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      applyWeeksSummary(
                        _applyWeeks,
                        widget.controller.totalWeeks,
                      ),
                      key: const Key('manual_edit_apply_weeks_summary'),
                      style: TimetableTheme.bodyStyle(color: colors.hint),
                    ),
                    Icon(Icons.chevron_right, color: colors.hint),
                  ],
                ),
                onTap: _saving
                    ? null
                    : () async {
                        final picked = await showApplyWeeksSheet(
                          context,
                          totalWeeks: widget.controller.totalWeeks,
                          initial: _applyWeeks,
                        );
                        if (picked == null || !mounted) return;
                        setState(() => _applyWeeks = picked.toSet());
                      },
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  '周次',
                  style: TimetableTheme.bodyStyle(color: colors.labelText),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => _quickPick(0),
                  child: const Text('全部'),
                ),
                TextButton(
                  onPressed: () => _quickPick(1),
                  child: const Text('单周'),
                ),
                TextButton(
                  onPressed: () => _quickPick(2),
                  child: const Text('双周'),
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (var w = 1; w <= _totalWeeks; w++)
                  FilterChip(
                    key: Key('manual_course_week_$w'),
                    label: Text('$w'),
                    selected: _weeks.contains(w),
                    showCheckmark: false,
                    selectedColor: colors.accent,
                    backgroundColor: colors.chipBg,
                    side: BorderSide.none,
                    labelStyle: TextStyle(
                      // 选中态是 accent 实心底，上面压白字。
                      color: _weeks.contains(w)
                          ? Colors.white
                          : colors.labelText,
                    ),
                    onSelected: (sel) => setState(() {
                      _weeksError = null;
                      sel ? _weeks.add(w) : _weeks.remove(w);
                    }),
                  ),
              ],
            ),
            if (_weeksError != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _weeksError!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('manual_course_location'),
              controller: _location,
              decoration: const InputDecoration(labelText: '地点'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('manual_course_teacher'),
              controller: _teacher,
              decoration: const InputDecoration(labelText: '教师'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('manual_course_note'),
              controller: _note,
              decoration: const InputDecoration(labelText: '备注（选填）'),
              maxLines: 3,
              minLines: 1,
            ),
          ],
        ),
      ),
    );
  }
}

/// 冲突提示文案（spec §5，不阻断保存）：一门「与「课名」第 X–Y 周冲突」，多门「与 N 门课冲突」。
///
/// [conflicts] 应来自 `controller.conflictsFor(candidate, ...)`；
/// 单门时周次 = 该课与 [candidate] 冲突的时段周次与候选周次的交集。
String? describeManualConflicts(CourseSlot candidate, List<Course> conflicts) {
  if (conflicts.isEmpty) return null;
  if (conflicts.length > 1) return '与 ${conflicts.length} 门课冲突';
  final course = conflicts.single;
  final common = <int>{};
  for (final slot in course.slots) {
    if (!slotsConflict(slot, candidate)) continue;
    for (var w = 1; w <= candidate.weeks.length; w++) {
      if (slot.hasClassInWeek(w) && candidate.hasClassInWeek(w)) common.add(w);
    }
  }
  if (common.isEmpty) return '与「${course.name}」冲突';
  return '与「${course.name}」${formatWeeks(common)}冲突';
}
