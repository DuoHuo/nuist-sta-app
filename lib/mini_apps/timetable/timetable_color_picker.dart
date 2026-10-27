import 'package:flutter/material.dart';

import 'timetable_controller.dart';
import 'timetable_course_color.dart';
import 'timetable_date_edits.dart';
import 'timetable_models.dart';
import 'timetable_theme.dart';

/// 选色结果：原始颜色或恢复默认；关闭面板返回 null。
@immutable
class TimetableColorPick {
  const TimetableColorPick.color(Color this.color) : reset = false;
  const TimetableColorPick.reset() : color = null, reset = true;

  final Color? color;
  final bool reset;
}

/// 连续选色面板：实时课表预览、饱和度/明度方盘、色相条和色号输入。
/// 所有修改先留在面板中，点保存才返回；色号无需键盘提交即可生效。
Future<TimetableColorPick?> showTimetableColorPicker(
  BuildContext context, {
  required Color current,
  Color? defaultColor,
  bool showReset = false,
  String title = '课程颜色',
  String previewTitle = '课程名称',
  bool forExam = false,
  int opacity = 100,
  CellTextColorMode textColorMode = CellTextColorMode.auto,
}) {
  // ModalBottomSheet 会随键盘高度更新；复用同一个内容实例，避免整棵选色树被重建。
  final picker = _ColorPicker(
    current: current,
    defaultColor: defaultColor ?? current,
    showReset: showReset,
    title: title,
    previewTitle: previewTitle,
    forExam: forExam,
    opacity: opacity,
    textColorMode: textColorMode,
  );
  return showModalBottomSheet<TimetableColorPick>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => picker,
  );
}

class _ColorPicker extends StatefulWidget {
  const _ColorPicker({
    required this.current,
    required this.defaultColor,
    required this.showReset,
    required this.title,
    required this.previewTitle,
    required this.forExam,
    required this.opacity,
    required this.textColorMode,
  });

  final Color current;
  final Color defaultColor;
  final bool showReset;
  final String title;
  final String previewTitle;
  final bool forExam;
  final int opacity;
  final CellTextColorMode textColorMode;

  @override
  State<_ColorPicker> createState() => _ColorPickerState();
}

class _ColorPickerState extends State<_ColorPicker> {
  late final ValueNotifier<HSVColor> _hsv;
  late final TextEditingController _hex;
  final _valid = ValueNotifier(true);
  bool _reset = false;

  @override
  void initState() {
    super.initState();
    _hsv = ValueNotifier(HSVColor.fromColor(widget.current));
    _hex = TextEditingController(text: _hexOf(widget.current));
  }

  @override
  void dispose() {
    _hsv.dispose();
    _valid.dispose();
    _hex.dispose();
    super.dispose();
  }

