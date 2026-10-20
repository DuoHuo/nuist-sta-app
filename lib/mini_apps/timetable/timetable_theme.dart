import 'package:flutter/material.dart';

import '../../core/colors.dart';
import 'timetable_colors.dart';
import 'timetable_models.dart';

/// 实时课表 UI Token（对齐 design/timetable-spec.md v0.2）。
///
/// 颜色分两类：
/// - 页面 chrome（底色、面色、文字、分隔线、强调色、非本周格）随系统明暗切换，
///   调用方用 [TimetableTheme.colorsOf] 从 context 取 [TimetableColors]，不要自己写
///   `isDark ? xxxDark : xxx`。本类里的 `static const` 只是两套基准值，用于构造
///   [TimetableColors.light] / [TimetableColors.dark]，以及确实需要 `const` 的场景。
/// - 课程色板（[coursePalettes]、[courseColor]、[courseTextColor]、[blendCellBg]）
///   是用户在设置里选的固定色板，明暗两套主题取值相同，理由见 [blendCellBg]。
abstract final class TimetableTheme {
  // ---- 颜色（复用 AppColors + 课表专用 *）----
  // 每个 token 的浅色值与深色值并列，成对喂给 [TimetableColors]。
  static const Color pageBg = AppColors.pageBg;
  static const Color pageBgDark = Color(0xFF121316);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceDark = Color(0xFF1C1D21);
  static const Color titleText = AppColors.titleText;
  static const Color titleTextDark = Color(0xFFF2F3F5);
  static const Color labelText = AppColors.labelText;
  static const Color labelTextDark = Color(0xFFC8CBD2);
  static const Color hint = AppColors.hint;
  static const Color hintDark = Color(0xFF8A8F99);
  static const Color divider = AppColors.divider;
  static const Color dividerDark = Color(0xFF2A2C32);

  /// 列表行右侧箭头，与 App 其余列表一致（[AppPalette.chevron]）。
  static const Color chevron = AppColors.chevron;
  static const Color chevronDark = AppColorsDark.chevron;

  /// 未选中的筹码（周次 FilterChip）底色：浅色沿用 [AppColors.rowDivider]。
  static const Color chipBg = AppColors.rowDivider;
  static const Color chipBgDark = Color(0xFF2A2C31);
  static const Color accent = AppColors.accent;
  static const Color accentDark = Color(0xFF4DA3F5);
  static const Color success = AppColors.success;
  static const Color successDark = AppColorsDark.success;
  static const Color warning = AppColors.warning;
  static const Color warningDark = AppColorsDark.warning;
  static const Color danger = AppColors.danger;
  static const Color dangerDark = AppColorsDark.danger;

  /// 今天表头底色：accent @12%。
  static Color get accentSoft => accent.withValues(alpha: 0.12);

  static Color get accentSoftDark => accentDark.withValues(alpha: 0.18);

  /// 当前主题的课表 chrome 配色。取不到色板时退化成浅色（同 [AppPalette.of]）。
  static TimetableColors colorsOf(BuildContext context) =>
      colorsForBrightness(AppPalette.of(context).brightness);

  /// 按明暗取课表 chrome 配色。
  static TimetableColors colorsForBrightness(Brightness brightness) =>
      brightness == Brightness.dark
      ? TimetableColors.dark
      : TimetableColors.light;

  /// 非本周格（spec §13.8）：白底 + 1px #DADDE3 描边（随圆角）+ #6B7280 字。
  /// 不使用任何配色色值，A/B/C 三套都不会撞色；不透明度设置不作用于它。
  static const Color offWeekBg = Color(0xFFFFFFFF);
  static const Color offWeekBorder = Color(0xFFDADDE3);
  static const double offWeekBorderWidth = 1;

  /// 深色下的非本周格：纯白格子太刺眼，改用比 [surfaceDark] 略亮一档的中性面色，
  /// 同样不取任何配色色值，A/B/C 三套都不会撞色。
  static const Color offWeekBgDark = Color(0xFF22242A);
  static const Color offWeekBorderDark = Color(0xFF3A3D45);

