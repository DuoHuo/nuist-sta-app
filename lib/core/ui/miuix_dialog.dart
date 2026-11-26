import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

/// Miuix 对话框的关闭控制器。
///
/// 对话框内容由 Miuix 注册到浮层里单独渲染，页面的 `setState` 刷不到它，
/// 所以交互状态（表单、异步保存错误、倒计时）必须放在内容自己的 StatefulWidget 里，
/// 通过 [close] 结束对话框并返回结果。
class MiuixDialogController<T> {
  void Function(T? result)? _onClose;

  /// 是否仍可关闭；关闭后为 `false`。
  bool get isOpen => _onClose != null;

  /// 关闭对话框并返回 [result]。
  void close([T? result]) {
    final onClose = _onClose;
    if (onClose == null) return;
    _onClose = null;
    onClose(result);
  }
}

/// 对话框内容构建器。
typedef MiuixDialogBuilder<T> = Widget Function(
  BuildContext context,
  MiuixDialogController<T> dialog,
);

/// 弹出 Miuix 对话框：手机上从屏幕下半部弹出，大屏居中。
///
/// - [centered] 为 `true` 时手机上也不管屏幕尺寸一律居中（对应 Miuix 的大屏布局）。
/// - [dismissible] 为 `false` 时点遮罩和系统返回都不会关闭。
/// - [maxWidth] 默认 420；公告、更新这类大内容可放宽到 480。
Future<T?> showMiuixDialog<T>(
  BuildContext context, {
  String? title,
  String? summary,
  required MiuixDialogBuilder<T> builder,
  bool dismissible = true,
  bool centered = false,
  bool useRootNavigator = false,
  double maxWidth = MiuixDialogDefaults.maxWidth,
  Size insideMargin = MiuixDialogDefaults.insideMargin,
}) {
  return showGeneralDialog<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    barrierDismissible: false,
    barrierColor: Colors.transparent,
    transitionDuration: Duration.zero,
    pageBuilder: (context, _, _) => _MiuixDialogPage<T>(
      title: title,
      summary: summary,
      builder: builder,
      dismissible: dismissible,
      centered: centered,
      maxWidth: maxWidth,
      insideMargin: insideMargin,
    ),
  );
}

/// 确认/取消对话框。确认返回 `true`，取消或其他方式关闭返回 `false`。
Future<bool> showMiuixConfirmDialog(
  BuildContext context, {
  String? title,
  String? message,
  List<String>? paragraphs,
  Widget? content,
  String confirmLabel = '确定',
  String cancelLabel = '取消',
  bool destructive = false,
  bool confirmPrimary = true,
  bool dismissible = true,
  bool centered = false,
  bool useRootNavigator = false,
  Key? confirmKey,
  Key? cancelKey,
  Key? contentKey,
  Key? messageKey,
}) async {
  final result = await showMiuixDialog<bool>(
    context,
    title: title,
    dismissible: dismissible,
    centered: centered,
    useRootNavigator: useRootNavigator,
    builder: (context, dialog) => _ConfirmContent(
      key: contentKey,
      message: message,
      paragraphs: paragraphs,
      messageKey: messageKey,
      content: content,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      destructive: destructive,
      confirmPrimary: confirmPrimary,
      confirmKey: confirmKey,
      cancelKey: cancelKey,
      onClose: (value) => dialog.close(value),
    ),
  );
  return result ?? false;
}

