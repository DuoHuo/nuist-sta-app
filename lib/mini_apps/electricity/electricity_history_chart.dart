import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/colors.dart';
import 'electricity_controller.dart';
import 'electricity_format.dart';
import 'electricity_models.dart';

/// 历史电量折线图：x 轴按真实时间铺开，10 度处画一条橙色警戒虚线。
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
    final end = DateTime.now();
    final start = end.subtract(Duration(days: days));
    final inRange = readings.where((r) => !r.time.isBefore(start)).toList();
    if (inRange.length < 2) {
      return const SizedBox(
        height: 200,
        child: Center(
          child: Text(
            '记录不足，刷新几次后再来看',
            style: TextStyle(fontSize: 12, color: AppColors.hint),
          ),
        ),
      );
    }

    double hoursOf(DateTime t) => t.difference(start).inMinutes / 60;
    final spots = [for (final r in inRange) FlSpot(hoursOf(r.time), r.kwh)];
    final maxHours = days * 24.0;

    var minY = inRange.map((r) => r.kwh).reduce((a, b) => a < b ? a : b);
    var maxY = inRange.map((r) => r.kwh).reduce((a, b) => a > b ? a : b);
    // 警戒线也算进纵轴范围，免得它画到图外面去。
    minY = minY < ElectricityController.lowKwhThreshold
        ? minY
        : ElectricityController.lowKwhThreshold;
    final span = (maxY - minY).abs();
    final pad = span < 1 ? 2.0 : span * 0.15;
    minY = (minY - pad).clamp(0, double.infinity);
    maxY = maxY + pad;

    const accent = AppColors.accent;
    final labelInterval = days <= 7 ? 24.0 : 24.0 * 5;

    return SizedBox(
      height: 200,
      child: LineChart(
        LineChartData(
          minX: 0,
          maxX: maxHours,
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
                reservedSize: 36,
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
                getTitlesWidget: (value, meta) {
                  if (value >= maxHours) return const SizedBox.shrink();
                  final t = start.add(Duration(minutes: (value * 60).round()));
                  String two(int n) => n.toString().padLeft(2, '0');
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
              HorizontalLine(
                y: ElectricityController.lowKwhThreshold,
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
                show: spots.length <= 40,
                getDotPainter: (_, _, _, _) => FlDotCirclePainter(
                  radius: 2.5,
                  color: Colors.white,
                  strokeWidth: 1.5,
                  strokeColor: accent,
                ),
              ),
              belowBarData: BarAreaData(
                show: true,
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
                    '${formatShortTime(inRange[spot.spotIndex].time)}\n'
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
