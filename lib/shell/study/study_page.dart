import 'package:flutter/material.dart';

import '../../mini_apps/academic/academic_controller.dart';
import '../../mini_apps/academic/academic_summary_card.dart';

/// 学习页：目前只有一张「学业概览」卡片，下拉可刷新。
class StudyPage extends StatelessWidget {
  const StudyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('学习')),
      body: RefreshIndicator(
        onRefresh: AcademicController.instance.refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          children: const [AcademicSummaryCard()],
        ),
      ),
    );
  }
}
