import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'colors.dart';

// 绘制与行高测量共用紧凑尺寸，长文字仍可按内容增高。
const _selectMinHeight = 40.0;
const _selectOptionPadding = EdgeInsets.symmetric(horizontal: 12, vertical: 8);
const _selectMenuPadding = EdgeInsets.symmetric(horizontal: 6, vertical: 4);

typedef _SelectMeasureEnvironment = ({
  double width,
  TextDirection direction,
  TextScaler textScaler,
  Locale? locale,
  TextStyle labelStyle,
  TextStyle selectedStyle,
  TextStyle hintStyle,
});

/// 统一选择器中的一个选项；用选项包装结果，区分空值选项与取消。
@immutable
class AppSelectOption<T> {
  const AppSelectOption({
    required this.value,
    required this.label,
    this.hint,
    this.enabled = true,
  });

  final T value;
  final String label;
  final String? hint;
  final bool enabled;
}

/// 统一单选框：短列表就地展开，长列表或狭窄空间使用底部选择面板。
class AppSelectField<T> extends StatefulWidget {
  const AppSelectField({
    super.key,
    required this.label,
    required this.options,
    this.value,
    this.onChanged,
    this.enabled = true,
    this.loading = false,
    this.hint = '请选择',
    this.showLabel = false,
    this.searchable = true,
    this.useBottomSheet = false,
    this.textStyle,
    this.errorText,
  });

  final String label;
  final List<AppSelectOption<T>> options;
  final T? value;
  final ValueChanged<T>? onChanged;
  final bool enabled;
  final bool loading;
  final String hint;
  final bool showLabel;
  final bool searchable;
  final bool useBottomSheet;
  final TextStyle? textStyle;
  final String? errorText;

  @override
  State<AppSelectField<T>> createState() => _AppSelectFieldState<T>();
}

class _AppSelectFieldState<T> extends State<AppSelectField<T>> {
  final _anchor = GlobalKey();
  final _focus = FocusNode();
  bool _opened = false;
  bool _focused = false;

