import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/colors.dart';
import '../electricity/electricity_format.dart' show formatShortTime;
import 'academic_controller.dart';
import 'academic_models.dart';

/// 学习页的「学业概览」卡片：顶部标题 + 更新时间 + 刷新，中间三个主要指标
/// （平均绩点 / GPA / 平均分），然后是学分进度条，底部四个次要指标。
///
/// 未绑定门户 / 从未拉到数据时只显示一行提示，不撑出空表格。
class AcademicSummaryCard extends StatefulWidget {
  const AcademicSummaryCard({super.key});

  @override
  State<AcademicSummaryCard> createState() => _AcademicSummaryCardState();
}

class _AcademicSummaryCardState extends State<AcademicSummaryCard> {
  final _controller = AcademicController.instance;

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
        final summary = c.summary;
        final error = c.error;

        final Widget body;
        if (!c.portalBound) {
          body = _Placeholder(
            text: '请先绑定统一门户',
            action: '去绑定',
            onTap: () => context.push('/portal-bind'),
          );
        } else if (summary == null) {
          body = _Placeholder(
            text: c.loading ? '正在获取学业数据…' : (error ?? '暂无数据'),
            action: c.loading ? null : '重试',
            onTap: c.refresh,
            isError: !c.loading && error != null,
          );
        } else {
          body = _SummaryBody(summary: summary);
        }

        return Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.school, size: 18, color: AppColors.accent),
                  const SizedBox(width: 4),
                  const Text(
                    '学业概览',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.titleText,
                    ),
                  ),
                  const Spacer(),
                  if (c.portalBound) ...[
                    Text(
                      error != null && summary != null
                          ? '更新失败'
                          : summary == null
                          ? ''
                          : formatShortTime(summary.fetchedAt),
                      style: TextStyle(
                        fontSize: 11,
                        color: error != null && summary != null
                            ? Theme.of(context).colorScheme.error
                            : AppColors.hint,
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
        );
      },
    );
  }
}

class _SummaryBody extends StatelessWidget {
  const _SummaryBody({required this.summary});

  final AcademicSummary summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final earned = double.tryParse(s.earnedCredits);
    final required = double.tryParse(s.requiredCredits);
    final progress = _parsePercent(s.creditProgress) ??
        (earned != null && required != null && required > 0
            ? earned / required
            : null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: _Metric(label: '平均绩点', value: s.averageGradePoint)),
            Expanded(child: _Metric(label: 'GPA', value: s.gpa)),
            Expanded(child: _Metric(label: '平均分', value: s.averageScore)),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            const Text(
              '学分进度',
              style: TextStyle(fontSize: 12, color: AppColors.labelText),
            ),
            const Spacer(),
            Text(
              '已获 ${_orDash(s.earnedCredits)} / 应修 ${_orDash(s.requiredCredits)}'
              '　${_orDash(s.creditProgress)}',
              style: const TextStyle(fontSize: 12, color: AppColors.labelText),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: progress?.clamp(0.0, 1.0),
            minHeight: 6,
            backgroundColor: AppColors.rowDivider,
            color: AppColors.accent,
          ),
        ),
        const SizedBox(height: 14),
        const Divider(height: 1, color: AppColors.rowDivider),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: _Stat(label: '班级排名', value: s.classRank)),
            Expanded(child: _Stat(label: '专业排名', value: s.majorRank)),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: _Stat(label: '课程通过率', value: s.passRateText)),
            Expanded(
              child: _Stat(label: '学分加权平均分', value: s.weightedAverageScore),
            ),
          ],
        ),
      ],
    );
  }

  static String _orDash(String v) => v.isEmpty ? '--' : v;

  /// 「32.9%」→ 0.329。
  static double? _parsePercent(String text) {
    final t = text.trim();
    if (!t.endsWith('%')) return null;
    final n = double.tryParse(t.substring(0, t.length - 1));
    return n == null ? null : n / 100;
  }
}

/// 大号主要指标：数值在上，标签在下。
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
          value.isEmpty ? '--' : value,
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: AppColors.titleText,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: AppColors.labelText),
        ),
      ],
    );
  }
}

/// 次要指标：标签在左，数值在右。
class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: AppColors.labelText),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            value.isEmpty ? '--' : value,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.titleText,
            ),
          ),
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

/// 刷新图标按钮，加载中原位换成小转圈，占位尺寸不变。
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
              color: AppColors.accent,
              icon: const Icon(Icons.refresh),
              onPressed: onPressed,
            ),
    );
  }
}
