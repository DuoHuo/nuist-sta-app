import 'package:flutter/material.dart';

import '../../core/app_manifest.dart';
import 'score_card.dart';
import 'score_controller.dart';
import 'score_page.dart';

/// 成绩查询小程序：学习页概况卡片与全屏成绩详情。
const scoreManifest = AppManifest(
  id: 'scores',
  label: '成绩查询',
  color: kScoreColor,
  icon: Icons.assessment_outlined,
  entry: _entry,
  showInHomeGrid: false,
  studyCard: StudyCardContribution(
    builder: _studyCard,
    order: 30,
    onRefresh: _studyRefresh,
  ),
);

Widget _entry(BuildContext context) => const ScorePage();

Widget _studyCard(BuildContext context) => const ScoreCard();

Future<void> _studyRefresh() => ScoreController.instance.refresh();
