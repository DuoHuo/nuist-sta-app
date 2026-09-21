import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/colors.dart';
import '../../core/time_format.dart';
import 'labor_score_card.dart' show kLaborColor;
import 'labor_score_controller.dart';
import 'labor_score_models.dart';

/// 劳动积分详情页：状态头（官方核算总分 / 确认 / 归档）→ 积分构成 →
/// 各分项页面的实时统计（与核算结果对照）。
class LaborScorePage extends StatefulWidget {
  const LaborScorePage({super.key});

  @override
  State<LaborScorePage> createState() => _LaborScorePageState();
}

class _LaborScorePageState extends State<LaborScorePage> {
  final _controller = LaborScoreController.instance;

  @override
  void initState() {
    super.initState();
    _controller.ensureStarted();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.pageBg,
      appBar: AppBar(title: const Text('劳动积分')),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final c = _controller;
          final score = c.score;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              _StatusHeader(controller: c),
              if (score != null) ...[
                const SizedBox(height: 12),
                _Breakdown(result: score.official),
                const SizedBox(height: 12),
                _LiveStats(score: score),
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

  final LaborScoreController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final score = c.score;
    final scheme = Theme.of(context).colorScheme;

    if (!c.portalBound) {
      return _IconHeader(
        icon: Icons.link_off,
        color: AppColors.hint,
        title: '未绑定统一门户',
        subtitle: '劳动积分查询需要门户身份，请先到「我的 → 绑定统一门户」完成绑定。',
        onTap: () => context.push('/portal-bind'),
      );
    }
    if (score == null) {
      return _IconHeader(
        icon: Icons.volunteer_activism_outlined,
        color: kLaborColor,
        title: c.loading ? '正在获取劳动积分…' : '暂无数据',
        subtitle: c.error ?? '数据来自劳动教育平台。',
        isError: !c.loading && c.error != null,
        onTap: c.loading ? null : c.refresh,
      );
    }

    final r = score.official;
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
                color: kLaborColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.volunteer_activism_outlined,
                color: kLaborColor,
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
                        r == null || r.total.isEmpty ? '--' : r.total,
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
                      if (r != null) ...[
                        const SizedBox(width: 10),
                        // 「未确认」是常态，不标；只在已确认时给标签。
                        if (r.isConfirmed) ...[
                          const _Tag(text: '已确认', color: AppColors.success),
                          const SizedBox(width: 6),
                        ],
                        _Tag(
                          text: r.isFiled ? '已归档' : '未归档',
                          color: r.isFiled ? AppColors.success : AppColors.hint,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    r == null
                        ? '平台尚未生成核算结果'
                        : r.updatedAt.isEmpty
                        ? '官方核算结果'
                        : '核算于 ${r.updatedAt}',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.labelText,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    c.error ?? '更新于 ${formatFullTime(score.fetchedAt)}',
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

/// 官方核算的分项。
class _Breakdown extends StatelessWidget {
  const _Breakdown({required this.result});

  final LaborResult? result;

  @override
  Widget build(BuildContext context) {
    final r = result;
    return _Section(
      title: '积分构成',
      children: r == null
          ? const [_Hint('尚无核算结果')]
          : [
              _KeyValue(label: '理论积分', value: r.theory),
              _KeyValue(label: '生活劳动', value: r.life),
              _KeyValue(label: '服务劳动', value: r.service),
              _KeyValue(label: '专业劳动 · 课程', value: r.majorCourse),
              _KeyValue(label: '专业劳动 · 竞赛', value: r.majorContest),
            ],
    );
  }
}

/// 各分项页面的实时统计。
class _LiveStats extends StatelessWidget {
  const _LiveStats({required this.score});

  final LaborScore score;

  @override
  Widget build(BuildContext context) {
    final major = score.liveMajor;
    return _Section(
      title: '实时统计',
      footnote: '实时统计取自各分项页面当前的数字，可能领先于官方核算；成绩以核算结果为准。',
      children: [
        _KeyValue(label: '生活劳动活动', value: score.liveLife ?? ''),
        _KeyValue(label: '服务劳动活动', value: score.liveService ?? ''),
        if (major == null)
          const _KeyValue(label: '专业劳动', value: '暂无数据', muted: true)
        else ...[
          _KeyValue(label: '专业劳动 · 课程', value: major.course),
          _KeyValue(label: '专业劳动 · 竞赛', value: major.contest),
          _KeyValue(label: '专业劳动 · 累计', value: major.total),
        ],
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, this.footnote});

  final String title;
  final List<Widget> children;
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.titleText,
              ),
            ),
          ),
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i != children.length - 1)
              const Padding(
                padding: EdgeInsets.only(left: 16),
                child: Divider(height: 1, color: AppColors.rowDivider),
              ),
          ],
          if (footnote != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text(
                footnote!,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.hint,
                  height: 1.5,
                ),
              ),
            )
          else
            const SizedBox(height: 4),
        ],
      ),
    );
  }
}

class _KeyValue extends StatelessWidget {
  const _KeyValue({
    required this.label,
    required this.value,
    this.muted = false,
  });

  final String label;
  final String value;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 13, color: AppColors.labelText),
          ),
          const Spacer(),
          Text(
            value.isEmpty ? '--' : value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: muted ? FontWeight.w400 : FontWeight.w600,
              color: muted ? AppColors.hint : AppColors.titleText,
            ),
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Text(
        text,
        style: const TextStyle(fontSize: 13, color: AppColors.hint),
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
