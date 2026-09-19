import 'campus_map/campus_map_manifest.dart';
import 'electricity/electricity_manifest.dart';
import '../core/app_manifest.dart';

/// 全量小程序注册表：首页宫格按此渲染。
///
/// 新增小程序 = 建 `lib/mini_apps/<name>/` 目录（或直接给 H5 地址），
/// 然后在这里加一行。除此之外不需要改动壳的任何代码。
final List<AppManifest> appRegistry = [
  electricityManifest,
  campusMapManifest,
  // H5 小程序示例：给 url 即可，由通用 WebView 页承载。
  // AppManifest(id: 'demo-web', label: '网页示例', color: Color(0xFF8B5CF6),
  //     glyph: '网', url: 'https://example.com'),
];

/// 按 id 索引，供路由 `/apps/:appId` 查找。
final Map<String, AppManifest> appRegistryById = {
  for (final m in appRegistry) m.id: m,
};
