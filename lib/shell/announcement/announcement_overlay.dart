import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/colors.dart';
import 'announcement_controller.dart';
import 'announcement_models.dart';
import 'announcement_sheet.dart';

/// 悬浮条自动收起的时长。
const Duration kAnnouncementBannerDuration = Duration(seconds: 8);

/// 首页顶栏的公告铃铛：存在未读可见公告时亮红点，点击打开公告列表并全部标为已读。
class AnnouncementBell extends StatelessWidget {
  const AnnouncementBell({super.key, this.controller});

  /// 为空时使用 [AnnouncementController.instance]。
  final AnnouncementController? controller;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final c = controller ?? AnnouncementController.instance;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => IconButton(
        tooltip: '公告',
        icon: Badge(
          isLabelVisible: c.hasUnread,
          smallSize: 8,
          backgroundColor: palette.danger,
          child: const Icon(Icons.notifications_none),
        ),
        onPressed: () => openAnnouncements(context, c),
      ),
    );
  }
}

/// 打开公告列表：先把当前可见项全部标为已读。
Future<void> openAnnouncements(BuildContext context, AnnouncementController c) {
  final items = c.visible;
  c.markAllVisibleRead();
  return showAnnouncementDialog(context, items);
}

/// 首页公告编排：首帧后静默检查，依次展示不可关闭公告、自动弹出公告，
/// 并在内容之上显示弱提醒悬浮条。只在首页位于栈顶时展示。
class AnnouncementOverlay extends StatefulWidget {
  const AnnouncementOverlay({super.key, required this.child, this.controller});

  final Widget child;

  /// 为空时使用 [AnnouncementController.instance]。
  final AnnouncementController? controller;

  @override
  State<AnnouncementOverlay> createState() => _AnnouncementOverlayState();
}

class _AnnouncementOverlayState extends State<AnnouncementOverlay> {
  AnnouncementController get _c =>
      widget.controller ?? AnnouncementController.instance;

  bool _presenting = false;
  bool _dirty = false;
  List<Announcement>? _banner;
  Timer? _bannerTimer;

  @override
  void initState() {
    super.initState();
    _c.addListener(_maybePresent);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _c.ensureStarted();
      _maybePresent();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 订阅路由状态：从小程序返回首页时重新尝试展示。
    if (ModalRoute.of(context)?.isCurrent ?? false) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybePresent());
    }
  }

  @override
  void dispose() {
    _c.removeListener(_maybePresent);
    _bannerTimer?.cancel();
    super.dispose();
  }

  bool get _onTop => mounted && (ModalRoute.of(context)?.isCurrent ?? true);

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
      // 3. 弱提醒悬浮条：本次进程只弹一次，收起不算已读。
      final badge = _c.unreadBadge;
      if (badge.isNotEmpty && !_c.bannerShownThisLaunch) {
        _c.markBannerShown();
        setState(() => _banner = badge);
        _bannerTimer?.cancel();
        _bannerTimer = Timer(kAnnouncementBannerDuration, _hideBanner);
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
    if (mounted) setState(() => _banner = null);
  }

  @override
  Widget build(BuildContext context) {
    final banner = _banner;
    return Stack(
      children: [
        widget.child,
        if (banner != null)
          Positioned(
            left: 16,
            right: 16,
            top: 8,
            child: _AnnouncementBanner(
              text: banner.length == 1
                  ? banner.first.title
                  : '共 ${banner.length} 条公告',
              onTap: () {
                _hideBanner();
                openAnnouncements(context, _c);
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
    required this.text,
    required this.onTap,
    required this.onClose,
  });

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
              Icon(Icons.campaign_outlined, size: 20, color: palette.accent),
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
      child: Dialog(
        backgroundColor: AppPalette.of(context).pageBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: AnnouncementListPanel(items: [widget.item], dismissible: false),
      ),
    );
  }
}
