import 'package:flutter/material.dart';

import '../../core/app_manifest.dart';
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
);

Widget _entry(BuildContext context) => const AnnouncementPage();

Widget _homeCard(BuildContext context) => const AnnouncementHomeCard();
