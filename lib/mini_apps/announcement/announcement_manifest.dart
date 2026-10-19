import 'package:flutter/material.dart';

import '../../core/app_manifest.dart';
import 'announcement_controller.dart';
import 'announcement_home_card.dart';
import 'announcement_page.dart';

/// 信息公告小程序：浏览学校公告并按主题订阅首页动态。
const announcementManifest = AppManifest(
  id: 'announcement',
  label: '信息公告',
  color: Color(0xFF1687E8),
  icon: Icons.campaign_outlined,
  entry: _entry,
  homeCard: _homeCard,
  onHomeRefresh: _homeRefresh,
);

Widget _entry(BuildContext context) => const AnnouncementPage();

Widget _homeCard(BuildContext context) => const AnnouncementHomeCard();

/// 订阅关闭时 [AnnouncementController.refreshFeed] 自己会直接返回。
Future<void> _homeRefresh() => AnnouncementController.instance.refreshFeed();