  /// 非本周格文字（课名/地点/老师/代码）与「非本周」胶囊的描边和字（§13.8，
  /// 白底对比度约 4.8）。
  static const Color offWeekText = Color(0xFF6B7280);

  /// 深色下的非本周格文字：在 [offWeekBgDark] 上对比度约 6.1，不低于浅色的 4.8。
  static const Color offWeekTextDark = Color(0xFF9CA3AF);

  /// 旧名保留为别名（指向 §13.8 新 token，不再有独立灰色值）。
  static const Color inactiveCellBg = offWeekBg;
  static const Color inactiveCellFg = offWeekText;
  static const Color inactiveCellBgDark = Color(0xFF2A2C32);
  static const Color inactiveCellFgDark = Color(0xFF8A8F99);

  /// 各配色方案的 16 色（底色 + 文字色），下标即 0-based 色号。
  /// A 柔和（spec §13.5，默认）、B 马卡龙、C 莫兰迪（§13.7）。
  static const Map<CoursePaletteScheme, List<CourseColorPair>> coursePalettes =
      {
        CoursePaletteScheme.soft: _paletteSoft,
        CoursePaletteScheme.macaron: _paletteMacaron,
        CoursePaletteScheme.morandi: _paletteMorandi,
      };

  /// A 柔和（spec §13.5，默认方案）：浅色底配同色系深色字，不再用白字。
  static const List<CourseColorPair> _paletteSoft = [
    CourseColorPair(Color(0xFFDCE8FB), Color(0xFF1F4E99)), // 0
    CourseColorPair(Color(0xFFFCE3D6), Color(0xFF9A3E1C)), // 1
    CourseColorPair(Color(0xFFDCF1E2), Color(0xFF1E6B3A)), // 2
    CourseColorPair(Color(0xFFE9E0FA), Color(0xFF5B36A8)), // 3
    CourseColorPair(Color(0xFFFBEBC8), Color(0xFF7F4A00)), // 4
    CourseColorPair(Color(0xFFD5EFF0), Color(0xFF145F66)), // 5
    CourseColorPair(Color(0xFFFADDE8), Color(0xFF9C2857)), // 6
    CourseColorPair(Color(0xFFE3E7EF), Color(0xFF3F4A60)), // 7
    CourseColorPair(Color(0xFFDEE2FB), Color(0xFF3240A8)), // 8
    CourseColorPair(Color(0xFFE8F0D2), Color(0xFF4A6214)), // 9
    CourseColorPair(Color(0xFFFBDCDC), Color(0xFFA3282A)), // 10
    CourseColorPair(Color(0xFFD3EEE8), Color(0xFF17665A)), // 11
    CourseColorPair(Color(0xFFF6E3D3), Color(0xFF82431A)), // 12
    CourseColorPair(Color(0xFFF1DDF5), Color(0xFF7D2F8F)), // 13
    CourseColorPair(Color(0xFFFCDCEF), Color(0xFFA0236C)), // 14
    CourseColorPair(Color(0xFFD6EAF8), Color(0xFF1B5B87)), // 15
  ];

  /// B 马卡龙（§13.7）所有色号共用的文字色。
  static const Color _macaronText = Color(0xFF1F2430);

  /// C 莫兰迪（§13.7）所有色号共用的文字色。
  static const Color _morandiText = Color(0xFF2A2E35);

