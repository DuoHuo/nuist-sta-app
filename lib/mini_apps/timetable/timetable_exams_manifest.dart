import 'package:flutter/material.dart';

import '../../core/app_manifest.dart';
import 'timetable_controller.dart';
import 'timetable_exams_card.dart';
import 'timetable_exams_page.dart';

/// 「考试安排」小程序注册信息（issue #30）。
///
/// 这是课表考试数据在主页的直观入口：数据复用课表已同步的考试，
/// 本小程序只新增展示（卡片 + 全屏列表），不修改课表任何已有实现。
/// 颜色取考试默认色 [kDefaultExamColor] 同款红，与课表里的考试格一致。
const examScheduleManifest = AppManifest(
  id: 'exam-schedule',
  label: '考试安排',
  color: Color(0xFFC62828),
  glyph: '考',
  entry: _entry,
  homeCard: _homeCard,
  onHomeRefresh: _homeRefresh,
);

Widget _entry(BuildContext context) => const TimetableExamsPage();

Widget _homeCard(BuildContext context) => const TimetableExamsCard();

/// 首页下拉等同课表手动同步（考试随课表一起拉取）；未绑定门户时不发请求。
Future<void> _homeRefresh() => TimetableController.instance.manualSync();
