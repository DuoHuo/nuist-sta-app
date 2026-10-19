import 'package:flutter/material.dart';

import '../../core/app_manifest.dart';
import 'timetable_controller.dart';
import 'timetable_home_card.dart';
import 'timetable_page.dart';

/// 实时课表小程序注册信息。
const timetableManifest = AppManifest(
  id: 'timetable',
  label: '课表',
  color: Color(0xFF0082EF),
  glyph: '课',
  entry: _entry,
  homeCard: _homeCard,
  onHomeRefresh: _homeRefresh,
);

Widget _entry(BuildContext context) => const TimetablePage();

Widget _homeCard(BuildContext context) => const TimetableHomeCard();

/// 首页下拉等同手动同步；未绑定门户时不发请求。
Future<void> _homeRefresh() => TimetableController.instance.manualSync();