  /// B 马卡龙（spec §13.7）：浅底 + 共用深字 #1F2430。
  static const List<CourseColorPair> _paletteMacaron = [
    CourseColorPair(Color(0xFFA8D8FF), _macaronText), // 0
    CourseColorPair(Color(0xFFFFC2A8), _macaronText), // 1
    CourseColorPair(Color(0xFFB5E5B9), _macaronText), // 2
    CourseColorPair(Color(0xFFD5C2FF), _macaronText), // 3
    CourseColorPair(Color(0xFFFFE29A), _macaronText), // 4
    CourseColorPair(Color(0xFF9FE3DD), _macaronText), // 5
    CourseColorPair(Color(0xFFFFB8D1), _macaronText), // 6
    CourseColorPair(Color(0xFFC9D3E6), _macaronText), // 7
    CourseColorPair(Color(0xFFB3BEFF), _macaronText), // 8
    CourseColorPair(Color(0xFFD6EBA0), _macaronText), // 9
    CourseColorPair(Color(0xFFFFB3B3), _macaronText), // 10
    CourseColorPair(Color(0xFFA3E6CF), _macaronText), // 11
    CourseColorPair(Color(0xFFF2CFA8), _macaronText), // 12
    CourseColorPair(Color(0xFFE8BFF2), _macaronText), // 13
    CourseColorPair(Color(0xFFFFBDE6), _macaronText), // 14
    CourseColorPair(Color(0xFFAEE0F5), _macaronText), // 15
  ];

  /// C 莫兰迪（spec §13.7）：浅底 + 共用深字 #2A2E35。
  static const List<CourseColorPair> _paletteMorandi = [
    CourseColorPair(Color(0xFFB7C9D6), _morandiText), // 0
    CourseColorPair(Color(0xFFD8B9A8), _morandiText), // 1
    CourseColorPair(Color(0xFFB9C8B0), _morandiText), // 2
    CourseColorPair(Color(0xFFC6B8D0), _morandiText), // 3
    CourseColorPair(Color(0xFFD9CBA6), _morandiText), // 4
    CourseColorPair(Color(0xFFA9C6C1), _morandiText), // 5
    CourseColorPair(Color(0xFFD4AFB9), _morandiText), // 6
    CourseColorPair(Color(0xFFC2C2BA), _morandiText), // 7
    CourseColorPair(Color(0xFFB3B8D3), _morandiText), // 8
    CourseColorPair(Color(0xFFC8CDA6), _morandiText), // 9
    CourseColorPair(Color(0xFFD6ADA8), _morandiText), // 10
    CourseColorPair(Color(0xFFA8C4B4), _morandiText), // 11
    CourseColorPair(Color(0xFFD2BFA6), _morandiText), // 12
    CourseColorPair(Color(0xFFCDB4C9), _morandiText), // 13
    CourseColorPair(Color(0xFFD9B3C3), _morandiText), // 14
    CourseColorPair(Color(0xFFADC3D3), _morandiText), // 15
  ];

  /// 默认方案（不传 scheme 时用）。实际方案来自设置 `paletteScheme`，
  /// 调用方用 [coursePaletteSchemeOf] 转换后传给 [courseColor]/[courseTextColor]。
  static const CoursePaletteScheme currentScheme = kDefaultCoursePaletteScheme;

  /// [scheme] 方案的 16 个 (底色, 文字色)。
  static List<CourseColorPair> pairsOf(CoursePaletteScheme scheme) =>
      coursePalettes[scheme] ?? coursePalettes[kDefaultCoursePaletteScheme]!;

  /// 底色按不透明度 [opacity]（30–100）往页面底色 [pageBg] 混合（spec §13.4/§13.6），
  /// 结果不透明。文字、角标、冲突圆点不走这里。
  ///
  /// 浅色往浅色 [pageBg] 混合（「浅底 + 深字」，往浅色混只会拉大对比度）；
  /// 深色（[dark] 为 true，spec-next item 12）往 [darkCellMixBase] #121316 混合：
  /// 深色下格子是「深底浅字」（[coursePair]），往深色混同样只会拉大对比度。
  static Color blendCellBg(Color bg, int opacity, {bool dark = false}) {
    final t = (opacity.clamp(30, 100)) / 100.0;
    if (t >= 1) return bg;
    return Color.lerp(dark ? darkCellMixBase : pageBg, bg, t)!;
  }

  /// 深色下课程格 / 考试格换算的混合目标（= 深色页面底 #121316）。
  static const Color darkCellMixBase = pageBgDark;

  /// 深色课程格底色：色板深字色往 #121316 混的比例。
  static const double darkCellFgMix = 0.45;

  /// 深色考试格底色：考试色往 #121316 混的比例。
  static const double darkExamMix = 0.25;

