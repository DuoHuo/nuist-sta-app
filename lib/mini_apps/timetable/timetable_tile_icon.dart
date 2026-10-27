import 'package:flutter/material.dart';

/// 首页宫格里课表入口的图形图标：白色日历格（方案 A）。
///
/// 按设计稿 `a-calendar-grid.svg`（viewBox 0 0 24 24）的几何用 [CustomPaint]
/// 绘制：日历外框 + 表头分隔线 + 两根装订钉 + 四格，左上格实心高亮。
/// 图案恒为白色，压在色块的品牌蓝底上，不随主题反色。
class TimetableTileIcon extends StatelessWidget {
  const TimetableTileIcon({super.key});

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size.square(24),
    painter: const _CalendarGridPainter(),
  );
}

/// 以 24×24 为设计坐标系，按实际尺寸等比缩放后绘制。
class _CalendarGridPainter extends CustomPainter {
  const _CalendarGridPainter();

  static const _white = Colors.white;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 24;
    canvas.save();
    canvas.scale(scale, scale);

    final outline = Paint()
      ..color = _white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final cellOutline = Paint()
      ..color = _white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = _white
      ..style = PaintingStyle.fill;

    // 日历外框。
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(3.5, 5.5, 17, 15),
        const Radius.circular(2.2),
      ),
      outline,
    );
    // 表头分隔线。
    canvas.drawLine(const Offset(3.5, 9.2), const Offset(20.5, 9.2), outline);
    // 顶部两根装订钉。
    canvas.drawLine(const Offset(8, 3.8), const Offset(8, 7), outline);
    canvas.drawLine(const Offset(16, 3.8), const Offset(16, 7), outline);

    // 左上格实心高亮。
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(6, 11.2, 4.2, 3.4),
        const Radius.circular(0.6),
      ),
      fill,
    );
    // 其余三格只描边。
    for (final rect in const [
      Rect.fromLTWH(11.4, 11.2, 4.2, 3.4),
      Rect.fromLTWH(6, 15.6, 4.2, 3.2),
      Rect.fromLTWH(11.4, 15.6, 4.2, 3.2),
    ]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(0.6)),
        cellOutline,
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CalendarGridPainter oldDelegate) => false;
}
