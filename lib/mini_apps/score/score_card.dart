import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/colors.dart';
import '../../core/time_format.dart';
import 'score_controller.dart';
import 'score_models.dart';

const kScoreColor = Color(0xFF7C4DFF);

/// 学习页的成绩查询卡片：展示最近学期概况，点击进入全部成绩。
class ScoreCard extends StatefulWidget {
  const ScoreCard({super.key});

  @override
  State<ScoreCard> createState() => _ScoreCardState();
}

class _ScoreCardState extends State<ScoreCard> {
  final _controller = ScoreController.instance;

  @override
  void initState() {
    super.initState();
    _controller.ensureStarted();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final c = _controller;
        final report = c.report;
        final latest = report?.latestTerm;
        final summary = report?.summaryFor(latest);
        final Widget body;
        if (!c.portalBound) {
          body = _Placeholder(
            text: '请先绑定统一门户',
            action: '去绑定',
            onTap: () => context.push('/portal-bind'),
          );
        } else if (report == null) {
          body = _Placeholder(
            text: c.loading ? '正在获取成绩…' : (c.error ?? '暂无成绩数据'),
            action: c.loading ? null : '重试',
            onTap: c.refresh,
            isError: !c.loading && c.error != null,
          );
        } else {
          body = _ScoreBody(term: latest, summary: summary!);
        }

        return InkWell(
          onTap: report == null ? null : () => context.push('/scores'),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.assessment_outlined,
                      size: 18,
                      color: kScoreColor,
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      '成绩查询',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.titleText,
                      ),
                    ),
                    const Spacer(),
                    if (c.portalBound) ...[
                      Text(
                        report == null ? '' : formatShortTime(report.fetchedAt),
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.hint,
                        ),
                      ),
                      _RefreshButton(loading: c.loading, onPressed: c.refresh),
                    ] else
                      const SizedBox(height: 32),
                  ],
                ),
                Padding(padding: const EdgeInsets.only(right: 8), child: body),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ScoreBody extends StatelessWidget {
  const _ScoreBody({required this.term, required this.summary});

  final String? term;
  final ScoreTermSummary summary;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              term ?? '全部成绩',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.titleText,
              ),
            ),
            const Spacer(),
            Text(
              '${summary.total} 门',
              style: const TextStyle(fontSize: 12, color: AppColors.hint),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _Metric(label: '平均分', value: _average(summary))),
            Expanded(
              child: _Metric(label: '通过', value: '${summary.passed} 门'),
            ),
            Expanded(
              child: _Metric(label: '学分', value: summary.creditsText),
            ),
          ],
        ),
        const SizedBox(height: 10),
        const Row(
          children: [
            Text(
              '查看全部成绩',
              style: TextStyle(fontSize: 12, color: AppColors.labelText),
            ),
            Spacer(),
            Icon(Icons.chevron_right, color: Color(0xFFC9CDD4)),
          ],
        ),
      ],
    );
  }

  static String _average(ScoreTermSummary summary) {
    final value = summary.averageScore;
    return value == null ? '--' : value.toStringAsFixed(1);
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
            fontSize: 18,
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

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.text,
    required this.onTap,
    this.action,
    this.isError = false,
  });

  final String text;
  final String? action;
  final VoidCallback onTap;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14,
                color: isError
                    ? Theme.of(context).colorScheme.error
                    : AppColors.hint,
              ),
            ),
          ),
          if (action != null)
            TextButton(
              onPressed: onTap,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(action!),
            ),
        ],
      ),
    );
  }
}

class _RefreshButton extends StatelessWidget {
  const _RefreshButton({required this.loading, required this.onPressed});

  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: loading
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
              onPressed: onPressed,
            ),
    );
  }
}