/// 只有一个按钮的提示对话框。
Future<void> showMiuixInfoDialog(
  BuildContext context, {
  String? title,
  String? message,
  String confirmLabel = '知道了',
  bool dismissible = true,
  bool centered = false,
  bool useRootNavigator = false,
}) {
  return showMiuixDialog<void>(
    context,
    title: title,
    dismissible: dismissible,
    centered: centered,
    useRootNavigator: useRootNavigator,
    builder: (context, dialog) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (message case final text?) _DialogMessage(text),
        const SizedBox(height: 12),
        MiuixButton(
          key: const Key('miuix_info_confirm'),
          colors: MiuixButtonDefaults.buttonColorsPrimary(context),
          onPressed: () => dialog.close(),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
}

/// 隐私同意等必须做出选择的对话框。
///
/// 点「确认」返回 `true`，点「取消」返回 `false`；点遮罩、系统返回等其他方式关闭
/// 返回 `null`。
///
/// - [message] 是纯文本正文；需要行内链接等富文本时改用 [messageBuilder]。
/// - [extra] 放在按钮上方，用于「查看隐私政策」这类链接。
/// - [confirmPrimary] 为 `false` 时，主色（蓝）按钮是「取消」，「确认」是灰色，
///   用于撤回这类不鼓励的操作。
/// - [dismissible] 为 `false` 时，点遮罩和系统返回都不会关闭，只能点「确认」或「取消」。
/// - [confirmDestructive] 为 `true` 时，「确认」按钮的文字用红色（倒计时中为浅红）。
/// - [confirmCountdown] 大于 0 时，「确认」先置灰并显示剩余秒数，倒计时结束才可点。
Future<bool?> showMiuixBottomDialog(
  BuildContext context, {
  String? title,
  String? message,
  WidgetBuilder? messageBuilder,
  required String confirmLabel,
  required String cancelLabel,
  Widget? extra,
  bool confirmPrimary = true,
  bool confirmDestructive = false,
  int confirmCountdown = 0,
  bool dismissible = true,
  bool centered = false,
}) {
  assert(message != null || messageBuilder != null);
  return showMiuixDialog<bool>(
    context,
    title: title,
    dismissible: dismissible,
    centered: centered,
    builder: (context, dialog) => _CountdownContent(
      message: messageBuilder == null ? message : null,
      messageBuilder: messageBuilder,
      extra: extra,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      confirmPrimary: confirmPrimary,
      confirmDestructive: confirmDestructive,
      confirmCountdown: confirmCountdown,
      onClose: dialog.close,
    ),
  );
}

/// 在 [anchorBounds] 附近弹出 Miuix 选项菜单（原地下拉）。
///
/// 点选返回对应 [MiuixOptionItem.value]；点遮罩、系统返回或取消项返回 `null`。
/// 选项较少（约 5 项以内）用这个；选项多时用 [showMiuixOptionDialog]。
Future<T?> showMiuixOptionMenu<T>(
  BuildContext context, {
  required Rect anchorBounds,
  required List<MiuixOptionItem<T>> items,
  String? cancelLabel,
  Key? menuKey,
  Key? cancelKey,
  bool dismissible = true,
  bool useRootNavigator = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    // 锚点是全局坐标；分支导航器只覆盖页面主体，会把菜单位置整体上移。
    // 固定走根导航器，坐标空间才和锚点一致。
    useRootNavigator: useRootNavigator,
    barrierDismissible: false,
    barrierColor: Colors.transparent,
    transitionDuration: Duration.zero,
    pageBuilder: (context, _, _) => _MiuixOptionMenuPage<T>(
      anchorBounds: anchorBounds,
      items: items,
      cancelLabel: cancelLabel,
      menuKey: menuKey,
      cancelKey: cancelKey,
      dismissible: dismissible,
    ),
  );
}

/// 选项较多的选择对话框（选项在内容区滚动）。
Future<T?> showMiuixOptionDialog<T>(
  BuildContext context, {
  required String title,
  required List<MiuixOptionItem<T>> items,
  String cancelLabel = '取消',
  Key? contentKey,
  Key? cancelKey,
  bool dismissible = true,
  bool centered = false,
  bool useRootNavigator = false,
}) {
  return showMiuixDialog<T>(
    context,
    title: title,
    dismissible: dismissible,
    centered: centered,
    useRootNavigator: useRootNavigator,
    // 多项选择弹窗内容较多，默认 24 的内边距会显得空白过大。
    insideMargin: const Size(12, 10),
    builder: (context, dialog) => Column(
      key: contentKey,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final item in items)
                  _OptionRow<T>(
                    item: item,
                    onTap: item.enabled ? () => dialog.close(item.value) : null,
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        MiuixTextButton(
          cancelLabel,
          key: cancelKey,
          minHeight: 36,
          insideMargin: const EdgeInsets.symmetric(vertical: 6),
          onPressed: () => dialog.close(),
        ),
      ],
    ),
  );
}

/// 选项菜单/对话框里的一项。
class MiuixOptionItem<T> {
  const MiuixOptionItem({
    this.key,
    required this.value,
    required this.label,
    this.description,
    this.enabled = true,
    this.selected = false,
    this.destructive = false,
  });

  final Key? key;
  final T value;
  final String label;
  final String? description;
  final bool enabled;
  final bool selected;
  final bool destructive;
}

/// 取 [context] 对应渲染对象的全局矩形，作为弹层锚点。
Rect miuixAnchorRect(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached) return Rect.zero;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// 在页面内提供 Miuix 弹层宿主（下拉菜单、选项菜单需要）。
///
/// 没有它时 `MiuixOverlayDropdownMenu` 等组件无处注册，点击后不会弹出。
class MiuixPopupHostScope extends StatelessWidget {
  const MiuixPopupHostScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MiuixTheme(
      data: MiuixThemeData.of(Theme.of(context).brightness),
      child: MiuixPopupScope(
        establishRoot: true,
        child: Stack(
          fit: StackFit.expand,
          children: [child, const MiuixPopupHost()],
        ),
      ),
    );
  }
}

