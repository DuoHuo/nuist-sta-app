import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/colors.dart';

/// 大 APP 的壳：底部三页签（首页 / 学习 / 我的），页签内容由路由的
/// StatefulShellRoute 提供（各 branch 独立保留导航状态）。
class RootPage extends StatelessWidget {
  const RootPage({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static const _items = <_TabItem>[
    _TabItem(Icons.home_outlined, Icons.home, '首页'),
    _TabItem(Icons.school_outlined, Icons.school, '学习'),
    _TabItem(Icons.person_outline, Icons.person, '我的'),
  ];

  @override
  Widget build(BuildContext context) {
    final current = navigationShell.currentIndex;
    return Scaffold(
      body: navigationShell,
      // 不用 BottomNavigationBar：它的水波纹以整条栏为画布铺开。
      // 每个条目各自一块 Material + InkWell，涟漪只落在被按的格子里。
      bottomNavigationBar: Material(
        color: Colors.white,
        child: Container(
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppColors.divider)),
          ),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 56,
              child: Row(
                children: [
                  for (var i = 0; i < _items.length; i++)
                    Expanded(
                      child: _TabButton(
                        item: _items[i],
                        selected: i == current,
                        onTap: () => navigationShell.goBranch(
                          i,
                          // 重复点击当前页签回到该页签首页。
                          initialLocation: i == current,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TabItem {
  const _TabItem(this.icon, this.activeIcon, this.label);

  final IconData icon;
  final IconData activeIcon;
  final String label;
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _TabItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accent : AppColors.tabInactive;
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(selected ? item.activeIcon : item.icon, color: color),
            const SizedBox(height: 2),
            Text(item.label, style: TextStyle(color: color, fontSize: 10)),
          ],
        ),
      ),
    );
  }
}