  /// 一个色板色号在深色下的（底色, 文字色）：底 = 浅色的深字色 fg 往 #121316 混 45%，
  /// 字 = 浅色的浅底色 bg（同色相「深底浅字」）。显示时换算，不存。
  static CourseColorPair darkCoursePair(CourseColorPair light) =>
      CourseColorPair(
        Color.lerp(light.fg, darkCellMixBase, darkCellFgMix)!,
        light.bg,
      );

  /// 色号 → 当前明暗下的（底色, 文字色）。浅色与 [courseColor]/[courseTextColor]
  /// 完全一致；深色见 [darkCoursePair]。
  static CourseColorPair coursePair(
    int index, {
    CoursePaletteScheme scheme = currentScheme,
    bool dark = false,
  }) {
    final list = pairsOf(scheme);
    final p = index < 0 ? list[0] : list[index % list.length];
    return dark ? darkCoursePair(p) : p;
  }

  /// 课程 / 考试共用的 12 个预设（对齐 WakeUp 自动色板采样 + 冷暖交错）。
  ///
  /// 核心 8 色来自 WakeUp `_defaultColor`（见 notes/wakeup-auto-palette-sample.md），
  /// 补齐至 12 并冷暖交错；B 的大色块 / 选色器 / 考试色共用此列表。
  static const List<Color> coursePresetColors = [
    Color(0xFFEC407A), // 1 粉 warm（WakeUp）
    Color(0xFF42A5F5), // 2 蓝 cool（WakeUp）
    Color(0xFFFF7043), // 3 橙 warm（WakeUp）
    Color(0xFF26A69A), // 4 青/薄荷 cool（WakeUp）
    Color(0xFFEF5350), // 5 红 warm（WakeUp）
    Color(0xFF5C6BC0), // 6 靛 cool（WakeUp）
    Color(0xFFFFB74D), // 7 橙黄 warm（Material/schedule）
    Color(0xFF66BB6A), // 8 绿 cool（WakeUp）
    Color(0xFFAB47BC), // 9 紫 warm（WakeUp）
    Color(0xFF4FC3F7), // 10 天蓝 cool（schedule）
    Color(0xFFFFD54F), // 11 黄 warm（扩展）
    Color(0xFF4DB6AC), // 12 青绿 cool（schedule）
  ];

  /// 冷色相带：约青绿–靛蓝（100°–260°）。其余视为暖色（红橙黄粉紫等）。
  static bool isCoolHue(double hue) {
    final h = hue % 360.0;
    return h > 100 && h < 260;
  }

  /// 冷暖交错排列，保证无连续 ≥3 个冷色。
  static List<Color> interleaveWarmCool(List<Color> colors) {
    final warm = <Color>[];
    final cool = <Color>[];
    for (final c in colors) {
      if (isCoolHue(HSVColor.fromColor(c).hue)) {
        cool.add(c);
      } else {
        warm.add(c);
      }
    }
    final out = <Color>[];
    var wi = 0, ci = 0, consecutiveCool = 0;
    while (wi < warm.length || ci < cool.length) {
      final canCool = ci < cool.length && consecutiveCool < 2;
      final preferCool =
          canCool &&
          (wi >= warm.length || (out.isNotEmpty && consecutiveCool == 0));
      if (preferCool) {
        out.add(cool[ci++]);
        consecutiveCool++;
      } else if (wi < warm.length) {
        out.add(warm[wi++]);
        consecutiveCool = 0;
      } else if (canCool) {
        out.add(cool[ci++]);
        consecutiveCool++;
      } else {
        break;
      }
    }
    return out;
  }

  static List<Color>? _hueSteppedCache;
  static int _hueSteppedCacheCount = -1;

