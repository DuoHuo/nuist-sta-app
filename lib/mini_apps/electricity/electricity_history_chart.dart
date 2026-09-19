import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/colors.dart';
import 'electricity_controller.dart';
import 'electricity_format.dart';
import 'electricity_models.dart';

/// 历史电量折线图：每天一个点（取当天最后一次记录）。
///
/// 横轴按天离散排布，每天占一格、点落在格子正中；从「窗口起点」和「最早一条
/// 记录当天」中较晚者开始，到今天为止，所以刚开始用时不会在左边留出空白，只有
/// 一天数据时那一天的日期就在正中间。纵轴取数据的实际范围并上下留白。
class ElectricityHistoryChart extends StatelessWidget {
  const ElectricityHistoryChart({
    super.key,
    required this.readings,
    required this.days,
  });

  final List<ElecReading> readings;

  /// 展示最近多少天。
  final int days;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final windowStart = today.subtract(Duration(days: days - 1));

    // readings 按时间升序，同一天后写入的覆盖先写入的，剩下的就是每天最后一条。
    final lastOfDay = <DateTime, ElecReading>{};
    for (final r in readings) {
      if (r.time.isBefore(windowStart)) continue;
      lastOfDay[DateTime(r.time.year, r.time.month, r.time.day)] = r;
    }
    if (lastOfDay.isEmpty) {
      return const SizedBox(
        height: 200,
        child: Center(
          child: Text(
            '暂无记录，刷新后再来看',
            style: TextStyle(fontSize: 12, color: AppColors.hint),
          ),
        ),
      );
    }

    final firstDay = lastOfDay.keys.reduce((a, b) => a.isBefore(b) ? a : b);
    final start = firstDay.isAfter(windowStart) ? firstDay : windowStart;
    final dayCount = today.difference(start).inDays + 1;

    final points = lastOfDay.values.toList()
      ..sort((a, b) => a.time.compareTo(b.time));
    int dayIndex(DateTime t) =>
        DateTime(t.year, t.month, t.day).difference(start).inDays;
    final spots = [
      for (final r in points) FlSpot(dayIndex(r.time).toDouble(), r.kwh),
    ];

    final dataMin = points.map((r) => r.kwh).reduce((a, b) => a < b ? a : b);
    final dataMax = points.map((r) => r.kwh).reduce((a, b) => a > b ? a : b);
    final span = dataMax - dataMin;
    final pad = span < 1 ? 2.0 : span * 0.25;
    final minY = dataMin - pad;
    final maxY = dataMax + pad;

    const threshold = ElectricityController.lowKwhThreshold;
    final showThreshold = threshold > minY && threshold < maxY;

    // 日期刻度控制在 6 个左右。
    final labelInterval = ((dayCount + 5) ~/ 6).toDouble();
    String two(int n) => n.toString().padLeft(2, '0');

    const accent = AppColors.accent;

    return SizedBox(
      height: 200,
      child: LineChart(
        LineChartData(
          minX: -0.5,
          maxX: dayCount - 0.5,
          minY: minY,
          maxY: maxY,
          clipData: const FlClipData.all(),
          gridData: FlGridData(
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) =>
                const FlLine(color: AppColors.rowDivider, strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                getTitlesWidget: (value, meta) {
                  if (value == meta.min || value == meta.max) {
                    return const SizedBox.shrink();
                  }
                  return SideTitleWidget(
                    meta: meta,
                    child: Text(
                      formatKwh(value),
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppColors.hint,
                      ),
                    ),
                  );
                },
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 24,
                interval: labelInterval,
                minIncluded: false,
                maxIncluded: false,
                getTitlesWidget: (value, meta) {
                  final t = start.add(Duration(days: value.round()));
                  return SideTitleWidget(
                    meta: meta,
                    child: Text(
                      '${two(t.month)}-${two(t.day)}',
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppColors.hint,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          extraLinesData: ExtraLinesData(
            horizontalLines: [
              if (showThreshold)
                HorizontalLine(
                  y: threshold,
                  color: ElecColors.warning,
                  strokeWidth: 1,
                  dashArray: [4, 4],
                ),
            ],
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              color: accent,
              barWidth: 2,
              isCurved: false,
              dotData: FlDotData(
                getDotPainter: (_, _, _, _) => FlDotCirclePainter(
                  radius: 2.5,
                  color: Colors.white,
                  strokeWidth: 1.5,
                  strokeColor: accent,
                ),
              ),
              belowBarData: BarAreaData(
                show: spots.length > 1,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    accent.withValues(alpha: 0.18),
                    accent.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ],
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              fitInsideHorizontally: true,
              fitInsideVertically: true,
              getTooltipColor: (_) => AppColors.titleText,
              getTooltipItems: (touched) => [
                for (final spot in touched)
                  LineTooltipItem(
                    '${formatShortTime(points[spot.spotIndex].time)}\n'
                    '${formatKwh(spot.y)} 度',
                    const TextStyle(color: Colors.white, fontSize: 11),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
