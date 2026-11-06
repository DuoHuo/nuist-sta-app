import 'package:flutter/material.dart';

import '../../core/app_manifest.dart';
import 'academic_controller.dart';
import 'academic_summary_card.dart';

/// 学业概览模块：仅向学习页提供学业汇总卡片。
const academicManifest = AppManifest.cardOnly(
  id: 'academic',
  label: '学业概览',
  onPortalBindingChanged: _portalBindingChanged,
  studyCard: StudyCardContribution(
    builder: _studyCard,
    order: 20,
    onRefresh: _studyRefresh,
  ),
);

Widget _studyCard(BuildContext context) => const AcademicSummaryCard();

Future<void> _studyRefresh() => AcademicController.instance.refresh();

Future<void> _portalBindingChanged(bool bound) =>
    AcademicController.instance.onPortalBindingChanged(bound);
