import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/navigation/app_navigation.dart';
import '../../core/privacy/privacy_consent.dart';
import '../../core/ui/app_bottom_sheet.dart';

import 'timetable_change_format.dart';
import 'timetable_change_log_page.dart';
import 'timetable_controller.dart';
import 'timetable_copy.dart';
import 'timetable_sync_diff.dart';
import 'timetable_theme.dart';

/// 系统路由（如桌面小组件直达 / 通知跳转）临时收起变更弹窗时传入的哨兵结果。
///
/// 传此结果关闭时不会把未读变动标为已通知，待目标页面稳定后仍会补弹。
const Object kTimetableChangeAlertDeferAcknowledge = Object();

/// 变动摘要弹窗路由名，便于外部识别并按「延后确认」方式安全收起。
const String kTimetableChangeAlertRouteName = 'timetable_change_alert';

/// 同步成功后弹出变动摘要（底部 sheet）；每 fingerprint 只弹一次。
///
/// 关闭（下滑 / 点击遮罩 / 知道了 / 查看记录）只确认本次展示的记录；
/// 若由系统跳转以 [kTimetableChangeAlertDeferAcknowledge] 临时收起，则保留未读以便补弹。
/// 查看记录时等待记录页返回，供调用方继续调度后续变动。
Future<void> showTimetableChangeAlert(
  BuildContext context, {
  List<TimetableChangeRecord>? records,
  TimetableController? controller,
  int maxRows = 5,
}) async {
  final c = controller ?? TimetableController.instance;
  final list = List<TimetableChangeRecord>.of(records ?? c.pendingChangeAlerts);
  if (list.isEmpty) return;
  final revision = c.changeAlertRevision;

  var notified = false;
  var viewLog = false;
  Future<void> markDone() async {
    if (notified) return;
    notified = true;
    final fps = {for (final r in list) r.fingerprint};
    await c.acknowledgeChangeAlerts(fps, revision: revision);
  }

  Object? sheetResult;
  var sheetCompletedNormally = false;
  try {
    sheetResult = await showAppModalBottomSheet<Object?>(
      context: context,
      isScrollControlled: true,
      routeSettings: const RouteSettings(name: kTimetableChangeAlertRouteName),
      backgroundColor: TimetableTheme.colorsOf(context).surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final colors = TimetableTheme.colorsOf(ctx);
        final shown = list.take(maxRows).toList();
        final more = list.length > maxRows;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: colors.divider,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text(
                  TimetableCopy.changeAlertTitle,
                  key: const Key('tt_change_alert_title'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: colors.titleText,
                  ),
                ),
                const SizedBox(height: 14),
                for (var i = 0; i < shown.length; i++) ...[
                  if (i > 0) const SizedBox(height: 10),
                  _AlertRow(
                    record: shown[i],
                    index: i,
                    fallbackTermStart: c.settings.termStartDate,
                  ),
                ],
                if (more) ...[
                  const SizedBox(height: 12),
                  Text(
                    TimetableCopy.changeAlertMoreLabel(list.length),
                    key: const Key('tt_change_alert_more'),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: colors.hint),
                  ),
                ],
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        key: const Key('tt_change_alert_view_log'),
                        onPressed: () {
                          viewLog = true;
                          Navigator.pop(ctx);
                        },
                        child: const Text(TimetableCopy.changeAlertViewLog),
                      ),
                    ),
                    const SizedBox(width: 12),
                    TextButton(
                      key: const Key('tt_change_alert_got_it'),
                      onPressed: () async {
                        final route = ModalRoute.of(ctx);
                        await markDone();
                        if (ctx.mounted && (route?.isCurrent ?? true)) {
                          Navigator.pop(ctx);
                        }
                      },
                      child: Text(
                        TimetableCopy.changeAlertGotIt,
                        style: TextStyle(color: colors.hint),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    sheetCompletedNormally = true;
  } finally {
    final deferred =
        identical(sheetResult, kTimetableChangeAlertDeferAcknowledge) ||
        TimetableChangeAlertCoordinator.isDeferring;
    if (sheetCompletedNormally && !deferred) {
      await markDone();
    }
  }
  if (viewLog && context.mounted && revision == c.changeAlertRevision) {
    await openTimetableChangeLogPage(context, controller: c);
  }
}

