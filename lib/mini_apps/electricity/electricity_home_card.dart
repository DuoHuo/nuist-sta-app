import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/colors.dart';
import 'electricity_controller.dart';
import 'electricity_format.dart';

/// 首页顶部的电费卡片：右上更新时间 + 刷新，中间剩余电量，左下宿舍。
///
/// 高度固定，各种状态只替换局部内容，避免刷新时整页跳动。
class ElectricityHomeCard extends StatefulWidget {
  const ElectricityHomeCard({super.key});

  @override
  State<ElectricityHomeCard> createState() => _ElectricityHomeCardState();
}

class _ElectricityHomeCardState extends State<ElectricityHomeCard> {
  final _controller = ElectricityController.instance;

  @override
  void initState() {
    super.initState();
    _controller.ensureStarted();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final elec = ElecColors.of(palette);
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final c = _controller;
        final room = c.room;
        final latest = c.latest;
        final error = c.error;

        final String centerText;
        final Color centerColor;
        final String footer;
        final VoidCallback onTap;
        if (!c.portalBound) {
          centerText = '请先绑定统一门户';
          centerColor = palette.hint;
          footer = '去绑定';
          onTap = () => context.push('/portal-bind');
        } else if (room == null) {
          centerText = '尚未绑定宿舍';
          centerColor = palette.hint;
          footer = '点击设置';
          // 与首页宫格一致用 push：go 会把小程序页替换成栈底，
          // 导致顶栏无返回按钮、系统返回键也退不回首页。
          onTap = () => context.push('/apps/electricity');
        } else {
          centerText = latest == null ? '--' : formatKwh(latest.kwh);
          centerColor = c.isOverdue
              ? elec.danger
              : c.isLow
              ? elec.warning
              : palette.titleText;
          footer = room.displayName;
          onTap = () => context.push('/apps/electricity');
        }
        final showValue = room != null && c.portalBound;

        return InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            height: 132,
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.bolt, size: 18, color: elec.warning),
                    const SizedBox(width: 4),
                    Text(
                      '宿舍电费',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: palette.titleText,
                      ),
                    ),
                    const Spacer(),
                    if (showValue) ...[
                      Text(
                        error != null
                            ? '更新失败'
                            : latest == null
                            ? ''
                            : formatShortTime(latest.time),
                        style: TextStyle(
                          fontSize: 11,
                          color: error != null
                              ? Theme.of(context).colorScheme.error
                              : palette.hint,
                        ),
                      ),
                      _RefreshButton(loading: c.loading, onPressed: c.refresh),
                    ] else
                      const SizedBox(height: 32),
                  ],
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: showValue
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(
                                centerText,
                                style: TextStyle(
                                  fontSize: 32,
                                  fontWeight: FontWeight.w700,
                                  color: centerColor,
                                  height: 1,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '度',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: palette.labelText,
                                ),
                              ),
                            ],
                          )
                        : Text(
                            centerText,
                            style: TextStyle(fontSize: 15, color: centerColor),
                          ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        footer,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: palette.labelText,
                        ),
                      ),
                    ),
                    Icon(Icons.chevron_right, color: palette.chevron),
                  ],
                ),
              ],
            ),
          ),
        );
      },
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
              color: AppPalette.of(context).accent,
              icon: const Icon(Icons.refresh),
              onPressed: onPressed,
            ),
    );
  }
}
