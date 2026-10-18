import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'timetable_controller.dart';
import 'timetable_models.dart';
import 'timetable_overrides.dart';
import 'timetable_theme.dart';
import 'timetable_course_color.dart';

/// 周视图中的一门课色块。
class CourseCell extends StatelessWidget {
  const CourseCell({
    super.key,
    required this.cell,
    required this.height,
    required this.width,
    required this.radius,
    this.onTap,
    this.onLongPress,
    this.controller,
    this.stackCount = 1,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onDragCancel,
  });

  /// 长按拖动调课的触发时长（spec §13.2：按住约 0.8 秒后开始移动才拖起来）。
  static const Duration dragHoldDuration = Duration(milliseconds: 800);

  final GridCell cell;
  final double height;
  final double width;
  final double radius;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 为空时用 [TimetableController.instance]。
  final TimetableController? controller;

  /// 本周该时段同时有课的门数（由 WeekGrid 聚合）；>1 时显示「N 门」胶囊与冲突点。
  final int stackCount;

  /// 长按满 [dragHoldDuration] 时回调（此时不给任何视觉/震动反馈，由 WeekGrid
  /// 等到手指真正移动后才拖起格子）。三个回调都为空时不挂长按识别器。
  final GestureLongPressStartCallback? onDragStart;
  final GestureLongPressMoveUpdateCallback? onDragUpdate;
  final GestureLongPressEndCallback? onDragEnd;
  final GestureLongPressCancelCallback? onDragCancel;

  TimetableController get _ctl => controller ?? TimetableController.instance;

