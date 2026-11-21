import 'package:flutter/material.dart';

import '../../core/navigation/app_navigation.dart';
import '../../core/colors.dart';
import 'electricity_controller.dart';
import 'electricity_format.dart';

/// 首页顶部的电费卡片：右上更新时间 + 刷新，中间剩余电量，左下宿舍。
///
/// 同一字号下高度固定，各种状态只替换局部内容，避免刷新时整页跳动。
class ElectricityHomeCard extends StatefulWidget {
  const ElectricityHomeCard({super.key, this.controller});

  /// 宿主可注入独立状态，默认与电费详情共用实例。
  final ElectricityController? controller;

  @override
  State<ElectricityHomeCard> createState() => _ElectricityHomeCardState();
}

class _ElectricityHomeCardState extends State<ElectricityHomeCard> {
  late final _controller = widget.controller ?? ElectricityController.instance;

  @override
  void initState() {
    super.initState();
    _controller.ensureStarted();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final elec = ElecColors.of(palette);
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final c = _controller;
        final room = c.room;
        final latest = c.latest;

        final String centerText;
        final Color centerColor;
        final String footer;
        final VoidCallback onTap;
        if (!c.portalBound) {
          centerText = '请先绑定统一门户';
          centerColor = palette.hint;
          footer = '去绑定';
          onTap = () => AppNavigation.push(context, '/portal-bind');
        } else if (room == null) {
          centerText = '尚未绑定宿舍';
          centerColor = palette.hint;
          footer = '点击设置';
          // 与首页宫格一致用 push：go 会把小程序页替换成栈底，
          // 导致顶栏无返回按钮、系统返回键也退不回首页。
          onTap = () => AppNavigation.push(context, '/apps/electricity');
        } else {
          centerText = latest == null ? '--' : formatKwh(latest.kwh);
          centerColor = c.isOverdue
              ? elec.danger
              : c.isLow
              ? elec.warning
              : palette.titleText;
          footer = room.displayName;
          onTap = () => AppNavigation.push(context, '/apps/electricity');
        }
        final showValue = room != null && c.portalBound;

        return InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            height:
                132 +
                (textScaler.scale(32) - 32) +
                (textScaler.scale(15) - 15) +
                (textScaler.scale(12) - 12),
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
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
                      ],
                    ),
                    // 右上角刷新按钮已删除（作者意见）；最后刷新时间保留，
                    // 失败不再在卡片上提示。
                    if (showValue) ...[
                      Text(
                        latest == null ? '' : formatShortTime(latest.time),
                        style: TextStyle(fontSize: 11, color: palette.hint),
                      ),
                    ] else
                      const SizedBox(height: 32),
                  ],
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: showValue
                        ? FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: centerText,
                                    style: TextStyle(
                                      fontSize: 32,
                                      fontWeight: FontWeight.w700,
                                      color: centerColor,
                                      height: 1,
                                    ),
                                  ),
                                  TextSpan(
                                    text: ' 度',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: palette.labelText,
                                    ),
                                  ),
                                ],
                              ),
                              maxLines: 1,
                              softWrap: false,
                            ),
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
