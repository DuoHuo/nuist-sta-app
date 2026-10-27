import 'package:flutter/material.dart';

import '../../core/app_manifest.dart';
import 'timetable_controller.dart';
import 'timetable_home_card.dart';
import 'timetable_page.dart';
import 'timetable_tile_icon.dart';

/// 实时课表小程序注册信息。
const timetableManifest = AppManifest(
  id: 'timetable',
  label: '课表',
  color: Color(0xFF0082EF),
  iconWidget: _tileIcon,
  entry: _entry,
  homeCard: _homeCard,
  onHomeRefresh: _homeRefresh,
);

Widget _tileIcon(BuildContext context) => const TimetableTileIcon();

Widget _entry(BuildContext context) => const TimetablePage();

Widget _homeCard(BuildContext context) => const TimetableHomeCard();

/// 首页下拉只重读本地磁盘并刷新 UI；不拉教务、不依赖门户。
/// 远程全量同步只在周课表页顶栏（[TimetableController.manualSync]）。
Future<void> _homeRefresh() async {
  await TimetableController.instance.refreshLocal();
}
