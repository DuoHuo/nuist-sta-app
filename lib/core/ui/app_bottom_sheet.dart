import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../navigation/app_navigation.dart';

const double _kDefaultScrollControlDisabledMaxHeightRatio = 9.0 / 16.0;

/// 显示支持 Android 预测性返回手势反馈的模态底部弹层。
///
/// 参数与 [showModalBottomSheet] 保持一致，内部使用 [AppModalBottomSheetRoute]，
/// 在手势推进阶段仅对弹层卡片本身做缩放反馈（不缩放全屏遮罩），并在宽屏双栏下
/// 遵循 [AppNavigationController.isBackTarget] 仅让返回目标栏响应手势。
Future<T?> showAppModalBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  String? barrierLabel,
  double? elevation,
  ShapeBorder? shape,
  Clip? clipBehavior,
  BoxConstraints? constraints,
  Color? barrierColor,
  bool isScrollControlled = false,
  double scrollControlDisabledMaxHeightRatio =
      _kDefaultScrollControlDisabledMaxHeightRatio,
  bool useRootNavigator = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool? showDragHandle,
  bool useSafeArea = false,
  RouteSettings? routeSettings,
  AnimationController? transitionAnimationController,
  Offset? anchorPoint,
  AnimationStyle? sheetAnimationStyle,
  bool? requestFocus,
}) {
  assert(debugCheckHasMediaQuery(context));
  assert(debugCheckHasMaterialLocalizations(context));

  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  final localizations = MaterialLocalizations.of(context);
  return navigator.push(
    AppModalBottomSheetRoute<T>(
      builder: builder,
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
      isScrollControlled: isScrollControlled,
      scrollControlDisabledMaxHeightRatio: scrollControlDisabledMaxHeightRatio,
      barrierLabel: barrierLabel ?? localizations.scrimLabel,
      barrierOnTapHint: localizations.scrimOnTapHint(
        localizations.bottomSheetLabel,
      ),
      backgroundColor: backgroundColor,
      elevation: elevation,
      shape: shape,
      clipBehavior: clipBehavior,
      constraints: constraints,
      isDismissible: isDismissible,
      modalBarrierColor:
          barrierColor ?? Theme.of(context).bottomSheetTheme.modalBarrierColor,
      enableDrag: enableDrag,
      showDragHandle: showDragHandle,
      settings: routeSettings,
      transitionAnimationController: transitionAnimationController,
      anchorPoint: anchorPoint,
      useSafeArea: useSafeArea,
      sheetAnimationStyle: sheetAnimationStyle,
      requestFocus: requestFocus,
    ),
  );
}

/// 在 [ModalBottomSheetRoute] 基础上附加 Android 预测性返回手势反馈的路由。
class AppModalBottomSheetRoute<T> extends ModalBottomSheetRoute<T> {
  AppModalBottomSheetRoute({
    required super.builder,
    super.capturedThemes,
    super.barrierLabel,
    super.barrierOnTapHint,
    super.backgroundColor,
    super.elevation,
    super.shape,
    super.clipBehavior,
    super.constraints,
    super.modalBarrierColor,
    super.isDismissible = true,
    super.enableDrag = true,
    super.showDragHandle,
    required super.isScrollControlled,
    super.scrollControlDisabledMaxHeightRatio =
        _kDefaultScrollControlDisabledMaxHeightRatio,
    super.settings,
    super.transitionAnimationController,
    super.anchorPoint,
    super.useSafeArea = false,
    super.sheetAnimationStyle,
    super.requestFocus,
  });

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return _PredictiveBackSheetFeedback(
      route: this,
      child: super.buildTransitions(
        context,
        animation,
        secondaryAnimation,
        child,
      ),
    );
  }
}

class _PredictiveBackSheetFeedback extends StatefulWidget {
  const _PredictiveBackSheetFeedback({
    required this.route,
    required this.child,
  });

  final AppModalBottomSheetRoute<dynamic> route;
  final Widget child;

  @override
  State<_PredictiveBackSheetFeedback> createState() =>
      _PredictiveBackSheetFeedbackState();
}

class _PredictiveBackSheetFeedbackState
    extends State<_PredictiveBackSheetFeedback>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  bool _previewing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _progress.dispose();
    super.dispose();
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    final route = widget.route;
    final navigator = route.navigator;
    if (backEvent.isButtonEvent ||
        navigator == null ||
        !route.isCurrent ||
        !route.isDismissible ||
        route.popDisposition != RoutePopDisposition.pop ||
        route.willHandlePopInternally) {
      return false;
    }
    final isBackTarget =
        AppNavigationScope.readOf(navigator.context)?.navigation
            .isBackTarget(navigator) ??
        true;
    if (!isBackTarget) return false;

    _previewing = true;
    _progress.stop();
    _progress.value = backEvent.progress.clamp(0.0, 1.0);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (_previewing) {
      _progress.value = backEvent.progress.clamp(0.0, 1.0);
    }
  }

  @override
  void handleCancelBackGesture() {
    if (!_previewing) return;
    _previewing = false;
    _progress.animateBack(0.0, curve: Curves.easeOutCubic);
  }

  @override
  void handleCommitBackGesture() {
    if (!_previewing) return;
    _previewing = false;
    _progress.value = 0.0;
    widget.route.navigator?.maybePop();
  }

  @override
  Widget build(BuildContext context) {
    // 参照 MDC-Android MaterialBottomContainerBackHelper：以底边中点为锚点，
    // 水平最多收窄约 48dp（受最小比例限制）、垂直最多压缩约 24dp。
    return AnimatedBuilder(
      animation: _progress,
      child: widget.child,
      builder: (context, child) {
        final raw = _progress.value;
        if (raw <= 0.0) return child!;
        final eased = Curves.easeOutCubic.transform(raw);
        final size = MediaQuery.sizeOf(context);
        final scaleX = size.width > 0
            ? 1.0 - (48.0 / size.width).clamp(0.0, 0.15) * eased
            : 1.0;
        final scaleY = size.height > 0
            ? 1.0 -
                  (24.0 / math.max(size.height * 0.5, 240.0)).clamp(0.0, 0.08) *
                      eased
            : 1.0;
        return Transform(
          alignment: Alignment.bottomCenter,
          transform: Matrix4.diagonal3Values(scaleX, scaleY, 1.0),
          child: child,
        );
      },
    );
  }
}