/// 统一的变动提醒弹窗协调器：供课表页、考试安排页等页面挂载使用。
///
/// 负责：
/// 1. 全局互斥展示，避免多页面（如双栏或课表+考试栈）叠加弹出；
/// 2. 同时感知 [AppNavigationScope.visible]、[TickerMode]、[ModalRoute.isCurrent]、
///    根导航器顶层弹层（公告/更新/隐私弹窗）与页面自定义阻塞条件；
/// 3. 在被子页、根弹层或不可见分支遮挡而延后时，监听导航/隐私状态并在恢复可见后自动补弹。
class TimetableChangeAlertCoordinator {
  TimetableChangeAlertCoordinator({
    required this.resolveContext,
    required this.resolveController,
    this.canPresent,
  }) {
    _liveCoordinators.add(this);
  }

  static Object? _globalOwner;
  static int _deferCount = 0;
  static final Set<TimetableChangeAlertCoordinator> _liveCoordinators = {};

  /// 当前是否正处于系统路由/小组件跳转的临时挂起窗口。
  static bool get isDeferring => _deferCount > 0;

  /// 临时挂起所有变动弹窗调度（如系统路由 / 桌面小组件热启动切换路由期间），
  /// 返回释放句柄；释放后自动唤醒当前可见页继续调度。
  static VoidCallback deferPresentation() {
    _deferCount++;
    var released = false;
    return () {
      if (released) return;
      released = true;
      if (_deferCount > 0) _deferCount--;
      if (_deferCount == 0) {
        for (final c in List<TimetableChangeAlertCoordinator>.of(
          _liveCoordinators,
        )) {
          c.schedule();
        }
      }
    };
  }

  final BuildContext? Function() resolveContext;
  final TimetableController Function() resolveController;
  final bool Function()? canPresent;

  TimetableController? _attachedController;
  AppNavigationController? _attachedNavigation;
  ModalRoute<dynamic>? _attachedRoute;
  bool _listeningPrivacy = false;
  bool _scheduled = false;
  bool _disposed = false;

  void attach({
    required TimetableController controller,
    AppNavigationController? navigation,
    ModalRoute<dynamic>? route,
  }) {
    if (_disposed) return;
    if (!identical(_attachedController, controller)) {
      _attachedController?.removeListener(schedule);
      _attachedController = controller;
      controller.addListener(schedule);
    }
    if (!identical(_attachedNavigation, navigation)) {
      _attachedNavigation?.removeListener(schedule);
      _attachedNavigation = navigation;
      navigation?.addListener(schedule);
    }
    if (!identical(_attachedRoute, route)) {
      _attachedRoute?.animation?.removeStatusListener(_onRouteAnimationStatus);
      _attachedRoute?.secondaryAnimation?.removeStatusListener(
        _onRouteAnimationStatus,
      );
      _attachedRoute = route;
      route?.animation?.addStatusListener(_onRouteAnimationStatus);
      route?.secondaryAnimation?.addStatusListener(_onRouteAnimationStatus);
    }
    if (!_listeningPrivacy) {
      _listeningPrivacy = true;
      PrivacyConsent.dialogPending.addListener(schedule);
    }
  }

