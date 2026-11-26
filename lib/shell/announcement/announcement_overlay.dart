import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/colors.dart';
import '../../core/logging/app_log.dart';
import '../../core/navigation/app_navigation.dart';
import '../../core/privacy/privacy_consent.dart';
import '../update/update_controller.dart';
import '../update/update_dialog.dart';
import '../update/update_models.dart';
import 'announcement_controller.dart';
import 'announcement_models.dart';
import 'announcement_sheet.dart';

/// 悬浮条自动收起的时长。
const Duration kAnnouncementBannerDuration = Duration(seconds: 8);

final _announcementOverlayLog = AppLog.logger('shell.announcement.overlay');

/// 将根壳路由的可见性传给嵌套首页，包含普通对话框和公告网页的遮挡。
class AnnouncementRouteScope extends InheritedWidget {
  const AnnouncementRouteScope({
    super.key,
    required this.isCurrent,
    required super.child,
  });

  final bool isCurrent;

  /// 首页订阅根路由变化，根导航器的非 GoRouter 路由关闭后也能补展示。
  static bool? isCurrentOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AnnouncementRouteScope>()
      ?.isCurrent;

  @override
  bool updateShouldNotify(AnnouncementRouteScope oldWidget) =>
      isCurrent != oldWidget.isCurrent;
}

/// 顶栏的公告铃铛：存在未读可见公告时亮红点，点击打开公告列表并全部标为已读。
class AnnouncementBell extends StatelessWidget {
  const AnnouncementBell({super.key, this.controller, this.updates});

  /// 为空时使用 [AnnouncementController.instance]。
  final AnnouncementController? controller;
  final UpdateController? updates;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final c = controller ?? AnnouncementController.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([c, updates]),
      builder: (context, _) => IconButton(
        tooltip: '公告',
        icon: Badge(
          isLabelVisible:
              c.hasUnread || (updates?.hasUnreadAnnouncement ?? false),
          smallSize: 8,
          backgroundColor: palette.danger,
          child: const Icon(Icons.notifications_none),
        ),
        onPressed: () => openAnnouncements(context, c, updates: updates),
      ),
    );
  }
}

/// 打开公告列表：先把当前可见项全部标为已读，并在关闭时补标打开期间渲染过的公告。
Future<void> openAnnouncements(
  BuildContext context,
  AnnouncementController c, {
  UpdateController? updates,
}) {
  final scope = AppNavigationScope.readOf(context);
  final rootNavigator =
      scope?.navigation.rootNavigatorKey.currentState ??
      Navigator.of(context, rootNavigator: true);
  final dialogContext = rootNavigator.context;
  Size? overlaySize;
  final overlayRender = rootNavigator.overlay?.context.findRenderObject();
  if (overlayRender is RenderBox && overlayRender.hasSize) {
    overlaySize = overlayRender.size;
  }
  _announcementOverlayLog.debug(
    'dialog.open',
    fields: {
      'has_scope': scope != null,
      'wide': scope?.wide ?? false,
      'target_navigator': rootNavigator.widget.key?.toString() ?? 'unknown',
      'overlay_width': overlaySize?.width.round(),
      'overlay_height': overlaySize?.height.round(),
    },
  );
  final shownAnnouncementIds = <String>{for (final item in c.visible) item.id};
  // 对话框持续订阅，更新撤回后同步移除对应条目。
  final dialog = showDialog<void>(
    context: dialogContext,
    useRootNavigator: true,
    builder: (_) => ListenableBuilder(
      listenable: Listenable.merge([c, updates]),
      builder: (_, _) {
        final update = _updateAnnouncement(updates);
        final realItems = c.visible
            .where((item) => item.id != update?.id)
            .toList();
        for (final item in realItems) {
          shownAnnouncementIds.add(item.id);
        }
        return AnnouncementDialog(
          // 更新固定排首位，普通公告继续沿用置顶和发布时间顺序。
          items: [?update, ...realItems],
          localActions: {
            if (update != null)
              update.id: AnnouncementLocalAction(
                label: '查看更新',
                onPressed: () =>
                    showUpdateDetails(dialogContext, controller: updates),
              ),
          },
        );
      },
    ),
  );
  c.markAllVisibleRead();
  if (_updateAnnouncement(updates) != null) updates?.markAnnouncementRead();
  return dialog.whenComplete(() {
    if (shownAnnouncementIds.isNotEmpty) {
      unawaited(c.markRead(shownAnnouncementIds));
    }
  });
}

