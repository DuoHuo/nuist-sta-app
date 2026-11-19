import 'dart:async';

import 'package:flutter/widgets.dart';

/// 所在页面不可见时延后构建内容，可见后立即构建，之后不再收起。
///
/// 冷启动直接进入课表时，首页作为返回落点在下层构建；「学习」页签也会在
/// 后台预加载。两者的卡片会启动各自的读盘和刷新，与前台页面的首帧及转场
/// 抢占界面线程。这里按页面可见性（[TickerMode]）判断：可见时与直接构建
/// 完全一致；不可见时等待 [delay] 后再在后台构建，返回或切换页签时只需绘制。
class DeferredWhileHidden extends StatefulWidget {
  const DeferredWhileHidden({
    super.key,
    required this.delay,
    required this.builder,
  });

  /// 不可见时距首次挂载的等待时间。
  final Duration delay;

  final WidgetBuilder builder;

  @override
  State<DeferredWhileHidden> createState() => _DeferredWhileHiddenState();
}

class _DeferredWhileHiddenState extends State<DeferredWhileHidden> {
  bool _built = false;
  Timer? _timer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_built) return;
    if (TickerMode.valuesOf(context).enabled) {
      _timer?.cancel();
      _built = true;
      return;
    }
    _timer ??= Timer(widget.delay, () {
      if (mounted) setState(() => _built = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _built ? widget.builder(context) : const SizedBox.shrink();
}
