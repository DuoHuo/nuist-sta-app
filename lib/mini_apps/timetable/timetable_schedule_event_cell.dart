import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'timetable_schedule_event.dart';
import 'timetable_schedule_event_layout.dart';
import 'timetable_controller.dart';
import 'timetable_theme.dart';

/// 周视图里的一格日程（考试 / 其他，spec §14.2–§14.4）。
///
/// 不可拖动（不挂长按识别器）。考试：底色 = 设置 examColor、白字、「考试」胶囊；
/// 其他：按名称取配色、「日程」胶囊。胶囊样式与课程格「单周」胶囊一致。
/// [stackCount] > 1（同时段还有别的日程）时显示冲突圆点与「N 门」。
///
/// [activeThisWeek]：考试所在周为 true；更早周幽灵为 false → 灰显 +
/// 「考试」与「非本周」双胶囊（互不覆盖）。
class ScheduleEventCell extends StatelessWidget {
  const ScheduleEventCell({
    super.key,
    required this.controller,
    required this.event,
    required this.width,
    required this.height,
    required this.radius,
    this.stackCount = 1,
    this.activeThisWeek = true,
    this.onTap,
    this.fontReferenceWidth,
  });

  final TimetableController controller;
  final ScheduleEvent event;
  final double width;

  /// 整周统一的字号参考格宽，避免列宽像素取整差异触发不同字号。
  final double? fontReferenceWidth;
  final double height;
  final double radius;
  final int stackCount;

  /// 考试：是否为所在周。false（更早周幽灵）→ 灰显 + 双胶囊。
  final bool activeThisWeek;
  final VoidCallback? onTap;

  static const String offWeekLabel = '非本周';

  /// 胶囊实际换行高度与正文共用预留空间，避免大字号或双胶囊遮住正文。
  double _badgeReserveFor(BuildContext context) {
    final available = math.max(1.0, width);
    final labels = stackCount > 1
        ? ['$stackCount 门']
        : [
            schedulePillLabel(event),
            if (event.isExam && !activeThisWeek) offWeekLabel,
          ];
    var totalHeight = 0.0;
    var rowWidth = 0.0;
    var rowHeight = 0.0;
    for (final label in labels) {
      final size = TimetableTheme.cellBadgeSize(
        context,
        label,
        maxWidth: available,
      );
      if (rowWidth > 0 && rowWidth + 2 + size.width > available) {
        totalHeight += rowHeight;
        rowWidth = 0;
        rowHeight = 0;
      }
      rowWidth += (rowWidth > 0 ? 2 : 0) + size.width;
      rowHeight = math.max(rowHeight, size.height);
    }
    return math.max(_badgeReserve, totalHeight + rowHeight) + 2;
  }

  /// 当前格宽下完整显示标题、时间、地点和标签所需的高度，不含格外边距。
  double preferredHeight(BuildContext context) {
    final referenceWidth = fontReferenceWidth ?? width;
    final contentWidth = referenceWidth > 8 ? referenceWidth - 8 : 1.0;
    final sizes = _textSizes(context, contentWidth);
    final base = DefaultTextStyle.of(context).style;
    double textHeight(String text, TextStyle style, {int? maxLines}) {
      if (text.isEmpty) return 0;
      final painter = TextPainter(
        text: TextSpan(text: text, style: base.merge(style)),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: maxLines,
      )..layout(maxWidth: contentWidth);
      final height = painter.height;
      painter.dispose();
      return height;
    }

    return 8 +
        _badgeReserveFor(context) +
        textHeight(
          event.title,
          TimetableTheme.cellStyle().copyWith(fontSize: sizes.nameSize),
        ) +
        textHeight(
          scheduleTimeText(event),
          TimetableTheme.cellSubStyle().copyWith(fontSize: sizes.subSize),
          maxLines: 2,
        ) +
        (controller.settings.showLocation && event.location.isNotEmpty
            ? textHeight(
                '@${event.location}',
                TimetableTheme.cellLocationStyle().copyWith(
                  fontSize: sizes.subSize,
                ),
              )
            : 0);
  }