  void _setHsv(HSVColor next) {
    _reset = false;
    _valid.value = true;
    _hsv.value = next;
    final text = _hexOf(next.toColor());
    _hex.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _changeHex(String value) {
    final parsed = _parseHex(value);
    _valid.value = parsed != null;
    _reset = false;
    if (parsed != null) _hsv.value = HSVColor.fromColor(parsed);
  }

  void _restoreDefault() {
    _setHsv(HSVColor.fromColor(widget.defaultColor));
    _reset = true;
  }

  void _save() {
    final color = _parseHex(_hex.text);
    if (color == null) return;
    Navigator.pop(
      context,
      _reset
          ? const TimetableColorPick.reset()
          : TimetableColorPick.color(color),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return Material(
      color: colors.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: SafeArea(
        child: _KeyboardInset(
          child: SingleChildScrollView(
            key: const Key('tt_color_picker'),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: colors.divider,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.title,
                            style: TimetableTheme.titleStyle(
                              color: colors.titleText,
                            ),
                          ),
                        ),
                        if (widget.showReset)
                          TextButton(
                            key: const Key('tt_color_reset'),
                            onPressed: _restoreDefault,
                            child: Text(
                              '恢复默认',
                              style: TextStyle(color: colors.labelText),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ValueListenableBuilder<HSVColor>(
                      valueListenable: _hsv,
                      builder: (context, hsv, _) {
                        final raw = Color(hsv.toColor().toARGB32());
                        final pair = widget.forExam
                            ? CourseColorPair(
                                TimetableTheme.examCellBg(
                                  raw,
                                  dark: colors.isDark,
                                ),
                                TimetableTheme.examText,
                              )
                            : TimetableTheme.userCoursePair(
                                raw,
                                dark: colors.isDark,
                              );
                        final bg = TimetableTheme.blendCellBg(
                          pair.bg,
                          widget.opacity,
                          dark: colors.isDark,
                        );
                        final autoFg = widget.forExam
                            ? pair.fg
                            : TimetableTheme.userCoursePair(bg).fg;
                        final fg = TimetableTheme.cellTextFor(
                          autoFg,
                          widget.textColorMode,
                        );
                        return Container(
                          key: const Key('tt_color_display_swatch'),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: bg,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.previewTitle,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: fg,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                widget.opacity == 100
                                    ? '课表效果预览'
                                    : '课表效果预览 · 不透明度 ${widget.opacity}%',
                                style: TextStyle(color: fg, fontSize: 12),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 20),
                    RepaintBoundary(
                      child: ValueListenableBuilder<HSVColor>(
                        valueListenable: _hsv,
                        builder: (context, hsv, _) => LayoutBuilder(
                          builder: (context, constraints) => _SvPanel(
                            key: const Key('tt_color_sv_panel'),
                            width: constraints.maxWidth,
                            height: (constraints.maxWidth * 0.58).clamp(
                              150.0,
                              220.0,
                            ),
                            hsv: hsv,
                            onChanged: _setHsv,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    RepaintBoundary(
                      child: ValueListenableBuilder<HSVColor>(
                        valueListenable: _hsv,
                        builder: (context, hsv, _) => _HueSlider(
                          hsv: hsv,
                          onChanged: (hue) => _setHsv(_hsv.value.withHue(hue)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ValueListenableBuilder<bool>(
                      valueListenable: _valid,
                      builder: (context, valid, _) => TextField(
                        key: const Key('tt_color_hex'),
                        controller: _hex,
                        keyboardType: TextInputType.visiblePassword,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.done,
                        style: TextStyle(
                          color: colors.titleText,
                          letterSpacing: 1,
                        ),
                        decoration: InputDecoration(
                          labelText: '色号',
                          hintText: 'RRGGBB',
                          prefixText: '# ',
                          filled: true,
                          fillColor: colors.pageBg,
                          errorText: valid ? null : '请输入 6 位十六进制色号，如 3B82F6',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onChanged: _changeHex,
                        onSubmitted: (_) => FocusScope.of(context).unfocus(),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 48,
                            child: TextButton(
                              key: const Key('tt_color_cancel'),
                              onPressed: () => Navigator.pop(context),
                              child: Text(
                                '取消',
                                style: TextStyle(color: colors.labelText),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: SizedBox(
                            height: 48,
                            child: ValueListenableBuilder<bool>(
                              valueListenable: _valid,
                              builder: (context, valid, _) => FilledButton(
                                key: const Key('tt_color_custom_apply'),
                                onPressed: valid ? _save : null,
                                style: FilledButton.styleFrom(
                                  backgroundColor: colors.accent,
                                  // 品牌色按钮上的白字保持明暗一致。
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                child: const Text('保存'),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 只订阅键盘高度；键盘动画不会重建选色器的静态内容和色盘。
class _KeyboardInset extends StatelessWidget {
  const _KeyboardInset({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: child,
  );
}

/// 方盘呈现原始色谱，因此渐变、游标的黑白色不跟随界面主题。
class _SvPanel extends StatelessWidget {
  const _SvPanel({
    super.key,
    required this.width,
    required this.height,
    required this.hsv,
    required this.onChanged,
  });

  final double width;
  final double height;
  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  void _change(Offset local) => onChanged(
    hsv
        .withSaturation((local.dx / width).clamp(0.0, 1.0))
        .withValue((1 - local.dy / height).clamp(0.0, 1.0)),
  );

  @override
  Widget build(BuildContext context) => Semantics(
    label: '饱和度与明度',
    value:
        '饱和度 ${(hsv.saturation * 100).round()}%，明度 ${(hsv.value * 100).round()}%',
    child: SizedBox(
      width: width,
      height: height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanDown: (details) => _change(details.localPosition),
        onPanUpdate: (details) => _change(details.localPosition),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.white,
                      HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor(),
                    ],
                  ),
                ),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black],
                  ),
                ),
              ),
              Positioned(
                left: (hsv.saturation * width - 11).clamp(0.0, width - 22),
                top: ((1 - hsv.value) * height - 11).clamp(0.0, height - 22),
                child: IgnorePointer(
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: hsv.toColor(),
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: const [
                        BoxShadow(color: Colors.black38, blurRadius: 3),
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
}

/// 水平色相条保留 Slider 的键盘、无障碍和拖动行为。
class _HueSlider extends StatelessWidget {
  const _HueSlider({required this.hsv, required this.onChanged});
  final HSVColor hsv;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: Stack(
      alignment: Alignment.center,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Container(
            height: 18,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              // 原始色相谱，明暗主题共用。
              gradient: LinearGradient(
                colors: [
                  for (var hue = 0; hue <= 360; hue += 60)
                    HSVColor.fromAHSV(1, hue.toDouble(), 1, 1).toColor(),
                ],
              ),
            ),
          ),
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 18,
            activeTrackColor: Colors.transparent,
            inactiveTrackColor: Colors.transparent,
            thumbColor: HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor(),
            overlayColor: TimetableTheme.colorsOf(context).accentSoft,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12),
            trackShape: const RoundedRectSliderTrackShape(),
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
          child: Slider(
            key: const Key('tt_color_hue'),
            value: hsv.hue,
            max: 360,
            semanticFormatterCallback: (value) => '色相 ${value.round()} 度',
            onChanged: onChanged,
          ),
        ),
      ],
    ),
  );
}

String _hexOf(Color color) => color
    .toARGB32()
    .toRadixString(16)
    .padLeft(8, '0')
    .substring(2)
    .toUpperCase();

Color? _parseHex(String raw) {
  final value = raw.trim().replaceFirst(RegExp(r'^#'), '');
  if (!RegExp(r'^(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$').hasMatch(value)) {
    return null;
  }
  return Color(int.parse(value, radix: 16) | 0xFF000000);
}

/// 选色保存后的范围选择；关闭面板即取消保存。
Future<EditScope?> showCourseColorScopeSheet(
  BuildContext context, {
  required GridCell cell,
}) => showModalBottomSheet<EditScope>(
  context: context,
  backgroundColor: TimetableTheme.colorsOf(context).surface,
  builder: (context) {
    final colors = TimetableTheme.colorsOf(context);
    final date = cell.date!;
    return SafeArea(
      child: Padding(
        key: const Key('course_color_scope_sheet'),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '颜色应用到哪里？',
              style: TimetableTheme.titleStyle(color: colors.titleText),
            ),
            const SizedBox(height: 16),
            ListTile(
              key: const Key('course_color_scope_this'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.event_outlined, color: colors.accent),
              title: const Text('仅本周这节课'),
              subtitle: Text(
                '${date.month}月${date.day}日 · 第 ${cell.slot.startNode}–${cell.slot.endNode} 节',
              ),
              trailing: Icon(Icons.chevron_right, color: colors.chevron),
              onTap: () => Navigator.pop(context, EditScope.thisDay),
            ),
            Divider(color: colors.divider),
            ListTile(
              key: const Key('course_color_scope_all'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.date_range_outlined, color: colors.hint),
              title: const Text('应用到全局'),
              subtitle: const Text('这门课的所有周次和时段'),
              trailing: Icon(Icons.chevron_right, color: colors.chevron),
              onTap: () => Navigator.pop(context, EditScope.allWeeks),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('取消', style: TextStyle(color: colors.labelText)),
            ),
          ],
        ),
      ),
    );
  },
);

/// 课程详情的颜色入口，只显示文字与箭头；有具体日期时保存前选择范围。
class CourseColorRow extends StatelessWidget {
  const CourseColorRow({
    super.key,
    required this.controller,
    required this.course,
    this.cell,
  });

  final TimetableController controller;
  final Course course;
  final GridCell? cell;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final user = controller.userColorOf(course);
    final raw = user == null
        ? coursePairFor(controller, course, dark: colors.isDark).bg
        : Color(user);
    final base = cell == null ? null : controller.baseOccurrenceOf(cell!);
    final fallback = cell?.dateEdit?.color != null
        ? coursePairFor(
            controller,
            base?.course ?? course,
            dark: colors.isDark,
          ).bg
        : TimetableTheme.autoCoursePair(
            coursePresetIndexForCourse(
              course,
              colorName: controller.colorNameOf(course),
            ),
            dark: colors.isDark,
          ).bg;
    return InkWell(
      key: const Key('course_detail_color'),
      onTap: () async {
        final pick = await showTimetableColorPicker(
          context,
          current: raw,
          defaultColor: fallback,
          showReset: user != null,
          previewTitle: course.name,
          opacity: controller.settings.cellOpacity,
          textColorMode: controller.settings.cellTextColor,
        );
        if (pick == null || !context.mounted) return;
        final occurrence = cell;
        final scope = occurrence?.date != null && occurrence!.activeThisWeek
            ? await showCourseColorScopeSheet(context, cell: occurrence)
            : EditScope.allWeeks;
        if (scope == null || !context.mounted) return;
        final value = pick.reset ? null : pick.color!.toARGB32();
        if (scope == EditScope.thisDay) {
          final ok = await controller.setOccurrenceColor(occurrence!, value);
          if (!ok && context.mounted) {
            ScaffoldMessenger.maybeOf(
              context,
            )?.showSnackBar(const SnackBar(content: Text('颜色保存失败，请重新打开课程后重试')));
          }
        } else {
          await controller.setUserCourseColor(
            base?.course.id ?? course.id,
            value,
          );
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              Icon(Icons.palette_outlined, size: 20, color: colors.hint),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '颜色',
                  style: TimetableTheme.bodyStyle(color: colors.labelText),
                ),
              ),
              Icon(Icons.chevron_right, color: colors.chevron),
            ],
          ),
        ),
      ),
    );
  }
}
