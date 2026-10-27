import 'package:flutter/material.dart';

import '../../core/app_manifest.dart';
import '../../core/colors.dart';

/// 首页宫格里的一个小程序入口卡片。
class AppGridItem extends StatelessWidget {
  const AppGridItem({super.key, required this.app, required this.onTap});

  final AppManifest app;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: app.color,
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: _buildIcon(),
          ),
          const SizedBox(height: 7),
          Text(
            app.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: palette.labelText, fontSize: 12),
          ),
        ],
      ),
    );
  }

  /// 色块里的图形：自定义图形 > 单字 glyph > Material 图标。
  Widget _buildIcon() {
    if (app.iconWidget case final build?) {
      // 统一按 24dp 摆，图形自己铺满这个方框。
      return SizedBox.square(dimension: 24, child: Builder(builder: build));
    }
    if (app.glyph case final glyph?) {
      return Text(
        glyph,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    return Icon(app.icon, color: Colors.white, size: 24);
  }
}
