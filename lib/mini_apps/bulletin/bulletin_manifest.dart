import 'package:flutter/material.dart';

import '../../core/app_manifest.dart';
import 'bulletin_controller.dart';
import 'bulletin_home_card.dart';
import 'bulletin_page.dart';

/// 信息公告小程序：浏览学校公告并按主题订阅首页动态。
const bulletinManifest = AppManifest(
  id: 'bulletin',
  label: '信息公告',
  color: Color(0xFF1687E8),
  icon: Icons.campaign_outlined,
  entry: _entry,
  homeCard: _homeCard,
  onHomeRefresh: _homeRefresh,
);

Widget _entry(BuildContext context) => const BulletinPage();

Widget _homeCard(BuildContext context) => const BulletinHomeCard();

/// 订阅关闭时 [BulletinController.refreshFeed] 自己会直接返回。
Future<void> _homeRefresh() => BulletinController.instance.refreshFeed();
