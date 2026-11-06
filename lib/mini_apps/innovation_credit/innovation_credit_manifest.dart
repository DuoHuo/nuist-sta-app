import 'package:flutter/material.dart';

import '../../core/app_manifest.dart';
import 'innovation_credit_card.dart';
import 'innovation_credit_controller.dart';
import 'innovation_credit_page.dart';

/// 双创学分小程序：学习页学分卡片与全屏认定项目详情。
const innovationCreditManifest = AppManifest(
  id: 'innovation-credit',
  label: '双创学分',
  color: kInnovationColor,
  icon: Icons.lightbulb_outline,
  entry: _entry,
  showInHomeGrid: false,
  onPortalBindingChanged: _portalBindingChanged,
  studyCard: StudyCardContribution(
    builder: _studyCard,
    order: 40,
    onRefresh: _studyRefresh,
  ),
);

Widget _entry(BuildContext context) => const InnovationCreditPage();

Widget _studyCard(BuildContext context) => const InnovationCreditCard();

Future<void> _studyRefresh() => InnovationCreditController.instance.refresh();

Future<void> _portalBindingChanged(bool bound) =>
    InnovationCreditController.instance.onPortalBindingChanged(bound);
