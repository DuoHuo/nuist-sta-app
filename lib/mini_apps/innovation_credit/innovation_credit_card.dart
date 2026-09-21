import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/colors.dart';
import '../../core/time_format.dart';
import 'innovation_credit_controller.dart';
import 'innovation_credit_models.dart';

/// 双创小程序自己的配色：标题图标用琥珀色。
const kInnovationColor = Color(0xFFFFB400);

/// 学习页的「双创学分」卡片：总分 + 成绩评定，下面最多列 3 条已认定项目，
/// 整卡可点进详情页看全部。
///
/// 未绑定门户 / 从未拉到数据时只显示一行提示，不撑出空列表。
class InnovationCreditCard extends StatefulWidget {
  const InnovationCreditCard({super.key});

  @override
  State<InnovationCreditCard> createState() => _InnovationCreditCardState();
}

class _InnovationCreditCardState extends State<InnovationCreditCard> {
  final _controller = InnovationCreditController.instance;

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
        final credit = c.credit;
        final error = c.error;

        final Widget body;
        if (!c.portalBound) {
          body = _Placeholder(
            text: '请先绑定统一门户',
            action: '去绑定',
            onTap: () => context.push('/portal-bind'),
          );
        } else if (credit == null) {
          body = _Placeholder(
            text: c.loading ? '正在获取双创学分…' : (error ?? '暂无数据'),
            action: c.loading ? null : '重试',
            onTap: c.refresh,
            isError: !c.loading && error != null,
          );
        } else {
          body = _CreditBody(credit: credit);
        }

        return InkWell(
          onTap: credit == null
              ? null
              : () => context.push('/innovation-credit'),
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
                      Icons.lightbulb_outline,
                      size: 18,
                      color: kInnovationColor,
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      '双创学分',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.titleText,
                      ),
                    ),
                    const Spacer(),
                    if (c.portalBound) ...[
                      Text(
                        error != null && credit != null
                            ? '更新失败'
                            : credit == null
                            ? ''
                            : formatShortTime(credit.fetchedAt),
                        style: TextStyle(
                          fontSize: 11,
                          color: error != null && credit != null
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

class _CreditBody extends StatelessWidget {
  const _CreditBody({required this.credit});

  final InnovationCredit credit;

  static const _maxItems = 3;

  @override
  Widget build(BuildContext context) {
    final items = credit.items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              credit.total.isEmpty ? '--' : credit.total,
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
            if (credit.grade.isNotEmpty) ...[
              const SizedBox(width: 10),
              _Tag(
                text: gradeLabel(credit),
                color: gradeColor(credit.gradeKind),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        const Divider(height: 1, color: AppColors.rowDivider),
        if (items.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Text(
              '暂无已认定的学分项目',
              style: TextStyle(fontSize: 12, color: AppColors.hint),
            ),
          )
        else
          for (final item in items.take(_maxItems))
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      item.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.titleText,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    item.date,
                    style: const TextStyle(fontSize: 11, color: AppColors.hint),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    item.score.isEmpty ? '--' : '+${item.score}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.accent,
                    ),
                  ),
                ],
              ),
            ),
        const SizedBox(height: 10),
        Row(
          children: [
            Text(
              items.length > _maxItems ? '共 ${items.length} 项 · 查看全部' : '查看明细',
              style: const TextStyle(fontSize: 12, color: AppColors.labelText),
            ),
            const Spacer(),
            const Icon(Icons.chevron_right, color: Color(0xFFC9CDD4)),
          ],
        ),
      ],
    );
  }
}

/// 成绩评定的展示文案：平台原话「不及格」对还在攒分的学生太刺眼，改成
/// 中性的「未达标」；其余照页面原文显示。
String gradeLabel(InnovationCredit credit) => switch (credit.gradeKind) {
  InnovationStatusKind.rejected => '未达标',
  _ => credit.grade,
};

/// 成绩评定用的颜色：合格绿、未达标灰（只是还没攒够，不是出了什么错）。
Color gradeColor(InnovationStatusKind? kind) => switch (kind) {
  InnovationStatusKind.approved => AppColors.success,
  InnovationStatusKind.rejected => AppColors.hint,
  _ => AppColors.labelText,
};

/// 条目状态用的颜色：通过绿、审核中橙、驳回红。
Color statusColor(InnovationStatusKind kind) => switch (kind) {
  InnovationStatusKind.approved => AppColors.success,
  InnovationStatusKind.pending => AppColors.warning,
  InnovationStatusKind.rejected => AppColors.danger,
};

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
