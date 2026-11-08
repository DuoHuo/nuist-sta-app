import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'colors.dart';

/// 可取消的下拉刷新。
///
/// Flutter 自带的 [RefreshIndicator] 一旦拉过阈值进入 armed 状态，再往回推
/// 也无法取消，松手必定刷新。这里自己跟踪拖拽距离：松手时仍超过阈值才刷新，
/// 推回阈值以下即取消。刷新过程仍交给内部的 [RefreshIndicator.show]，转圈
/// 动画与系统一致。
///
/// [child] 需要是可滚动组件，且使用 [AlwaysScrollableScrollPhysics]，
/// 否则内容不足一屏时收不到拖拽。
class PullToRefresh extends StatefulWidget {
  const PullToRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
  });

  final RefreshCallback onRefresh;
  final Widget child;

  @override
  State<PullToRefresh> createState() => _PullToRefreshState();
}

class _PullToRefreshState extends State<PullToRefresh> {
  /// 触发刷新所需的手指下拉距离（逻辑像素）。
  static const double _threshold = 160;

  final _indicatorKey = GlobalKey<RefreshIndicatorState>();

  /// 当前拖拽距离；null 表示没在下拉。
  double? _drag;
  bool _refreshing = false;

  bool _handleScroll(ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.vertical || _refreshing) {
      return false;
    }
    final atTop = n.metrics.pixels <= n.metrics.minScrollExtent;
    final drag = _drag;
    if (drag == null) {
      // 在顶部向下拖（Clamping 下表现为 overscroll，Bouncing 下为负向滚动）开始跟踪。
      final pullingDown =
          (n is OverscrollNotification &&
              n.dragDetails != null &&
              n.overscroll < 0) ||
          (n is ScrollUpdateNotification &&
              n.dragDetails != null &&
              atTop &&
              (n.scrollDelta ?? 0) < 0);
      if (pullingDown) {
        _detachListDrag(n);
        setState(
          () => _drag = n is OverscrollNotification
              ? -n.overscroll
              : -(n as ScrollUpdateNotification).scrollDelta!,
        );
      }
    }
    // 开始跟踪后由 [_handlePointerMove] 按手指位移更新。
    return false;
  }

  /// 进入下拉后立即结束列表自己的拖拽：列表停在顶部，本次手势剩下的
  /// 移动（包括上推取消）和松手后的惯性都不再作用到列表上，手指改由
  /// [Listener] 跟踪。下一次按下时列表照常响应。
  ///
  /// 放到微任务里执行，避免在列表派发通知的过程中销毁它的拖拽控制器。
  void _detachListDrag(ScrollNotification n) {
    final context = n.context;
    if (context == null) return;
    final position = Scrollable.maybeOf(context)?.position;
    if (position == null) return;
    scheduleMicrotask(() {
      if (!position.hasPixels) return;
      position.jumpTo(
        position.pixels.clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  /// 下拉期间手指的竖直位移：往下加、往上减，最小到 0。
  ///
  /// 推回 0 也保持在下拉状态，直到松手，列表不会被带着滚动。
  void _handlePointerMove(PointerMoveEvent e) {
    final drag = _drag;
    if (drag == null) return;
    setState(() => _drag = math.max(0, drag + e.delta.dy));
  }

  /// 松手：仍超过阈值才刷新，否则视为取消。
  void _handlePointerEnd(PointerEvent e) {
    final drag = _drag;
    if (drag == null) return;
    setState(() => _drag = null);
    if (drag >= _threshold) _indicatorKey.currentState?.show();
  }

  bool _handleOverscrollIndicator(OverscrollIndicatorNotification n) {
    // 下拉过程中不显示 Android 边缘光晕，和系统 RefreshIndicator 一致。
    // 顶部的拉伸 / 光晕一律关掉：它会比 [_drag] 先一步启动，若只在下拉中
    // 才拦，内容会先被拉伸，上推取消时跟着回缩，看起来像列表在动。
    if (n.depth == 0 && n.leading) {
      n.disallowIndicator();
      return true;
    }
    return false;
  }

  Future<void> _refresh() async {
    _refreshing = true;
    try {
      await widget.onRefresh();
    } finally {
      _refreshing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final drag = _drag;
    final progress = drag == null ? 0.0 : (drag / _threshold).clamp(0.0, 1.0);
    return Stack(
      children: [
        RefreshIndicator(
          key: _indicatorKey,
          color: AppColors.accent,
          // 拖拽由本组件自己判断，内部指示器只负责刷新动画。
          notificationPredicate: (_) => false,
          onRefresh: _refresh,
          child: NotificationListener<OverscrollIndicatorNotification>(
            onNotification: _handleOverscrollIndicator,
            child: NotificationListener<ScrollNotification>(
              onNotification: _handleScroll,
              child: Listener(
                onPointerMove: _handlePointerMove,
                onPointerUp: _handlePointerEnd,
                onPointerCancel: _handlePointerEnd,
                child: widget.child,
              ),
            ),
          ),
        ),
        if (drag != null && drag > 0)
          Positioned(
            top: -40 + 80 * progress,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: Opacity(
                  opacity: progress,
                  child: RefreshProgressIndicator(
                    // 未到阈值时转圈不满，到阈值后完整，松手即刷新。
                    value: progress >= 1 ? 1 : progress * 0.8,
                    color: AppColors.accent,
                    semanticsLabel: progress >= 1 ? '松手刷新' : '下拉刷新',
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
