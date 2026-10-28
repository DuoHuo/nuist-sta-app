import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'timetable_theme.dart';

/// 课表设置与外观页共用的分组，标题和行文字使用同一条左边线。
class TimetableSettingsGroup extends StatelessWidget {
  const TimetableSettingsGroup({super.key, this.title, required this.children});

  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Semantics(
              header: true,
              child: Text(
                title!,
                style:
                    TimetableTheme.bodyStyle(
                      color: TimetableTheme.colorsOf(context).labelText,
                    ).copyWith(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      height: 1.4,
                    ),
              ),
            ),
          ),
        Material(
          color: TimetableTheme.colorsOf(context).surface,
          borderRadius: BorderRadius.circular(TimetableTheme.cardRadius),
          clipBehavior: Clip.antiAlias,
          child: _SettingsGroupScope(
            title: title ?? '',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ],
    ),
  );
}

class _SettingsGroupScope extends InheritedWidget {
  const _SettingsGroupScope({required this.title, required super.child});
  final String title;

  static String labelFor(BuildContext context, String row) {
    final group = context
        .dependOnInheritedWidgetOfExactType<_SettingsGroupScope>()
        ?.title;
    return group == null || group.isEmpty ? row : '$group，$row';
  }

  @override
  bool updateShouldNotify(_SettingsGroupScope oldWidget) =>
      title != oldWidget.title;
}

/// 普通设置行：最小高度 52dp，值、开关和箭头始终留在右侧。
class TimetableSettingsRow extends StatelessWidget {
  const TimetableSettingsRow({
    super.key,
    required this.title,
    this.trailing,
    this.onTap,
    this.enabled = true,
    this.showChevron = false,
    this.value,
    this.titleColor,
  });

  final String title;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;
  final bool showChevron;
  final String? value;
  final Color? titleColor;

