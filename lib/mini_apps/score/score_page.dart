import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/colors.dart';
import '../../core/time_format.dart';
import 'score_card.dart' show kScoreColor;
import 'score_controller.dart';
import 'score_models.dart';

/// 成绩详情页：最近学期默认置顶，支持按学期查看全部课程成绩。
class ScorePage extends StatefulWidget {
  const ScorePage({super.key});

  @override
  State<ScorePage> createState() => _ScorePageState();
}

class _ScorePageState extends State<ScorePage> {
  final _controller = ScoreController.instance;
  String? _selectedTerm;

  @override
  void initState() {
    super.initState();
    _controller.ensureStarted();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.pageBg,
      appBar: AppBar(title: const Text('成绩查询')),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final c = _controller;
          final report = c.report;
          if (!c.portalBound) {
            return _StateCard(
              icon: Icons.link_off,
              title: '未绑定统一门户',
              subtitle: '成绩查询需要教务系统登录，请先到「我的 → 绑定统一门户」完成绑定。',
              onTap: () => context.push('/portal-bind'),
            );
          }
          if (report == null) {
            return _StateCard(
              icon: Icons.assessment_outlined,
              title: c.loading ? '正在获取成绩…' : '暂无成绩数据',
              subtitle: c.error ?? '数据来自教务系统。',
              isError: !c.loading && c.error != null,
              onTap: c.loading ? null : c.refresh,
            );
          }

          final terms = report.terms;
          final term = terms.contains(_selectedTerm)
              ? _selectedTerm
              : report.latestTerm;
          final records = report.recordsFor(term);
          final summary = report.summaryFor(term);
          return RefreshIndicator(
            onRefresh: c.refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                _OverviewCard(
                  controller: c,
                  report: report,
                  summary: summary,
                  term: term,
                ),
                if (terms.length > 1) ...[
                  const SizedBox(height: 12),
                  _TermPicker(
                    terms: terms,
                    selected: term,
                    onChanged: (value) => setState(() => _selectedTerm = value),
                  ),
                ],
                const SizedBox(height: 12),
                _CourseSection(records: records),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _OverviewCard extends StatelessWidget {
  const _OverviewCard({
    required this.controller,
    required this.report,
    required this.summary,
    required this.term,
  });

  final ScoreController controller;
  final ScoreReport report;
  final ScoreTermSummary summary;
  final String? term;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.assessment_outlined,
                  size: 20,
                  color: kScoreColor,
                ),
                const SizedBox(width: 6),
                const Text(
                  '成绩概览',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.titleText,
                  ),
                ),
                const Spacer(),
                Text(
                  formatShortTime(report.fetchedAt),
                  style: const TextStyle(fontSize: 11, color: AppColors.hint),
                ),
                SizedBox(
                  width: 32,
                  height: 32,
                  child: controller.loading
                      ? const Center(
                          child: SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          padding: EdgeInsets.zero,
                          iconSize: 18,
                          color: kScoreColor,
                          icon: const Icon(Icons.refresh),
                          onPressed: controller.refresh,
                        ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              term ?? '全部成绩',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: AppColors.titleText,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _Metric(label: '课程', value: '${summary.total} 门'),
                ),
                Expanded(
                  child: _Metric(label: '平均分', value: _average(summary)),
                ),
                Expanded(
                  child: _Metric(label: '通过', value: '${summary.passed} 门'),
                ),
                Expanded(
                  child: _Metric(label: '学分', value: summary.creditsText),
                ),
              ],
            ),
            if (controller.error != null) ...[
              const SizedBox(height: 10),
              Text(
                '刷新失败：${controller.error}',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _average(ScoreTermSummary summary) {
    final value = summary.averageScore;
    return value == null ? '--' : value.toStringAsFixed(1);
  }
}

class _TermPicker extends StatelessWidget {
  const _TermPicker({
    required this.terms,
    required this.selected,
    required this.onChanged,
  });

  final List<String> terms;
  final String? selected;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: selected,
            isExpanded: true,
            icon: const Icon(Icons.expand_more),
            style: const TextStyle(fontSize: 14, color: AppColors.titleText),
            items: [
              for (final term in terms)
                DropdownMenuItem(value: term, child: Text(term)),
            ],
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }
}

class _CourseSection extends StatelessWidget {
  const _CourseSection({required this.records});

  final List<ScoreRecord> records;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: records.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '这个学期还没有成绩记录',
                style: TextStyle(fontSize: 13, color: AppColors.hint),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    '课程成绩',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.titleText,
                    ),
                  ),
                ),
                for (var i = 0; i < records.length; i++) ...[
                  _CourseTile(record: records[i]),
                  if (i != records.length - 1)
                    const Padding(
                      padding: EdgeInsets.only(left: 16),
                      child: Divider(height: 1, color: AppColors.rowDivider),
                    ),
                ],
                const SizedBox(height: 4),
              ],
            ),
    );
  }
}

class _CourseTile extends StatelessWidget {
  const _CourseTile({required this.record});

  final ScoreRecord record;

  @override
  Widget build(BuildContext context) {
    final color = record.failed
        ? AppColors.danger
        : record.passed
        ? AppColors.success
        : AppColors.warning;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  record.displayCourseName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.titleText,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _details(record),
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.hint,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                record.score.isEmpty ? '--' : record.score,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              if (record.passStatus.isNotEmpty)
                Text(
                  record.passStatus,
                  style: TextStyle(fontSize: 11, color: color),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _details(ScoreRecord record) {
    final values = <String>[];
    if (record.credit.isNotEmpty) values.add('${record.credit} 学分');
    if (record.gradePoint.isNotEmpty) values.add('绩点 ${record.gradePoint}');
    if (record.courseCode.isNotEmpty) values.add(record.courseCode);
    if (record.examType.isNotEmpty) values.add(record.examType);
    if (record.retakeType.isNotEmpty) values.add(record.retakeType);
    if (record.usualScore.isNotEmpty || record.finalScore.isNotEmpty) {
      final usual = record.usualScore.isEmpty ? '--' : record.usualScore;
      final finalScore = record.finalScore.isEmpty ? '--' : record.finalScore;
      values.add('平时 $usual · 期末 $finalScore');
    }
    return values.isEmpty ? '暂无课程附加信息' : values.join(' · ');
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: AppColors.titleText,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: AppColors.labelText),
        ),
      ],
    );
  }
}

class _StateCard extends StatelessWidget {
  const _StateCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.isError = false,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool isError;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _Card(
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: (isError ? AppColors.danger : kScoreColor)
                          .withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      icon,
                      color: isError ? AppColors.danger : kScoreColor,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppColors.titleText,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          style: TextStyle(
                            fontSize: 12,
                            color: isError
                                ? Theme.of(context).colorScheme.error
                                : AppColors.hint,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (onTap != null)
                    const Icon(Icons.chevron_right, color: Color(0xFFC9CDD4)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}