class _MiuixDialogPage<T> extends StatefulWidget {
  const _MiuixDialogPage({
    required this.title,
    required this.summary,
    required this.builder,
    required this.dismissible,
    required this.centered,
    required this.maxWidth,
    required this.insideMargin,
  });

  final String? title;
  final String? summary;
  final MiuixDialogBuilder<T> builder;
  final bool dismissible;
  final bool centered;
  final double maxWidth;
  final Size insideMargin;

  @override
  State<_MiuixDialogPage<T>> createState() => _MiuixDialogPageState<T>();
}

class _MiuixDialogPageState<T> extends State<_MiuixDialogPage<T>> {
  final MiuixDialogController<T> _controller = MiuixDialogController<T>();
  Widget? _content;
  bool _show = true;
  T? _result;

  @override
  void initState() {
    super.initState();
    _controller._onClose = _close;
  }

  /// 先播放 Miuix 的退出动画，动画结束后再关闭路由。
  void _close(T? result) {
    if (!_show) return;
    setState(() {
      _show = false;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = MiuixThemeData.of(Theme.of(context).brightness);
    // 内容只构建一次：键盘、旋转等 MediaQuery 变化会让页面重建，
    // 每次都新建内容 widget 会让表单/列表跟着重建。需要随尺寸变化的部分
    // 由内容自己在内部按约束布局。
    _content ??= widget.builder(context, _controller);
    // 统一拦住系统返回：可关闭时走 _close 播放 Miuix 退场动画，避免
    // showGeneralDialog(transitionDuration: Duration.zero) 直接 0ms 硬切消失；
    // 不可关闭时保持拦截，按钮关闭由 onDismissFinished 程序化 pop 完成。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && widget.dismissible) _close(null);
      },
      child: MiuixTheme(
        data: theme,
        child: MiuixPopupScope(
          establishRoot: true,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const MiuixPopupHost(),
              MiuixOverlayDialog(
                show: _show,
                title: widget.title,
                summary: widget.summary,
                largeScreen: widget.centered ? true : null,
                maxWidth: widget.maxWidth,
                insideMargin: widget.insideMargin,
                onDismissRequest: widget.dismissible
                    ? () => _close(null)
                    : null,
                onDismissFinished: () {
                  if (mounted) Navigator.of(context).pop(_result);
                },
                content: _content!,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConfirmContent extends StatelessWidget {
  const _ConfirmContent({
    super.key,
    required this.message,
    required this.paragraphs,
    required this.messageKey,
    required this.content,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.destructive,
    required this.confirmPrimary,
    required this.confirmKey,
    required this.cancelKey,
    required this.onClose,
  });

  final String? message;
  final List<String>? paragraphs;
  final Key? messageKey;
  final Widget? content;
  final String confirmLabel;
  final String cancelLabel;
  final bool destructive;
  final bool confirmPrimary;
  final Key? confirmKey;
  final Key? cancelKey;
  final ValueChanged<bool> onClose;

  @override
  Widget build(BuildContext context) {
    final primary = MiuixButtonDefaults.buttonColorsPrimary(context);
    final confirmColors = destructive
        ? _destructiveColors(context)
        : confirmPrimary
        ? primary
        : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (message case final text?) _DialogMessage(text, key: messageKey),
        if (paragraphs case final texts?)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (index, text) in texts.indexed) ...[
                if (index > 0) const SizedBox(height: 12),
                _DialogMessage(text),
              ],
            ],
          ),
        ?content,
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: MiuixButton(
                key: cancelKey,
                colors: confirmPrimary && !destructive ? null : primary,
                onPressed: () => onClose(false),
                child: Text(cancelLabel),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: MiuixButton(
                key: confirmKey,
                colors: confirmColors,
                onPressed: () => onClose(true),
                child: Text(confirmLabel),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _CountdownContent extends StatefulWidget {
  const _CountdownContent({
    required this.message,
    required this.messageBuilder,
    required this.extra,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.confirmPrimary,
    required this.confirmDestructive,
    required this.confirmCountdown,
    required this.onClose,
  });

  final String? message;
  final WidgetBuilder? messageBuilder;
  final Widget? extra;
  final String confirmLabel;
  final String cancelLabel;
  final bool confirmPrimary;
  final bool confirmDestructive;
  final int confirmCountdown;
  final ValueChanged<bool?> onClose;

  @override
  State<_CountdownContent> createState() => _CountdownContentState();
}

class _CountdownContentState extends State<_CountdownContent> {
  late int _remaining = widget.confirmCountdown;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (_remaining > 0) {
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) return;
        setState(() => _remaining--);
        if (_remaining <= 0) timer.cancel();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = MiuixButtonDefaults.buttonColorsPrimary(context);
    final counting = _remaining > 0;
    final colors = widget.confirmPrimary
        ? primary
        : widget.confirmDestructive
        ? _destructiveColors(context)
        : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.messageBuilder != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: widget.messageBuilder!(context),
          )
        else if (widget.message case final text?)
          _DialogMessage(text),
        if (widget.extra != null) widget.extra!,
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: MiuixButton(
                colors: widget.confirmPrimary ? null : primary,
                onPressed: () => widget.onClose(false),
                child: Text(widget.cancelLabel),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: MiuixButton(
                enabled: !counting,
                colors: colors,
                onPressed: counting ? null : () => widget.onClose(true),
                child: Text(
                  counting
                      ? '${widget.confirmLabel}（${_remaining}s）'
                      : widget.confirmLabel,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _DialogMessage extends StatelessWidget {
  const _DialogMessage(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    return Text(
      text,
      style: theme.textStyles.body1.copyWith(
        color: theme.colors.onSurfaceSecondary,
        height: 1.5,
      ),
    );
  }
}

class _MiuixOptionMenuPage<T> extends StatefulWidget {
  const _MiuixOptionMenuPage({
    required this.anchorBounds,
    required this.items,
    required this.cancelLabel,
    required this.menuKey,
    required this.cancelKey,
    required this.dismissible,
  });

  final Rect anchorBounds;
  final List<MiuixOptionItem<T>> items;
  final String? cancelLabel;
  final Key? menuKey;
  final Key? cancelKey;
  final bool dismissible;

  @override
  State<_MiuixOptionMenuPage<T>> createState() =>
      _MiuixOptionMenuPageState<T>();
}

/// 固定在锚点下方展开的定位器：不因空间不足翻到上方。
class _BelowPopupPositionProvider implements MiuixPopupPositionProvider {
  const _BelowPopupPositionProvider();

  @override
  EdgeInsetsGeometry get margins =>
      const EdgeInsets.symmetric(horizontal: 8, vertical: 4);

  @override
  Offset calculatePosition({
    required Rect anchorBounds,
    required Rect windowBounds,
    required TextDirection textDirection,
    required Size popupContentSize,
    required EdgeInsets popupMargin,
    required MiuixPopupAlign alignment,
  }) {
    final maxX = math.max(
      windowBounds.left + popupMargin.left,
      windowBounds.right - popupContentSize.width - popupMargin.right,
    );
    final maxY = math.max(
      windowBounds.top + popupMargin.top,
      windowBounds.bottom - popupContentSize.height - popupMargin.bottom,
    );
    return Offset(
      (anchorBounds.right - popupContentSize.width - popupMargin.right)
          .clamp(windowBounds.left + popupMargin.left, maxX)
          .toDouble(),
      (anchorBounds.bottom + popupMargin.top)
          .clamp(windowBounds.top + popupMargin.top, maxY)
          .toDouble(),
    );
  }
}

class _MiuixOptionMenuPageState<T> extends State<_MiuixOptionMenuPage<T>> {
  bool _show = true;
  T? _result;

  void _close([T? result]) {
    if (!_show) return;
    setState(() {
      _show = false;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = MiuixThemeData.of(Theme.of(context).brightness);
    final height = MediaQuery.sizeOf(context).height;
    final verticalPadding = MediaQuery.paddingOf(context).vertical;
    // 锚点靠近屏幕底部时下方放不下：菜单仍固定向下展开，但整体被定位器
    // 夹紧进窗口内，所以最大高度按整个窗口可用高度算，而不是锚点下方的余量。
    final maxHeight = math.max(120.0, height - verticalPadding - 16);
    return PopScope(
      canPop: widget.dismissible,
      child: MiuixTheme(
        data: theme,
        child: MiuixPopupScope(
          establishRoot: true,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const MiuixPopupHost(),
              KeyedSubtree(
                key: widget.menuKey,
                child: MiuixOverlayListPopup(
                  show: _show,
                  anchorBounds: widget.anchorBounds,
                  alignment: MiuixPopupAlign.end,
                  popupPositionProvider: const _BelowPopupPositionProvider(),
                  onDismissRequest: widget.dismissible ? _close : null,
                  onDismissFinished: () {
                    if (mounted) Navigator.of(context).pop(_result);
                  },
                  maxHeight: maxHeight,
                  content: MiuixListPopupColumn(
                    children: [
                      for (final (index, item) in widget.items.indexed)
                        _OptionRow<T>(
                          item: item,
                          isFirst: index == 0,
                          isLast:
                              index == widget.items.length - 1 &&
                              widget.cancelLabel == null,
                          onTap: item.enabled ? () => _close(item.value) : null,
                        ),
                      if (widget.cancelLabel case final label?)
                        _MenuRow(
                          key: widget.cancelKey,
                          label: label,
                          destructive: true,
                          isFirst: widget.items.isEmpty,
                          isLast: true,
                          onTap: () => _close(),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 选项行：标题 + 可选说明，支持选中、禁用和危险色。
class _OptionRow<T> extends StatelessWidget {
  const _OptionRow({
    required this.item,
    required this.onTap,
    this.isFirst = false,
    this.isLast = false,
  });

  final MiuixOptionItem<T> item;
  final VoidCallback? onTap;
  final bool isFirst;
  final bool isLast;

  @override
  Widget build(BuildContext context) => _MenuRow(
    key: item.key,
    label: item.label,
    description: item.description,
    enabled: item.enabled,
    selected: item.selected,
    destructive: item.destructive,
    isFirst: isFirst,
    isLast: isLast,
    onTap: onTap,
  );
}

/// 菜单行：标题 + 可选说明，支持选中、禁用和危险色。
class _MenuRow extends StatelessWidget {
  const _MenuRow({
    super.key,
    required this.label,
    this.description,
    this.enabled = true,
    this.selected = false,
    this.destructive = false,
    this.isFirst = false,
    this.isLast = false,
    required this.onTap,
  });

  final String label;
  final String? description;
  final bool enabled;
  final bool selected;
  final bool destructive;
  final bool isFirst;
  final bool isLast;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    final colors = theme.colors;
    final active = enabled && onTap != null;
    final titleColor = !active
        ? colors.disabledOnSecondaryVariant
        : destructive
        ? colors.error
        : selected
        ? colors.primary
        : colors.onBackground;
    return MergeSemantics(
      child: Semantics(
        selected: selected,
        button: true,
        child: MiuixPressable(
          onPressed: active ? onTap : null,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              isFirst ? 20 : 12,
              20,
              isLast ? 20 : 12,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textStyles.body1.copyWith(color: titleColor),
                ),
                if (description case final text?) ...[
                  const SizedBox(height: 2),
                  Text(
                    text,
                    style: theme.textStyles.body2.copyWith(
                      color: active
                          ? colors.onSurfaceVariantSummary
                          : colors.disabledOnSecondaryVariant,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 灰底红字：沿用 Miuix 默认的次级按钮底色（禁用态更浅），只把文字换成错误色。
MiuixButtonColors miuixDestructiveButtonColors(BuildContext context) {
  final base = MiuixButtonDefaults.buttonColors(context);
  final error = MiuixTheme.of(context).colors.error;
  return MiuixButtonColors(
    color: base.color,
    disabledColor: base.disabledColor,
    contentColor: error,
    disabledContentColor: error.withValues(alpha: 0.4),
  );
}

MiuixButtonColors _destructiveColors(BuildContext context) =>
    miuixDestructiveButtonColors(context);
