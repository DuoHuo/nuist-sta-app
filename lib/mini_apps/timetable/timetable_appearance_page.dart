import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'timetable_color_picker.dart';
import 'timetable_colors.dart';
import 'timetable_controller.dart';
import 'timetable_models.dart';
import 'timetable_theme.dart';
import 'timetable_week_grid.dart';

/// spec-next-1020b：外观页——上半 ~48% 为本周真实课表缩略，下半为可滚动设置；
/// 设置改完上半即时变。周六/日、非本周、表头字号、节数时间等只在此页入口。
///
/// 预览复用 [WeekGrid]（含 `scheduleItemsForColumn` / [ScheduleEventCell]），
/// 与周视图一致；非本周考试双胶囊等由数据侧落地后自动出现。
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
          final headerSize = s.headerTextSize
              .clamp(kHeaderTextSizeMin, kHeaderTextSizeMax)
              .toDouble();
          final week = c.currentWeek
              .clamp(1, math.max(1, c.totalWeeks))
              .toInt();
          return Column(
            children: [
              Expanded(
                flex: 48,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    TimetableTheme.pagePaddingH,
                    8,
                    TimetableTheme.pagePaddingH,
                    0,
                  ),
                  child: Material(
                    key: const Key('tt_appearance_preview'),
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(
                      TimetableTheme.cardRadius,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: WeekGrid(
                      key: const Key('tt_appearance_preview_grid'),
                      week: week,
                      controller: c,
                      enableDrag: false,
                      previewMode: true,
                    ),
                  ),
                ),
              ),
              Expanded(
                flex: 52,
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    _ApGroup(
                      key: const Key('tt_appearance_group'),
                      title: '外观',
                      children: [
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
                        _ApSliderRow(
                          title: '表头文字大小',
                          valueLabel: '${headerSize.round()}',
                          valueKey: const Key(
                            'tt_settings_header_text_size_value',
                          ),
                          slider: Slider(
                            key: const Key('tt_settings_header_text_size'),
                            min: kHeaderTextSizeMin,
                            max: kHeaderTextSizeMax,
                            divisions: (kHeaderTextSizeMax - kHeaderTextSizeMin)
                                .round(),
                            value: headerSize,
                            activeColor: colors.accent,
                            label: '${headerSize.round()}',
                            onChanged: (v) {
                              final next = v.roundToDouble();
                              if (next == c.settings.headerTextSize) return;
                              update((x) => x.copyWith(headerTextSize: next));
                            },
                          ),
                        ),
                        _ApSwitchRow(
                          key: const Key('tt_settings_show_period_times'),
                          title: '节数栏显示时间',
                          value: s.showPeriodTimes,
                          onChanged: (v) =>
                              update((x) => x.copyWith(showPeriodTimes: v)),
                        ),
                        _ApSwitchRow(
                          key: const Key('tt_settings_saturday'),
                          title: '周六',
                          value: s.showSaturday,
                          onChanged: (v) =>
                              update((x) => x.copyWith(showSaturday: v)),
                        ),
                        _ApSwitchRow(
                          key: const Key('tt_settings_sunday'),
                          title: '周日',
                          value: s.showSunday,
                          onChanged: (v) =>
                              update((x) => x.copyWith(showSunday: v)),
                        ),
                        _ApSwitchRow(
                          key: const Key('tt_settings_non_current'),
                          title: '非本周课程',
                          value: s.showNonCurrentWeek,
                          onChanged: (v) =>
                              update((x) => x.copyWith(showNonCurrentWeek: v)),
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
                                  border: Border.all(color: colors.divider),
                                ),
                              ),
                              Icon(Icons.chevron_right, color: colors.hint),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
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

class _ApSwitchRow extends StatelessWidget {
  const _ApSwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return _ApRow(
      title: title,
      onTap: () => onChanged(!value),
      trailing: Switch(
        value: value,
        activeThumbColor: TimetableTheme.colorsOf(context).accent,
        onChanged: onChanged,
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
