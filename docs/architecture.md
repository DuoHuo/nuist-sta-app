# 架构

整体是「**壳 + 注册表 + 小程序**」三层。

壳（底部页签 + 宫格首页）固定不变；每个小程序是 `lib/mini_apps/` 下一个自包含目录，
在注册表登记一行就上宫格，点击进入全屏路由 `/apps/<id>`。

这样切分的目的是**让小程序可以独立增删、并行开发、合并互不冲突** —— 社团同学各做各的，
不需要协调同一个文件。

## 目录

```
lib/
├── app.dart            # NuistApp：MaterialApp.router + 主题（主题内联在这里，没抽出来）
├── router.dart         # go_router 路由表
├── core/               # 壳与所有小程序共用（尽量少放，别让它变成垃圾场）
│   ├── auth/           # 统一门户登录 —— 见 portal-auth.md
│   ├── app_manifest.dart   # AppManifest：小程序描述
│   ├── app_info.dart       # kAppName
│   ├── colors.dart         # AppColors 设计稿色板
│   ├── html_table.dart     # 教务 HTML 表格解析
│   ├── time_format.dart    # 时间格式化
│   └── wip.dart            # showWipSnackBar「开发中」占位反馈
├── shell/              # 大 APP 的壳（社团一般不用动）
│   ├── home/           # 首页宫格
│   ├── study/          # 学习页
│   └── profile/        # 我的页（含 portal_bind/ 绑定统一门户）
└── mini_apps/          # 所有小程序，每个一个目录
    ├── registry.dart   # ★ 全量注册表
    └── …
```

## 路由

`lib/router.dart` 的 `buildRouter()`：

| 路径 | 内容 |
|---|---|
| `/` `/study` `/profile` | 三个页签，包在 `StatefulShellRoute.indexedStack` 里 |
| `/apps/:appId` | 全屏小程序；按 id 查注册表，查不到显示「小程序不存在或已下线」 |
| `/portal-bind`、`/portal-bind/register` | 统一门户绑定与状态页 |
| `/innovation-credit`、`/labor-score` | 两个详情页，硬编码在路由表里 |

小程序路由与壳路由**平级**，所以进小程序后不带底部页签，系统返回键自然退回宫格。

> **⚠️ 必须用 `context.push('/apps/<id>')`，不要用 `go`。**
> 用 `go` 会替换掉栈底，小程序页顶栏就没有返回按钮、返回键也退不回宫格。

## AppManifest

小程序的描述对象（`lib/core/app_manifest.dart`）：

| 字段 | 类型 | 必填 | 含义 |
|---|---|---|---|
| `id` | `String` | ✅ | 全局唯一，决定路由 `/apps/<id>` |
| `label` | `String` | ✅ | 宫格文字，**同时**是小程序内的顶栏标题 |
| `color` | `Color` | ✅ | 图标底色 |
| `glyph` | `String?` | | 底色上的单字（如「图」）。设计稿首选形式 |
| `icon` | `IconData?` | | 备选 Material 图标。**与 `glyph` 同时存在时 `glyph` 优先** |
| `entry` | `WidgetBuilder?` | 二选一 | 原生小程序的入口页面 |
| `url` | `String?` | 二选一 | H5 小程序地址 |
| `requiresPortal` | `bool` | | 仅对 H5 有意义，默认 `false` |
| `homeCard` | `WidgetBuilder?` | | 首页宫格**上方**的常驻卡片 |

两条构造断言（写错了会在构造时直接抛）：

1. **`entry` 与 `url` 必须恰好二选一** —— 原生给 `entry`，H5 给 `url`
2. **`requiresPortal` 为 `true` 时 `url` 必须非空** —— 原生小程序请直接用 `PortalSession`

## 一个小程序能贡献的四种 UI 面

这是最容易误解的地方。**只有前两种走注册表机制**：

| 贡献面 | 机制 | 要改哪里 |
|---|---|---|
| 首页宫格入口 | 注册表加一行 | `lib/mini_apps/registry.dart` |
| 首页常驻卡片 | `AppManifest.homeCard` | 自己的 manifest，**不用改壳** |
| 学习页常驻卡片 | ⚠️ **没有注册表机制** | 必须改 `shell/study/study_page.dart`（卡片列表**和** `_refreshAll` 两处）+ `router.dart` |
| 全屏详情页路由 | `router.dart` 里手写 `GoRoute` | `lib/router.dart` |

`homeCard` 的设计意图是壳只负责「把它摆出来」，卡片内部的数据与跳转由小程序自理，
壳不感知 —— 所以首页加卡片确实不用动壳。学习页目前没有对应的机制，见下文「已知架构债」。

