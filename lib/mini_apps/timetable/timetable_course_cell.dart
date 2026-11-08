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
    this.pairOverride,
    this.fontReferenceWidth,
  });

  /// 长按拖动调课的触发时长（spec §13.2：按住约 0.8 秒后开始移动才拖起来）。
  static const Duration dragHoldDuration = Duration(milliseconds: 800);

  final GridCell cell;
  final double height;
  final double width;

  /// 整周统一的字号参考格宽，避免列宽像素取整差异触发不同字号。
  final double? fontReferenceWidth;
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

  /// 选色预览等：非空时跳过 [coursePairFor]，直接用该对（再经不透明度混合）。
  final CourseColorPair? pairOverride;

  TimetableController get _ctl => controller ?? TimetableController.instance;

  /// 当前格宽下完整显示课名、地点、教师和标签所需的高度，不含格外边距。
  double preferredHeight(BuildContext context) {
    final ctl = _ctl;
    final settings = ctl.settings;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final base = DefaultTextStyle.of(context).style;
    final contentWidth = math.max(1.0, (fontReferenceWidth ?? width) - 8);
    final sizes = TimetableTheme.cellTextSizesForWidth(
      maxWidth: math.max(1.0, (fontReferenceWidth ?? width) - 8),
      nameStyle: base.merge(TimetableTheme.cellStyle()),
      factor: settings.fontScale.factor,
      textScaler: scaler,
      textDirection: direction,
    );
    final nameStyle = base
        .merge(TimetableTheme.cellStyle())
        .copyWith(fontSize: sizes.nameSize);
    final subStyle = base
        .merge(TimetableTheme.cellSubStyle())
        .copyWith(fontSize: sizes.subSize);
    final locationStyle = base
        .merge(TimetableTheme.cellLocationStyle())
        .copyWith(fontSize: sizes.subSize);
    double textHeight(String text, TextStyle style) {
      if (text.isEmpty) return 0;
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: direction,
        textScaler: scaler,
      )..layout(maxWidth: contentWidth);
      final height = painter.height;
      painter.dispose();
      return height;
    }

    final name = layoutCellCourseName(
      courseDisplayName(course: cell.course, slot: cell.slot),
      style: nameStyle,
      maxWidth: contentWidth,
      textScaler: scaler,
      textDirection: direction,
    );
    final location = settings.showLocation && cell.slot.location.isNotEmpty
        ? cellLocationText(cell.slot.location)
        : '';
    final teacher = settings.showTeacher
        ? cellTeacherText(cell.slot.teacher)
        : '';
    final source = slotOriginOf(cell.slot)?.original ?? cell.slot;
    final showParity =
        cell.activeThisWeek &&
        source.parity != WeekParity.all &&
        _weekCount(source.weeks) > 1 &&
        _weekCount(cell.slot.weeks) > 1;
    final showLab = _showsLabLabel && cell.slot.span > 1;
    final badgeHeight =
        showLab || showParity || stackCount > 1 || !cell.activeThisWeek
        ? _badgeReserveFor(context, showLab: showLab)
        : 0.0;
    return 8 +
        badgeHeight +
        textHeight(name, nameStyle) +
        textHeight(location, locationStyle) +
        (teacher.isNotEmpty ? textHeight('课', subStyle) : 0) +
        textHeight(teacher, subStyle);
  }

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
    // 自动色使用柔和配色，自选色原样显示。不透明度只作用于 bg（往页面底色混合）；
    // 文字、冲突圆点、角标都用不透明的 fg，不从 bg 派生（§13.6）。
    // 非本周格（§13.8）：白底 + 1px 描边 + offWeekText，不取配色、不受不透明度影响。
    // 深色（item 12）：同色相「深底浅字」（[TimetableTheme.coursePair]），显示时换算；
    // 不透明度往 #121316 混；非本周格取上游 [TimetableColors.dark] 的 offWeek*。
    final colors = TimetableTheme.colorsOf(context);
    // item 9：用户自选色优先（[coursePairFor]）；选色预览可 [pairOverride]。
    final pair =
        pairOverride ?? coursePairFor(ctl, cell.course, dark: colors.isDark);
    final bg = active
        ? TimetableTheme.blendCellBg(
            pair.bg,
            settings.cellOpacity,
            dark: colors.isDark,
          )
        : colors.offWeekBg;
    // item 14：白字 / 黑字强制；非本周格仍用 offWeekText。
    final fg = active
        ? TimetableTheme.cellTextFor(
            TimetableTheme.readableCellText(
              bg,
              ctl.userColorOf(cell.course) == null
                  ? pair.fg
                  : TimetableTheme.userCoursePair(bg).fg,
            ),
            settings.cellTextColor,
          )
        : colors.offWeekText;
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
    // 显式类型优先；旧体育数据即使带实验标记，也保持原有的不打标行为。
    final labSlot = _showsLabLabel;
    // 1 节高的格子放不下底部标签行：格内省略「实验」，改由课程详情标注「实验课」。
    final showLab = labSlot && cell.slot.span > 1;
    // 有「实验」时底部只留一行：居中，「实验」在前，其余角标依次靠后（放不下就省略）。
    final showCenterBadge = !showLab && (showParity || stacked || showOffWeek);
    final showBottomBadge = showLab || showCenterBadge;

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
                            color: colors.offWeekBorder,
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
                      builder: (context, box) => _content(
                        context,
                        box,
                        fg,
                        showBottomBadge,
                        _badgeReserveFor(context, showLab: showLab),
                      ),
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
                if (showLab)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 3,
                    child: LayoutBuilder(
                      builder: (context, box) {
                        // 除「实验」外最多再放一个角标；行宽不够时只保留「实验」。
                        final parityLabel = parity == WeekParity.odd
                            ? '单周'
                            : '双周';
                        final (String?, Widget?) extra = stacked
                            ? (
                                '$stackCount 门',
                                _badge(
                                  '$stackCount 门',
                                  fg,
                                  key: const Key('course_cell_stack_badge'),
                                ),
                              )
                            : showOffWeek
                            ? (
                                offWeekLabel,
                                // 「非本周」已由格子语义标签念过一次，胶囊不再重复朗读。
                                ExcludeSemantics(
                                  child: _badge(
                                    offWeekLabel,
                                    fg,
                                    key: const Key('course_cell_off_week_pill'),
                                  ),
                                ),
                              )
                            : showParity
                            ? (
                                parityLabel,
                                _badge(
                                  parityLabel,
                                  fg,
                                  key: const Key('course_cell_parity_pill'),
                                ),
                              )
                            : (null, null);
                        final fits =
                            extra.$1 != null &&
                            box.maxWidth >=
                                _badgeWidth(
                                      context,
                                      labPillLabel,
                                      fontSize: labPillFontSize,
                                      paddingH: labPillPaddingH,
                                    ) +
                                    labPillGap +
                                    _badgeWidth(context, extra.$1!);
                        return Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _badge(
                                labPillLabel,
                                fg,
                                key: const Key('course_cell_lab_pill'),
                                fontSize: labPillFontSize,
                                paddingH: labPillPaddingH,
                                height: _labPillHeight(context),
                                borderAlpha: labPillBorderAlpha,
                              ),
                              if (fits) ...[
                                const SizedBox(width: labPillGap),
                                extra.$2!,
                              ],
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                if (showCenterBadge)
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
  /// 先为底部胶囊预留空间；不显示课序号，地点与老师之间留一行。
  /// 地点和教师完整换行显示，不限行数。空间不够时依次
  /// ① 课名截断（至少 1 行，末尾省略）
  /// ② 本格字号逐级缩小（每级 1sp，最小 10sp，取整）。见 [planCellContent]。
  /// 到下限仍放不下：地点和教师完整排版、课名 1 行省略号截断，不再继续缩；
  /// 超出格子的部分被裁掉，不报 overflow。
  Widget _content(
    BuildContext context,
    BoxConstraints box,
    Color fg,
    bool showBadge,
    double badgeReserve,
  ) {
    final scaler = MediaQuery.textScalerOf(context);
    final base = DefaultTextStyle.of(context).style;
    final settings = _ctl.settings;
    final factor = settings.fontScale.factor;
    final contentWidth = fontReferenceWidth == null
        ? box.maxWidth
        : math.max(1.0, fontReferenceWidth! - 8);
    final sizes = TimetableTheme.cellTextSizesForWidth(
      maxWidth: contentWidth,
      nameStyle: base.merge(TimetableTheme.cellStyle(color: fg)),
      factor: factor,
      textScaler: scaler,
      textDirection: Directionality.of(context),
    );
    var avail = box.maxHeight.isFinite ? box.maxHeight : double.infinity;
    if (showBadge) avail -= badgeReserve;
    final hasLoc = settings.showLocation && cell.slot.location.isNotEmpty;
    final rawTeacher = cell.slot.teacher.trim();
    final teacher = cellTeacherText(rawTeacher);
    final hasTeacher = settings.showTeacher && teacher.isNotEmpty;
    final locText = hasLoc ? cellLocationText(cell.slot.location) : '';
    final plan = planCellContent(
      name: courseDisplayName(course: cell.course, slot: cell.slot),
      location: locText,
      teacher: hasTeacher ? teacher : '',
      nameStyle: base.merge(TimetableTheme.cellStyle(color: fg)),
      subStyle: base.merge(TimetableTheme.cellSubStyle(color: fg)),
      locationStyle: base.merge(TimetableTheme.cellLocationStyle(color: fg)),
      nameSize: sizes.nameSize,
      subSize: sizes.subSize,
      maxWidth: contentWidth,
      maxHeight: avail,
      textScaler: scaler,
      textDirection: Directionality.of(context),
    );
    final nameStyle = TimetableTheme.cellStyle(color: fg)
        .copyWith(fontSize: plan.nameSize);
    final subStyle = TimetableTheme.cellSubStyle(color: fg)
        .copyWith(fontSize: plan.subSize);
    final locationStyle = TimetableTheme.cellLocationStyle(color: fg)
        .copyWith(fontSize: plan.subSize);

    // OverflowBox：极端情况下内容可超出格子高度，由外层 ClipRect 裁掉而不是报溢出。
    return OverflowBox(
      alignment: AlignmentDirectional.topStart,
      minWidth: contentWidth,
      maxWidth: contentWidth,
      minHeight: 0,
      maxHeight: double.infinity,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CourseNameText(
            name: courseDisplayName(course: cell.course, slot: cell.slot),
            style: nameStyle,
            maxLines: plan.nameLines,
          ),
          if (hasLoc)
            // 地点永不截断：不限行数、无省略号（§13.9）。
            Text(
              locText,
              key: const Key('course_cell_location'),
              semanticsLabel: '@${cell.slot.location}',
              softWrap: true,
              style: locationStyle,
            ),
          if (plan.teacherGap > 0) SizedBox(height: plan.teacherGap),
          if (plan.showTeacher)
            Text(
              teacher,
              key: const Key('course_cell_teacher'),
              semanticsLabel: rawTeacher,
              softWrap: true,
              style: subStyle,
            ),
        ],
      ),
    );
  }

  /// 格内字号：基准 × 文字大小系数（§13.3），乘系统缩放后不小于 10sp；结果取整避免发虚。
  static double cellFontSize(double base, double factor, TextScaler scaler) =>
      TimetableTheme.cellFontSize(base, factor, scaler);

  /// 非本周格底部胶囊文字（§13.8：替代原课名前缀写法）。
  static const String offWeekLabel = '非本周';

  /// 实验时段格内胶囊文字。
  static const String labPillLabel = '实验';

  /// 实验胶囊字号（sp）。
  static const double labPillFontSize = 10;

  /// 实验胶囊高度（dp）与圆角（= 高度一半）。
  static const double labPillHeight = 16;

  /// 实验胶囊水平内边距（dp）。
  static const double labPillPaddingH = 4;

  /// 实验胶囊描边不透明度：同文字色 60%。
  static const double labPillBorderAlpha = 0.6;

  /// 「实验」与同行下一个胶囊的间距（dp）。
  static const double labPillGap = 4;

  static int _weekCount(String weeks) => '1'.allMatches(weeks).length;

  /// 底部胶囊预留高度（胶囊 + bottom 3 - 内边距 4 + 余量）。
  static const double badgeReserve = 14;

  /// 实验胶囊行的预留高度：16dp 胶囊 + bottom 3 - 内边距 4 + 余量。
  static const double labBadgeReserve = 16;

  double _labPillHeight(BuildContext context) => TimetableTheme.cellBadgeSize(
    context,
    labPillLabel,
    maxWidth: width,
    fontSize: labPillFontSize,
    paddingH: labPillPaddingH,
    minimumHeight: labPillHeight,
  ).height;

  double _badgeReserveFor(BuildContext context, {required bool showLab}) {
    if (showLab) return math.max(labBadgeReserve, _labPillHeight(context) + 2);
    final source = slotOriginOf(cell.slot)?.original ?? cell.slot;
    final label = stackCount > 1
        ? '$stackCount 门'
        : !cell.activeThisWeek
        ? offWeekLabel
        : source.parity == WeekParity.odd
        ? '单周'
        : '双周';
    final size = TimetableTheme.cellBadgeSize(context, label, maxWidth: width);
    return math.max(badgeReserve, size.height + 2);
  }

  /// Micro 胶囊（单/双周、「非本周」、「N 门」与「实验」共用样式）：
  /// 文字与描边都用该课文字色 [fg]，无填充。
  ///
  /// 「实验」用 [fontSize] 10 / [paddingH] 4 / [height] 16 / [borderAlpha] 0.6；
  /// 其余胶囊保持原有 9sp、横向 5dp、自适应高度、实色描边。
  static Widget _badge(
    String text,
    Color fg, {
    Key? key,
    double fontSize = TimetableTheme.badgeSize,
    double paddingH = 5,
    double? height,
    double borderAlpha = 1,
  }) => Container(
    key: key,
    height: height,
    alignment: height == null ? null : Alignment.center,
    padding: EdgeInsets.symmetric(horizontal: paddingH, vertical: 0),
    decoration: BoxDecoration(
      border: Border.all(color: fg.withValues(alpha: borderAlpha), width: 1),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: fontSize, color: fg),
    ),
  );

  /// 胶囊在当前字体与系统缩放下的宽度（含横向内边距与 1dp 描边），
  /// 供底部行决定是否还能放下下一个胶囊。
  static double _badgeWidth(
    BuildContext context,
    String text, {
    double fontSize = TimetableTheme.badgeSize,
    double paddingH = 5,
  }) {
    final base = DefaultTextStyle.of(context).style;
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: base.copyWith(fontSize: fontSize),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width + paddingH * 2 + 2;
  }

  bool get _showsLabLabel =>
      courseKindOf(course: cell.course, slot: cell.slot) == CourseKind.lab &&
      (cell.slot.kind != null || !cell.course.isPe);

  String _semanticsLabel(bool showBadge, WeekParity parity) {
    final parts = <String>[
      if (!cell.activeThisWeek) '非本周',
      courseDisplayName(course: cell.course, slot: cell.slot),
      '第${cell.slot.startNode}-${cell.slot.endNode}节',
      if (cell.slot.location.isNotEmpty) cell.slot.location,
      if (_showsLabLabel) '实验课',
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
    required this.showTeacher,
    required this.teacherGap,
    required this.fits,
  });

  /// 课名 / 副行字号（未乘系统缩放，交给 Text 的 textScaler）。
  final double nameSize;
  final double subSize;

  /// 课名最多行数（≥1，末行省略）。
  final int nameLines;
  final bool showTeacher;

  /// 教师显示时，教师前留一行副文字高度；不显示教师时为 0。
  final double teacherGap;

  /// false：已缩到最小字号仍放不下（地点和教师完整排版、课名 1 行，超出部分被裁）。
  final bool fits;
}