  bool get _active =>
      widget.enabled &&
      !widget.loading &&
      widget.onChanged != null &&
      widget.options.any((option) => option.enabled);

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<AppSelectOption<T>?> _showMenu({required bool keyboard}) {
    final palette = AppPalette.of(context);
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final box = _anchor.currentContext!.findRenderObject()! as RenderBox;
    final options = List<AppSelectOption<T>>.of(widget.options);
    final focusOption =
        options
            .where((option) => option.enabled && option.value == widget.value)
            .firstOrNull ??
        options.where((option) => option.enabled).firstOrNull;
    final width = box.size.width;
    var position = RelativeRect.fromRect(
      Rect.fromLTWH(0, 0, width, 0),
      Offset.zero & overlay.size,
    );
    // 使用独立弹出路由承接系统返回，避免触发表单自身的放弃修改提示。
    return showMenu<AppSelectOption<T>>(
      context: context,
      requestFocus: true,
      semanticLabel: widget.label,
      positionBuilder: (context, constraints) {
        final anchorBox = _anchor.currentContext?.findRenderObject();
        if (anchorBox is RenderBox && anchorBox.attached && overlay.attached) {
          final offset = anchorBox.localToGlobal(
            Offset.zero,
            ancestor: overlay,
          );
          final height = options.fold<double>(
            _selectMenuPadding.vertical,
            (sum, option) =>
                sum +
                _optionHeight(
                  context,
                  option,
                  width - _selectMenuPadding.horizontal,
                  selected: option.value == widget.value,
                ),
          );
          final below =
              overlay.size.height - offset.dy - anchorBox.size.height - 16;
          final top = height > below && offset.dy > below
              ? offset.dy - height - 8
              : offset.dy + anchorBox.size.height + 8;
          position = RelativeRect.fromRect(
            Rect.fromLTWH(offset.dx, top, anchorBox.size.width, 0),
            Offset.zero & overlay.size,
          );
        }
        return position;
      },
      constraints: BoxConstraints.tightFor(width: width),
      menuPadding: _selectMenuPadding,
      color: palette.surface,
      surfaceTintColor: Colors.transparent,
      shadowColor: palette.titleText.withValues(alpha: .14),
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: palette.divider),
      ),
      popUpAnimationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : const AnimationStyle(
              duration: Duration(milliseconds: 170),
              reverseDuration: Duration(milliseconds: 110),
            ),
      items: [
        for (final option in options)
          PopupMenuItem<AppSelectOption<T>>(
            value: option,
            enabled: option.enabled,
            padding: EdgeInsets.zero,
            height: _selectMinHeight,
            child: Semantics(
              selected: option.value == widget.value,
              child: Ink(
                decoration: BoxDecoration(
                  color: option.value == widget.value
                      ? Color.alphaBlend(
                          palette.accent.withValues(alpha: .1),
                          palette.surface,
                        )
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: _selectOptionPadding,
                  child: Focus(
                    autofocus: keyboard && identical(option, focusOption),
                    skipTraversal: true,
                    child: _OptionContent(
                      label: option.label,
                      hint: option.hint,
                      selected: option.value == widget.value,
                      enabled: option.enabled,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _open({required bool sheet, bool keyboard = false}) async {
    if (!_active || _opened) return;
    _focus.requestFocus();
    setState(() => _opened = true);
    try {
      final picked = sheet
          ? await showAppSelectSheet<T>(
              context,
              title: widget.label,
              options: widget.options,
              selected: widget.value,
              searchable: widget.searchable,
            )
          : await _showMenu(keyboard: keyboard);
      if (!mounted || !_active || picked == null) return;
      // 级联选择期间上级可能改变，只接受最新列表中仍然有效的选项。
      for (final option in widget.options) {
        if (option.enabled && option.value == picked.value) {
          widget.onChanged?.call(option.value);
          break;
        }
      }
    } finally {
      if (mounted) {
        setState(() => _opened = false);
        if (_active) _focus.requestFocus();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final selected = widget.options
        .where((option) => option.value == widget.value)
        .firstOrNull;
    final display = widget.loading ? '加载中…' : selected?.label ?? widget.hint;
    final textStyle = (widget.textStyle ?? const TextStyle(fontSize: 14))
        .copyWith(
          color: selected == null || !_active
              ? palette.labelText
              : palette.titleText,
          fontWeight: selected == null ? FontWeight.w400 : FontWeight.w500,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.showLabel) ...[
          ExcludeSemantics(
            child: Text(
              widget.label,
              style: TextStyle(fontSize: 13, color: palette.labelText),
            ),
          ),
          const SizedBox(height: 6),
        ],
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.hasBoundedWidth
                ? constraints.maxWidth
                : 280.0;
            final sheet =
                widget.useBottomSheet ||
                widget.options.length > 6 ||
                width < 180 ||
                MediaQuery.textScalerOf(context).scale(14) > 23;
            return SizedBox(
              key: _anchor,
              width: width,
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                      _open(sheet: sheet, keyboard: true),
                  const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                      _open(sheet: sheet, keyboard: true),
                },
                child: Semantics(
                  label: widget.label,
                  value: display,
                  button: true,
                  enabled: _active,
                  expanded: _opened,
                  onTap: _active ? () => _open(sheet: sheet) : null,
                  excludeSemantics: true,
                  child: AnimatedContainer(
                    duration: reduceMotion
                        ? Duration.zero
                        : const Duration(milliseconds: 140),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: widget.errorText != null
                            ? palette.danger
                            : _opened || _focused
                            ? palette.accent
                            : palette.divider,
                      ),
                      boxShadow: _opened || _focused
                          ? [
                              BoxShadow(
                                color: palette.accent.withValues(alpha: .1),
                                spreadRadius: 2,
                              ),
                            ]
                          : [],
                    ),
                    child: Material(
                      color: _active ? palette.surface : palette.pageBg,
                      borderRadius: BorderRadius.circular(12),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        focusNode: _focus,
                        canRequestFocus: _active,
                        excludeFromSemantics: true,
                        onFocusChange: (value) =>
                            setState(() => _focused = value),
                        onTap: _active ? () => _open(sheet: sheet) : null,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            minHeight: _selectMinHeight,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(display, style: textStyle),
                                ),
                                const SizedBox(width: 8),
                                if (widget.loading)
                                  SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: palette.accent,
                                    ),
                                  )
                                else
                                  AnimatedRotation(
                                    turns: _opened ? .5 : 0,
                                    duration: reduceMotion
                                        ? Duration.zero
                                        : const Duration(milliseconds: 160),
                                    child: Icon(
                                      Icons.expand_more,
                                      size: 20,
                                      color: _opened
                                          ? palette.accent
                                          : palette.labelText,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        if (widget.errorText != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 12),
            child: Semantics(
              liveRegion: true,
              child: Text(
                widget.errorText!,
                style: TextStyle(fontSize: 12, color: palette.danger),
              ),
            ),
          ),
      ],
    );
  }
}

/// 保留校验、重置和保存语义的统一表单选择框。
class AppSelectFormField<T> extends FormField<T> {
  AppSelectFormField({
    super.key,
    required String label,
    required List<AppSelectOption<T>> options,
    super.initialValue,
    this.onChanged,
    super.enabled = true,
    bool loading = false,
    String hint = '请选择',
    bool showLabel = false,
    bool searchable = true,
    bool useBottomSheet = false,
    TextStyle? textStyle,
    String? errorText,
    super.validator,
    super.onSaved,
    super.autovalidateMode,
  }) : super(
         builder: (field) => AppSelectField<T>(
           label: label,
           value: field.value,
           options: options,
           enabled: enabled,
           loading: loading,
           hint: hint,
           showLabel: showLabel,
           searchable: searchable,
           useBottomSheet: useBottomSheet,
           textStyle: textStyle,
           errorText: field.errorText ?? errorText,
           onChanged: onChanged == null
               ? null
               : (value) {
                   field.didChange(value);
                   onChanged(value);
                 },
         ),
       );

  final ValueChanged<T>? onChanged;

  @override
  FormFieldState<T> createState() => _AppSelectFormFieldState<T>();
}

class _AppSelectFormFieldState<T> extends FormFieldState<T> {
  @override
  void didUpdateWidget(covariant AppSelectFormField<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialValue != widget.initialValue) {
      setValue(widget.initialValue);
    }
  }
}

/// 展示统一单选面板；仅搜索已有选项，不请求网络、不记录搜索词。
///
/// 关闭时返回 null，点选时返回选项本身，即使其 value 为 null。
Future<AppSelectOption<T>?> showAppSelectSheet<T>(
  BuildContext context, {
  required String title,
  required List<AppSelectOption<T>> options,
  T? selected,
  bool searchable = true,
}) {
  final palette = AppPalette.of(context);
  return showModalBottomSheet<AppSelectOption<T>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: palette.surface,
    barrierColor: (palette.isDark ? palette.pageBg : palette.titleText)
        .withValues(alpha: palette.isDark ? .6 : .24),
    constraints: const BoxConstraints(maxWidth: 560),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    clipBehavior: Clip.antiAlias,
    sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : const AnimationStyle(
            duration: Duration(milliseconds: 220),
            reverseDuration: Duration(milliseconds: 140),
          ),
    builder: (context) => _AppSelectSheet<T>(
      title: title,
      options: List.unmodifiable(options),
      selected: selected,
      searchable: searchable && options.length > 6,
    ),
  );
}

class _AppSelectSheet<T> extends StatefulWidget {
  const _AppSelectSheet({
    required this.title,
    required this.options,
    required this.selected,
    required this.searchable,
  });

  final String title;
  final List<AppSelectOption<T>> options;
  final T? selected;
  final bool searchable;

  @override
  State<_AppSelectSheet<T>> createState() => _AppSelectSheetState<T>();
}

class _AppSelectSheetState<T> extends State<_AppSelectSheet<T>> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _headerKey = GlobalKey();
  String _query = '';
  bool _positioned = false;
  late List<String> _searchLabels;
  late List<AppSelectOption<T>> _filtered;
  final Map<AppSelectOption<T>, double> _optionHeights = {};
  List<double>? _filteredHeights;
  _SelectMeasureEnvironment? _measureEnvironment;
  T? _measuredSelection;

  @override
  void initState() {
    super.initState();
    _updateOptions();
  }

  @override
  void didUpdateWidget(covariant _AppSelectSheet<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.options, widget.options)) {
      _optionHeights.clear();
      _updateOptions();
    }
  }

  void _updateOptions() {
    _searchLabels = [
      for (final option in widget.options) option.label.toLowerCase(),
    ];
    _updateFiltered();
  }

  void _updateFiltered() {
    _filtered = _query.isEmpty
        ? widget.options
        : [
            for (var index = 0; index < widget.options.length; index++)
              if (_searchLabels[index].contains(_query)) widget.options[index],
          ];
    _filteredHeights = null;
  }

  List<double> _heightsFor(BuildContext context, double width) {
    final environment = (
      width: width,
      direction: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
      labelStyle: _selectTextStyle(context),
      selectedStyle: _selectTextStyle(context, emphasized: true),
      hintStyle: _selectTextStyle(context, fontSize: 12, secondary: true),
    );
    // 键盘动画只改变可用高度，不改变文字排版；搜索也复用同一选项的精确行高。
    // 宽度、字体、缩放、语言或选中样式变化时才重新测量，保留长标签的真实高度。
    if (_measureEnvironment != environment ||
        _measuredSelection != widget.selected) {
      _measureEnvironment = environment;
      _measuredSelection = widget.selected;
      _optionHeights.clear();
      _filteredHeights = null;
    }
    return _filteredHeights ??= [
      for (final option in _filtered)
        _optionHeights.putIfAbsent(
          option,
          () => _optionHeight(
            context,
            option,
            width,
            selected: option.value == widget.selected,
          ),
        ),
    ];
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _filter(String value) {
    final query = value.trim().toLowerCase();
    if (_query == query) return;
    setState(() {
      _query = query;
      _updateFiltered();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Widget _header(BuildContext context) {
    final palette = AppPalette.of(context);
    return KeyedSubtree(
      key: _headerKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: _selectTextStyle(
                    context,
                    fontSize: 17,
                    emphasized: true,
                  ),
                  textHeightBehavior: _selectTextHeightBehavior,
                ),
              ),
              IconButton(
                tooltip: '关闭',
                constraints: const BoxConstraints.tightFor(
                  width: _selectMinHeight,
                  height: _selectMinHeight,
                ),
                padding: EdgeInsets.zero,
                onPressed: () => Navigator.pop(context),
                icon: Icon(Icons.close, color: palette.labelText),
              ),
            ],
          ),
          if (widget.searchable) ...[
            const SizedBox(height: 4),
            TextField(
              controller: _search,
              onChanged: _filter,
              style: _selectTextStyle(context, fontSize: 16),
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索${widget.title}',
                hintStyle: _selectTextStyle(
                  context,
                  fontSize: 16,
                  secondary: true,
                ),
                prefixIcon: Icon(Icons.search, color: palette.labelText),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: _selectMinHeight,
                  minHeight: _selectMinHeight,
                ),
                suffixIconConstraints: const BoxConstraints(
                  minWidth: _selectMinHeight,
                  minHeight: _selectMinHeight,
                ),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空搜索',
                        constraints: const BoxConstraints.tightFor(
                          width: _selectMinHeight,
                          height: _selectMinHeight,
                        ),
                        padding: EdgeInsets.zero,
                        onPressed: () {
                          _search.clear();
                          _filter('');
                        },
                        icon: const Icon(Icons.close),
                      ),
                filled: true,
                fillColor: palette.pageBg,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: palette.divider),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: palette.accent, width: 2),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final media = MediaQuery.of(context);
    final filtered = _filtered;
    final maxHeight = math.max(
      0.0,
      (media.size.height - media.viewInsets.bottom - media.padding.top) * .65,
    );
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final titleHeight = _selectTextHeight(
                  context,
                  widget.title,
                  _selectTextStyle(context, fontSize: 17, emphasized: true),
                  width - _selectMinHeight,
                );
                final headerHeight =
                    math.max(_selectMinHeight, titleHeight) +
                    (widget.searchable
                        ? 12 +
                              math.max(
                                _selectMinHeight,
                                media.textScaler.scale(16) * 1.4 + 20,
                              )
                        : 0);
                // 头部以外至少留两行空间；横屏键盘与大字时改为整面板滚动。
                final compact =
                    constraints.maxHeight < headerHeight + _selectMinHeight * 2;
                final header = _header(context);
                final heights = _heightsFor(context, width);
                if (!_positioned) {
                  _positioned = true;
                  final selectedIndex = filtered.indexWhere(
                    (option) => option.value == widget.selected,
                  );
                  final offset = heights
                      .take(math.max(0, selectedIndex))
                      .fold(0.0, (sum, height) => sum + height);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && _scroll.hasClients) {
                      final headerBox = _headerKey.currentContext
                          ?.findRenderObject();
                      final headerOffset =
                          compact && selectedIndex > 0 && headerBox is RenderBox
                          ? headerBox.size.height
                          : 0.0;
                      _scroll.jumpTo(
                        (offset + headerOffset).clamp(
                          0,
                          _scroll.position.maxScrollExtent,
                        ),
                      );
                    }
                  });
                }
                final list = Scrollbar(
                  controller: _scroll,
                  child: CustomScrollView(
                    controller: _scroll,
                    shrinkWrap: true,
                    slivers: [
                      if (compact) SliverToBoxAdapter(child: header),
                      if (filtered.isEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Center(
                              child: Semantics(
                                liveRegion: true,
                                child: Text(
                                  _query.isEmpty ? '暂无可选项' : '没有匹配的选项',
                                  style: _selectTextStyle(
                                    context,
                                    secondary: true,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        )
                      else
                        SliverVariedExtentList.builder(
                          itemCount: filtered.length,
                          itemExtentBuilder: (index, dimensions) =>
                              heights[index],
                          itemBuilder: (context, index) {
                            final option = filtered[index];
                            return MergeSemantics(
                              child: Semantics(
                                selected: option.value == widget.selected,
                                child: TextButton(
                                  onPressed: option.enabled
                                      ? () => Navigator.pop(context, option)
                                      : null,
                                  style: _optionStyle(
                                    palette,
                                    selected: option.value == widget.selected,
                                  ),
                                  child: _OptionContent(
                                    label: option.label,
                                    hint: option.hint,
                                    selected: option.value == widget.selected,
                                    enabled: option.enabled,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                );
                return compact
                    ? list
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          header,
                          Flexible(child: list),
                        ],
                      );
              },
            ),
          ),
        ),
      ),
    );
  }
}

ButtonStyle _optionStyle(AppPalette palette, {required bool selected}) =>
    TextButton.styleFrom(
      minimumSize: const Size(0, _selectMinHeight),
      padding: _selectOptionPadding,
      foregroundColor: palette.titleText,
      disabledForegroundColor: palette.labelText,
      backgroundColor: selected
          ? Color.alphaBlend(
              palette.accent.withValues(alpha: .1),
              palette.surface,
            )
          : Colors.transparent,
      overlayColor: palette.accent.withValues(alpha: .1),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      alignment: AlignmentDirectional.centerStart,
    );

const _selectTextHeightBehavior = TextHeightBehavior(
  leadingDistribution: TextLeadingDistribution.even,
);

// 不继承按钮行高；测量和绘制共用字号、字距、系统粗体与字体设置。
TextStyle _selectTextStyle(
  BuildContext context, {
  double fontSize = 14,
  bool emphasized = false,
  bool secondary = false,
}) {
  final palette = AppPalette.of(context);
  return (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(
    inherit: false,
    fontSize: fontSize,
    fontWeight: MediaQuery.boldTextOf(context)
        ? FontWeight.w700
        : emphasized
        ? FontWeight.w600
        : FontWeight.w400,
    height: 1.4,
    letterSpacing: 0,
    textBaseline: TextBaseline.alphabetic,
    color: secondary ? palette.labelText : palette.titleText,
  );
}

double _selectTextHeight(
  BuildContext context,
  String text,
  TextStyle style,
  double width,
) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    textHeightBehavior: _selectTextHeightBehavior,
    locale: Localizations.maybeLocaleOf(context),
  )..layout(maxWidth: math.max(1, width));
  final height = painter.height.ceilToDouble();
  painter.dispose();
  return height;
}

double _optionHeight<T>(
  BuildContext context,
  AppSelectOption<T> option,
  double width, {
  bool selected = false,
}) {
  // 56 = 两侧留白 24 + 勾选图标 20 + 图文间距 12。
  return math.max(
    _selectMinHeight,
    _selectOptionPadding.vertical +
        _selectTextHeight(
          context,
          option.label,
          _selectTextStyle(context, emphasized: selected),
          width - 56,
        ) +
        (option.hint?.isNotEmpty == true
            ? 4 +
                  _selectTextHeight(
                    context,
                    option.hint!,
                    _selectTextStyle(context, fontSize: 12, secondary: true),
                    width - 56,
                  )
            : 0),
  );
}

class _OptionContent extends StatelessWidget {
  const _OptionContent({
    required this.label,
    required this.hint,
    required this.selected,
    required this.enabled,
  });

  final String label;
  final String? hint;
  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: _selectTextStyle(
                  context,
                  emphasized: selected,
                  secondary: !enabled,
                ),
                textHeightBehavior: _selectTextHeightBehavior,
              ),
              if (hint?.isNotEmpty == true) ...[
                const SizedBox(height: 4),
                Text(
                  hint!,
                  style: _selectTextStyle(
                    context,
                    fontSize: 12,
                    secondary: true,
                  ),
                  textHeightBehavior: _selectTextHeightBehavior,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        SizedBox.square(
          dimension: 20,
          child: selected
              ? Icon(Icons.check, size: 20, color: palette.accent)
              : null,
        ),
      ],
    );
  }
}
