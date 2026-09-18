import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/colors.dart';

/// 大 APP 的壳：底部双页签（首页 / 我的），页签内容由路由的
/// StatefulShellRoute 提供（各 branch 独立保留导航状态）。
class RootPage extends StatelessWidget {
  const RootPage({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.divider)),
        ),
        child: BottomNavigationBar(
          type: BottomNavigationBarType.fixed,
          backgroundColor: Colors.white,
          selectedItemColor: AppColors.accent,
          unselectedItemColor: AppColors.tabInactive,
          selectedFontSize: 10,
          unselectedFontSize: 10,
          currentIndex: navigationShell.currentIndex,
          onTap:
              (i) => navigationShell.goBranch(
                i,
                // 重复点击当前页签回到该页签首页。
                initialLocation: i == navigationShell.currentIndex,
              ),
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.home_outlined),
              activeIcon: Icon(Icons.home),
              label: '首页',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.person_outline),
              activeIcon: Icon(Icons.person),
              label: '我的',
            ),
          ],
        ),
      ),
    );
  }
}