Announcement? _updateAnnouncement(UpdateController? updates) {
  final release = updates?.available;
  if (release == null) return null;
  return Announcement(
    id: 'app-update:${release.revision}',
    title: '发现新版本 v${release.versionName}',
    summary: '应用更新 · ${formatUpdateBytes(release.size)}',
    content: '',
    publishedAt: release.publishedAt,
    remind: AnnouncementRemind.badge,
    tone: AnnouncementTone.notice,
  );
}

/// 首页公告编排：首帧后静默检查，依次展示不可关闭公告、自动弹出公告，
/// 并在内容之上显示弱提醒悬浮条。只在首页位于栈顶时展示。
class AnnouncementOverlay extends StatefulWidget {
  const AnnouncementOverlay({
    super.key,
    required this.child,
    this.controller,
    this.updates,
  });

  final Widget child;

  /// 为空时使用 [AnnouncementController.instance]。
  final AnnouncementController? controller;

  /// 首页可接入更新提示，与公告共用顺序，独立公告测试无需启动更新。
  final UpdateController? updates;

  @override
  State<AnnouncementOverlay> createState() => _AnnouncementOverlayState();
}

class _AnnouncementOverlayState extends State<AnnouncementOverlay> {
  AnnouncementController get _c =>
      widget.controller ?? AnnouncementController.instance;

