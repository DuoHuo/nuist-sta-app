import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/colors.dart';
import 'electricity_controller.dart';
import 'electricity_format.dart';
import 'electricity_history_chart.dart';
import 'electricity_models.dart';
import 'room_picker_panel.dart';

/// 电费详情页：状态头 → 更换宿舍（原地展开三级下拉）→ 历史电量折线图。
class ElectricityPage extends StatefulWidget {
  const ElectricityPage({super.key});

  @override
  State<ElectricityPage> createState() => _ElectricityPageState();
}

class _ElectricityPageState extends State<ElectricityPage> {
  final _controller = ElectricityController.instance;

  bool _pickerOpen = false;
  int _rangeDays = 7;

  /// 历史记录按需读文件；最近一条记录变了（刷新或换宿舍）就重读。
  Future<List<ElecReading>>? _history;
  ElecReading? _historyFor;

  @override
  void initState() {
    super.initState();
    // 未绑定宿舍时直接把选择面板打开，省一次点击。
    _controller.ensureStarted().then((_) {
      if (mounted && _controller.room == null) {
        setState(() => _pickerOpen = true);
      }
    });
  }

  Future<List<ElecReading>> _loadHistory() {
    // 以最近一条记录为版本号：它变了说明有新数据落盘。
    if (_history == null || !identical(_historyFor, _controller.latest)) {
      _historyFor = _controller.latest;
      _history = _controller.history();
    }
    return _history!;
  }

  Future<void> _saveRoom(ElecRoom room) async {
    await _controller.bindRoom(room);
    if (!mounted) return;
    setState(() => _pickerOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.pageBg,
      appBar: AppBar(title: const Text('宿舍电费')),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final c = _controller;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              _StatusHeader(controller: c),
              const SizedBox(height: 12),
              _Card(
                child: Column(
                  children: [
                    _ActionRow(
                      icon: Icons.home_outlined,
                      label: c.room == null ? '绑定宿舍' : '更换宿舍',
                      hint: '从区域、楼栋、房间列表中选择',
                      expanded: _pickerOpen,
                      onTap: () => setState(() => _pickerOpen = !_pickerOpen),
                    ),
                    _Expandable(
                      expanded: _pickerOpen,
                      child: Column(
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(left: 16),
                            child: Divider(height: 1, color: AppColors.rowDivider),
                          ),
                          RoomPickerPanel(
                            // 换 key 让每次展开都重新拉列表、重新预选。
                            key: ValueKey(_pickerOpen),
                            initial: c.room,
                            onSave: _saveRoom,
                            onCancel: () => setState(() => _pickerOpen = false),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (c.room != null) ...[
                const SizedBox(height: 12),
                _Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text(
                              '历史电量',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: AppColors.titleText,
                              ),
                            ),
                            const Spacer(),
                            _RangeSelector(
                              value: _rangeDays,
                              onChanged: (d) => setState(() => _rangeDays = d),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        FutureBuilder<List<ElecReading>>(
                          future: _loadHistory(),
                          builder: (context, snapshot) =>
                              ElectricityHistoryChart(
                                readings: snapshot.data ?? const [],
                                days: _rangeDays,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
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

  final ElectricityController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final room = c.room;
    final latest = c.latest;
    final scheme = Theme.of(context).colorScheme;

    if (!c.portalBound) {
      return _IconHeader(
        icon: Icons.link_off,
        color: AppColors.hint,
        title: '未绑定统一门户',
        subtitle: '电费查询需要门户身份，请先到「我的 → 统一门户」完成绑定。',
        onTap: () => context.push('/portal-bind'),
      );
    }
    if (room == null) {
      return const _IconHeader(
        icon: Icons.home_outlined,
        color: AppColors.hint,
        title: '未绑定宿舍',
        subtitle: '选择区域、楼栋和房间后，首页会常驻显示剩余电量。',
      );
    }

    final valueColor = c.isOverdue
        ? ElecColors.danger
        : c.isLow
        ? ElecColors.warning
        : AppColors.titleText;
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
                color: ElecColors.warning.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.bolt, color: ElecColors.warning, size: 22),
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
                        latest == null ? '--' : formatKwh(latest.kwh),
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                          color: valueColor,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Text(
                        '度',
                        style: TextStyle(fontSize: 13, color: AppColors.labelText),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    room.displayName,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.labelText,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    c.error != null
                        ? c.error!
                        : latest == null
                        ? '尚未查询'
                        : '更新于 ${formatFullTime(latest.time)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: c.error != null ? scheme.error : AppColors.hint,
                      height: 1.4,
                    ),
                  ),
                  if (c.isOverdue) ...[
                    const SizedBox(height: 4),
                    const Text(
                      '已欠费，请尽快充值',
                      style: TextStyle(fontSize: 11, color: ElecColors.danger),
                    ),
                  ] else if (c.isLow) ...[
                    const SizedBox(height: 4),
                    const Text(
                      '电量不足，请及时充值',
                      style: TextStyle(fontSize: 11, color: ElecColors.warning),
                    ),
                  ],
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

class _IconHeader extends StatelessWidget {
  const _IconHeader({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
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
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.hint,
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

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.hint,
    required this.expanded,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String hint;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              Icon(icon, size: 20, color: AppColors.labelText),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: AppColors.titleText,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hint,
                    style: const TextStyle(fontSize: 11, color: AppColors.hint),
                  ),
                ],
              ),
              const Spacer(),
              AnimatedRotation(
                turns: expanded ? 0.25 : 0,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                child: const Icon(Icons.chevron_right, color: Color(0xFFC9CDD4)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 高度从 0 展开的同时淡入；收起时随高度一起裁掉。
class _Expandable extends StatelessWidget {
  const _Expandable({required this.expanded, required this.child});

  final bool expanded;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: expanded
          ? TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOut,
              builder: (_, opacity, child) =>
                  Opacity(opacity: opacity, child: child),
              child: child,
            )
          : const SizedBox(width: double.infinity),
    );
  }
}

class _RangeSelector extends StatelessWidget {
  const _RangeSelector({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: AppColors.pageBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [for (final d in const [7, 30]) _segment(d)],
      ),
    );
  }

  Widget _segment(int days) {
    final selected = days == value;
    return GestureDetector(
      onTap: () => onChanged(days),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          '近 $days 天',
          style: TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? AppColors.titleText : AppColors.hint,
          ),
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