/// 格内让位。地点（[location]，已是 [cellLocationText] 结果）和教师（[teacher]）
/// 完整换行显示，空串表示不显示；教师前始终留一行，课序号不参与格内排版。
/// 高度不够时依次 ① 课名截断到能放下的行数（≥1）
/// ② 字号每级缩小 1sp（实际字号，含系统缩放），最小 10sp；算完取整。
/// 到下限仍放不下：地点和教师完整排版、课名 1 行省略号截断，不再继续缩。
/// [nameSize]/[subSize] 为未乘系统缩放的起始字号。
CellContentPlan planCellContent({
  required String name,
  required String location,
  required String teacher,
  required TextStyle nameStyle,
  required TextStyle subStyle,
  TextStyle? locationStyle,
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
  final minSize = scale > 0
      ? (kCellMinFontSize / scale).ceilToDouble()
      : kCellMinFontSize;
  final hasTeacher = teacher.isNotEmpty;
  const eps = 0.01;
  bool fit(double h) => h <= maxHeight + eps;
  for (var i = 0; ; i++) {
    final ns = TimetableTheme.snapFontSp(
      math.max(minSize, nameSize - i * unit),
    );
    final ss = TimetableTheme.snapFontSp(math.max(minSize, subSize - i * unit));
    final nSt = nameStyle.copyWith(fontSize: ns);
    final sSt = subStyle.copyWith(fontSize: ss);
    final lSt = (locationStyle ?? subStyle).copyWith(fontSize: ss);
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
    final locH = location.isEmpty ? 0.0 : heightOf(location, lSt);
    final teacherH = hasTeacher ? heightOf(teacher, sSt) : 0.0;
    final teacherGap = hasTeacher ? subH : 0.0;
    final secondaryH = locH + teacherH + teacherGap;
    final full = needed * nameH;
    CellContentPlan plan(int lines, {bool fits = true}) => CellContentPlan(
      nameSize: ns,
      subSize: ss,
      nameLines: lines,
      showTeacher: hasTeacher,
      teacherGap: teacherGap,
      fits: fits,
    );
    if (fit(full + secondaryH)) {
      return plan(needed);
    }
    // ① 课名截断（至少 1 行），保留完整地点和教师。
    if (fit(nameH + secondaryH)) {
      final lines = ((maxHeight - secondaryH + eps) / nameH).floor().clamp(
        1,
        needed,
      );
      return plan(lines);
    }
    // ② 字号再小一级；到 10sp 仍放不下：地点和教师完整排版、课名 1 行。
    if (ns <= minSize + 1e-6 && ss <= minSize + 1e-6) {
      return plan(1, fits: false);
    }
  }
}

/// 格内最小字号（sp，含系统缩放）。
const double kCellMinFontSize = 10;

/// 教师名单按姓名换行，避免将前后两位教师的名字连在一起拆行。
String cellTeacherText(String teacher) => teacher
    .trim()
    .split(RegExp(r'[,，、;；]\s*'))
    .map((name) => name.trim())
    .where((name) => name.isNotEmpty)
    .join('\n');

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
///   长括注一行放不下 → 自然换行，不把超宽括注粘成不可断单元。
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
  return plain;
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
