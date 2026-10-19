import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/colors.dart';
import 'bulletin_controller.dart';
import 'bulletin_detail_page.dart';
import 'bulletin_models.dart';

/// 首页展示用户订阅主题命中的最新公告。
class BulletinHomeCard extends StatefulWidget {
  /// 创建展示订阅动态的首页卡片。
  const BulletinHomeCard({super.key, this.controller});

  /// 可注入独立状态；默认与公告阅读页共用状态。
  final BulletinController? controller;

  @override
  State<BulletinHomeCard> createState() => _BulletinHomeCardState();
}

class _BulletinHomeCardState extends State<BulletinHomeCard>
    with WidgetsBindingObserver {
  late final _controller = widget.controller ?? BulletinController.instance;
  Timer? _refreshTimer;
  bool _isForeground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_controller.ensureStarted());
    _refreshTimer = Timer.periodic(
      const Duration(minutes: 15),
      (_) => _refreshIfEnabled(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isForeground = state == AppLifecycleState.resumed;
    if (_isForeground) _refreshIfEnabled();
  }

  void _refreshIfEnabled() {
    if (_isForeground && _controller.subscription.enabled) {
      unawaited(_controller.refreshFeed());
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final controller = _controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final enabled = controller.subscription.enabled;
        final feed = controller.feed.take(2).toList();
        final hideFeed = enabled && controller.feedUnavailable;
        return Container(
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            children: [
              InkWell(
                onTap: () => context.push('/apps/bulletin'),
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 13, 12, 10),
                  child: Row(
                    children: [
                      Icon(
                        Icons.campaign_outlined,
                        size: 19,
                        color: palette.accent,
                      ),
                      const SizedBox(width: 7),
                      Text(
                        '信息公告',
                        style: TextStyle(
                          color: palette.titleText,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      if (controller.feedLoading)
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else if (enabled && !hideFeed)
                        Text(
                          '${controller.feed.length} 条动态',
                          style: TextStyle(color: palette.hint, fontSize: 11),
                        ),
                      const SizedBox(width: 5),
                      Icon(
                        Icons.chevron_right,
                        size: 19,
                        color: palette.chevron,
                      ),
                    ],
                  ),
                ),
              ),
              if (!hideFeed &&
                  feed.isEmpty &&
                  (!enabled || !controller.feedLoading))
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  child: Row(
                    children: [
                      Icon(
                        enabled
                            ? Icons.inbox_outlined
                            : Icons.notifications_none,
                        size: 17,
                        color: palette.hint,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          enabled ? '暂时没有匹配的新公告' : '开启主题订阅，感兴趣的新公告会显示在这里',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: palette.hint, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                )
              else if (!hideFeed)
                for (final bulletin in feed)
                  _HomeBulletinRow(bulletin: bulletin),
            ],
          ),
        );
      },
    );
  }
}

class _HomeBulletinRow extends StatelessWidget {
  const _HomeBulletinRow({required this.bulletin});

  final Bulletin bulletin;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final topics = bulletin.topics;
    final topic = topics.isEmpty ? null : topics.first;
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => BulletinDetailPage(bulletin: bulletin),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 7, 16, 11),
        child: Row(
          children: [
            Container(
              width: 4,
              height: 30,
              decoration: BoxDecoration(
                color: palette.accent.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    bulletin.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.labelText,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (topic != null) topic.label,
                      bulletin.publishedAt,
                    ].join(' · '),
                    style: TextStyle(color: palette.hint, fontSize: 10),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 17, color: palette.chevron),
          ],
        ),
      ),
    );
  }
}
