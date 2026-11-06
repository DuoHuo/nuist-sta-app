import 'package:flutter/material.dart';

import '../../core/app_manifest.dart';
import 'labor_score_card.dart';
import 'labor_score_controller.dart';
import 'labor_score_page.dart';

/// 劳动积分小程序：学习页积分卡片与全屏积分明细。
const laborScoreManifest = AppManifest(
  id: 'labor-score',
  label: '劳动积分',
  color: kLaborColor,
  icon: Icons.volunteer_activism_outlined,
  entry: _entry,
  showInHomeGrid: false,
  onPortalBindingChanged: _portalBindingChanged,
  studyCard: StudyCardContribution(
    builder: _studyCard,
    order: 50,
    onRefresh: _studyRefresh,
  ),
);

Widget _entry(BuildContext context) => const LaborScorePage();

Widget _studyCard(BuildContext context) => const LaborScoreCard();

Future<void> _studyRefresh() => LaborScoreController.instance.refresh();

Future<void> _portalBindingChanged(bool bound) =>
    LaborScoreController.instance.onPortalBindingChanged(bound);
