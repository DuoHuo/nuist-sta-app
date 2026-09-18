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
            child: app.glyph != null
                ? Text(
                    app.glyph!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                : Icon(app.icon, color: Colors.white, size: 24),
          ),
          const SizedBox(height: 7),
          Text(
            app.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.labelText, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