  /// 同一主题下标题、值和选择项统一行距。
  static TextStyle textStyle(BuildContext context) => TimetableTheme.bodyStyle(
    color: TimetableTheme.colorsOf(context).titleText,
  ).copyWith(height: 1.4);

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final label = _SettingsGroupScope.labelFor(context, title);
    final row = InkWell(
      onTap: enabled ? onTap : null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: LayoutBuilder(
            builder: (context, constraints) {
              double? balancedWidth;
              // 只在自然换行留下单字时均分，其他标题保留自然断行。
              if (trailing == null &&
                  value != null &&
                  title.runes.every(
                    (rune) => rune >= 0x4E00 && rune <= 0x9FFF,
                  )) {
                final style = textStyle(context);
                final available =
                    constraints.maxWidth -
                    TimetableSettingsSegments.measure(
                      context,
                      value!,
                      style,
                    ).width -
                    (showChevron ? 24 : 0) -
                    8;
                final fullWidth = TimetableSettingsSegments.measure(
                  context,
                  title,
                  style,
                ).width;
                if (available > 0 && fullWidth > available) {
                  final count = title.runes.length;
                  final perLine = (available / (fullWidth / count)).floor();
                  if (perLine > 0 && count % perLine == 1) {
                    final lines = (fullWidth / available).ceil();
                    balancedWidth = math.min(
                      available,
                      fullWidth / count * (count / lines).ceil() + 1,
                    );
                  }
                }
              }
              final titleText = Text(
                title,
                semanticsLabel: value == null ? label : '$label，$value',
                style: textStyle(context)
                    .copyWith(color: titleColor ?? colors.titleText),
              );
              return Row(
                children: [
                  Expanded(
                    child: balancedWidth == null
                        ? titleText
                        : Align(
                            alignment: Alignment.centerLeft,
                            child: SizedBox(
                              width: balancedWidth,
                              child: titleText,
                            ),
                          ),
                  ),
                  if (trailing != null || value != null)
                    const SizedBox(width: 8),
                  if (trailing != null)
                    DefaultTextStyle.merge(
                      style: textStyle(context)
                          .copyWith(color: colors.labelText),
                      child: trailing!,
                    )
                  else if (value != null)
                    ExcludeSemantics(
                      child: Text(
                        value!,
                        style: textStyle(context)
                            .copyWith(color: colors.labelText),
                      ),
                    ),
                  if (showChevron) ...[
                    const SizedBox(width: 4),
                    ExcludeSemantics(
                      child: Icon(
                        Icons.chevron_right,
                        size: 20,
                        color: colors.chevron,
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
    final semanticRow = onTap == null
        ? Semantics(container: true, child: row)
        : MergeSemantics(child: row);
    return Semantics(
      enabled: enabled,
      child: enabled
          ? semanticRow
          : IgnorePointer(child: Opacity(opacity: 0.38, child: semanticRow)),
    );
  }
}

/// 全页共用的开关行，避免原生列表与自定义行的留白差异。
class TimetableSettingsSwitchRow extends StatelessWidget {
  const TimetableSettingsSwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => TimetableSettingsRow(
    title: title,
    onTap: () => onChanged(!value),
    trailing: Switch(
      value: value,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      activeThumbColor: TimetableTheme.colorsOf(context).accent,
      onChanged: onChanged,
    ),
  );
}

/// 连续分段选择：可见底板为 32dp，单项点击区域至少 48dp。
class TimetableSettingsSegments<T> extends StatelessWidget {
  const TimetableSettingsSegments({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
  });

  final Map<T, String> options;
  final T selected;
  final ValueChanged<T> onSelected;

  static TextStyle _style(BuildContext context) =>
      TimetableSettingsRow.textStyle(context).copyWith(fontSize: 13);

  /// 测量文字的实际尺寸，包含当前字体、方向和系统字号。
  static Size measure(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: DefaultTextStyle.of(context).style.merge(style),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final size = painter.size;
    painter.dispose();
    return size;
  }

  /// 同组按最长选项计算等宽按钮。
  static double itemWidth(BuildContext context, Iterable<String> labels) =>
      labels
          .fold<double>(
            48,
            (width, label) => math.max(
              width,
              measure(context, label, _style(context)).width + 16,
            ),
          )
          .ceilToDouble();

  /// 全组尺寸用于判断是否能够和标题同行。
  static double widthFor(BuildContext context, Iterable<String> labels) =>
      itemWidth(context, labels) * labels.length;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final width = itemWidth(context, options.values);
    final visualHeight = math.max(
      32.0,
      measure(context, options.values.first, _style(context)).height + 12,
    );
    final targetHeight = math.max(48.0, visualHeight + 4);
    return SizedBox(
      width: width * options.length,
      height: targetHeight,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: (targetHeight - visualHeight) / 2,
            height: visualHeight,
            child: Ink(
              key: const Key('tt_settings_segment_track'),
              decoration: BoxDecoration(
                color: colors.chipBg,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in options.entries)
                Semantics(
                  button: true,
                  selected: entry.key == selected,
                  inMutuallyExclusiveGroup: true,
                  child: SizedBox(
                    width: width,
                    height: targetHeight,
                    child: InkWell(
                      key: ValueKey('seg_${entry.value}'),
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        if (entry.key != selected) onSelected(entry.key);
                      },
                      child: Center(
                        child: SizedBox(
                          width: width - 4,
                          height: visualHeight - 4,
                          child: Ink(
                            decoration: BoxDecoration(
                              color: entry.key == selected
                                  ? colors.surface
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Center(
                              child: Text(
                                entry.value,
                                maxLines: 1,
                                style: _style(context).copyWith(
                                  color: entry.key == selected
                                      ? TimetableTheme.settingsAccentText(
                                          context,
                                        )
                                      : colors.labelText,
                                  fontWeight: entry.key == selected
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 能容纳时同行显示选择项；空间不足时改为带当前值的完整选择入口。
class TimetableSettingsChoiceRow<T> extends StatelessWidget {
  const TimetableSettingsChoiceRow({
    super.key,
    required this.title,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.enabled = true,
    this.unit,
    this.segmentsKey,
    this.showInlineOptions = true,
  });

  final String title;
  final Map<T, String> options;
  final T selected;
  final ValueChanged<T> onSelected;
  final bool enabled;
  final String? unit;
  final Key? segmentsKey;

  /// 为 false 时始终显示当前值，点击打开选择弹层。
  final bool showInlineOptions;

  Future<void> _pick(BuildContext context) async {
    final picked = await showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  title,
                  style: TimetableSettingsRow.textStyle(context),
                ),
              ),
              for (final option in options.entries)
                ListTile(
                  title: Text('${option.value}${unit == null ? '' : ' $unit'}'),
                  selected: option.key == selected,
                  trailing: option.key == selected
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.pop(context, option.key),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) onSelected(picked);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final style = TimetableSettingsRow.textStyle(context);
      final labelWidth = TimetableSettingsSegments.measure(
        context,
        title,
        style,
      ).width;
      final unitWidth = unit == null
          ? 0.0
          : 8 + TimetableSettingsSegments.measure(context, unit!, style).width;
      final controlsWidth =
          TimetableSettingsSegments.widthFor(context, options.values) +
          unitWidth;
      if (!showInlineOptions ||
          labelWidth + 8 + controlsWidth > constraints.maxWidth - 24) {
        return TimetableSettingsRow(
          title: title,
          enabled: enabled,
          value: '${options[selected]}${unit == null ? '' : ' $unit'}',
          showChevron: true,
          onTap: () => _pick(context),
        );
      }
      return TimetableSettingsRow(
        title: title,
        enabled: enabled,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TimetableSettingsSegments<T>(
              key: segmentsKey,
              options: options,
              selected: selected,
              onSelected: onSelected,
            ),
            if (unit != null) ...[const SizedBox(width: 8), Text(unit!)],
          ],
        ),
      );
    },
  );
}
