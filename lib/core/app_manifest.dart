import 'package:flutter/material.dart';

/// 一个「小程序」在注册表里的描述。
///
/// 壳按注册信息展示宫格与卡片；有入口的模块统一走 `/apps/[id]`。
/// 普通构造要求 [entry] 与 [url] 恰好二选一：
///
/// - 原生小程序：在 `lib/mini_apps/<name>/` 下写 Flutter 页面，
///   模块里导出一个 [AppManifest] 常量并在注册表登记；
/// - H5 小程序：只登记 [url]，由通用 WebView 承载页打开，
///   适合不会 Flutter 的社团用任意 Web 技术栈交付。
///
/// 没有全屏入口、只提供学习卡片的模块使用 [AppManifest.cardOnly]。
class AppManifest {
  /// 声明带原生或 H5 入口的小程序。
  const AppManifest({
    required this.id,
    required this.label,
    required Color this.color,
    this.glyph,
    this.icon,
    this.iconWidget,
    this.entry,
    this.url,
    this.requiresPortal = false,
    this.homeCard,
    this.onHomeRefresh,
    this.showInHomeGrid = true,
    this.studyCard,
    this.onPortalBindingChanged,
  }) : assert(
         (entry == null) != (url == null),
         '$id 必须且只能提供 entry（原生）或 url（H5）之一',
       ),
       assert(
         !requiresPortal || url != null,
         '$id 的 requiresPortal 只对 H5 小程序有意义；原生小程序请直接用 PortalSession',
       );

  /// 声明只有学习卡片的模块，不提供全屏入口或首页宫格图标。
  const AppManifest.cardOnly({
    required this.id,
    required this.label,
    required StudyCardContribution this.studyCard,
    this.onPortalBindingChanged,
  }) : color = null,
       glyph = null,
       icon = null,
       iconWidget = null,
       entry = null,
       url = null,
       requiresPortal = false,
       homeCard = null,
       onHomeRefresh = null,
       showInHomeGrid = false;

  /// 全注册表唯一的标识；有入口时对应 `/apps/$id`。
  final String id;

  /// 模块名称；有宫格或全屏入口时也是对应的显示名称。
  final String label;

  /// 宫格图标底色；仅卡片模块没有宫格配色。
  final Color? color;

  /// 图标底色上的单字，如「图」。
  ///
  /// 没有 [iconWidget] 时才会用到，仍优先于 [icon]。
  final String? glyph;

  /// 备选：Material 图标。优先级最低。
  final IconData? icon;

  /// 可选：自定义图形图标，优先级最高（如按设计稿 SVG 绘制的图案）。
  ///
  /// 壳把它放进色块内 **24×24** 的方框里居中，图形自己负责填满这个方框；
  /// 图案应当自带颜色，壳不做着色。用了它就把 [glyph] 清空，避免双显。
  final WidgetBuilder? iconWidget;

  /// 原生小程序的入口页面。
  final WidgetBuilder? entry;

  /// H5 小程序的地址。
  final String? url;

  /// H5 小程序是否需要统一门户登录态。
  ///
  /// 为 true 时，承载页会先确保门户已登录、把会话 Cookie 灌进 WebView，再加载
  /// 页面，于是 H5 打开即是登录状态，不用自己再登一次。未绑定门户时会提示用户
  /// 先去「我的 → 绑定统一门户」。
  ///
  /// 原生小程序不需要这个开关，直接用 `PortalSession.instance` 取会话即可。
  final bool requiresPortal;

  /// 可选：在首页宫格上方额外展示的信息卡片（如电费余额）。
  ///
  /// 壳只负责把它摆出来，卡片内部的数据与跳转由小程序自己处理，壳不感知。
  final WidgetBuilder? homeCard;

  /// 可选：首页下拉刷新时调用，用来刷新 [homeCard] 的数据。
  ///
  /// 壳会并发调用所有小程序的这个回调，等全部完成后收起转圈；各自的失败
  /// 由小程序自己在卡片上展示，不要抛出异常。
  final Future<void> Function()? onHomeRefresh;

  /// 是否在首页宫格展示入口；不影响首页卡片或全屏路由。
  final bool showInHomeGrid;

  /// 可选：学习页常驻卡片及其排序、刷新行为。
  final StudyCardContribution? studyCard;

  /// 可选：本机门户绑定变化后的处理，优先于卡片的默认刷新。
  ///
  /// `bound` 为 true 表示注册、重新绑定或导入凭据成功，为 false 表示解绑；
  /// 普通会话续期不会触发。未提供时，注册表会刷新已有的首页卡片与学习卡片，
  /// 由各模块重新检查绑定状态；需要清理缓存等特殊处理时提供此回调。
  final Future<void> Function(bool bound)? onPortalBindingChanged;

  /// 是否提供可通过 `/apps/$id` 访问的全屏入口。
  bool get hasEntry => entry != null || url != null;

  /// 是否为 H5 形态。
  bool get isWeb => url != null;
}

/// 小程序贡献的学习卡片，展示与刷新始终使用同一份注册配置。
class StudyCardContribution {
  /// [order] 越小越靠前；相同时按模块 id 排序。
  const StudyCardContribution({
    required this.builder,
    required this.order,
    this.onRefresh,
  });

  /// 构建卡片；数据启动、状态展示和点击行为由卡片自身负责。
  final WidgetBuilder builder;

  /// 学习页展示顺序，独立于首页宫格顺序。
  final int order;

  /// 可选的下拉刷新操作；业务失败由模块在卡片中展示。
  ///
  /// 壳并发调用所有回调并等待完成；静态卡片可以不提供刷新操作。
  final Future<void> Function()? onRefresh;
}
