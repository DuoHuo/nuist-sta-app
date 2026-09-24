import 'package:flutter/material.dart';

import '../../mini_apps/academic/academic_controller.dart';
import '../../mini_apps/academic/academic_summary_card.dart';
import '../../mini_apps/innovation_credit/innovation_credit_card.dart';
import '../../mini_apps/innovation_credit/innovation_credit_controller.dart';
import '../../mini_apps/labor_score/labor_score_card.dart';
import '../../mini_apps/labor_score/labor_score_controller.dart';
import '../../mini_apps/score/score_card.dart';
import '../../mini_apps/score/score_controller.dart';
import '../../mini_apps/student_info/student_info_card.dart';
import '../../mini_apps/student_info/student_info_controller.dart';

/// 学习页：本学期（学期 / 周次 / 进度）→ 学业概览 → 双创学分 → 劳动积分，
/// 下拉一次并发刷新四张卡。各卡自己处理未绑定 / 加载 / 失败三态。
class StudyPage extends StatelessWidget {
  const StudyPage({super.key});

  static Future<void> _refreshAll() => Future.wait([
    StudentInfoController.instance.refresh(),
    AcademicController.instance.refresh(),
    InnovationCreditController.instance.refresh(),
    LaborScoreController.instance.refresh(),
    ScoreController.instance.refresh(),
  ]);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('学习')),
      body: RefreshIndicator(
        onRefresh: _refreshAll,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          children: const [
            StudentInfoCard(),
            SizedBox(height: 12),
            AcademicSummaryCard(),
            SizedBox(height: 12),
            ScoreCard(),
            SizedBox(height: 12),
            InnovationCreditCard(),
            SizedBox(height: 12),
            LaborScoreCard(),
          ],
        ),
      ),
    );
  }
}
