import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/colors.dart';
import '../core/layout/app_pane_layout.dart';
import '../core/navigation/app_navigation.dart';
import 'announcement/announcement_controller.dart';
import 'announcement/announcement_overlay.dart';
import 'update/update_controller.dart';

/// 按窗口宽度展示一个或两个分支，各导航器始终留在同一个 Stack 槽位。
class RootPage extends StatefulWidget {
  const RootPage({
    super.key,
    required this.navigationShell,
    required this.navigation,
    required this.children,
    this.updates,
    this.announcements,
  });

  final StatefulNavigationShell navigationShell;
  final AppNavigationController navigation;
  final List<Widget> children;

  /// 宽屏全局通知入口与首页共用的控制器。
  final UpdateController? updates;
  final AnnouncementController? announcements;

  @override
  State<RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<RootPage> {
  final _lastRects = <int, Rect>{};

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_recordInputFocus);
  }

  void _recordInputFocus() {
    final focus = FocusManager.instance.primaryFocus;
    final focusContext = focus?.context;
    if (focusContext == null || !focusContext.mounted) return;
    // 只记录真实输入焦点，忽略预加载导航器自动取得的 FocusScope 焦点。
    if (focusContext.widget is! EditableText &&
        focusContext.findAncestorWidgetOfExactType<EditableText>() == null) {
      return;
    }
    final scope = AppNavigationScope.readOf(focusContext);
    if (scope == null || scope.navigation != widget.navigation) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !focusContext.mounted ||
          FocusManager.instance.primaryFocus != focus) {
        return;
      }
      widget.navigation.interact(scope.branch);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_recordInputFocus);
    super.dispose();
  }

  static const _phoneItems = <_TabItem>[
    _TabItem(Icons.home_outlined, Icons.home, '首页', 0),
    _TabItem(Icons.school_outlined, Icons.school, '学习', 1),
    _TabItem(Icons.person_outline, Icons.person, '我的', 2),
  ];
  static const _wideItems = <_TabItem>[
    _TabItem(Icons.dashboard_outlined, Icons.dashboard, '首页+学习', 0),
    _TabItem(Icons.person_outline, Icons.person, '我的', 2),
  ];

  @override
  Widget build(BuildContext context) {
    return BackButtonListener(
      onBackButtonPressed: widget.navigation.handleBack,
      child: ListenableBuilder(
        listenable: widget.navigation,
        builder: (context, _) => LayoutBuilder(
          builder: (context, constraints) {
            final palette = AppPalette.of(context);
            final media = MediaQuery.of(context)
                .copyWith(size: constraints.biggest);
            final layout = AppPaneLayout.resolve(media);
            final navigation = widget.navigation;
            final current = navigation.updateLayout(wide: layout.wide);
            final combined = layout.wide && current != 2;
            final showBar = layout.wide || !navigation.hasDetails(current);
            Widget tabButton(_TabItem item) => _TabButton(
              item: item,
              selected: layout.wide
                  ? (item.branch == 2) == (current == 2)
                  : item.branch == current,
              onTap: () => navigation.showBranch(item.branch),
            );
            final region = current == 2
                ? layout.windowRegion
                : combined
                ? layout.region
                : layout.singleRegion;
            final barHeight = showBar
                ? math
                      .max(56.0, 30 + media.textScaler.scale(10))
                      .clamp(0.0, region.height)
                : 0.0;
            Rect contentRect(Rect rect) => Rect.fromLTRB(
              rect.left,
              rect.top,
              rect.right,
              math.max(rect.top, rect.bottom - barHeight),
            );
            final singleRect = contentRect(region);
            final rects = <int, Rect>{
              if (combined) ...{
                0: contentRect(layout.home!),
                1: contentRect(layout.study!),
              } else
                current: singleRect,
            };
            _lastRects.addAll(rects);
            final scaffold = Scaffold(
              resizeToAvoidBottomInset: false,
              backgroundColor: palette.pageBg,
              body: Stack(
                children: [
                  for (var index = 0; index < widget.children.length; index++)
                    _pane(
                      index,
                      rects[index] ?? _lastRects[index] ?? singleRect,
                      media,
                      visible: rects.containsKey(index),
                      wide: layout.wide,
                    ),
                  if (combined &&
                      !(navigation.branchNavigatorKeys[1].currentState
                              ?.canPop() ??
                          false))
                    Positioned(
                      left: rects[1]!.right - kMinInteractiveDimension,
                      top: rects[1]!.top,
                      width: kMinInteractiveDimension,
                      height: kToolbarHeight,
                      child: Center(
                        // 全局入口不改变活动栏，弹层也由根导航器统一管理。
                        child: AnnouncementBell(
                          updates: widget.updates ?? UpdateController.instance,
                          controller: widget.announcements,
                        ),
                      ),
                    ),
                ],
              ),
              // 真实底栏参与 Scaffold 几何，浮动提示显示在入口上方。
              bottomNavigationBar: showBar
                  ? SizedBox(
                      height: media.size.height - region.bottom + barHeight,
                      child: Stack(
                        children: [
                          Positioned(
                            left: region.left,
                            top: 0,
                            width: region.width,
                            height: barHeight,
                            child: Material(
                              color: palette.surface,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  border: Border(
                                    top: BorderSide(color: palette.divider),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    if (combined &&
                                        layout.separatedByHinge) ...[
                                      SizedBox(
                                        width: layout.home!.width,
                                        child: tabButton(_wideItems[0]),
                                      ),
                                      SizedBox(
                                        width:
                                            layout.study!.left -
                                            layout.home!.right,
                                      ),
                                      SizedBox(
                                        width: layout.study!.width,
                                        child: tabButton(_wideItems[1]),
                                      ),
                                    ] else
                                      for (final item
                                          in layout.wide
                                              ? _wideItems
                                              : _phoneItems)
                                        Expanded(child: tabButton(item)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : null,
            );
            // 面板切换只改变可见性，也要通知根路由更新系统返回登记。
            // 仅有可见详情、内部保护或弹层时接管，耗尽后立即恢复系统退出。
            return PopScope(canPop: !navigation.canHandleBack, child: scaffold);
          },
        ),
      ),
    );
  }

  Widget _pane(
    int index,
    Rect rect,
    MediaQueryData media, {
    required bool visible,
    required bool wide,
  }) => Positioned.fromRect(
    key: ValueKey('app-pane-$index'),
    rect: rect,
    child: AppNavigationScope(
      navigation: widget.navigation,
      branch: index,
      visible: visible,
      wide: wide,
      child: Offstage(
        offstage: !visible,
        child: TickerMode(
          enabled: visible,
          child: FocusScope(
            canRequestFocus: visible,
            onKeyEvent: (_, event) {
              widget.navigation.interact(index);
              return KeyEventResult.ignored;
            },
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => widget.navigation.interact(index),
              child: MediaQuery(
                data: AppPaneLayout.mediaForRect(media, rect),
                child: ClipRect(
                  child: NotificationListener<NavigationNotification>(
                    // 隐藏分支的返回通知不能改写 Android 当前窗口的返回登记。
                    onNotification: (_) => !visible,
                    child: widget.children[index],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _TabItem {
  const _TabItem(this.icon, this.activeIcon, this.label, this.branch);

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final int branch;
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
    final palette = AppPalette.of(context);
    final color = selected ? palette.accent : palette.tabInactive;
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