## 依赖方向

**约定**（目的：任何小程序都能独立增删）：

- `mini_apps/*` 只能 import `core/*` 和第三方包；**不得** import `shell/*` 或其他小程序
- `shell/*` 应当只 import `core/*` 和 `mini_apps/registry.dart`，不感知具体小程序
- 跨小程序共享的组件才进 `core/`，且尽量少加

**现状**（写文档时点名的两处，别照抄约定当现实）：

- ✅ `mini_apps/*` 侧完全合规：没有任何一处 import `shell/*` 或兄弟小程序
- ⚠️ `shell/*` 侧**有三处合法例外**：
  - `shell/study/study_page.dart` 直接 import 了四个小程序模块 —— 因为学习页卡片没有注册表机制
  - `shell/profile/portal_bind/portal_status_page.dart` import 了 `student_info` 的模型与存储，用于展示学生身份
  - `router.dart` 直接 import 了几个小程序页面

  真正「只认注册表」的壳页面只有 `shell/home/home_page.dart`。

**这些规则没有任何工具强制**（`analysis_options.yaml` 里 `linter.rules` 是空的，
也没有自定义 lint），纯靠人工 review。

## 状态管理

没有 provider / riverpod / bloc，也没有基类。约定就三条：

**Controller 管状态**（`*_controller.dart`）
`ChangeNotifier` + 私有构造单例，暴露 `instance`。启动走幂等的 `ensureStarted()`：

```dart
Future<void> ensureStarted() {
  if (_started) return _starting ?? Future.value();
  _started = true;
  return _starting = _start();
}
```

UI 侧用 `ListenableBuilder(listenable: controller, builder: …)` 订阅。跨页面共享靠单例
（首页的电费卡片和电费详情页共用同一个 `ElectricityController.instance`，刷新两边同步）。

**Store 管落盘**（`*_store.dart`）
全是 `static` 方法，无状态、无 listener。JSON 文件写在
`getApplicationDocumentsDirectory()/<小程序名>/` 下。**所有读写都 try/catch 退化成「没有存储」**，
这样 widget 测试在没有平台通道时也能跑。

**Api 管网络**（`*_api.dart`）
也全是 `static`。走 `PortalSession`，抛 `PortalException` 子类，不碰 UI。

## 主题与色板

- Material 3 **开启**（`useMaterial3: true`）
- **没有配 `colorScheme` / seed color**，所以 `colorScheme.primary` 是 Flutter 默认 M3 紫，
  不是品牌色。品牌色只存在于 `AppColors.accent`，UI 里显式引用
- `AppColors`（`lib/core/colors.dart`）是与设计稿 `design/home.op` 对齐的静态色板：
  `pageBg` / `titleText` / `labelText` / `hint` / `rowDivider` / `accent` / `tabInactive` /
  `divider` / `success` / `warning` / `danger`
- 小程序私有配色就地在自己的目录里定义（如 `kClassroomColor`、`ElecColors`）
- **没有暗色模式**，没有自定义字体

主题内联在 `app.dart` 的 `build` 里，没有抽成独立函数 —— 这意味着单独 pump 某个页面时
拿不到 `scaffoldBackgroundColor`。

## 已知架构债

如实列出，不是「规范」，是「将来要还的账」：

1. **学习页卡片没有注册表化**。新增学习页卡片必须改壳的两个地方（卡片列表 + `_refreshAll`），
   与「小程序独立增删」的设计目标相悖。
2. **依赖方向没有工具强制**。约定的三条规则零 lint 覆盖，全靠 review 把关。
3. **`_RefreshButton` 在四个卡片文件里各写了一份私有同名类**（`academic` / `student_info` /
   `innovation_credit` / `labor_score`），没有上收到 `core/`。
4. **主题没有抽成函数**，导致测试里单独渲染页面会丢主题。
5. **`lib/core/auth/` 没有单元测试**。

## 测试

`test/widget_test.dart` 是冒烟测试，自动守护两条不变量：

- 注册表 `id` 全局唯一（重复会导致 `/apps/:id` 路由冲突）
- 每个 manifest 恰好提供 `entry` 或 `url` 之一

另外它还用 `findsOneWidget` 断言了若干界面文案。**副作用：新增小程序的 `label` 不能与
现有重名**，否则这些断言会挂。

CI 只要求 `flutter analyze` 零警告 + `flutter test` 全绿，没有覆盖率门槛。

## 相关文档

- [新增一个小程序](mini-app-guide.md)
- [统一门户登录](portal-auth.md)
- [路线图与架构债排期](roadmap.md)
