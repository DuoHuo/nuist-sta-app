import 'package:flutter/material.dart';

import '../../core/app_manifest.dart';
import 'student_info_card.dart';
import 'student_info_controller.dart';

/// 本学期模块：仅向学习页提供学期卡片。
const studentInfoManifest = AppManifest.cardOnly(
  id: 'student-info',
  label: '本学期',
  onPortalBindingChanged: _portalBindingChanged,
  studyCard: StudyCardContribution(
    builder: _studyCard,
    order: 10,
    onRefresh: _studyRefresh,
  ),
);

Widget _studyCard(BuildContext context) => const StudentInfoCard();

Future<void> _studyRefresh() => StudentInfoController.instance.refresh();

Future<void> _portalBindingChanged(bool bound) =>
    StudentInfoController.instance.onPortalBindingChanged(bound);
