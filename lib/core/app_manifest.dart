import 'package:flutter/material.dart';

/// 一个「小程序」在注册表里的描述。
///
/// 壳首页宫格按注册表渲染；点击后统一跳转全屏路由 `/apps/[id]`。
/// 小程序有两种形态，[entry] 与 [url] 恰好二选一：
///
/// - 原生小程序：在 `lib/mini_apps/<name>/` 下写 Flutter 页面，
///   模块里导出一个 [AppManifest] 常量并在注册表登记；
/// - H5 小程序：只登记 [url]，由通用 WebView 承载页打开，
///   适合不会 Flutter 的社团用任意 Web 技术栈交付。
class AppManifest {
  const AppManifest({
    required this.id,
    required this.label,
    required this.color,
    this.glyph,
    this.icon,
    this.iconWidget,
    this.entry,
    this.url,
    this.requiresPortal = false,
    this.homeCard,
    this.onHomeRefresh,
  }) : assert(
         (entry == null) != (url == null),
         '$id 必须且只能提供 entry（原生）或 url（H5）之一',
       ),
       assert(
         !requiresPortal || url != null,
         '$id 的 requiresPortal 只对 H5 小程序有意义；原生小程序请直接用 PortalSession',
       );

  /// 路由标识，如 'campus-map'，全注册表唯一，跳转 `/apps/$id` 用。
  final String id;

  /// 宫格与小程序内顶栏显示的名字。
  final String label;

  /// 宫格图标底色。
  final Color color;

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

  /// 是否为 H5 形态。
  bool get isWeb => url != null;
}