  /// 自动补色列表：优先 [coursePresetColors]（已冷暖交错）；count>12 时再步进补齐。
  /// 过滤过灰（S<30%）或过暗/过亮；无连续 ≥3 个冷色。
  /// 显示自动色请用 [autoCoursePair] / [autoCoursePairForName]，勿再对 16 色号映射。
  static List<Color> hueSteppedColors(int count) {
    if (count <= 0) return const [];
    if (_hueSteppedCache != null &&
        _hueSteppedCacheCount == count &&
        _hueSteppedCache!.length >= count) {
      return _hueSteppedCache!.sublist(0, count);
    }
    // 预设本身已冷暖交错，直接作自动色底，避免再交错打乱与选色器一致的顺序。
    final out = <Color>[for (final c in coursePresetColors) c];
    if (out.length >= count) {
      _hueSteppedCache = out;
      _hueSteppedCacheCount = count;
      return out.sublist(0, count);
    }

    bool tooClose(Color c, double hue) {
      return out.any((o) {
        final dh = (HSVColor.fromColor(o).hue - hue).abs();
        final d = dh > 180 ? 360 - dh : dh;
        return d < 12;
      });
    }

    final warmExtra = <Color>[];
    final coolExtra = <Color>[];
    for (var step = 0; step < 72; step++) {
      final hue = (step * 5.0) % 360.0;
      for (final s in const [0.70, 0.55, 0.85]) {
        for (final v in const [0.92, 0.80, 0.70]) {
          if (s < 0.30) continue;
          final c = HSVColor.fromAHSV(1, hue, s, v).toColor();
          final lum = c.computeLuminance();
          if (lum < 0.18 || lum > 0.90) continue;
          if (tooClose(c, hue)) continue;
          if (isCoolHue(hue)) {
            coolExtra.add(c);
          } else {
            warmExtra.add(c);
          }
        }
      }
    }
    out.addAll(interleaveWarmCool([...warmExtra, ...coolExtra]));
    // 去重保序（步进候选可能与 seed 近似已滤，但同列表内仍可能重复引用）。
    final seen = <int>{};
    final unique = <Color>[];
    for (final c in out) {
      final key = c.toARGB32();
      if (seen.add(key)) unique.add(c);
      if (unique.length >= count) break;
    }
    // 若仍不足，放宽色相间距再扫一轮。
    if (unique.length < count) {
      for (var step = 0; step < 72 && unique.length < count; step++) {
        final hue = (step * 7.0 + 3.0) % 360.0;
        final c = HSVColor.fromAHSV(1, hue, 0.65, 0.88).toColor();
        final lum = c.computeLuminance();
        if (lum < 0.18 || lum > 0.90) continue;
        if (!seen.add(c.toARGB32())) continue;
        // 追加时仍遵守「无连续 3 冷」。
        final lastCool =
            unique.length >= 2 &&
            isCoolHue(HSVColor.fromColor(unique[unique.length - 1]).hue) &&
            isCoolHue(HSVColor.fromColor(unique[unique.length - 2]).hue);
        if (lastCool && isCoolHue(hue)) continue;
        unique.add(c);
      }
    }
    _hueSteppedCache = unique;
    _hueSteppedCacheCount = count;
    return unique.length > count ? unique.sublist(0, count) : unique;
  }

  /// 未自选 [userColors] 的课：按下标取 [coursePresetColors]（冷暖交错 12 色）。
  /// 自动配色下标应为 [coursePresetIndexForName]（课名哈希 % 12），不是 Course.id。
  static CourseColorPair autoCoursePair(int index, {bool dark = false}) {
    final list = coursePresetColors;
    final bg = list[index < 0 ? 0 : index % list.length];
    return userCoursePair(bg, dark: dark);
  }

  /// 课名 → 自动色对：稳定哈希进 12 预设（同名同色）。
  static CourseColorPair autoCoursePairForName(
    String name, {
    bool dark = false,
  }) => autoCoursePair(coursePresetIndexForName(name), dark: dark);

  /// item 9：用户自选色 [c]（原始 ARGB）在当前明暗下的（底色, 文字色），显示时换算：
  /// 浅色系（亮度 > 0.4）按色板规则「浅底 + 同色相深字」，深色下走 [darkCoursePair]；
  /// 深色系按考试格规则「白字」，深色下往 #121316 混 25%（[examCellBg]）。
  static CourseColorPair userCoursePair(Color c, {bool dark = false}) {
    if (c.computeLuminance() > 0.4) {
      final hsl = HSLColor.fromColor(c);
      final fg = hsl
          .withLightness(0.25)
          .withSaturation(hsl.saturation.clamp(0.0, 0.7))
          .toColor();
      final p = CourseColorPair(c, fg);
      return dark ? darkCoursePair(p) : p;
    }
    return CourseColorPair(examCellBg(c, dark: dark), examText);
  }