  void _onRouteAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      schedule();
    }
  }

  void dispose() {
    _disposed = true;
    _liveCoordinators.remove(this);
    final wasOwner = identical(_globalOwner, this);
    if (wasOwner) {
      _globalOwner = null;
    }
    _attachedController?.removeListener(schedule);
    _attachedController = null;
    _attachedNavigation?.removeListener(schedule);
    _attachedNavigation = null;
    _attachedRoute?.animation?.removeStatusListener(_onRouteAnimationStatus);
    _attachedRoute?.secondaryAnimation?.removeStatusListener(
      _onRouteAnimationStatus,
    );
    _attachedRoute = null;
    if (_listeningPrivacy) {
      _listeningPrivacy = false;
      PrivacyConsent.dialogPending.removeListener(schedule);
    }
    if (wasOwner && _deferCount == 0) {
      for (final c in List<TimetableChangeAlertCoordinator>.of(
        _liveCoordinators,
      )) {
        c.schedule();
      }
    }
  }

  void schedule() {
    if (_disposed || _scheduled || _globalOwner != null || _deferCount > 0) {
      return;
    }
    final ctx = resolveContext();
    if (ctx == null || !ctx.mounted) return;
    final guard = canPresent;
    if (guard != null && !guard()) return;
    final c = resolveController();
    if (c.loading || c.pendingChangeAlerts.isEmpty) return;

    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      unawaited(_tryPresent());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _isVisibleAndUnobstructed(BuildContext context) {
    if (!context.mounted) return false;
    if (PrivacyConsent.dialogPending.value) return false;
    if (!TickerMode.valuesOf(context).enabled) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;

    final scope = AppNavigationScope.readOf(context);
    if (scope != null) {
      if (!scope.visible) return false;
      if (scope.navigation.hasRouteAboveRoot ||
          scope.navigation.gestureInProgress) {
        return false;
      }
    } else {
      final rootNav = Navigator.maybeOf(context, rootNavigator: true);
      final localNav = Navigator.maybeOf(context);
      if (localNav?.userGestureInProgress ?? false) return false;
      if (rootNav != null &&
          !identical(rootNav, localNav) &&
          (rootNav.canPop() || rootNav.userGestureInProgress)) {
        return false;
      }
    }
    return true;
  }

  Future<void> _tryPresent() async {
    if (_disposed || _globalOwner != null || _deferCount > 0) return;
    final ctx = resolveContext();
    if (ctx == null || !ctx.mounted) return;
    final guard = canPresent;
    if (guard != null && !guard()) return;
    if (!_isVisibleAndUnobstructed(ctx)) return;

    final c = resolveController();
    if (c.loading) return;
    final records = c.pendingChangeAlerts;
    if (records.isEmpty) return;

    _globalOwner = this;
    try {
      await showTimetableChangeAlert(ctx, records: records, controller: c);
    } finally {
      if (identical(_globalOwner, this)) {
        _globalOwner = null;
      }
      if (!_disposed) schedule();
    }
  }
}

class _AlertRow extends StatelessWidget {
  const _AlertRow({
    required this.record,
    required this.index,
    this.fallbackTermStart,
  });

  final TimetableChangeRecord record;
  final int index;
  final DateTime? fallbackTermStart;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final chip = changeTypeChipStyle(record.type, colors);
    return Row(
      key: Key('tt_change_alert_row_$index'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          key: Key('tt_change_alert_chip_$index'),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: chip.bg,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            record.type.labelZh,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: chip.fg,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            TimetableChangeFormat.alertBody(
              record,
              fallbackTermStart: fallbackTermStart,
            ),
            style: TextStyle(
              fontSize: 14,
              color: colors.titleText,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

/// 类型胶囊色（弹窗浅底深字；记录页可复用 [bg]/[fg]）。
({Color bg, Color fg}) changeTypeChipStyle(
  TimetableChangeType type,
  TimetableColors colors,
) {
  // 色值来自 [TimetableColors] / [TimetableTheme] 变动类型 token；文案仍用 type.labelZh。
  switch (type) {
    case TimetableChangeType.added:
      return (bg: colors.changeAddedBg, fg: colors.changeAddedFg);
    case TimetableChangeType.removed:
      return (bg: colors.changeRemovedBg, fg: colors.changeRemovedFg);
    case TimetableChangeType.timeChanged:
      return (bg: colors.changeTimeBg, fg: colors.changeTimeFg);
    case TimetableChangeType.locationChanged:
      return (bg: colors.changeLocationBg, fg: colors.changeLocationFg);
    case TimetableChangeType.teacherChanged:
      return (bg: colors.changeTeacherBg, fg: colors.changeTeacherFg);
    case TimetableChangeType.retakeFlagChanged:
      return (bg: colors.changeRetakeBg, fg: colors.changeRetakeFg);
  }
}
