import 'package:flutter/material.dart';

import 'timetable_colors.dart';
import 'timetable_controller.dart';
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
}) {
  return Navigator.of(context).push<Course>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ManualCourseForm(
        controller: controller,
        initial: initial,
        initialSlot: initialSlot,
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
  });

  final TimetableController controller;
  final Course? initial;
  final CourseSlot? initialSlot;

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

  /// 用户自选色号；null = 未选（跟随默认配色）。
  int? _colorIndex;
  bool _saving = false;
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
    setState(() => _saving = true);
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
    final initial = widget.initial;
    if (initial != null) {
      final slots = [...initial.slots];
      final idx = widget.initialSlot == null
          ? -1
          : slots.indexOf(widget.initialSlot!);
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
    if (!mounted) return;
    navigator.pop(saved);
  }

  /// 当前表单对应的周次位串（下标 0 = 第 1 周）。
  String get _weekBits => List.generate(
    _totalWeeks,
    (i) => _weeks.contains(i + 1) ? '1' : '0',
  ).join();

  /// 预览色号：用户自选优先，否则按 [courseColorIndex] 的默认规则。
  int get _previewColorIndex {
    final name = _name.text.trim();
    final base = (widget.initial ?? const Course(id: '', name: '')).copyWith(
      name: name,
      colorIndex: _colorIndex,
      clearColor: _colorIndex == null,
    );
    return courseColorIndex(widget.controller, base);
  }

  Future<void> _pickColor() async {
    // MVP 仅浅色色板（暗色为 P1）：不随系统暗色切换。
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('选择颜色', style: TimetableTheme.titleStyle()),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (var i = 0; i < kCoursePaletteSize; i++)
                    InkResponse(
                      key: Key('manual_course_color_$i'),
                      onTap: () => Navigator.pop(ctx, i),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: TimetableTheme.courseColor(
                            i,
                            scheme: coursePaletteSchemeFor(widget.controller),
                          ),
                          shape: BoxShape.circle,
                          border: i == _previewColorIndex
                              ? Border.all(
                                  color: TimetableTheme.titleText,
                                  width: 2,
                                )
                              : null,
                        ),
                        child: i == _previewColorIndex
                            ? Icon(
                                Icons.check,
                                size: 20,
                                color: TimetableTheme.courseTextColor(
                                  i,
                                  scheme: coursePaletteSchemeFor(
                                    widget.controller,
                                  ),
                                ),
                              )
                            : null,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && mounted) setState(() => _colorIndex = picked);
  }

  @override
  Widget build(BuildContext context) {
    final nodes = _nodes;
    final dark = Theme.of(context).brightness == Brightness.dark;
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
          primary: TimetableTheme.accent,
          onPrimary: Colors.white,
        ),
      ),
      child: _buildScaffold(context, nodes, dark, conflict),
    );
  }

  Widget _buildScaffold(
    BuildContext context,
    List<int> nodes,
    bool dark,
    String? conflict,
  ) {
    return Scaffold(
      backgroundColor: TimetableTheme.surface,
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
                  backgroundColor: TimetableTheme.accent,
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
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    key: const Key('manual_course_color_preview'),
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      // 预览用当前配色方案的浅色底。
                      color: TimetableTheme.courseColor(
                        _previewColorIndex,
                        scheme: coursePaletteSchemeFor(widget.controller),
                      ),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
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
                  style: const TextStyle(
                    fontSize: 12,
                    color: TimetableTheme.warning,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text('周次', style: TimetableTheme.bodyStyle()),
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
                    selectedColor: TimetableTheme.accent,
                    backgroundColor: dark
                        ? const Color(0xFF2A2C31)
                        : const Color(0xFFF0F1F3),
                    side: BorderSide.none,
                    labelStyle: TextStyle(
                      color: _weeks.contains(w)
                          ? Colors.white
                          : (dark ? Colors.white70 : TimetableTheme.labelText),
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