  /// item 14「文字颜色」强制白字 / 黑字（明暗都一样）。
  static const Color forcedWhiteText = Color(0xFFFFFFFF);
  static const Color forcedBlackText = Color(0xFF1F2329);

  /// 课程格 / 考试格文字：自动用 [auto]（色板字色或深色规则），白字 / 黑字强制。
  static Color cellTextFor(Color auto, CellTextColorMode mode) =>
      switch (mode) {
        CellTextColorMode.auto => auto,
        CellTextColorMode.white => forcedWhiteText,
        CellTextColorMode.black => forcedBlackText,
      };

  /// 考试格底色：浅色原样；深色往 #121316 混 25%（白字 [examText]）。
  /// 用户自选的考试色同样在显示时换算，不另存。
  static Color examCellBg(Color exam, {bool dark = false}) =>
      dark ? Color.lerp(exam, darkCellMixBase, darkExamMix)! : exam;

  /// 当前方案的 16 个 (底色, 文字色)。
  static List<CourseColorPair> get coursePalettePairs =>
      coursePalettes[currentScheme]!;

  /// 当前方案 16 色底色（A 柔和为浅底；文字色见 [coursePaletteText]）。
  static List<Color> get coursePalette =>
      List.unmodifiable([for (final p in coursePalettePairs) p.bg]);

  /// 当前方案 16 色文字色；课名、地点、冲突圆点、「N 门」等角标都用它，始终不透明。
  static List<Color> get coursePaletteText =>
      List.unmodifiable([for (final p in coursePalettePairs) p.fg]);

  /// 暗色模式课程色浅变体（字用 #121316）。
  static const List<Color> coursePaletteDark = [
    Color(0xFF7FA9F0),
    Color(0xFFF09A7D),
    Color(0xFF72C690),
    Color(0xFFB99BF2),
    Color(0xFFEBB15C),
    Color(0xFF5FC6CC),
    Color(0xFFEE8DB2),
    Color(0xFFA4B0C8),
    Color(0xFF8FA6EC),
    Color(0xFFCF9BE8),
    Color(0xFFA8C66A),
    Color(0xFFF2917F),
    Color(0xFF6CC7B7),
    Color(0xFFE3A574),
    Color(0xFF9AA4F0),
    Color(0xFFE88FB9),
  ];

  static const Color courseTextOnDarkPalette = Color(0xFF121316);

  /// 考试格默认底色（§14.3，白字对比度 5.6）；实际取设置 `examColor`。
  static const Color examDefault = Color(0xFFC62828);

  /// 考试格文字 / 「考试」胶囊（白）。
  static const Color examText = Color(0xFFFFFFFF);

  /// 设置「考试 → 颜色」与课程同一套 12 预设（spec-next-1020 item 3）。
  /// 默认考试色仍为 [examDefault]（不在 12 色内时预览/重置用）。
  static const List<Color> examColorOptions = coursePresetColors;

  /// 课名稳定哈希 → 0-based 色号（与 [Course.resolvedColorIndex] 一致）。
  static int colorIndexFor(String courseName) =>
      courseColorIndexForName(courseName);

  /// 课程底色（色号 → 当前方案底色）。
  static Color courseColor(
    int index, {
    bool dark = false,
    CoursePaletteScheme scheme = currentScheme,
  }) {
    if (dark) {
      if (index < 0) return coursePaletteDark[0];
      return coursePaletteDark[index % coursePaletteDark.length];
    }
    final list = pairsOf(scheme);
    if (index < 0) return list[0].bg;
    return list[index % list.length].bg;
  }

