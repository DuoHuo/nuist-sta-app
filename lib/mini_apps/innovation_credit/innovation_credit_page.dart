import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/colors.dart';
import '../../core/time_format.dart';
import 'innovation_credit_card.dart'
    show kInnovationColor, gradeColor, gradeLabel, statusColor;
import 'innovation_credit_controller.dart';
import 'innovation_credit_models.dart';

/// 双创学分详情页：状态头（总分 / 成绩评定 / 项数）→ 全部已认定项目列表。
class InnovationCreditPage extends StatefulWidget {
  const InnovationCreditPage({super.key});

  @override
  State<InnovationCreditPage> createState() => _InnovationCreditPageState();
}

class _InnovationCreditPageState extends State<InnovationCreditPage> {
  final _controller = InnovationCreditController.instance;

  @override
  void initState() {
    super.initState();
    _controller.ensureStarted();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.pageBg,
      appBar: AppBar(title: const Text('双创学分')),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final c = _controller;
          final credit = c.credit;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              _StatusHeader(controller: c),
              if (credit != null) ...[
                const SizedBox(height: 12),
                _ItemList(items: credit.items),
              ],
            ],
          );
        },
      ),
    );
  }
}

// ==================== 子组件 ====================

class _StatusHeader extends StatelessWidget {
  const _StatusHeader({required this.controller});

  final InnovationCreditController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final credit = c.credit;
    final scheme = Theme.of(context).colorScheme;

    if (!c.portalBound) {
      return _IconHeader(
        icon: Icons.link_off,
        color: AppColors.hint,
        title: '未绑定统一门户',
        subtitle: '双创学分查询需要门户身份，请先到「我的 → 绑定统一门户」完成绑定。',
        onTap: () => context.push('/portal-bind'),
      );
    }
    if (credit == null) {
      return _IconHeader(
        icon: Icons.lightbulb_outline,
        color: kInnovationColor,
        title: c.loading ? '正在获取双创学分…' : '暂无数据',
        subtitle: c.error ?? '数据来自创新创业学分认定系统。',
        isError: !c.loading && c.error != null,
        onTap: c.loading ? null : c.refresh,
      );
    }

    return _Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: kInnovationColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.lightbulb_outline,
                color: kInnovationColor,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        credit.total.isEmpty ? '--' : credit.total,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                          color: AppColors.titleText,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Text(
                        '分',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.labelText,
                        ),
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
                  const SizedBox(height: 6),
                  Text(
                    '已认定 ${credit.items.length} 项',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.labelText,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    c.error ?? '更新于 ${formatFullTime(credit.fetchedAt)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: c.error != null ? scheme.error : AppColors.hint,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 40,
              height: 40,
              child: c.loading
                  ? const Center(
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      icon: const Icon(Icons.refresh),
                      color: AppColors.accent,
                      onPressed: c.refresh,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ItemList extends StatelessWidget {
  const _ItemList({required this.items});

  final List<InnovationCreditItem> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const _Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Center(
            child: Text(
              '暂无已认定的双创学分',
              style: TextStyle(fontSize: 13, color: AppColors.hint),
            ),
          ),
        ),
      );
    }
    return _Card(
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            _ItemTile(item: items[i]),
            if (i != items.length - 1)
              const Padding(
                padding: EdgeInsets.only(left: 16),
                child: Divider(height: 1, color: AppColors.rowDivider),
              ),
          ],
        ],
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item});

  final InnovationCreditItem item;

  @override
  Widget build(BuildContext context) {
    final meta = [
      if (item.date.isNotEmpty) item.date,
      if (item.batch.isNotEmpty) item.batch,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  item.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.titleText,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    item.score.isEmpty ? '--' : '+${item.score}',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.accent,
                    ),
                  ),
                  if (item.isDiscounted)
                    Text(
                      '参照 ${item.standardScore}',
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppColors.hint,
                      ),
                    ),
                ],
              ),
            ],
          ),
          if (item.categoryPath.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              item.categoryPath,
              style: const TextStyle(fontSize: 12, color: AppColors.labelText),
            ),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  meta,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: AppColors.hint),
                ),
              ),
              if (item.status.isNotEmpty)
                _Tag(text: item.status, color: statusColor(item.statusKind)),
            ],
          ),
        ],
      ),
    );
  }
}

class _IconHeader extends StatelessWidget {
  const _IconHeader({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    this.isError = false,
    this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final bool isError;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 22),
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
