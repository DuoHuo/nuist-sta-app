import 'package:flutter/material.dart';

import 'timetable_color_picker.dart';
import 'timetable_colors.dart';
import 'timetable_controller.dart';
import 'timetable_models.dart';
import 'timetable_theme.dart';

/// spec-next-1020 item 8：外观独立页——顶部预览格 + 配色/字色/不透明度/
/// 今日最多显示/考试颜色。
class TimetableAppearancePage extends StatelessWidget {
  const TimetableAppearancePage({super.key, this.controller});

  final TimetableController? controller;

  static const int opacityMin = 30;
  static const int opacityMax = 100;
  static const int opacityStep = 10;

  static const cellTextColorLabels = {
    CellTextColorMode.auto: '自动',
    CellTextColorMode.white: '白字',
    CellTextColorMode.black: '黑字',
  };

  static const homeMaxLabels = {1: '1', 2: '2', 3: '3', 4: '4'};

  @override
  Widget build(BuildContext context) {
    final c = controller ?? TimetableController.instance;
    void update(TimetableSettings Function(TimetableSettings s) change) =>
        c.updateSettings(change(c.settings));

    return Scaffold(
      backgroundColor: TimetableTheme.colorsOf(context).pageBg,
      appBar: AppBar(title: const Text('外观')),
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final s = c.settings;
          final colors = TimetableTheme.colorsOf(context);
          final opacity = s.cellOpacity.clamp(opacityMin, opacityMax);
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  TimetableTheme.pagePaddingH,
                  12,
                  TimetableTheme.pagePaddingH,
                  0,
                ),
                child: _AppearancePreview(
                  key: const Key('tt_appearance_preview'),
                  settings: s,
                  colors: colors,
                ),
              ),
              _ApGroup(
                key: const Key('tt_appearance_group'),
                title: '外观',
                children: [
                  // 暂时隐藏配色方案 A/B/C 入口；storage/enum/读路径保留。
                  _ApRow(
                    title: '文字颜色',
                    trailing: _ApSegments<CellTextColorMode>(
                      key: const Key('tt_settings_cell_text_color'),
                      options: cellTextColorLabels,
                      selected: s.cellTextColor,
                      onSelected: (v) =>
                          update((x) => x.copyWith(cellTextColor: v)),
                    ),
                  ),
                  _ApSliderRow(
                    title: '不透明度',
                    valueLabel: '$opacity%',
                    valueKey: const Key('tt_settings_opacity_value'),
                    slider: Slider(
                      key: const Key('tt_settings_opacity'),
                      min: opacityMin.toDouble(),
                      max: opacityMax.toDouble(),
                      divisions: (opacityMax - opacityMin) ~/ opacityStep,
                      value: opacity.toDouble(),
                      activeColor: colors.accent,
                      label: '$opacity%',
                      onChanged: (v) {
                        final next = v.round();
                        if (next == c.settings.cellOpacity) return;
                        update((x) => x.copyWith(cellOpacity: next));
                      },
                    ),
                  ),
                  _ApRow(
                    key: const Key('tt_settings_home_max_items'),
                    title: '今日课表最多显示',
                    trailing: _ApSegments<int>(
                      key: const Key('tt_settings_home_max_segments'),
                      options: homeMaxLabels,
                      selected: s.homeMaxItems,
                      onSelected: (v) =>
                          update((x) => x.copyWith(homeMaxItems: v)),
                    ),
                  ),
                  _ApRow(
                    key: const Key('tt_settings_exam_color'),
                    title: '考试颜色',
                    onTap: () => _pickExamColor(context, c),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          key: const Key('tt_settings_exam_color_swatch'),
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            color: TimetableTheme.examCellBg(
                              Color(s.examColor),
                              dark: colors.isDark,
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        Icon(Icons.chevron_right, color: colors.hint),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _pickExamColor(
    BuildContext context,
    TimetableController c,
  ) async {
    final pick = await showTimetableColorPicker(
      context,
      current: Color(c.settings.examColor),
      presets: TimetableTheme.examColorOptions,
      showReset: c.settings.examColor != kDefaultExamColor,
      forExam: true,
      title: '考试颜色',
    );
    if (pick == null) return;
    final argb = pick.reset
        ? kDefaultExamColor
        : (pick.color!.toARGB32() | 0xFF000000);
    if (argb == c.settings.examColor) return;
    await c.updateSettings(c.settings.copyWith(examColor: argb));
  }
}

/// 页顶固定预览：模拟课程格，随字色 / 不透明度 / 明暗即时变。
class _AppearancePreview extends StatelessWidget {
  const _AppearancePreview({
    super.key,
    required this.settings,
    required this.colors,
  });

  final TimetableSettings settings;
  final TimetableColors colors;

  @override
  Widget build(BuildContext context) {
    // item 3：预览格与未自选课一致，走色相步进自动色板（非 A/B/C）。
    final pair = TimetableTheme.autoCoursePair(0, dark: colors.isDark);
    final bg = TimetableTheme.blendCellBg(
      pair.bg,
      settings.cellOpacity,
      dark: colors.isDark,
    );
    final fg = TimetableTheme.cellTextFor(pair.fg, settings.cellTextColor);
    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(TimetableTheme.cardRadius),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '预览',
              style: TimetableTheme.captionStyle(color: colors.labelText),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                key: const Key('tt_appearance_preview_cell'),
                width: 96,
                height: 72,
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(settings.cellRadius),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '示例课程',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12 * settings.fontScale.factor,
                        fontWeight: FontWeight.w600,
                        height: 1.15,
                        color: fg,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '@示例地点',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10 * settings.fontScale.factor,
                        height: 1.1,
                        color: fg,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- 本页私有行组件（与设置页视觉一致，避免循环依赖导出私有类）----

class _ApGroup extends StatelessWidget {
  const _ApGroup({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        TimetableTheme.pagePaddingH,
        12,
        TimetableTheme.pagePaddingH,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Material(
            color: TimetableTheme.colorsOf(context).surface,
            borderRadius: BorderRadius.circular(TimetableTheme.cardRadius),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}

class _ApRow extends StatelessWidget {
  const _ApRow({super.key, required this.title, this.trailing, this.onTap});
  final String title;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: TimetableTheme.listRowHeight,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TimetableTheme.bodyStyle(color: colors.titleText),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}

class _ApSliderRow extends StatelessWidget {
  const _ApSliderRow({
    required this.title,
    required this.valueLabel,
    required this.valueKey,
    required this.slider,
  });
  final String title;
  final String valueLabel;
  final Key valueKey;
  final Widget slider;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TimetableTheme.bodyStyle(color: colors.titleText),
                ),
              ),
              Text(
                valueLabel,
                key: valueKey,
                style: TimetableTheme.bodyStyle(color: colors.hint),
              ),
            ],
          ),
          slider,
        ],
      ),
    );
  }
}

class _ApSegments<T> extends StatelessWidget {
  const _ApSegments({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
  });
  final Map<T, String> options;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return Wrap(
      spacing: 6,
      children: [
        for (final e in options.entries)
          ChoiceChip(
            label: Text(e.value),
            selected: e.key == selected,
            onSelected: (_) => onSelected(e.key),
            selectedColor: colors.accent.withValues(alpha: 0.18),
            labelStyle: TextStyle(
              color: e.key == selected ? colors.accent : colors.titleText,
              fontSize: 13,
            ),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
      ],
    );
  }
}

/// 配色方案二级页（A/B/C）。暂时从外观页入口隐藏；类与 storage 保留以便恢复。
class TimetablePalettePage extends StatelessWidget {
  const TimetablePalettePage({super.key, this.controller});