  /// 课程文字色（色号 → 当前方案文字色；暗色模式沿用 #121316）。
  /// 课名、地点、冲突圆点、「N 门」/单双周（及将来的「调」）角标都用它，不受底色不透明度影响。
  static Color courseTextColor(
    int index, {
    bool dark = false,
    CoursePaletteScheme scheme = currentScheme,
  }) {
    if (dark) return courseTextOnDarkPalette;
    final list = pairsOf(scheme);
    if (index < 0) return list[0].fg;
    return list[index % list.length].fg;
  }

  // ---- 字号（sp）----
  static const double displaySize = 20;
  static const FontWeight displayWeight = FontWeight.w600;
  static const double titleSize = 17;
  static const FontWeight titleWeight = FontWeight.w600;
  static const double bodySize = 14;
  static const FontWeight bodyWeight = FontWeight.w400;
  static const double cellSize = 12;
  static const FontWeight cellWeight = FontWeight.w600;
  static const double cellSubSize = 11;
  static const FontWeight cellSubWeight = FontWeight.w400;
  static const double captionSize = 12;
  static const FontWeight captionWeight = FontWeight.w400;
  static const double microSize = 10;
  static const FontWeight microWeight = FontWeight.w400;
  static const double badgeSize = 9;

  // ---- 间距与圆角（dp）----
  static const double pagePaddingH = 16;
  static const double cardRadius = 12;
  static const double cardPaddingH = 16;
  static const double cardPaddingV = 12;
  static const double listRowHeight = 52;
  static const double cellRadius = 4;
  static const double cellMargin = 1.5;
  static const double periodHeight = 64;
  static const double periodHeightMin = 52;
  static const double periodHeightMax = 90;
  static const double todayHeaderRadius = 6;
  static const double sheetTopRadius = 16;
  static const double appBarHeight = 56;

  /// 周视图表头高度（设计师 10/18：统一 48dp，点击热区 ≥48dp，EV40）。
  static const double weekHeaderHeight = 48;
  static const double periodColumnWidth = 34;
  static const double iconSize = 24;
  static const double iconTapSize = 48;
  static const double syncBarHeight = 32;
  static const double conflictDotSize = 6;

  /// 单日修改圆点（第 1 条）。
  static const double dateEditDotSize = 4;

  /// AS-1：自动同步失败时顶栏同步图标右上角的小圆点（6dp，#C62828）。
  static const Color syncErrorDot = Color(0xFFC62828);
  static const double syncErrorDotSize = 6;

  /// 设置「教务账号」行登录已过期时的「已过期」字色（同 [syncErrorDot]）。
  static const Color sessionExpiredText = syncErrorDot;
  static const int defaultNodesPerDay = 11;
  static const int maxNodesPerDay = 20;
  static const int defaultMaxWeeks = 20;

  // ---- 文字样式 ----
  // [color] 省略时退化成浅色基准值；深色下请显式传
  // `TimetableTheme.colorsOf(context)` 里的对应色。

  static TextStyle displayStyle({Color? color}) => TextStyle(
    fontSize: displaySize,
    fontWeight: displayWeight,
    color: color ?? titleText,
    height: 1.2,
  );

  static TextStyle titleStyle({Color? color}) => TextStyle(
    fontSize: titleSize,
    fontWeight: titleWeight,
    color: color ?? titleText,
  );

  static TextStyle bodyStyle({Color? color}) => TextStyle(
    fontSize: bodySize,
    fontWeight: bodyWeight,
    color: color ?? labelText,
  );

  static TextStyle cellStyle({Color? color}) => TextStyle(
    fontSize: cellSize,
    fontWeight: cellWeight,
    color: color ?? titleText,
    height: 1.2,
  );

  static TextStyle cellSubStyle({Color? color}) => TextStyle(
    fontSize: cellSubSize,
    fontWeight: cellSubWeight,
    color: color ?? labelText,
    height: 1.15,
  );

  static TextStyle captionStyle({Color? color}) => TextStyle(
    fontSize: captionSize,
    fontWeight: captionWeight,
    color: color ?? labelText,
  );

  static TextStyle microStyle({Color? color}) => TextStyle(
    fontSize: microSize,
    fontWeight: microWeight,
    color: color ?? hint,
  );
}

