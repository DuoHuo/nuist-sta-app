import 'package:flutter/material.dart';

/// 顶栏标题占位：正式名称定稿后改这一处即可全局生效（顶栏、系统任务栏等）。
const String kAppName = 'APP名称';

/// 与设计稿 design/home.op 保持一致的颜色。
abstract final class AppColors {
  static const pageBg = Color(0xFFF5F6F8);
  static const titleText = Color(0xFF171A1F);
  static const labelText = Color(0xFF4A4F66);
  static const hint = Color(0xFF9AA0B4);
  static const rowDivider = Color(0xFFF0F1F3);
  static const accent = Color(0xFF0082EF);
  static const tabInactive = Color(0xFF8A8F99);
  static const divider = Color(0xFFE5E6EB);
}

/// 未实现功能的统一占位反馈。
void showWipSnackBar(BuildContext context, String label) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text('「$label」开发中')));
}

/// 首页宫格里的一个应用。
///
/// 新增应用：在 [HomePage.apps] 里加一条数据即可，
/// 宫格按每行 4 个自动排版，无需改动任何布局代码。
class AppItem {
  const AppItem({
    required this.label,
    required this.color,
    this.glyph,
    this.icon,
    this.onTap,
  });

  final String label;
  final Color color;

  /// 图标底色上的单字，如「图」。与设计稿一致的首选图标形式。
  final String? glyph;

  /// 备选：Material 图标。glyph 与 icon 同时存在时 glyph 优先。
  final IconData? icon;

  final VoidCallback? onTap;
}

void main() => runApp(const NuistApp());

class NuistApp extends StatelessWidget {
  const NuistApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: kAppName,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: AppColors.pageBg,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          centerTitle: true,
          elevation: 0,
          titleTextStyle: TextStyle(
            color: AppColors.titleText,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      home: const RootPage(),
    );
  }
}

class RootPage extends StatefulWidget {
  const RootPage({super.key});

  @override
  State<RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<RootPage> {
  int _index = 0;

  static const _pages = [HomePage(), ProfilePage()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
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
          currentIndex: _index,
          onTap: (i) => setState(() => _index = i),
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

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  /// 首页应用数据源：目前只有校园地图，往下加就是了。
  static const apps = <AppItem>[
    AppItem(label: '校园地图', color: Color(0xFF00B578), icon: Icons.map),
    // AppItem(label: '社团大全', glyph: '团', color: Color(0xFF4A7DFF)),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(kAppName)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 14,
              childAspectRatio: 0.86,
              children: [
                for (final app in apps)
                  AppGridItem(
                    app: app,
                    onTap: () => showWipSnackBar(context, app.label),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AppGridItem extends StatelessWidget {
  const AppGridItem({super.key, required this.app, required this.onTap});

  final AppItem app;
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

/// 「我的」页的功能入口行。
class ProfileTile {
  const ProfileTile({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
}

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  static const _tiles = <ProfileTile>[
    ProfileTile(icon: Icons.groups, label: '我的社团'),
    ProfileTile(icon: Icons.event, label: '我的活动'),
    ProfileTile(icon: Icons.settings_outlined, label: '设置'),
    ProfileTile(icon: Icons.info_outline, label: '关于'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          // 用户卡片：登录前展示占位态，接好账号体系后替换成真实资料。
          _UserCard(onTap: () => showWipSnackBar(context, '登录')),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                for (final tile in _tiles)
                  _ProfileListTile(
                    tile: tile,
                    showDivider: tile != _tiles.last,
                    onTap: () => showWipSnackBar(context, tile.label),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UserCard extends StatelessWidget {
  const _UserCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 92,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const CircleAvatar(
              radius: 28,
              backgroundColor: AppColors.accent,
              child: Icon(Icons.person, color: Colors.white, size: 30),
            ),
            const SizedBox(width: 14),
            const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '点击登录',
                  style: TextStyle(
                    color: AppColors.titleText,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 5),
                Text(
                  '登录后同步我的社团与活动',
                  style: TextStyle(color: AppColors.hint, fontSize: 11),
                ),
              ],
            ),
            const Spacer(),
            const Icon(Icons.chevron_right, color: Color(0xFFC9CDD4)),
          ],
        ),
      ),
    );
  }
}

class _ProfileListTile extends StatelessWidget {
  const _ProfileListTile({
    required this.tile,
    required this.showDivider,
    required this.onTap,
  });

  final ProfileTile tile;
  final bool showDivider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Column(
        children: [
          SizedBox(
            height: 52,
            child: Row(
              children: [
                Icon(tile.icon, color: AppColors.labelText, size: 20),
                const SizedBox(width: 12),
                Text(
                  tile.label,
                  style: const TextStyle(
                    color: Color(0xFF1F2329),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                const Icon(Icons.chevron_right, color: Color(0xFFC9CDD4)),
              ],
            ),
          ),
          if (showDivider)
            const Divider(height: 1, color: AppColors.rowDivider),
        ],
      ),
    );
  }
}