  final TimetableController? controller;

  @override
  Widget build(BuildContext context) {
    final c = controller ?? TimetableController.instance;
    return Scaffold(
      backgroundColor: TimetableTheme.colorsOf(context).pageBg,
      appBar: AppBar(title: const Text('配色')),
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final current = coursePaletteSchemeOf(c.settings.paletteScheme);
          final colors = TimetableTheme.colorsOf(context);
          return ListView(
            children: [
              _ApGroup(
                title: '方案',
                children: [
                  for (final scheme in CoursePaletteScheme.values)
                    _ApRow(
                      key: Key('tt_palette_${coursePaletteSchemeKey(scheme)}'),
                      title: coursePaletteSchemeLabel(scheme),
                      onTap: () {
                        final key = coursePaletteSchemeKey(scheme);
                        if (c.settings.paletteScheme == key) return;
                        c.updateSettings(
                          c.settings.copyWith(paletteScheme: key),
                        );
                      },
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final pair in TimetableTheme.pairsOf(
                            scheme,
                          ).take(8))
                            Container(
                              width: 14,
                              height: 14,
                              margin: const EdgeInsets.only(left: 3),
                              decoration: BoxDecoration(
                                color: pair.bg,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          const SizedBox(width: 8),
                          Icon(
                            scheme == current
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            color: scheme == current
                                ? colors.accent
                                : colors.hint,
                            size: 20,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
