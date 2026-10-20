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

/// 颜色选择面板——大色块 4 列网格（预设）+ 末格「+」弹出 WakeUp 式 HSV 对话框 +
/// 可选「恢复默认」。只存原始 ARGB；大色块按课表显示规则换算（spec-next-1020b）。
///
/// HSV 不常驻网格下方；点「+」打开 [showDialog]：SV 方盘 + 色相条 + hex + 取消/保存。
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

  return showModalBottomSheet<TimetableColorPick>(
    context: context,
    isScrollControlled: true,
    backgroundColor: colors.surface,
    builder: (sheetContext) => SafeArea(
      child: StatefulBuilder(
        builder: (context, setState) {
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

          final shown = displayOf(current);

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

          Future<void> openHsvDialog() async {
            final picked = await showDialog<Color>(
              context: sheetContext,
              builder: (dialogContext) =>
                  _HsvColorDialog(initial: current, colors: colors),
            );
            if (picked == null) return;
            if (!sheetContext.mounted) return;
            Navigator.pop(sheetContext, TimetableColorPick.color(picked));
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
                      child: Text(
                        '课表中',
                        style: TimetableTheme.captionStyle(
                          color: colors.labelText,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // 大色块 4 列网格；末格「+」弹出 HSV 对话框（不展开在网格下）。
                LayoutBuilder(
                  builder: (context, constraints) {
                    const cols = 4;
                    const gap = 10.0;
                    final cellW =
                        (constraints.maxWidth - gap * (cols - 1)) / cols;
                    final cellH = cellW * 0.72;
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
                          semanticsLabel: '自定义颜色',
                          onTap: openHsvDialog,
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
  );
}

/// WakeUp 式自定义色对话框：SV 方盘 + 竖向色相条 + 预览/hex 下划线 + 取消/保存。
/// 固定尺寸，避免 AlertDialog IntrinsicWidth + LayoutBuilder 冲突。
class _HsvColorDialog extends StatefulWidget {
  const _HsvColorDialog({required this.initial, required this.colors});

  final Color initial;
  final TimetableColors colors;

  @override
  State<_HsvColorDialog> createState() => _HsvColorDialogState();
}

class _HsvColorDialogState extends State<_HsvColorDialog> {
  static const double _panel = 220;
  static const double _hueW = 22;

  late HSVColor _hsv;
  late TextEditingController _hexCtrl;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initial);
    _hexCtrl = TextEditingController(text: _hexOf(widget.initial));
  }

  @override
  void dispose() {
    _hexCtrl.dispose();
    super.dispose();
  }

  void _setHsv(HSVColor next) {
    setState(() {
      _hsv = next;
      _hexCtrl.text = _hexOf(next.toColor());
    });
  }

  void _applyHex(String raw) {
    final parsed = _parseHex(raw);
    if (parsed == null) return;
    _setHsv(HSVColor.fromColor(parsed));
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final raw = _hsv.toColor();
    final accent = colors.accent;
    return Dialog(
      key: const Key('tt_color_hsv_dialog'),
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
        child: SizedBox(
          width: _panel + 12 + _hueW,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '选择颜色',
                style: TimetableTheme.titleStyle(color: colors.titleText),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SvPanel(
                    key: const Key('tt_color_sv_panel'),
                    size: _panel,
                    hue: _hsv.hue,
                    saturation: _hsv.saturation,
                    value: _hsv.value,
                    onChanged: (s, v) =>
                        _setHsv(_hsv.withSaturation(s).withValue(v)),
                  ),
                  const SizedBox(width: 12),
                  _HueBar(
                    key: const Key('tt_color_hue'),
                    width: _hueW,
                    height: _panel,
                    hue: _hsv.hue,
                    onChanged: (h) => _setHsv(_hsv.withHue(h)),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Container(
                    key: const Key('tt_color_custom_preview'),
                    width: 56,
                    height: 32,
                    decoration: BoxDecoration(
                      color: raw,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: colors.divider),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: const Key('tt_color_hex'),
                      controller: _hexCtrl,
                      style: TimetableTheme.bodyStyle(color: colors.titleText),
                      decoration: InputDecoration(
                        isDense: true,
                        prefixText: '# ',
                        hintText: 'RRGGBB',
                        border: const UnderlineInputBorder(),
                        enabledBorder: UnderlineInputBorder(
                          borderSide: BorderSide(color: colors.divider),
                        ),
                        focusedBorder: UnderlineInputBorder(
                          borderSide: BorderSide(color: accent),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 0,
                          vertical: 8,
                        ),
                      ),
                      onSubmitted: _applyHex,
                      onEditingComplete: () => _applyHex(_hexCtrl.text),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton(
                    key: const Key('tt_color_hsv_cancel'),
                    onPressed: () => Navigator.pop(context),
                    child: Text('取消', style: TextStyle(color: accent)),
                  ),
                  const Spacer(),
                  TextButton(
                    key: const Key('tt_color_custom_apply'),
                    onPressed: () => Navigator.pop(context, _hsv.toColor()),
                    child: Text('保存', style: TextStyle(color: accent)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 饱和度（横）× 明度（纵）方盘；白心圆形光标（WakeUp）。
class _SvPanel extends StatelessWidget {
  const _SvPanel({
    super.key,
    required this.size,
    required this.hue,
    required this.saturation,
    required this.value,
    required this.onChanged,
  });

  final double size;
  final double hue;
  final double saturation;
  final double value;
  final void Function(double saturation, double value) onChanged;

  void _fromLocal(Offset local) {
    final s = (local.dx / size).clamp(0.0, 1.0);
    final v = (1.0 - local.dy / size).clamp(0.0, 1.0);
    onChanged(s, v);
  }

  @override
  Widget build(BuildContext context) {
    final hueColor = HSVColor.fromAHSV(1, hue, 1, 1).toColor();
    return SizedBox(
      width: size,
      height: size,
      child: GestureDetector(
        onPanDown: (d) => _fromLocal(d.localPosition),
        onPanUpdate: (d) => _fromLocal(d.localPosition),
        onTapDown: (d) => _fromLocal(d.localPosition),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [Colors.white, hueColor]),
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
                left: (saturation * size) - 10,
                top: ((1.0 - value) * size) - 10,
                child: IgnorePointer(
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.85),
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: const [
                        BoxShadow(blurRadius: 3, color: Colors.black45),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 竖向彩虹色相条 + 深色横柄（WakeUp：方盘右侧）。
class _HueBar extends StatelessWidget {
  const _HueBar({
    super.key,
    required this.width,
    required this.height,
    required this.hue,
    required this.onChanged,
  });

  final double width;
  final double height;
  final double hue;
  final ValueChanged<double> onChanged;

  static const _spectrum = <Color>[
    Color(0xFFFF0000),
    Color(0xFFFFFF00),
    Color(0xFF00FF00),
    Color(0xFF00FFFF),
    Color(0xFF0000FF),
    Color(0xFFFF00FF),
    Color(0xFFFF0000),
  ];

  void _fromLocal(Offset local) {
    onChanged((local.dy / height * 360).clamp(0.0, 360.0));
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: GestureDetector(
        onPanDown: (d) => _fromLocal(d.localPosition),
        onPanUpdate: (d) => _fromLocal(d.localPosition),
        onTapDown: (d) => _fromLocal(d.localPosition),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: _spectrum,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: -3,
              right: -3,
              top: (hue / 360 * height) - 4,
              child: IgnorePointer(
                child: Container(
                  height: 8,
                  decoration: BoxDecoration(
                    color: const Color(0xFF424242),
                    borderRadius: BorderRadius.circular(2),
                    border: Border.all(color: Colors.white70, width: 1),
                    boxShadow: const [
                      BoxShadow(blurRadius: 2, color: Colors.black38),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
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
