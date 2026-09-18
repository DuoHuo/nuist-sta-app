import 'package:flutter/material.dart';

import '../../core/colors.dart';

/// 校园地图小程序入口页：当前为占位，功能另行开发。
class CampusMapPage extends StatelessWidget {
  const CampusMapPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('校园地图')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.map_outlined, size: 48, color: AppColors.hint),
            const SizedBox(height: 12),
            const Text(
              '建设中',
              style: TextStyle(color: AppColors.hint, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
