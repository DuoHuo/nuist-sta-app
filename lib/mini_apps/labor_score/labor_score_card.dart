import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/colors.dart';
import '../../core/time_format.dart';
import 'labor_score_controller.dart';
import 'labor_score_models.dart';

/// 劳动小程序自己的配色：标题图标用绿色。
const kLaborColor = Color(0xFF00B42A);

/// 学习页的「劳动积分」卡片：官方核算的总积分 + 确认状态 + 核算日期，
/// 下面四个分项（理论 / 生活 / 服务 / 专业），整卡可点进详情页。
///
/// 未绑定门户 / 从未拉到数据时只显示一行提示，不撑出空表格。
class LaborScoreCard extends StatefulWidget {
  const LaborScoreCard({super.key});

  @override
  State<LaborScoreCard> createState() => _LaborScoreCardState();
}

class _LaborScoreCardState extends State<LaborScoreCard> {
  final _controller = LaborScoreController.instance;

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
        final score = c.score;
        final error = c.error;

        final Widget body;
        if (!c.portalBound) {
          body = _Placeholder(
            text: '请先绑定统一门户',
            action: '去绑定',
            onTap: () => context.push('/portal-bind'),
          );
        } else if (score == null) {
          body = _Placeholder(
            text: c.loading ? '正在获取劳动积分…' : (error ?? '暂无数据'),
            action: c.loading ? null : '重试',
            onTap: c.refresh,
            isError: !c.loading && error != null,
          );
        } else {
          body = _ScoreBody(score: score);
        }

        return InkWell(
          onTap: score == null ? null : () => context.push('/labor-score'),
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
                      Icons.volunteer_activism_outlined,
                      size: 18,
                      color: kLaborColor,
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      '劳动积分',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.titleText,
                      ),
                    ),
                    const Spacer(),
                    if (c.portalBound) ...[
                      Text(
                        error != null && score != null
                            ? '更新失败'
                            : score == null
                            ? ''
                            : formatShortTime(score.fetchedAt),
                        style: TextStyle(
                          fontSize: 11,
                          color: error != null && score != null
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
          ),
        );
      },
    );
  }
}

class _ScoreBody extends StatelessWidget {
  const _ScoreBody({required this.score});

  final LaborScore score;

  @override
  Widget build(BuildContext context) {
    final r = score.official;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        if (r == null)
          const Text(
            '平台尚未生成你的劳动积分核算结果',
            style: TextStyle(fontSize: 13, color: AppColors.hint),
          )
        else ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                r.total.isEmpty ? '--' : r.total,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: AppColors.titleText,
                  height: 1.1,
                ),
              ),
              const SizedBox(width: 4),
              const Text(
                '分',
                style: TextStyle(fontSize: 13, color: AppColors.labelText),
              ),
              // 「未确认」是常态（确认由学生在平台上手动点），标出来只会让人
              // 以为哪里出了问题，所以只在已确认时给个标签。
              if (r.isConfirmed) ...[
                const SizedBox(width: 10),
                const _Tag(text: '已确认', color: AppColors.success),
              ],
              if (r.updatedAt.isNotEmpty) ...[
                const SizedBox(width: 10),
                Text(
                  '核算于 ${r.updatedShort}',
                  style: const TextStyle(fontSize: 11, color: AppColors.hint),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, color: AppColors.rowDivider),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _Stat(label: '理论', value: r.theory),
              ),
              Expanded(
                child: _Stat(label: '生活', value: r.life),
              ),
              Expanded(
                child: _Stat(label: '服务', value: r.service),
              ),
              Expanded(
                child: _Stat(label: '专业', value: r.majorTotal),
              ),
            ],
          ),
        ],
        const SizedBox(height: 10),
        const Row(
          children: [
            Text(
              '查看明细',
              style: TextStyle(fontSize: 12, color: AppColors.labelText),
            ),
            Spacer(),
            Icon(Icons.chevron_right, color: Color(0xFFC9CDD4)),
          ],
        ),
      ],
    );
  }
}

/// 分项：数值在上，标签在下，居中。
class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value.isEmpty ? '--' : value,
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

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
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