  ({double nameSize, double subSize}) _textSizes(
    BuildContext context,
    double contentWidth,
  ) => TimetableTheme.cellTextSizesForWidth(
    maxWidth: fontReferenceWidth == null
        ? contentWidth
        : fontReferenceWidth! > 8
        ? fontReferenceWidth! - 8
        : 1.0,
    nameStyle: DefaultTextStyle.of(context).style
        .merge(TimetableTheme.cellStyle()),
    factor: controller.settings.fontScale.factor,
    textScaler: MediaQuery.textScalerOf(context),
    textDirection: Directionality.of(context),
  );

  Widget _content(BuildContext context, double contentWidth, Color fg) {
    if (fontReferenceWidth != null) {
      contentWidth = fontReferenceWidth! > 8 ? fontReferenceWidth! - 8 : 1.0;
    }
    final sizes = _textSizes(context, contentWidth);
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
          Text(
            event.title,
            style: TimetableTheme.cellStyle(color: fg)
                .copyWith(fontSize: sizes.nameSize),
          ),
          Text(
            scheduleTimeText(event),
            maxLines: 2,
            style: TimetableTheme.cellSubStyle(color: fg)
                .copyWith(fontSize: sizes.subSize),
          ),
          if (controller.settings.showLocation && event.location.isNotEmpty)
            Text(
              '@${event.location}',
              style: TimetableTheme.cellLocationStyle(color: fg)
                  .copyWith(fontSize: sizes.subSize),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final dark = colors.isDark;
    final offWeek = event.isExam && !activeThisWeek;
    final bg = scheduleCellBg(
      controller,
      event,
      dark: dark,
      activeThisWeek: activeThisWeek,
    );
    final autoFg = scheduleCellFg(
      controller,
      event,
      dark: dark,
      activeThisWeek: activeThisWeek,
    );
    final readableFg = TimetableTheme.readableCellText(bg, autoFg);
    // item 14：考试格也受「文字颜色」白字 / 黑字强制；非本周灰显仍用 offWeekText。
    final fg = offWeek
        ? autoFg
        : event.isExam
        ? TimetableTheme.cellTextFor(
            readableFg,
            controller.settings.cellTextColor,
          )
        : readableFg;
    final stacked = stackCount > 1;
    final badgeReserve = _badgeReserveFor(context);
    return Semantics(
      button: true,
      label: [
        if (offWeek) offWeekLabel,
        schedulePillLabel(event),
        event.title,
        scheduleTimeText(event),
        if (event.location.isNotEmpty) event.location,
        if (stacked) '本时段 $stackCount 项',
      ].join('，'),
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: Key('schedule_cell_${event.id}'),
          onTap: onTap,
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
                // 边框只覆盖绘制，不内缩正文；与课程格使用相同的参考文字宽度。
                if (offWeek)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        key: const Key('schedule_cell_off_week_border'),
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
                  padding: EdgeInsets.fromLTRB(4, 4, 4, 4 + badgeReserve),
                  child: ClipRect(
                    child: LayoutBuilder(
                      builder: (context, box) =>
                          _content(context, box.maxWidth, fg),
                    ),
                  ),
                ),
                if (stacked)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Container(
                      key: const Key('schedule_cell_conflict_dot'),
                      width: TimetableTheme.conflictDotSize,
                      height: TimetableTheme.conflictDotSize,
                      decoration: BoxDecoration(
                        color: fg,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 3,
                  child: Center(
                    child: stacked
                        ? SchedulePill(
                            key: const Key('schedule_cell_stack_badge'),
                            text: '$stackCount 门',
                            color: fg,
                          )
                        : Wrap(
                            spacing: 2,
                            alignment: WrapAlignment.center,
                            children: [
                              SchedulePill(
                                key: Key(
                                  event.isExam
                                      ? 'schedule_cell_exam_pill'
                                      : 'schedule_cell_other_pill',
                                ),
                                text: schedulePillLabel(event),
                                color: fg,
                              ),
                              if (offWeek)
                                // 「非本周」已在语义标签念过，胶囊不再重复。
                                ExcludeSemantics(
                                  child: SchedulePill(
                                    key: const Key(
                                      'schedule_cell_off_week_pill',
                                    ),
                                    text: offWeekLabel,
                                    color: fg,
                                  ),
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

  static const double _badgeReserve = 10;
}
