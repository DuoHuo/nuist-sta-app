import 'package:flutter/material.dart';

abstract final class MapPalette {
  static const blue = Color(0xFF1475F5);
  static const ink = Color(0xFF20252D);
  static const secondary = Color(0xFF686F79);
  static const surface = Color(0xFFF7F8FA);
  static const field = Color(0xFFEDEEF1);
  static const line = Color(0xFFE4E6E9);
  static const green = Color(0xFF34856C);
}

class MapSurface extends StatelessWidget {
  const MapSurface({
    super.key,
    required this.child,
    this.radius = 20,
    this.padding = EdgeInsets.zero,
  });
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .97),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: Colors.white.withValues(alpha: .9)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x14252F3D),
          blurRadius: 28,
          offset: Offset(0, 8),
        ),
      ],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Material(
        color: Colors.transparent,
        child: Padding(padding: padding, child: child),
      ),
    ),
  );
}

class MapIconButton extends StatelessWidget {
  const MapIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.active = false,
    this.color,
    this.busy = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool active;
  final Color? color;

  /// 进行中：显示进度圈并禁止重复触发，但不改变按钮配色。
  final bool busy;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: label,
    onPressed: onPressed,
    isSelected: active,
    style: IconButton.styleFrom(
      minimumSize: const Size(48, 48),
      foregroundColor: color ?? (active ? MapPalette.blue : MapPalette.ink),
      backgroundColor: active
          ? MapPalette.blue.withValues(alpha: .09)
          : Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    icon: busy
        ? const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          )
        : Icon(icon, size: 23),
  );
}

class MapAction extends StatelessWidget {
  const MapAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.primary = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    onPressed: onPressed,
    icon: Icon(icon, size: 21),
    label: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
    style: FilledButton.styleFrom(
      minimumSize: const Size(0, 50),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      backgroundColor: primary
          ? MapPalette.blue
          : MapPalette.blue.withValues(alpha: .09),
      foregroundColor: primary ? Colors.white : MapPalette.blue,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
    ),
  );
}

class MapSectionTitle extends StatelessWidget {
  const MapSectionTitle(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: -.3,
          ),
        ),
      ),
      ?trailing,
    ],
  );
}
