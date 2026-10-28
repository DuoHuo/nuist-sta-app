import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'timetable_color_picker.dart';
import 'timetable_colors.dart';
import 'timetable_controller.dart';
import 'timetable_models.dart';
import 'timetable_theme.dart';
import 'timetable_settings_widgets.dart';
import 'timetable_week_grid.dart';

/// 课表外观：固定真实课表预览与独立滚动的四组设置，修改后即时刷新。
/// 短屏或大字号时预览默认收起；预览周独立于主课表的当前查看周。
class TimetableAppearancePage extends StatefulWidget {
  const TimetableAppearancePage({super.key, this.controller});

  final TimetableController? controller;

  static const int opacityMin = 30;
  static const int opacityMax = 100;
  static const int opacityStep = 10;

  static const cellTextColorLabels = {
    CellTextColorMode.auto: '自动',
    CellTextColorMode.white: '白',
    CellTextColorMode.black: '黑',
  };

  static const homeMaxLabels = {1: '1', 2: '2', 3: '3', 4: '4'};

  @override
  State<TimetableAppearancePage> createState() =>
      _TimetableAppearancePageState();
}

class _TimetableAppearancePageState extends State<TimetableAppearancePage> {
  late final TimetableController _c =
      widget.controller ?? TimetableController.instance;
  PageController? _pageController;
  late int _previewWeek;
  bool _previewExpanded = false;

  int get _totalWeeks => math.max(1, _c.totalWeeks);

  @override
  void initState() {
    super.initState();
    _previewWeek = _c.currentWeek.clamp(1, _totalWeeks).toInt();
    _pageController = PageController(initialPage: _previewWeek - 1);
    _c.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _c.removeListener(_onControllerChanged);
    _pageController?.dispose();
    super.dispose();
  }

  /// 总周数缩小时钳制预览周并 jump；设置变更由 ListenableBuilder 同帧刷新。
  void _onControllerChanged() {
    final total = _totalWeeks;
    final clamped = _previewWeek.clamp(1, total).toInt();
    if (clamped == _previewWeek) return;
    _previewWeek = clamped;
    final pc = _pageController;
    if (pc != null && pc.hasClients) {
      final target = clamped - 1;
      final page = pc.page?.round() ?? pc.initialPage;
      if (page != target) pc.jumpToPage(target);
    }
  }

  void _onPreviewPageChanged(int index) {
    final week = (index + 1).clamp(1, _totalWeeks).toInt();
    if (week == _previewWeek) return;
    setState(() => _previewWeek = week);
  }

  void _update(TimetableSettings Function(TimetableSettings s) change) =>
      _c.updateSettings(change(_c.settings));

