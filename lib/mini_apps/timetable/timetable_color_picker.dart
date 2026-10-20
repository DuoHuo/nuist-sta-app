import 'package:flutter/material.dart';

import 'timetable_controller.dart';
import 'timetable_course_color.dart';
import 'timetable_models.dart';
import 'timetable_theme.dart';

/// [showTimetableColorPicker] 的结果：[color] 为选中的颜色；[reset] 为「恢复默认」。
@immutable
class TimetableColorPick {
  const TimetableColorPick.color(Color this.color) : reset = false;
  const TimetableColorPick.reset() : color = null, reset = true;

  final Color? color;
  final bool reset;
}

/// 颜色选择面板——大色块 4 列网格（预设）+ 末格「+」进 HSV 自定义 +
/// 可选「恢复默认」。只存原始 ARGB；大色块按课表显示规则换算（spec-next-1020b）。
Future<TimetableColorPick?> showTimetableColorPicker(
  BuildContext context, {
  required Color current,
  bool showReset = false,
  String title = '颜色',
  List<Color>? presets,

  /// 考试色预览走 [TimetableTheme.examCellBg]；课程走 [userCoursePair]。
  bool forExam = false,
}) {
  final colors = TimetableTheme.colorsOf(context);
  final options = presets ?? TimetableTheme.coursePresetColors;
  var hsv = HSVColor.fromColor(current);
  final hexCtrl = TextEditingController(text: _hexOf(current));
  // 当前色不在预设里时，默认展开 HSV，避免自定义色无处编辑。
  final currentArgb = current.toARGB32();
  var showHsv = !options.any((c) => c.toARGB32() == currentArgb);

  return showModalBottomSheet<TimetableColorPick>(
    context: context,
    isScrollControlled: true,
    backgroundColor: colors.surface,
    builder: (sheetContext) => SafeArea(
      child: StatefulBuilder(
        builder: (context, setState) {
          void setRaw(Color c) {
            hsv = HSVColor.fromColor(c);
            hexCtrl.text = _hexOf(c);
            setState(() {});
          }

          CourseColorPair displayOf(Color raw) {
            final dark = colors.isDark;
            if (forExam) {
              return CourseColorPair(
                TimetableTheme.examCellBg(raw, dark: dark),
                TimetableTheme.examText,
              );
            }
            return TimetableTheme.userCoursePair(raw, dark: dark);
          }

          final raw = hsv.toColor();
          final shown = displayOf(raw);

          Widget swatchCell({
            required Key key,
            required Color? fill,
            required VoidCallback onTap,
            required String semanticsLabel,
            bool selected = false,
            Widget? child,
          }) {
            return Semantics(
              button: true,
              selected: selected,
              label: semanticsLabel,
              excludeSemantics: true,
              child: InkWell(
                key: key,
                onTap: onTap,
                borderRadius: BorderRadius.circular(10),
                child: Ink(
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: selected ? colors.accent : colors.divider,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  child: child,
                ),
              ),
            );
          }

          return SingleChildScrollView(
            key: const Key('tt_color_picker'),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TimetableTheme.titleStyle(color: colors.titleText),
                ),
                const SizedBox(height: 12),
                // spec-next-1020 item 9：大色块用显示换算，旁标「课表中」。
                Row(
                  children: [
                    Container(
                      key: const Key('tt_color_display_swatch'),
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: shown.bg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: colors.divider),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        'Aa',
                        style: TextStyle(
                          color: shown.fg,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '课表中',
                            style: TimetableTheme.captionStyle(
                              color: colors.labelText,
                            ),
                          ),
                          const SizedBox(height: 4),
                          SizedBox(
                            height: 36,
                            child: TextField(
                              key: const Key('tt_color_hex'),
                              controller: hexCtrl,
                              style: TimetableTheme.bodyStyle(
                                color: colors.titleText,
                              ),
                              decoration: InputDecoration(
                                isDense: true,
                                prefixText: '#',
                                hintText: 'RRGGBB',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                              ),
                              onSubmitted: (v) {
                                final parsed = _parseHex(v);
                                if (parsed != null) {
                                  setRaw(parsed);
                                  setState(() => showHsv = true);
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // spec-next-1020b：大色块 4 列网格；末格「+」展开 HSV。
                LayoutBuilder(
                  builder: (context, constraints) {
                    const cols = 4;
                    const gap = 10.0;
                    final cellW =
                        (constraints.maxWidth - gap * (cols - 1)) / cols;
                    final cellH = cellW * 0.72;
                    // 色块本身用原始预设色（深色主题下仍为浅色）；「课表中」预览才走显示换算。
                    final cells = <Widget>[
                      for (var i = 0; i < options.length; i++)
                        SizedBox(
                          width: cellW,
                          height: cellH,
                          child: swatchCell(
                            key: Key('tt_color_preset_$i'),
                            fill: options[i],
                            selected:
                                options[i].toARGB32() == current.toARGB32(),
                            semanticsLabel: '预设颜色 ${i + 1}',
                            onTap: () => Navigator.pop(
                              sheetContext,
                              TimetableColorPick.color(options[i]),
                            ),
                            child: Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: options[i],
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: options[i].toARGB32() == current.toARGB32()
                                  ? Icon(Icons.check, color: colors.titleText)
                                  : null,
                            ),
                          ),
                        ),
                      SizedBox(
                        width: cellW,
                        height: cellH,
                        child: swatchCell(
                          key: const Key('tt_color_custom_plus'),
                          fill: colors.pageBg,
                          selected: showHsv,
                          semanticsLabel: '自定义颜色',
                          onTap: () => setState(() => showHsv = true),
                          child: Center(
                            child: Text(
                              '+',
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w300,
                                color: colors.titleText,
                                height: 1,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ];
                    return Wrap(spacing: gap, runSpacing: gap, children: cells);
                  },
                ),
                if (showHsv) ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text(
                        '自定义',
                        style: TimetableTheme.bodyStyle(
                          color: colors.titleText,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        key: const Key('tt_color_custom_preview'),
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: raw,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: colors.divider),
                        ),
                      ),
                    ],
                  ),
                  _slider(
                    key: const Key('tt_color_hue'),
                    label: '色相',
                    value: hsv.hue,
                    max: 360,
                    color: colors.labelText,
                    onChanged: (v) => setState(() {
                      hsv = hsv.withHue(v);
                      hexCtrl.text = _hexOf(hsv.toColor());
                    }),
                  ),
                  _slider(
                    key: const Key('tt_color_saturation'),
                    label: '饱和度',
                    value: hsv.saturation,
                    max: 1,
                    color: colors.labelText,
                    onChanged: (v) => setState(() {
                      hsv = hsv.withSaturation(v);
                      hexCtrl.text = _hexOf(hsv.toColor());
                    }),
                  ),
                  _slider(
                    key: const Key('tt_color_value'),
                    label: '明度',
                    value: hsv.value,
                    max: 1,
                    color: colors.labelText,
                    onChanged: (v) => setState(() {
                      hsv = hsv.withValue(v);
                      hexCtrl.text = _hexOf(hsv.toColor());
                    }),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      key: const Key('tt_color_custom_apply'),
                      style: FilledButton.styleFrom(
                        backgroundColor: colors.accent,
                      ),
                      onPressed: () => Navigator.pop(
                        sheetContext,
                        TimetableColorPick.color(hsv.toColor()),
                      ),
                      child: const Text('使用自定义颜色'),
                    ),
                  ),
                ],
                if (showReset) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: const Key('tt_color_reset'),
                      onPressed: () => Navigator.pop(
                        sheetContext,
                        const TimetableColorPick.reset(),
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: colors.labelText,
                      ),
                      child: const Text('恢复默认'),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    ),
  ).whenComplete(hexCtrl.dispose);
}

String _hexOf(Color c) =>
    c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase();

Color? _parseHex(String raw) {
  var s = raw.trim();
  if (s.startsWith('#')) s = s.substring(1);
  if (s.length == 6) {
    final v = int.tryParse(s, radix: 16);
    if (v == null) return null;
    return Color(0xFF000000 | v);
  }
  if (s.length == 8) {
    final v = int.tryParse(s, radix: 16);
    if (v == null) return null;
    return Color(v);
  }
  return null;
}

Widget _slider({
  required Key key,
  required String label,
  required double value,
  required double max,
  required Color color,
  required ValueChanged<double> onChanged,
}) => Row(
  children: [
    SizedBox(
      width: 48,
      child: Text(label, style: TimetableTheme.captionStyle(color: color)),
    ),
    Expanded(
      child: Slider(
        key: key,
        value: value.clamp(0, max).toDouble(),
        max: max,
        onChanged: onChanged,
      ),
    ),
  ],
);

/// 课程详情里的「颜色」行（item 9）：色块 + 「自定义 / 默认」，点开 [showTimetableColorPicker]。
class CourseColorRow extends StatelessWidget {
  const CourseColorRow({
    super.key,
    required this.controller,
    required this.course,
  });

  final TimetableController controller;
  final Course course;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final colors = TimetableTheme.colorsOf(context);
        final user = controller.userColorOf(course);
        final shown = coursePairFor(controller, course).bg;
        return Semantics(
          button: true,
          excludeSemantics: true,
          label: user == null ? '颜色，默认' : '颜色，已自选',
          child: InkWell(
            key: const Key('course_detail_color'),
            onTap: () async {
              final pick = await showTimetableColorPicker(
                context,
                current: shown,
                showReset: user != null,
              );
              if (pick == null) return;
              await controller.setUserCourseColor(
                course.id,
                pick.reset ? null : pick.color!.toARGB32(),
              );
            },
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Icon(Icons.palette_outlined, size: 20, color: colors.hint),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        user == null ? '颜色（默认）' : '颜色（已自选）',
                        style: TimetableTheme.bodyStyle(
                          color: colors.labelText,
                        ),
                      ),
                    ),
                    Container(
                      key: const Key('course_detail_color_swatch'),
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: shown,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: colors.divider),
                      ),
                    ),
                    Icon(Icons.chevron_right, color: colors.chevron),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
