import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/colors.dart';
import 'announcement_controller.dart';
import 'announcement_detail_page.dart';
import 'announcement_models.dart';

/// 首页展示用户订阅主题命中的最新公告。
class AnnouncementHomeCard extends StatefulWidget {
  /// 创建展示订阅动态的首页卡片。
  const AnnouncementHomeCard({super.key});

  @override
  State<AnnouncementHomeCard> createState() => _AnnouncementHomeCardState();
}

class _AnnouncementHomeCardState extends State<AnnouncementHomeCard>
    with WidgetsBindingObserver {
  final _controller = AnnouncementController.instance;
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
    final controller = _controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final enabled = controller.subscription.enabled;
        final feed = controller.feed.take(2).toList();
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            children: [
              InkWell(
                onTap: () => context.push('/apps/announcement'),
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 13, 12, 10),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.campaign_outlined,
                        size: 19,
                        color: AppColors.accent,
                      ),
                      const SizedBox(width: 7),
                      const Text(
                        '信息公告',
                        style: TextStyle(
                          color: AppColors.titleText,
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
                      else if (enabled)
                        Text(
                          '${controller.feed.length} 条动态',
                          style: const TextStyle(
                            color: AppColors.hint,
                            fontSize: 11,
                          ),
                        ),
                      const SizedBox(width: 5),
                      const Icon(
                        Icons.chevron_right,
                        size: 19,
                        color: AppColors.hint,
                      ),
                    ],
                  ),
                ),
              ),
              if (feed.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  child: Row(
                    children: [
                      Icon(
                        enabled
                            ? Icons.inbox_outlined
                            : Icons.notifications_none,
                        size: 17,
                        color: AppColors.hint,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          enabled
                              ? controller.feedError ?? '暂时没有匹配的新公告'
                              : '开启主题订阅，感兴趣的新公告会显示在这里',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.hint,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else
                for (final announcement in feed)
                  _HomeAnnouncementRow(announcement: announcement),
            ],
          ),
        );
      },
    );
  }
}

class _HomeAnnouncementRow extends StatelessWidget {
  const _HomeAnnouncementRow({required this.announcement});

  final Announcement announcement;

  @override
  Widget build(BuildContext context) {
    final topics = announcement.topics;
    final topic = topics.isEmpty ? null : topics.first;
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AnnouncementDetailPage(announcement: announcement),
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
                color: AppColors.accent.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    announcement.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.labelText,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (topic != null) topic.label,
                      announcement.publishedAt,
                    ].join(' · '),
                    style: const TextStyle(color: AppColors.hint, fontSize: 10),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 17, color: AppColors.hint),
          ],
        ),
      ),
    );
  }
}