  Future<void> _pickExamColor(BuildContext context) async {
    final pick = await showTimetableColorPicker(
      context,
      current: Color(_c.settings.examColor),
      defaultColor: const Color(kDefaultExamColor),
      previewTitle: '考试',
      opacity: _c.settings.cellOpacity,
      textColorMode: _c.settings.cellTextColor,
      showReset: _c.settings.examColor != kDefaultExamColor,
      forExam: true,
      title: '考试颜色',
    );
    if (pick == null) return;
    final argb = pick.reset
        ? kDefaultExamColor
        : (pick.color!.toARGB32() | 0xFF000000);
    if (argb == _c.settings.examColor) return;
    await _c.updateSettings(_c.settings.copyWith(examColor: argb));
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final pc = _pageController;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: TimetableTheme.colorsOf(context).pageBg,
      appBar: AppBar(title: const Text('外观')),
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final s = c.settings;
          final colors = TimetableTheme.colorsOf(context);
          final opacity = s.cellOpacity.clamp(
            TimetableAppearancePage.opacityMin,
            TimetableAppearancePage.opacityMax,
          );
          final headerSize = s.headerTextSize
              .clamp(kHeaderTextSizeMin, kHeaderTextSizeMax)
              .toDouble();
          final total = _totalWeeks;
          return SafeArea(
            top: false,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final textScale =
                    MediaQuery.textScalerOf(context).scale(14) / 14;
                final previewHeight = math.min(
                  MediaQuery.sizeOf(context).height * 0.38,
                  constraints.maxHeight * 0.45,
                );
                final collapsible =
                    previewHeight < 160 ||
                    constraints.maxHeight < 560 ||
                    textScale >= 1.5;
                final expanded = !collapsible || _previewExpanded;
                return Column(
                  children: [
                    if (collapsible)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                        child: Material(
                          color: colors.surface,
                          borderRadius: BorderRadius.circular(
                            TimetableTheme.cardRadius,
                          ),
                          child: InkWell(
                            key: const Key(
                              'tt_appearance_preview_collapse_bar',
                            ),
                            borderRadius: BorderRadius.circular(
                              TimetableTheme.cardRadius,
                            ),
                            onTap: () => setState(
                              () => _previewExpanded = !_previewExpanded,
                            ),
                            child: SizedBox(
                              height: 44,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '预览 · 第 $_previewWeek 周',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TimetableTheme.bodyStyle(
                                          color: colors.titleText,
                                        ),
                                      ),
                                    ),
                                    Icon(
                                      expanded
                                          ? Icons.expand_less
                                          : Icons.expand_more,
                                      color: colors.hint,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (expanded)
                      SizedBox(
                        key: const Key('tt_appearance_preview_expanded'),
                        height: previewHeight,
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
                            child: pc == null
                                ? const SizedBox.shrink()
                                : PageView.builder(
                                    key: const Key(
                                      'tt_appearance_preview_pager',
                                    ),
                                    controller: pc,
                                    itemCount: total,
                                    onPageChanged: _onPreviewPageChanged,
                                    itemBuilder: (context, index) {
                                      final week = index + 1;
                                      return MediaQuery(
                                        data: MediaQuery.of(context).copyWith(
                                          textScaler: MediaQuery.textScalerOf(
                                            context,
                                          ).clamp(maxScaleFactor: 1.3),
                                        ),
                                        child: WeekGrid(
                                          key: week == _previewWeek
                                              ? const Key(
                                                  'tt_appearance_preview_grid',
                                                )
                                              : ValueKey(
                                                  'tt_appearance_preview_grid_$week',
                                                ),
                                          week: week,
                                          controller: c,
                                          enableDrag: false,
                                          previewMode: true,
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ),
                      ),
                    // 设置区在预览/折叠条分界线处裁切，上滚时不与预览叠层。
                    Expanded(
                      child: ClipRect(
                        key: const Key('tt_appearance_settings_clip'),
                        child: ListView(
                          key: const Key('tt_appearance_settings_list'),
                          padding: const EdgeInsets.only(bottom: 24),
                          children: [
                            TimetableSettingsGroup(
                              key: const Key('tt_appearance_group'),
                              title: '外观',
                              children: [
                                TimetableSettingsChoiceRow<CellTextColorMode>(
                                  key: const Key(
                                    'tt_appearance_text_color_row',
                                  ),
                                  title: '文字颜色',
                                  segmentsKey: const Key(
                                    'tt_settings_cell_text_color',
                                  ),
                                  options: TimetableAppearancePage
                                      .cellTextColorLabels,
                                  selected: s.cellTextColor,
                                  onSelected: (v) => _update(
                                    (x) => x.copyWith(cellTextColor: v),
                                  ),
                                ),
                                _ApSliderRow(
                                  title: '不透明度',
                                  valueLabel: '$opacity%',
                                  valueKey: const Key(
                                    'tt_settings_opacity_value',
                                  ),
                                  slider: Slider(
                                    key: const Key('tt_settings_opacity'),
                                    min: TimetableAppearancePage.opacityMin
                                        .toDouble(),
                                    max: TimetableAppearancePage.opacityMax
                                        .toDouble(),
                                    divisions:
                                        (TimetableAppearancePage.opacityMax -
                                            TimetableAppearancePage
                                                .opacityMin) ~/
                                        TimetableAppearancePage.opacityStep,
                                    value: opacity.toDouble(),
                                    activeColor: colors.accent,
                                    label: '$opacity%',
                                    onChanged: (v) {
                                      final next = v.round();
                                      if (next == c.settings.cellOpacity) {
                                        return;
                                      }
                                      _update(
                                        (x) => x.copyWith(cellOpacity: next),
                                      );
                                    },
                                  ),
                                ),
                                _ApSliderRow(
                                  title: '表头字号',
                                  valueLabel: '${headerSize.round()}',
                                  valueKey: const Key(
                                    'tt_settings_header_text_size_value',
                                  ),
                                  slider: Slider(
                                    key: const Key(
                                      'tt_settings_header_text_size',
                                    ),
                                    min: kHeaderTextSizeMin,
                                    max: kHeaderTextSizeMax,
                                    divisions:
                                        (kHeaderTextSizeMax -
                                                kHeaderTextSizeMin)
                                            .round(),
                                    value: headerSize,
                                    activeColor: colors.accent,
                                    label: '${headerSize.round()}',
                                    onChanged: (v) {
                                      final next = v.roundToDouble();
                                      if (next == c.settings.headerTextSize) {
                                        return;
                                      }
                                      _update(
                                        (x) => x.copyWith(headerTextSize: next),
                                      );
                                    },
                                  ),
                                ),
                                TimetableSettingsSwitchRow(
                                  key: const Key(
                                    'tt_settings_show_period_times',
                                  ),
                                  title: '节次显示时间',
                                  value: s.showPeriodTimes,
                                  onChanged: (v) => _update(
                                    (x) => x.copyWith(showPeriodTimes: v),
                                  ),
                                ),
                                _ApSliderRow(
                                  title: '格子高度',
                                  valueLabel: '${s.periodHeight.round()}',
                                  valueKey: const Key(
                                    'tt_settings_period_height_value',
                                  ),
                                  slider: Slider(
                                    key: const Key('tt_settings_period_height'),
                                    min: TimetableTheme.periodHeightMin,
                                    max: TimetableTheme.periodHeightMax,
                                    divisions:
                                        ((TimetableTheme.periodHeightMax -
                                                    TimetableTheme
                                                        .periodHeightMin) /
                                                2)
                                            .round(),
                                    value: s.periodHeight.clamp(
                                      TimetableTheme.periodHeightMin,
                                      TimetableTheme.periodHeightMax,
                                    ),
                                    activeColor: colors.accent,
                                    onChanged: (v) => _update(
                                      (x) => x.copyWith(periodHeight: v),
                                    ),
                                  ),
                                ),
                                // 与「不透明度」等行同级左对齐，勿嵌进滑杆行。
                                TimetableSettingsChoiceRow<CellFontScale>(
                                  key: const Key(
                                    'tt_appearance_font_scale_row',
                                  ),
                                  title: '格子字号',
                                  segmentsKey: const Key(
                                    'tt_settings_font_scale',
                                  ),
                                  options: const {
                                    CellFontScale.small: '小',
                                    CellFontScale.standard: '标准',
                                    CellFontScale.large: '大',
                                  },
                                  selected: s.fontScale,
                                  onSelected: (v) =>
                                      _update((x) => x.copyWith(fontScale: v)),
                                ),
                              ],
                            ),
                            TimetableSettingsGroup(
                              key: const Key('tt_appearance_group_week'),
                              title: '周视图',
                              children: [
                                TimetableSettingsRow(
                                  key: const Key('tt_settings_week_start'),
                                  title: '一周起始',
                                  value: s.weekStartsOnMonday ? '周一' : '周日',
                                  showChevron: true,
                                  onTap: () async {
                                    final monday = await showDialog<bool>(
                                      context: context,
                                      builder: (context) => SimpleDialog(
                                        title: const Text('一周起始'),
                                        children: [
                                          for (final option in const {
                                            true: '周一',
                                            false: '周日',
                                          }.entries)
                                            SimpleDialogOption(
                                              onPressed: () => Navigator.pop(
                                                context,
                                                option.key,
                                              ),
                                              child: Text(option.value),
                                            ),
                                        ],
                                      ),
                                    );
                                    if (monday != null) {
                                      _update(
                                        (x) => x.copyWith(
                                          weekStartsOnMonday: monday,
                                        ),
                                      );
                                    }
                                  },
                                ),
                                TimetableSettingsSwitchRow(
                                  key: const Key('tt_settings_saturday'),
                                  title: '显示周六',
                                  value: s.showSaturday,
                                  onChanged: (v) => _update(
                                    (x) => x.copyWith(showSaturday: v),
                                  ),
                                ),
                                TimetableSettingsSwitchRow(
                                  key: const Key('tt_settings_sunday'),
                                  title: '显示周日',
                                  value: s.showSunday,
                                  onChanged: (v) =>
                                      _update((x) => x.copyWith(showSunday: v)),
                                ),
                              ],
                            ),
                            TimetableSettingsGroup(
                              key: const Key('tt_settings_group_exam'),
                              title: '考试',
                              children: [
                                TimetableSettingsSwitchRow(
                                  key: const Key('tt_settings_show_exams'),
                                  title: '显示考试',
                                  value: s.showExams,
                                  onChanged: (v) =>
                                      _update((x) => x.copyWith(showExams: v)),
                                ),
                                TimetableSettingsRow(
                                  key: const Key('tt_settings_exam_color'),
                                  title: '考试颜色',
                                  onTap: () => _pickExamColor(context),
                                  showChevron: true,
                                  trailing: ExcludeSemantics(
                                    child: Container(
                                      key: const Key(
                                        'tt_settings_exam_color_swatch',
                                      ),
                                      width: 18,
                                      height: 18,
                                      decoration: BoxDecoration(
                                        color: TimetableTheme.examCellBg(
                                          Color(s.examColor),
                                          dark: colors.isDark,
                                        ),
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: colors.divider,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            TimetableSettingsGroup(
                              key: const Key('tt_appearance_group_cell_info'),
                              title: '格子信息',
                              children: [
                                TimetableSettingsSwitchRow(
                                  key: const Key('tt_settings_show_location'),
                                  title: '显示地点',
                                  value: s.showLocation,
                                  onChanged: (v) => _update(
                                    (x) => x.copyWith(showLocation: v),
                                  ),
                                ),
                                TimetableSettingsSwitchRow(
                                  key: const Key('tt_settings_show_teacher'),
                                  title: '显示教师',
                                  value: s.showTeacher,
                                  onChanged: (v) => _update(
                                    (x) => x.copyWith(showTeacher: v),
                                  ),
                                ),
                                TimetableSettingsSwitchRow(
                                  key: const Key('tt_settings_non_current'),
                                  title: '显示非本周课',
                                  value: s.showNonCurrentWeek,
                                  onChanged: (v) => _update(
                                    (x) => x.copyWith(showNonCurrentWeek: v),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          );
        },
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
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TimetableSettingsRow.textStyle(context),
                ),
              ),
              Text(
                valueLabel,
                key: valueKey,
                style: TimetableSettingsRow.textStyle(context)
                    .copyWith(color: colors.labelText),
              ),
            ],
          ),
          slider,
        ],
      ),
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
              TimetableSettingsGroup(
                title: '方案',
                children: [
                  for (final scheme in CoursePaletteScheme.values)
                    TimetableSettingsRow(
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
