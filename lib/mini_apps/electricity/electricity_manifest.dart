import 'package:flutter/material.dart';

import '../../core/app_manifest.dart';
import 'electricity_home_card.dart';
import 'electricity_page.dart';

/// 宿舍电费小程序：首页顶部常驻余额卡片，点进去看历史折线与换宿舍。
const electricityManifest = AppManifest(
  id: 'electricity',
  label: '宿舍电费',
  color: Color(0xFFFF7D00),
  icon: Icons.bolt,
  entry: _entry,
  homeCard: _homeCard,
);

Widget _entry(BuildContext context) => const ElectricityPage();

Widget _homeCard(BuildContext context) => const ElectricityHomeCard();