  bool _presenting = false;
  bool _dirty = false;
  UpdateRelease? _updateBanner;
  List<Announcement>? _announcementBanner;
  bool _updateBannerShownThisLaunch = false;
  Timer? _bannerTimer;
  bool _announcementsReady = false;
  GoRouter? _router;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onAnnouncementsChanged);
    widget.updates?.addListener(_onUpdatesChanged);
    PrivacyConsent.dialogPending.addListener(_onPrivacyPendingChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _c.ensureStarted().whenComplete(() {
        _announcementsReady = true;
        if (mounted) _maybePresent();
      });
      if (!PrivacyConsent.dialogPending.value) {
        widget.updates?.onLaunch();
      }
      _maybePresent();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final router = GoRouter.maybeOf(context);
    if (_router != router) {
      _router?.routerDelegate.removeListener(_onRouteChanged);
      _router = router;
      _router?.routerDelegate.addListener(_onRouteChanged);
    }
    // 同时订阅根壳路由：对话框关闭不一定触发 GoRouter 的路由变化。
    AppNavigationScope.maybeOf(context);
    if (AnnouncementRouteScope.isCurrentOf(context) != false && _onTop) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybePresent());
    }
  }

  @override
  void dispose() {
    _c.removeListener(_onAnnouncementsChanged);
    widget.updates?.removeListener(_onUpdatesChanged);
    PrivacyConsent.dialogPending.removeListener(_onPrivacyPendingChanged);
    _router?.routerDelegate.removeListener(_onRouteChanged);
    _bannerTimer?.cancel();
    super.dispose();
  }

  bool get _onTop {
    if (!mounted ||
        PrivacyConsent.dialogPending.value ||
        !TickerMode.valuesOf(context).enabled ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return false;
    }
    // 双栏的首页可见性独立于最近操作栏的 URI。
    // 直接读导航器，避免刚关闭提示时继承的根路由快照尚未重建。
    final scope = AppNavigationScope.readOf(context);
    return (scope?.visible ??
            (_router == null ||
                _router!.routerDelegate.currentConfiguration.uri.path ==
                    '/')) &&
        !Navigator.of(context, rootNavigator: true).canPop();
  }

  void _onRouteChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_maybePresent());
    });
  }

  void _onAnnouncementsChanged() {
    if (!mounted) return;
    setState(() {});
    unawaited(_maybePresent());
  }

  void _onUpdatesChanged() {
    if (!mounted) return;
    setState(() {});
    unawaited(_maybePresent());
  }

  void _onPrivacyPendingChanged() {
    if (!mounted || PrivacyConsent.dialogPending.value) return;
    widget.updates?.onLaunch();
    _schedulePresentAfterRootPop();
  }

  void _schedulePresentAfterRootPop([int remainingFrames = 30]) {
    if (!mounted || PrivacyConsent.dialogPending.value) return;
    if (!Navigator.of(context, rootNavigator: true).canPop() ||
        remainingFrames <= 0) {
      unawaited(_maybePresent());
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _schedulePresentAfterRootPop(remainingFrames - 1);
    });
  }

  Future<void> _maybePresent() async {
    if (_presenting) {
      // 展示期间数据有更新（如拉取完成），结束后再检查一轮。
      _dirty = true;
      return;
    }
    if (!_onTop) return;
    _presenting = true;
    _dirty = false;
    try {
      // 1. 不可关闭的公告：逐条单独展示，展示前再查一次是否已释放。
      while (_onTop) {
        final blocking = _c.blocking;
        if (blocking.isEmpty) break;
        await showDialog<void>(
          context: context,
          useRootNavigator: true,
          barrierDismissible: false,
          builder: (_) => _BlockingDialog(controller: _c, item: blocking.first),
        );
        // 防止对话框因外部原因被关闭但条目仍有效时死循环。
        if (_c.blocking.any((a) => a.id == blocking.first.id)) break;
      }
      if (!_onTop || _c.blocking.isNotEmpty) return;
      // 2. 自动弹出：关闭即标为已读。
      final popup = _c.unreadPopup;
      if (popup.isNotEmpty && mounted) {
        await showAnnouncementDialog(context, popup);
        await _c.markRead(popup.map((a) => a.id));
      }
      if (!_onTop) return;
      // 公告检查结束且没有其他弹窗时，才展示自动更新提示。
      final updates = widget.updates;
      if (_announcementsReady &&
          updates != null &&
          updates.shouldPrompt &&
          mounted) {
        final release = updates.available!;
        updates.markPrompted(release);
        await showUpdateDetails(context, controller: updates, automatic: true);
      }
      if (!_onTop) return;
      // 3. 弱提醒悬浮条：新版本与公告彻底分离，本次进程有新版本时只弹新版本悬浮条。
      if (updates != null && updates.shouldShowBanner) {
        updates.markBannerShown();
        _updateBannerShownThisLaunch = true;
        _c.markBannerShown();
        setState(() {
          _updateBanner = updates.available;
          _announcementBanner = null;
        });
        _bannerTimer?.cancel();
        _bannerTimer = Timer(kAnnouncementBannerDuration, _hideBanner);
      } else {
        final waitingForUpdates =
            updates != null &&
            !updates.disabled &&
            (!updates.initialized ||
                updates.checking ||
                updates.awaitingInitialCheck);
        if (!waitingForUpdates &&
            !_updateBannerShownThisLaunch &&
            !(updates?.hasUnreadAnnouncement ?? false) &&
            !_c.bannerShownThisLaunch &&
            _c.unreadBadge.isNotEmpty) {
          _c.markBannerShown();
          setState(() {
            _announcementBanner = List<Announcement>.of(_c.unreadBadge);
            _updateBanner = null;
          });
          _bannerTimer?.cancel();
          _bannerTimer = Timer(kAnnouncementBannerDuration, _hideBanner);
        }
      }
    } finally {
      _presenting = false;
      if (_dirty && mounted) {
        _dirty = false;
        WidgetsBinding.instance.addPostFrameCallback((_) => _maybePresent());
      }
    }
  }

  void _hideBanner() {
    _bannerTimer?.cancel();
    _bannerTimer = null;
    if (mounted) {
      setState(() {
        _updateBanner = null;
        _announcementBanner = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final updates = widget.updates;
    final updateBanner = _updateBanner;
    final showUpdateBanner =
        updateBanner != null &&
        updates != null &&
        updates.hasUnreadAnnouncement &&
        updates.available?.revision == updateBanner.revision &&
        (!updates.task.hasTask || updates.taskSuperseded);
    final unreadBadgeIds = {for (final item in _c.unreadBadge) item.id};
    final announcementBanner = showUpdateBanner
        ? null
        : _announcementBanner
              ?.where((item) => unreadBadgeIds.contains(item.id))
              .toList();
    return Stack(
      children: [
        widget.child,
        if (showUpdateBanner)
          Positioned(
            left: 16,
            right: 16,
            top: 8,
            child: _AnnouncementBanner(
              icon: Icons.system_update_rounded,
              text: '发现新版本 v${updateBanner.versionName}',
              onTap: () {
                _hideBanner();
                unawaited(updates.markAnnouncementRead());
                showUpdateDetails(context, controller: updates);
              },
              onClose: _hideBanner,
            ),
          )
        else if (announcementBanner != null && announcementBanner.isNotEmpty)
          Positioned(
            left: 16,
            right: 16,
            top: 8,
            child: _AnnouncementBanner(
              icon: Icons.campaign_outlined,
              text: announcementBanner.length == 1
                  ? announcementBanner.first.title
                  : '共 ${announcementBanner.length} 条公告',
              onTap: () {
                _hideBanner();
                openAnnouncements(context, _c, updates: widget.updates);
              },
              onClose: _hideBanner,
            ),
          ),
      ],
    );
  }
}

class _AnnouncementBanner extends StatelessWidget {
  const _AnnouncementBanner({
    required this.icon,
    required this.text,
    required this.onTap,
    required this.onClose,
  });

  final IconData icon;
  final String text;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Material(
      // 悬浮条是贴在页面内容之上的面板，底色随主题走。
      color: palette.surface,
      elevation: 3,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(left: 14),
          child: Row(
            children: [
              Icon(icon, size: 20, color: palette.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: palette.titleText),
                ),
              ),
              IconButton(
                tooltip: '收起',
                icon: Icon(Icons.close, size: 18, color: palette.hint),
                onPressed: onClose,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 不可关闭的公告对话框：无关闭按钮、拦截返回键；过期或被服务器移除后自动关闭。
class _BlockingDialog extends StatefulWidget {
  const _BlockingDialog({required this.controller, required this.item});

  final AnnouncementController controller;
  final Announcement item;

  @override
  State<_BlockingDialog> createState() => _BlockingDialogState();
}

class _BlockingDialogState extends State<_BlockingDialog> {
  Timer? _timer;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_check);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.controller.removeListener(_check);
    super.dispose();
  }

  void _check() {
    if (!mounted || _closed) return;
    final released = !widget.controller.blocking.any(
      (a) => a.id == widget.item.id,
    );
    if (released) {
      _closed = true;
      _timer?.cancel();
      // 只移除对话框自身路由：其上可能叠着公告网页，直接 pop 会弹错路由。
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
      return;
    }
    // 按剩余时长定时重检；时钟可能被调整，至少 1 秒后再查。
    var wait = widget.item.expiresAt!.difference(widget.controller.now);
    if (wait < const Duration(seconds: 1)) wait = const Duration(seconds: 1);
    _timer?.cancel();
    _timer = Timer(wait, _check);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AnnouncementDialog(items: [widget.item], dismissible: false),
    );
  }
}
