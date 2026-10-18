import 'package:flutter/material.dart';

import '../../core/colors.dart';
import 'timetable_colors.dart';
import 'timetable_models.dart';

/// 实时课表 UI Token（对齐 design/timetable-spec.md v0.2）。
///
/// 浅色为 MVP 默认；暗色 token 已备，P1 再切主题。
abstract final class TimetableTheme {
  // ---- 颜色（复用 AppColors + 课表专用 *）----
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
  static const Color accent = AppColors.accent;
  static const Color accentDark = Color(0xFF4DA3F5);
  static const Color success = AppColors.success;
  static const Color warning = AppColors.warning;
  static const Color danger = AppColors.danger;

  /// 今天表头底色：accent @12%。
  static Color get accentSoft => accent.withValues(alpha: 0.12);

  static Color get accentSoftDark => accentDark.withValues(alpha: 0.18);

  /// 非本周格（spec §13.8）：白底 + 1px #DADDE3 描边（随圆角）+ #6B7280 字。
  /// 不使用任何配色色值，A/B/C 三套都不会撞色；不透明度设置不作用于它。
  static const Color offWeekBg = Color(0xFFFFFFFF);
  static const Color offWeekBorder = Color(0xFFDADDE3);
  static const double offWeekBorderWidth = 1;

  /// 非本周格文字（课名/地点/老师/代码）与「非本周」胶囊的描边和字（§13.8，
  /// 白底对比度约 4.8）。
  static const Color offWeekText = Color(0xFF6B7280);

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
  static Color blendCellBg(Color bg, int opacity) {
    final t = (opacity.clamp(30, 100)) / 100.0;
    if (t >= 1) return bg;
    return Color.lerp(pageBg, bg, t)!;
  }

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

  /// 设置「考试 → 颜色」色板（§14.3：每个选项与白字对比度 ≥ 4.5）。第一项为默认。
  static const List<Color> examColorOptions = [
    examDefault, // 红 5.6
    Color(0xFFBF360C), // 橙红 5.6
    Color(0xFFAD1457), // 玫红 7.0
    Color(0xFF6A1B9A), // 紫 9.4
    Color(0xFF283593), // 靛蓝 10.4
    Color(0xFF1565C0), // 蓝 5.8
    Color(0xFF00695C), // 青 6.6
    Color(0xFF2E7D32), // 绿 5.1
  ];

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

  /// AS-1：自动同步失败时顶栏同步图标右上角的小圆点（6dp，#C62828）。
  static const Color syncErrorDot = Color(0xFFC62828);
  static const double syncErrorDotSize = 6;

  /// 设置「教务账号」行登录已过期时的「已过期」字色（同 [syncErrorDot]）。
  static const Color sessionExpiredText = syncErrorDot;
  static const int defaultNodesPerDay = 11;
  static const int maxNodesPerDay = 20;
  static const int defaultMaxWeeks = 20;

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