  @override
  Widget build(BuildContext context) {
    final cellWidget = _buildCell(context);
    if (onDragStart == null && onDragUpdate == null && onDragEnd == null) {
      return cellWidget;
    }
    return RawGestureDetector(
      gestures: {
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(duration: dragHoldDuration),
              (r) {
                r
                  ..onLongPressStart = onDragStart
                  ..onLongPressMoveUpdate = onDragUpdate
                  ..onLongPressEnd = onDragEnd
                  ..onLongPressCancel = onDragCancel;
              },
            ),
      },
      child: cellWidget,
    );
  }

  Widget _buildCell(BuildContext context) {
    final active = cell.activeThisWeek;
    final ctl = _ctl;
    final settings = ctl.settings;
    final scheme = coursePaletteSchemeFor(ctl);
    final colorIndex = courseColorIndex(ctl, cell.course);
    // 浅底 + 该色号文字色（spec §13.5/§13.7）。不透明度只作用于 bg（往页面底色混合）；
    // 文字、冲突圆点、角标都用不透明的 fg，不从 bg 派生（§13.6）。
    // 非本周格（§13.8）：白底 + 1px 描边 + offWeekText，不取配色、不受不透明度影响。
    final bg = active
        ? TimetableTheme.blendCellBg(
            TimetableTheme.courseColor(colorIndex, scheme: scheme),
            settings.cellOpacity,
          )
        : TimetableTheme.offWeekBg;
    final fg = active
        ? TimetableTheme.courseTextColor(colorIndex, scheme: scheme)
        : TimetableTheme.offWeekText;
    // 单/双周按教务原始周次（[SlotOrigin.original]，即调课记录的 origWeeks）判断：
    // 「只改本周」后新时段的位串只剩一周，不能据此显示/朗读「单周」「双周」。
    final source = slotOriginOf(cell.slot)?.original ?? cell.slot;
    final parity = source.parity;
    // 只有一周上课（「只改本周」拆出的那一周、教务/手动课只排了一周）不标单/双周；
    // 胶囊与朗读共用这一判断。非本周格只显示「非本周」胶囊，不再同时显示单/双周（§13.8）。
    final showParity =
        active &&
        parity != WeekParity.all &&
        _weekCount(source.weeks) > 1 &&
        _weekCount(cell.slot.weeks) > 1;
    final stacked = stackCount > 1;
    final showOffWeek = !active;
    final showBadge = showParity || stacked || showOffWeek;

    return Semantics(
      button: true,
      label: _semanticsLabel(showParity, parity),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(radius),
          child: Ink(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(radius),
            ),
            child: Stack(
              children: [
                // 非本周描边画在内容之上的覆盖层：不占布局，课名/胶囊位置
                // 与本周格完全一致（Ink 的 border 会把内容内缩 1px）。
                if (!active)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        key: const Key('course_cell_off_week_border'),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(radius),
                          border: Border.all(
                            color: TimetableTheme.offWeekBorder,
                            width: TimetableTheme.offWeekBorderWidth,
                          ),
                        ),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                  child: ClipRect(
                    child: LayoutBuilder(
                      builder: (context, box) =>
                          _content(context, box, fg, showBadge),
                    ),
                  ),
                ),
                if (stacked)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Container(
                      key: const Key('course_cell_conflict_dot'),
                      width: TimetableTheme.conflictDotSize,
                      height: TimetableTheme.conflictDotSize,
                      decoration: BoxDecoration(
                        color: fg,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                if (showBadge)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 3,
                    child: Center(
                      child: Wrap(
                        spacing: 2,
                        alignment: WrapAlignment.center,
                        children: [
                          if (stacked)
                            _badge(
                              '$stackCount 门',
                              fg,
                              key: const Key('course_cell_stack_badge'),
                            ),
                          if (showOffWeek && !stacked)
                            // 「非本周」已由格子语义标签念过一次，胶囊不再重复朗读。
                            ExcludeSemantics(
                              child: _badge(
                                offWeekLabel,
                                fg,
                                key: const Key('course_cell_off_week_pill'),
                              ),
                            )
                          else if (showParity && !stacked)
                            _badge(
                              parity == WeekParity.odd ? '单周' : '双周',
                              fg,
                              key: const Key('course_cell_parity_pill'),
                            ),
                        ],
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

  /// 按可用高度排版格内文字（spec §13.9，替代 §2.4 / §13.3 的旧优先级）：
  /// 先为底部胶囊预留空间；地点永不截断（逐字换行，不限行数）。空间不够时依次
  /// ① 隐藏课程代码 [xx] ② 隐藏老师 ③ 课名截断（至少 1 行，末尾省略）
  /// ④ 本格字号逐级缩小（每级 1sp，最小 10sp）。见 [planCellContent]。
  /// 仍放不下（极端：1 节 + 大字号 + 长地点）：地点完整、课名 1 行省略，
  /// 超出格子的部分被裁掉，不报 overflow。
  Widget _content(
    BuildContext context,
    BoxConstraints box,
    Color fg,
    bool showBadge,
  ) {
    final scaler = MediaQuery.textScalerOf(context);
    final base = DefaultTextStyle.of(context).style;
    final settings = _ctl.settings;
    final factor = settings.fontScale.factor;
    var avail = box.maxHeight.isFinite ? box.maxHeight : double.infinity;
    if (showBadge) avail -= badgeReserve;
    final hasLoc = settings.showLocation && cell.slot.location.isNotEmpty;
    final teacher = cell.slot.teacher.trim();
    final hasTeacher = settings.showTeacher && teacher.isNotEmpty;
    final locText = hasLoc ? cellLocationText(cell.slot.location) : '';
    final plan = planCellContent(
      name: cell.course.name,
      location: locText,
      hasClass: cell.course.classId.isNotEmpty,
      hasTeacher: hasTeacher,
      nameStyle: base.merge(TimetableTheme.cellStyle(color: fg)),
      subStyle: base.merge(TimetableTheme.cellSubStyle(color: fg)),
      nameSize: cellFontSize(TimetableTheme.cellSize, factor, scaler),
      subSize: cellFontSize(TimetableTheme.cellSubSize, factor, scaler),
      maxWidth: box.maxWidth,
      maxHeight: avail,
      textScaler: scaler,
      textDirection: Directionality.of(context),
    );
    final nameStyle = TimetableTheme.cellStyle(color: fg)
        .copyWith(fontSize: plan.nameSize);
    final subStyle = TimetableTheme.cellSubStyle(color: fg)
        .copyWith(fontSize: plan.subSize);

    // OverflowBox：极端情况下内容可超出格子高度，由外层 ClipRect 裁掉而不是报溢出。
    return OverflowBox(
      alignment: AlignmentDirectional.topStart,
      minHeight: 0,
      maxHeight: double.infinity,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CourseNameText(
            name: cell.course.name,
            style: nameStyle,
            maxLines: plan.nameLines,
          ),
          if (plan.showClass)
            Text(
              '[${cell.course.classId}]',
              key: const Key('course_cell_class'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: subStyle,
            ),
          if (hasLoc)
            // 地点永不截断：不限行数、无省略号（§13.9）。
            Text(
              locText,
              key: const Key('course_cell_location'),
              semanticsLabel: '@${cell.slot.location}',
              softWrap: true,
              style: subStyle,
            ),
          if (plan.showTeacher)
            Text(
              teacher,
              key: const Key('course_cell_teacher'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: subStyle,
            ),
        ],
      ),
    );
  }

  /// 格内字号：基准 × 文字大小系数（§13.3），乘系统缩放后不小于 10sp。
  static double cellFontSize(double base, double factor, TextScaler scaler) {
    final scale = scaler.scale(1);
    final sized = base * factor;
    if (scale <= 0) return sized;
    final minUnscaled = 10 / scale;
    return sized < minUnscaled ? minUnscaled : sized;
  }

  /// 非本周格底部胶囊文字（§13.8：替代原课名前缀写法）。
  static const String offWeekLabel = '非本周';

  static int _weekCount(String weeks) => '1'.allMatches(weeks).length;

  /// 底部胶囊预留高度（胶囊 + bottom 3 - 内边距 4 + 余量）。
  static const double badgeReserve = 14;

  /// Micro 胶囊（单/双周、「非本周」与「N 门」共用样式）：
  /// 文字与描边都用该课文字色 [fg]（不透明），无填充。
  static Widget _badge(String text, Color fg, {Key? key}) => Container(
    key: key,
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 0),
    decoration: BoxDecoration(
      border: Border.all(color: fg, width: 1),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: TimetableTheme.badgeSize, color: fg),
    ),
  );

  String _semanticsLabel(bool showBadge, WeekParity parity) {
    final parts = <String>[
      if (!cell.activeThisWeek) '非本周',
      cell.course.name,
      '第${cell.slot.startNode}-${cell.slot.endNode}节',
      if (cell.slot.location.isNotEmpty) cell.slot.location,
      if (showBadge) (parity == WeekParity.odd ? '单周' : '双周'),
      if (stackCount > 1) '本时段 $stackCount 门课',
    ];
    return parts.join('，');
  }
}

/// 格内排版结果（[planCellContent]）。
@immutable
class CellContentPlan {
  const CellContentPlan({
    required this.nameSize,
    required this.subSize,
    required this.nameLines,
    required this.showClass,
    required this.showTeacher,
    required this.fits,
  });

  /// 课名 / 副行字号（未乘系统缩放，交给 Text 的 textScaler）。
  final double nameSize;
  final double subSize;

  /// 课名最多行数（≥1，末行省略）。
  final int nameLines;
  final bool showClass;
  final bool showTeacher;

  /// false：已缩到最小字号仍放不下（地点完整、课名 1 行，超出部分被裁）。
  final bool fits;
}

/// 格内让位（spec §13.9）。地点（[location]，已是 [cellLocationText] 结果，空串表示不显示）
/// 永不截断；高度不够时依次 ① 隐藏代码 ② 隐藏老师 ③ 课名截断到能放下的行数（≥1）
/// ④ 字号每级缩小 1sp（实际字号，含系统缩放），最小 10sp。缩小后代码与老师保持隐藏，
/// 只尽量多给课名行数。[nameSize]/[subSize] 为未乘系统缩放的起始字号。
CellContentPlan planCellContent({
  required String name,
  required String location,
  required bool hasClass,
  required bool hasTeacher,
  required TextStyle nameStyle,
  required TextStyle subStyle,
  required double nameSize,
  required double subSize,
  required double maxWidth,
  required double maxHeight,
  TextScaler textScaler = TextScaler.noScaling,
  TextDirection textDirection = TextDirection.ltr,
}) {
  final w = maxWidth.isFinite && maxWidth > 0 ? maxWidth : 1e9;
  TextPainter painter(String text, TextStyle st) => TextPainter(
    text: TextSpan(text: text, style: st),
    textDirection: textDirection,
    textScaler: textScaler,
  )..layout(maxWidth: w);
  double heightOf(String text, TextStyle st) {
    final p = painter(text, st);
    final h = p.height;
    p.dispose();
    return h;
  }

  int linesOf(String text, TextStyle st) {
    final p = painter(text, st);
    final n = p.computeLineMetrics().length;
    p.dispose();
    return n < 1 ? 1 : n;
  }

  final scale = textScaler.scale(1);
  final unit = scale > 0 ? 1 / scale : 1.0;
  final minSize = scale > 0 ? kCellMinFontSize / scale : kCellMinFontSize;
  const eps = 0.01;
  bool fit(double h) => h <= maxHeight + eps;
  for (var i = 0; ; i++) {
    final ns = math.max(minSize, nameSize - i * unit);
    final ss = math.max(minSize, subSize - i * unit);
    final nSt = nameStyle.copyWith(fontSize: ns);
    final sSt = subStyle.copyWith(fontSize: ss);
    final nameH = heightOf('课', nSt);
    final subH = heightOf('课', sSt);
    final laid = layoutCellCourseName(
      name,
      style: nSt,
      maxWidth: maxWidth,
      textScaler: textScaler,
      textDirection: textDirection,
    );
    final needed = linesOf(laid, nSt);
    final locH = location.isEmpty ? 0.0 : heightOf(location, sSt);
    final classH = hasClass ? subH : 0.0;
    final teacherH = hasTeacher ? subH : 0.0;
    final full = needed * nameH;
    CellContentPlan plan(int lines, bool cls, bool tch, {bool fits = true}) =>
        CellContentPlan(
          nameSize: ns,
          subSize: ss,
          nameLines: lines,
          showClass: cls,
          showTeacher: tch,
          fits: fits,
        );
    if (i == 0) {
      if (fit(full + classH + locH + teacherH)) {
        return plan(needed, hasClass, hasTeacher);
      }
      // ① 隐藏课程代码。
      if (fit(full + locH + teacherH)) return plan(needed, false, hasTeacher);
    }
    // ② 隐藏老师。
    if (fit(full + locH)) return plan(needed, false, false);
    // ③ 课名截断（至少 1 行）。
    if (fit(nameH + locH)) {
      final lines = ((maxHeight - locH + eps) / nameH).floor().clamp(1, needed);
      return plan(lines, false, false);
    }
    // ④ 字号再小一级；到 10sp 仍放不下：地点完整、课名 1 行。
    if (ns <= minSize + 1e-6 && ss <= minSize + 1e-6) {
      return plan(1, false, false, fits: false);
    }
  }
}

/// 格内最小字号（sp，含系统缩放）。
const double kCellMinFontSize = 10;

/// 格内地点文字「@地点」：在相邻两个非汉字（字母、数字、符号）之间插入 U+200B，
/// 让「A101」这类串也能逐字换行（汉字之间本来就可断行）。只插不可见字符，可见文字不变。
String cellLocationText(String location) {
  final out = StringBuffer();
  int? prev;
  for (final r in '@$location'.runes) {
    if (prev != null && _breakableRun(prev) && _breakableRun(r)) {
      out.write(_zeroWidthSpace);
    }
    out.writeCharCode(r);
    prev = r;
  }
  return out.toString();
}

const _zeroWidthSpace = '\u200B';

/// 非空白、非 CJK（汉字/全角符号）的字符：行断器不会在这类相邻字符之间断行。
bool _breakableRun(int r) {
  if (r == 0x20 || r == 0x09 || r == 0x0A || r == 0x200B) return false;
  final cjk =
      (r >= 0x2E80 && r <= 0x9FFF) ||
      (r >= 0xF900 && r <= 0xFAFF) ||
      (r >= 0xFF00 && r <= 0xFFEF) ||
      (r >= 0x20000 && r <= 0x3FFFF);
  return !cjk;
}

const _wordJoiner = '\u2060';
final _trailingParen = RegExp(r'^(.*\S)(（[^（）]*）)$');

/// 课程格内的课名：先 [normalizeCourseName]（半角括号转全角），
/// 再用 U+2060 把末尾括注粘连到前一字。
///
/// 注意：仅靠 U+2060 不够——当「末字+括注」这一不可断单元比格宽还宽时，
/// 行断器会退回逐字强制断行，「）」仍会单独掉行。真实格子请用
/// [CourseNameText] / [layoutCellCourseName]，按实际宽度决定换行位置。
String formatCellCourseName(String name) {
  final s = normalizeCourseName(name);
  final m = _trailingParen.firstMatch(s);
  if (m == null) return s;
  final head = m.group(1)!;
  final tail = m.group(2)!.split('').join(_wordJoiner);
  return '$head$_wordJoiner$tail';
}

/// 末尾「罗马数字 + 括注」单元，如「Ⅱ（2）」：group1 = 前文，group2 = 罗马数字，group3 = 括注。
final _trailingRomanParen = RegExp(r'^(.*\S)([\u2160-\u217F]+)(（[^（）]*）)$');

/// 按实际宽度排版课名（B02/B02b），只插入 `\n`，从不复制、删除或改写字符：
/// 去掉 `\n` / U+2060 后恒等于 [normalizeCourseName]。
///
/// 规则：
/// * 末尾「罗马数字+括注」（如「Ⅱ（2）」）视为一个单元，只在它前面断行；
///   单元单行放得下时 Ⅱ 与「（」绝不分行（「大学物理 / Ⅱ（2）」）。
///   单元本身放不下 → 退回下面的括注规则（在「（」前断）。
/// * 末尾括注：普通排版已完整 → 原样；「末字+括注」放得下 → 末字前断
///   （「学术英 / 语（1）」）；否则括注放得下 → 「（」前断（「学术英 / 语 / （1）」）；
///   括注一行都放不下 → 退回 [formatCellCourseName]。
///
/// 判断「是否完整/放得下」全部用与 [Text] 相同样式的 [TextPainter] 实际排版结果，
/// 而不是自行估算第 1 行在哪里结束。
String layoutCellCourseName(
  String name, {
  required TextStyle style,
  required double maxWidth,
  TextScaler textScaler = TextScaler.noScaling,
  TextDirection textDirection = TextDirection.ltr,
}) {
  final plain = normalizeCourseName(name);
  final m = _trailingParen.firstMatch(plain);
  if (m == null || !maxWidth.isFinite || maxWidth <= 0) return plain;

  TextPainter painterFor(String text, {double? width}) => TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: textDirection,
    textScaler: textScaler,
  )..layout(maxWidth: width ?? double.infinity);

  bool fitsOneLine(String text) {
    final p = painterFor(text);
    final ok = p.width <= maxWidth + 0.01;
    p.dispose();
    return ok;
  }

  /// [text] 从 [start] 到末尾在实际排版中是否落在同一行。
  bool tailIntact(String text, int start) {
    final p = painterFor(text, width: maxWidth);
    final tops = <int>{
      for (final box in p.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: text.length),
      ))
        box.top.round(),
    };
    p.dispose();
    return tops.length <= 1;
  }

  final r = _trailingRomanParen.firstMatch(plain);
  if (r != null) {
    final unitHead = r.group(1)!;
    final unit = '${r.group(2)!}${r.group(3)!}';
    if (fitsOneLine(unit)) {
      if (tailIntact(plain, unitHead.length)) return plain;
      return '$unitHead\n$unit';
    }
    // 单元本身放不下：在「（」前断（括注规则）。
  }

  final head = m.group(1)!;
  final paren = m.group(2)!;
  if (tailIntact(plain, head.length)) return plain;
  final chars = head.characters;
  if (r == null && chars.length > 1 && fitsOneLine('${chars.last}$paren')) {
    return '${chars.skipLast(1)}\n${chars.last}$paren';
  }
  if (fitsOneLine(paren)) return '$head\n$paren';
  return formatCellCourseName(name);
}

/// 课程格课名：最多 [maxLines] 行省略，按格宽避免括注拆行。
class CourseNameText extends StatelessWidget {
  const CourseNameText({
    super.key,
    required this.name,
    required this.style,
    this.maxLines = 3,
    this.prefix = '',
  });

  final String name;

  /// 拼在课名前的标记，与课名一起换行/省略；朗读只读课名。
  /// 课程格已不再使用（§13.8：非本周改为底部胶囊），保留给其他调用方。
  final String prefix;
  final TextStyle style;

  /// 最多行数，末行省略。
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    // 与 Text 实际使用的样式一致（合并 DefaultTextStyle 的字体等）。
    final effective = DefaultTextStyle.of(context).style.merge(style);
    return LayoutBuilder(
      builder: (context, constraints) => Text(
        layoutCellCourseName(
          prefix.isEmpty ? name : '$prefix${name.trim()}',
          style: effective,
          maxWidth: constraints.maxWidth,
          textScaler: scaler,
          textDirection: Directionality.of(context),
        ),
        semanticsLabel: prefix.isEmpty ? null : normalizeCourseName(name),
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    );
  }
}