/// 一个色号的 (底色, 文字色)。不透明度（以后的设置项）只作用于 [bg]，[fg] 始终不透明。
@immutable
class CourseColorPair {
  const CourseColorPair(this.bg, this.fg);

  final Color bg;
  final Color fg;
}

/// 课表 chrome（页面底色、表头、文字、分隔线、非本周格）的一套配色。
///
/// 用 `TimetableTheme.colorsOf(context)` 取当前主题的那一套，调用方不要再写
/// `isDark ? xxxDark : xxx`。课程格的配色不在这里（见 [TimetableTheme.courseColor]）。
@immutable
class TimetableColors {
  const TimetableColors({
    required this.brightness,
    required this.pageBg,
    required this.surface,
    required this.titleText,
    required this.labelText,
    required this.hint,
    required this.divider,
    required this.chevron,
    required this.chipBg,
    required this.accent,
    required this.accentSoft,
    required this.offWeekBg,
    required this.offWeekBorder,
    required this.offWeekText,
    required this.warning,
    required this.danger,
  });

  /// 这套配色对应的明暗。
  final Brightness brightness;

  /// 页面底色。
  final Color pageBg;

  /// 卡片 / 弹层 / 表单的面色。
  final Color surface;

  /// 主文字。
  final Color titleText;

  /// 次级文字。
  final Color labelText;

  /// 占位、辅助说明文字。
  final Color hint;

  /// 分隔线、描边。
  final Color divider;

  /// 列表行右侧箭头，比 [hint] 更淡。
  final Color chevron;

  /// 未选中的筹码（周次 FilterChip）底色。
  final Color chipBg;

  /// 品牌强调色。
  final Color accent;

  /// 今天表头底色（[accent] 的低不透明度变体）。
  final Color accentSoft;

  /// 非本周格底色（§13.8）。
  final Color offWeekBg;

  /// 非本周格描边（§13.8）。
  final Color offWeekBorder;

  /// 非本周格文字与「非本周」胶囊（§13.8）。
  final Color offWeekText;

  /// 语义色：待同步 / 提醒。
  final Color warning;

  /// 语义色：失败 / 删除。
  final Color danger;

  /// 是否为深色模式。
  bool get isDark => brightness == Brightness.dark;

  /// 浅色（设计稿基准）。
  static final light = TimetableColors(
    brightness: Brightness.light,
    pageBg: TimetableTheme.pageBg,
    surface: TimetableTheme.surface,
    titleText: TimetableTheme.titleText,
    labelText: TimetableTheme.labelText,
    hint: TimetableTheme.hint,
    divider: TimetableTheme.divider,
    chevron: TimetableTheme.chevron,
    chipBg: TimetableTheme.chipBg,
    accent: TimetableTheme.accent,
    accentSoft: TimetableTheme.accentSoft,
    offWeekBg: TimetableTheme.offWeekBg,
    offWeekBorder: TimetableTheme.offWeekBorder,
    offWeekText: TimetableTheme.offWeekText,
    warning: TimetableTheme.warning,
    danger: TimetableTheme.danger,
  );

  /// 深色。
  static final dark = TimetableColors(
    brightness: Brightness.dark,
    pageBg: TimetableTheme.pageBgDark,
    surface: TimetableTheme.surfaceDark,
    titleText: TimetableTheme.titleTextDark,
    labelText: TimetableTheme.labelTextDark,
    hint: TimetableTheme.hintDark,
    divider: TimetableTheme.dividerDark,
    chevron: TimetableTheme.chevronDark,
    chipBg: TimetableTheme.chipBgDark,
    accent: TimetableTheme.accentDark,
    accentSoft: TimetableTheme.accentSoftDark,
    offWeekBg: TimetableTheme.offWeekBgDark,
    offWeekBorder: TimetableTheme.offWeekBorderDark,
    offWeekText: TimetableTheme.offWeekTextDark,
    warning: TimetableTheme.warningDark,
    danger: TimetableTheme.dangerDark,
  );
}
