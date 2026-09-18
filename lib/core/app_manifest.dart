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
    this.entry,
    this.url,
  }) : assert(
          (entry == null) != (url == null),
          '$id 必须且只能提供 entry（原生）或 url（H5）之一',
        );

  /// 路由标识，如 'campus-map'，全注册表唯一，跳转 `/apps/$id` 用。
  final String id;

  /// 宫格与小程序内顶栏显示的名字。
  final String label;

  /// 宫格图标底色。
  final Color color;

  /// 图标底色上的单字，如「图」。与设计稿一致的首选图标形式。
  final String? glyph;

  /// 备选：Material 图标。glyph 与 icon 同时存在时 glyph 优先。
  final IconData? icon;

  /// 原生小程序的入口页面。
  final WidgetBuilder? entry;

  /// H5 小程序的地址。
  final String? url;

  /// 是否为 H5 形态。
  bool get isWeb => url != null;
}
