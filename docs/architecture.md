# 架构

整体是「**壳 + 注册表 + 小程序**」三层。

壳（底部页签 + 宫格首页）固定不变；每个小程序是 `lib/mini_apps/` 下一个自包含目录，
在注册表登记一次，由 manifest 声明首页宫格、首页卡片和学习页卡片；有入口的小程序
通过全屏路由 `/apps/<id>` 打开，也可以只贡献学习卡片。

这样切分的目的是**让小程序可以独立增删、并行开发、合并互不冲突** —— 社团同学各做各的，
不需要协调同一个文件。

## 目录

```
lib/
├── app.dart            # NuistApp：MaterialApp.router，监听 AppThemeMode 切换明暗
├── router.dart         # go_router 路由表
├── core/               # 壳与所有小程序共用（尽量少放，别让它变成垃圾场）
│   ├── auth/           # 统一门户登录 —— 见 portal-auth.md
│   ├── config/         # campus_config.dart 校园地址与密钥（hex 编码）—— 见 configuration.md；
│   │                   # api_endpoints.dart 社团自有服务地址（明文）
│   ├── logging/        # 结构化日志、Trace/Span、轮转存储与用户导出
│   ├── network/        # 自有服务客户端与元数据；校园 VPN 与 Rust 原生库的 FFI 封装
│   ├── schedule/       # WeeklyClasses：「本周课程」跨小程序接口（课表提供，地图读取）
│   ├── app_manifest.dart   # AppManifest：小程序描述
│   ├── app_registry.dart   # AppRegistry：注册校验与宫格、学习卡片、入口索引
│   ├── app_info.dart       # kAppName
│   ├── colors.dart         # AppPalette 与 AppColors / AppColorsDark 色板
│   ├── theme.dart          # appLightTheme() / appDarkTheme()
│   ├── theme_mode.dart     # AppThemeMode：明暗模式选择与持久化
│   ├── html_table.dart     # 教务 HTML 表格解析
│   ├── refresh/            # silent_refresh.dart：静默刷新、失败重试与成功提示
│   ├── pull_to_refresh.dart # 可取消的下拉刷新
│   ├── time_format.dart    # 时间格式化
│   └── wip.dart            # showWipSnackBar「开发中」占位反馈
├── shell/              # 大 APP 的壳（社团一般不用动）
│   ├── root_page.dart  # 底部三页签
│   ├── announcement/   # 应用公告（拉取社团自有服务）
│   ├── home/           # 首页宫格
│   ├── study/          # 学习页
│   └── profile/        # 我的页（portal_bind/ 统一门户、settings/ 设置、about/ 关于）
└── mini_apps/          # 所有小程序，每个一个目录
    ├── registry.dart   # ★ 全量注册表
    └── …
```

## 路由

`lib/router.dart` 的 `buildRouter()`：

| 路径 | 内容 |
|---|---|
| `/` `/study` `/profile` | 三个页签，包在 `StatefulShellRoute.indexedStack` 里 |
| `/apps/:appId` | 全屏小程序；按 id 查注册表的入口索引，未知 id 或仅卡片模块显示「小程序不存在或已下线」 |
| `/portal-bind`、`/portal-bind/register` | 统一门户绑定与状态页 |
| `/portal-bind/export`、`/portal-bind/import`、`/portal-bind/import/scan` | 通行密钥导出、导入与扫码导入 |
| `/place/:placeId` | 校园地图地物详情页，可深链 |
| `/about`、`/settings` | 关于页、App 级设置页 |

学习页的成绩、双创学分、劳动积分详情分别使用 `/apps/scores`、`/apps/innovation-credit`、
`/apps/labor-score`，页面入口由各模块的 manifest 提供。

小程序路由与壳路由**平级**，所以进小程序后不带底部页签；从宫格或学习页 `push` 进入后，
系统返回键自然退回原页面。

> **⚠️ 必须用 `context.push('/apps/<id>')`，不要用 `go`。**
> 用 `go` 会替换掉栈底，小程序页顶栏就没有返回按钮、返回键也退不回原页面。

### 返回行为与预测性返回

壳与所有小程序都遵守同一原则：先明确返回的目标，再设计动画和拦截。Android 上有上一页、
且当前允许退出的页面必须支持预测性返回：画面随手势变化，取消后保留页面与内容，完成后
退回正确的上一页。不能为了动画跳过未保存确认、网页历史或地图内部层级。

全局适配由 `android/app/src/main/AndroidManifest.xml` 的
`android:enableOnBackInvokedCallback="true"` 和 `lib/core/theme.dart` 的
`PredictiveBackPageTransitionsBuilder` 共同提供，明暗主题共享；页面应沿用这套配置。
`fullscreenDialog: true` 会让 Flutter 的 `PageRoute.popGestureEnabled` 返回 `false`，
也会阻断 Android 预测性返回。因此，全屏表单在 Android 上使用普通 Material 路由，
需要关闭图标时显式配置顶栏；iOS 如需全屏模态语义，应按平台设置，不能连带关闭 Android 手势。

需要拦截时使用 `PopScope`，由当前状态提前决定 `canPop`，不要等返回回调里才异步判断能否
离开，也不要使用 `WillPopScope`。为保护未保存修改而拦截时，应提供继续编辑或确认放弃的选择；
关键写入期间可以暂缓退出；网页有历史时先后退网页，地图有选中地点、路线等状态时
先处理内部返回。拦截原因消失后
立即恢复允许退出，不能一律拦住再手动 `pop` 来模拟正常返回。

普通提示应允许关闭或返回；业务确需禁止关闭时，应在对应设计或代码注释中说明依据、
作用范围和解除条件。已有不可关闭公告仅限制该公告对话框，过期或服务端移除后解除，
不能据此把普通公告或整个页面都设为不可返回。

涉及路由或返回拦截的改动，测试必须通过真实入口函数或页面操作进入目标页，不能只验证
另外创建的 `MaterialPageRoute`。按适用状态验证：

- 未修改时，手势可以开始、跟随、取消和完成；取消不丢内容，完成返回正确的页面。
- 表单设有未保存保护时，继续编辑保留内容，确认放弃才离开；修改恢复原值后重新允许正常返回。
- 写入结束、网页历史耗尽或内部状态退出后，拦截及时解除，不绕过原有返回层级。
- 明暗主题行为一致；按平台调整路由时，同时检查其他平台需要保留的模态语义。

Widget 测试可通过 `flutter/backgesture` 通道验证手势进度、取消和完成，但不能替代设备上
的系统手势检查；未做真机验证时需在交付中明确说明。

## AppManifest

小程序的描述对象（`lib/core/app_manifest.dart`）：

| 字段 | 类型 | 必填 | 含义 |
|---|---|---|---|
| `id` | `String` | ✅ | 全局唯一；有入口时决定路由 `/apps/<id>` |
| `label` | `String` | ✅ | 模块名称；有宫格或全屏入口时也是对应的显示名称 |
| `color` | `Color?` | 普通构造必填 | 图标底色；仅卡片构造固定为 `null` |
| `glyph` | `String?` | | 底色上的单字（如「图」）。设计稿首选形式 |
| `icon` | `IconData?` | | 备选 Material 图标。**与 `glyph` 同时存在时 `glyph` 优先** |
| `entry` | `WidgetBuilder?` | 普通构造二选一 | 原生小程序的入口页面 |
| `url` | `String?` | 普通构造二选一 | H5 小程序地址 |
| `requiresPortal` | `bool` | | 仅对 H5 有意义，默认 `false` |
| `showInHomeGrid` | `bool` | | 是否展示首页宫格入口，普通构造默认 `true` |
| `homeCard` | `WidgetBuilder?` | | 首页宫格**上方**的常驻卡片 |
| `onHomeRefresh` | `Future<void> Function()?` | | 首页下拉刷新时调用，刷新自己 `homeCard` 的数据；壳并发调用全部回调 |
| `studyCard` | `StudyCardContribution?` | 仅卡片构造必填 | 学习页卡片及其排序、刷新配置 |

普通构造 `AppManifest(...)` 有两条断言（写错了会在构造时直接抛）：

1. **`entry` 与 `url` 必须恰好二选一** —— 原生给 `entry`，H5 给 `url`
2. **`requiresPortal` 为 `true` 时 `url` 必须非空** —— 原生小程序请直接用 `PortalSession`

只有卡片、没有详情页的模块使用 `AppManifest.cardOnly(...)`，必须提供 `id`、`label` 和
`studyCard`。该构造固定无 `entry/url`、无宫格信息、`showInHomeGrid: false`，不需要补一个
占位页面。`hasEntry` 表示是否有原生或 H5 入口。

`StudyCardContribution` 将学习卡片的三个配置放在一起：

| 字段 | 类型 | 含义 |
|---|---|---|
| `builder` | `WidgetBuilder` | 必填，构建卡片；启动与状态仍由卡片内部管理 |
| `order` | `int` | 必填，学习页按数值升序排列；相同数值按模块 id 排序 |
| `onRefresh` | `Future<void> Function()?` | 可选，学习页下拉时调用；静态卡片可以省略 |

`lib/mini_apps/registry.dart` 只维护一份 `appRegistry = AppRegistry([...])`。`AppRegistry`
在构造时拒绝重复 id，并生成只读的 `apps`（全量模块）、`homeGridApps`（宫格可见模块）、
`studyApps`（按学习顺序排序的模块）和 `byId`（仅包含有入口模块的索引）。首页宫格与学习页
排序互不影响；增删模块只需调整这一份登记。

## 一个小程序能贡献的四种 UI 面

这四种常用贡献面都由 manifest 和注册表接入：

| 贡献面 | 机制 | 要改哪里 |
|---|---|---|
| 首页宫格入口 | 注册并保持 `showInHomeGrid: true` | 自己的 manifest + `lib/mini_apps/registry.dart` |
| 首页常驻卡片 | `AppManifest.homeCard` | 自己的 manifest，**不用改壳** |
| 学习页常驻卡片 | `AppManifest.studyCard` | 自己的 manifest，**不用改壳或刷新名单** |
| 全屏入口页路由 | `AppManifest.entry` 或 `url`，统一 `/apps/<id>` | 自己的 manifest，**不用改路由表** |

壳只负责摆放卡片，卡片内部的数据、状态和跳转由小程序自理。学习页用同一份 `studyApps`
渲染卡片和收集刷新回调，并发等待所有回调；单项抛错不会阻止其余项启动，异常由壳
记录脱敏日志并兜底，等待其余刷新完成后正常结束下拉。

### 静默刷新

首页与学习页的刷新统一走 `lib/core/refresh/silent_refresh.dart`（issue #31，口径经作者 review 调整）：

- **自动刷新静默**：首次进入、门户绑定变化、回到前台等后台刷新不出现转圈，
  失败也不在界面提示，只按模块写 `WARNING` 诊断日志；
- **手动刷新有反馈**：首页与学习页下拉仍走 `RefreshIndicator` 转圈；详情页的
  刷新按钮保留加载动画；手动刷新失败时由控制器置一条友好文案（「刷新失败，
  请稍后再试」），不把原始异常抛给界面；
- 「已更新」提示只在**真正刷新成功**时发出：批量刷新不会因为「有任一模块成功」
  就统一提示，避免失败也被报成已更新；同批多次成功在界面上做 400ms 去重；
- 网络类失败（超时、连不上、连接被重置）自动重试两次，间隔 1s、3s；
- 凭据类失败仍向上抛：这类失败必须提示用户重新绑定，不能静默。

注册表本身不启动 Controller 或请求网络。学习卡片仍在挂载时调用 `ensureStarted()`，
详情页与卡片继续共享各模块的单例状态。

## 依赖方向

**约定**（目的：任何小程序都能独立增删）：

- `mini_apps/*` 只能 import `core/*` 和第三方包；**不得** import `shell/*` 或其他小程序
- `shell/*` 应当只 import `core/*` 和 `mini_apps/registry.dart`，不感知具体小程序
- 跨小程序共享的组件才进 `core/`，且尽量少加

**现状**（别照抄约定当现实）：

- ✅ `mini_apps/*` 侧完全合规：没有任何一处 import `shell/*` 或兄弟小程序
- ⚠️ 壳侧**有三处合法例外**：
  - `shell/profile/portal_bind/portal_status_page.dart` import 了 `student_info` 的模型与存储，
    用于展示学生身份；还 import 了 `TimetableController`，在登录成功、解绑时通知课表
  - `router.dart` 仍直接 import 地图地物详情、课表特殊入口和通用 WebView 承载页
  - `app.dart` import 了课表的 `TimetableWeeklyClasses` 与 `TimetableLifecycleScope`，
    启动时登记为 `WeeklyClasses.source` 并挂上课表生命周期

  `shell/home/home_page.dart` 和 `shell/study/study_page.dart` 都只通过注册表接入小程序。

**只有第一条有工具强制**：CI 的「Check dependency direction」步骤会检查 `mini_apps/*` 的 import；
其余两条仍靠人工 review（`analysis_options.yaml` 里 `linter.rules` 是空的，也没有自定义 lint）。

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
- **明暗模式默认跟随系统**，也可以在「我的 → 设置」里手动选浅色或深色。
  选择由 `AppThemeMode`（`lib/core/theme_mode.dart`）持有并存到应用支持目录的
  `settings/theme_mode`，`NuistApp` 监听它切换 `themeMode`
- `colorScheme` 由 `ColorScheme.fromSeed` 生成后覆盖 `primary` / `surface` / `error`，
  所以 `colorScheme.primary` 就是品牌色，不再是 M3 默认紫
- **取色一律用 `AppPalette.of(context)`**（`lib/core/colors.dart`），它是挂在
  `ThemeData.extensions` 上的 `ThemeExtension`，随当前主题明暗返回对应色值：
  `pageBg` / `surface` / `titleText` / `labelText` / `hint` / `rowDivider` / `accent` /
  `tabInactive` / `divider` / `chevron` / `success` / `warning` / `danger`，另有
  `brightness` 与 `isDark`。取不到扩展时退化成浅色，不抛异常
- `AppColors` / `AppColorsDark` 是浅色、深色两套 `static const` 基准值，
  **只用于构造主题**，业务代码不要直接引用
- 小程序私有配色同样按明暗取值：课表用 `TimetableTheme.colorsOf(context)`
  （返回 `TimetableColors`），电费用 `ElecColors.of(palette)`，空教室用
  `ClassroomFillColors`，校园地图用 `MapPalette.of(context)`
- 没有自定义字体

主题在 `lib/core/theme.dart` 里，`appLightTheme()` / `appDarkTheme()` 两个函数，
测试里可直接复用（见 `test/dark_theme_test.dart`、`test/score_page_test.dart`）。

少数颜色**刻意不跟随主题**，都在代码里写了中文注释说明原因：

- 贴在品牌色实心块上的白字白图标（底色本身不随主题变）
- 导出页的二维码（必须浅底深码才扫得出）、扫码页（相机取景框固定深色）
- 电费折线图的 tooltip（固定深底白字）
- 校园地图：底图 tile、`campus_map_native.dart` 里的自绘图层色与
  `assets/map_layers/*.png` 图例都是浅色素材，深色底图需服务端提供，
  所以底图和压在底图上的状态栏图标维持浅色；面板、浮层、弹层等界面外壳跟随主题
- WebView 承载的网页（H5 小程序、公告详情、门户登录绑定）是学校自己的页面，
  只适配容器层（顶栏、进度条、加载态、错误页），不注入 CSS / JS 反色

## 自有服务请求与公告缓存

公告、贡献者、WakeUp 分享和同域头像通过 `core/network/owned_api_client.dart` 的
`createOwnedApiDio()` 请求自有服务。初始请求只允许访问 `api_endpoints.dart` 配置的 HTTPS 原点，
按协议、精确主机和端口检查，拒绝带用户信息的地址；添加客户端元数据，不复用门户 Cookie。
重定向遵循 Dio 默认行为及调用方配置。已有外部头像仍通过不带设备头的图片加载路径处理。

`ClientMetadataProvider` 惰性读取并在进程内缓存包名、版本、渠道与 Android 信息。
渠道由 `APP_CHANNEL` 构建参数显式指定为 `release/dev/ci`，本地默认 `dev`；
不能由 Flutter 的 release/debug 模式或包名猜测。非法渠道省略且记录安全的诊断事件。
原生通道 `nuist/client_metadata` 在后台读取受限的厂商属性，返回可识别的 ROM 名称和
市场版本，以及不包含包名和渠道的 SSAID 派生值；不把原始 Android ID、完整固件字符串或系统指纹传回 Dart。
元数据单项不可用时省略，不阻断业务。没有采集开关，字段与用途见 [隐私说明](../PRIVACY.md)。

标识类型为 `ssaid_sha256_v1`，计算方式是 `SHA256('nuist-sta:ssaid:v1:' + canonicalSSAID)`；
服务端直接保存客户端标识，不再进行二次 HMAC 或哈希。相同标识跨包名、渠道去重，应用版本
仍按包名、渠道分别保存。Android SSAID 也受签名影响，因此不保证不同签名的构建共用标识。

ROM 解析接受 OriginOS Ocean 这一明确市场代号，其余版本仍按受限数字格式处理。
ANCO 环境优先于普通 ROM 判断，类别为 `HarmonyOSNEXT`；从宿主软件版本属性提取鸿蒙
版本，去掉机型、构建号与补丁后缀，不从 Android 版本或兼容层 API 编号反推宿主版本。
这个类别表示鸿蒙的 Android 兼容环境，不能仅凭这些属性区分卓易通和出境易。
属性与真实样例参考 [DeviceCompat 源码](https://github.com/getActivity/DeviceCompat/blob/main/library/src/main/java/com/hjq/device/compat/DeviceOs.java)、
[OriginOS 样例](https://github.com/getActivity/DeviceCompat/issues/6) 和
[ColorOS 版本讨论](https://github.com/getActivity/DeviceCompat/issues/10)；这些属性并非厂商保证稳定的公开 API。

公告的版本范围由服务端按数字 versionCode 判断。客户端只处理过期、排序、已读及阻断公告
到期释放，不再比较版本字符串。公告缓存包含格式版本和平台、包名、渠道、versionCode 变体；
先取得完整上下文，再复用匹配缓存及其条件请求头。升级、渠道变化、旧格式或上下文缺失时不
展示旧缓存，离线也不退回其他版本的公告。无缓存却收到 304 时最多补一次无条件请求。
服务端筛选后没返回某个 ID 不代表该公告已删除，因此已读记录独立保留。

## 校园 VPN 网络请求

需要访问校内网络接口时，使用 `lib/core/network/vpn_dio.dart` 提供的 `vpnDio()`，
不要直接修改全局 Dio 或手动管理 VPN 隧道。它返回普通的 `Dio`，请求、JSON、表单和下载
仍按 Dio 的方式调用：

```dart
import 'package:dio/dio.dart';
import 'package:nuist_sta_app/core/network/vpn_dio.dart';

final client = vpnDio(
  options: BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 20),
  ),
);

try {
  final response = await client.get<Map<String, dynamic>>(
    'https://internal.example/api/data',
  );
  final data = response.data;
} finally {
  client.close(force: true);
}
```

默认选路规则如下：

- `forceVpn: false` 时，校园网检测结果为 `onCampus` 才直连；结果为 `offCampus` 或
  `unknown` 时走 VPN。当前未配置全局校园网检测器，因此默认走 VPN。
- 客户端需要始终走 VPN 时使用 `vpnDio(forceVpn: true)`。
- 只强制某一次请求走 VPN 时，在 `Options.extra` 中设置导出的 `forceVpnKey`；这个字段
  只在本地选路，不会发送给服务器：

```dart
final response = await client.get<String>(
  url,
  options: Options(
    extra: <String, Object?>{forceVpnKey: true},
  ),
);
```

`vpnDio()` 创建的客户端分别维护直连和 VPN 的连接池。调用方创建了客户端就负责在不用时
调用 `close()`；小程序 API 若接收外部注入的 `Dio`，只有自己创建的实例才应关闭，参考
`CampusMapApi` 的 `_ownsDio` 写法。仅支持 `http` 和 `https` URL，VPN 连接失败不会自动
降级为直连，也不会重放请求体。

首次真正发起 VPN 请求时才会加载原生库并完成 VPN 认证，因此使用前必须已经绑定统一门户。
未绑定或凭据失效会抛出 `PortalCredentialError`，登录流程失败会抛出 `PortalLoginError`，
网络连接问题仍按 Dio / `PortalNetworkError` 处理；业务层不要把所有异常都当成需要重新绑定。

## 日志与诊断

统一入口位于 `lib/core/logging/app_log.dart`。Controller 记录可信的最终结果，API 记录阶段与
协议判定，Store 记录损坏及降级；组件重建、滚动和普通筛选不创建业务日志。
开发与正式构建均本地留存完整脱敏诊断，控制台默认展示关键步骤与结果摘要。
DevTools 详情、应用内展开与导出使用相同字段；保留完整错误原因链及原始堆栈，不裁剪 AOT 帧。
业务失败详情直接带入当前 Span 子树的原始交流和输入证据，不要求用户另找一条 HTTP 日志。
共享登录只向等待者转交相应登录证据，不能混入生产者其他业务的正文；同一响应按精确引用去重。
DevTools 用单一 message 承载摘要与详情，不将普通诊断文本放进 VM 的 error/stackTrace 对象字段。
Android `logcat` 沿用 `flutter.NUIST++` 和原生级别，长行分片。

一次业务操作创建 Trace，内部阶段使用 Span。`SilentRefresh` 记录总耗时、单次尝试、重试原因和
退避等待；批量刷新依据实际结果统计，不能用 Future 正常返回推断刷新成功。
`operation` 支持 `outcomeForResult`，子步骤可通过 `AppLog.reportOutcome` 报告降级、跳过等结果。
凭据失效、HTTP 拒绝、响应结构改变、业务拒绝和本地保存失败必须区分。
异常包装实现 `DiagnosticError`，携带 cause、causeStackTrace、固定原因码和阶段；
TLS/VPN 保留原始错误描述、原生阶段、系统错误码。业务可以恢复或回退，但不能吞掉诊断依据。
Trace/Span 只用于本机，不向学校或其他服务添加追踪请求头。

`http_diagnostics.dart` 在最终 Dio 适配器上旁路复制请求和响应流，在 JSON 转换前采集。
同一请求的准备、VPN 与正文使用相同编号和 Span；不重放请求或改变证书信任策略。
完整详情包括地址、请求头、请求体、状态、响应头及正文，文本保留原文，二进制使用 base64。
JSON 解码失败也保留收到的实体内容。流中断、读取取消、自动重定向中间正文不可见等情况
显式标记完整性和缺失原因。采集到的是 HTTP 客户端处理后的实体，不是 TLS 加密前的网络抓包。
AIA 补证书请求和 Android 更新另接诊断出口；原生下载完成后从可信文件读取快照。
门户落地缓存保存原登录响应的日志引用，不把正文重复写入凭据存储。命中缓存时记录实际落地地址、
来源和授权参数检查结果；需要原文时按引用读取。旧缓存无引用、日志已清理或附件丢失时明确说明，
不得用最近一次响应代替真实来源，也不得把不存在的余额请求说成已有响应。

WebView 的 `WebDiagnostics` 观察加载终态及注入后可见的 fetch/XHR，分片在内存重组后统一脱敏。
当前平台不提供主文档和原生子资源的完整网络正文，脚本看不到注入前、跨域帧及 worker 请求；
这些覆盖缺口写入日志，不能用 DOM 快照或另发请求冒充原始响应。原生更新在没有 Flutter 监听时
记录采集缺口，既有任务状态仍持久化。
提醒和小组件的系统广播故障写入本机原生诊断队列，最多 64 条、最长七天，超量淘汰数量明确记录。
启动、回前台及导出前通过现有日志通道读取；逐条写入日志成功后才确认移除，保留原事件时间。
原生队列在保存前清洗系统错误和 JSON 解析消息，移除可能包含课程源内容的片段；用户清除日志时
同时清除此队列。同步 MethodChannel 调用沿用原回执，保留完整异常链与堆栈，避免重复入队。

`diagnostic_redactor.dart` 负责凭据、设备标识和可识别个人字段的定点遮蔽，保留非敏感正文。
JSON（包括嵌套字符串）、表单、URL 认证参数与 HTML 表格/控件分别处理，正文不做长度截断。
私钥上下文额外标记 `secret_context`，异常保留类型、阶段和堆栈，禁止将密钥解析器的源内容输出。
摘要指标采用类型和范围校验，完整上下文放入 `details`；读取旧记录和导出时重新检查。
日志和导出不自动上传，不引入遥测或崩溃上报服务。

事件索引使用 JSON Lines：每文件最多 512 KiB，四个文件约 2 MiB。超过 64 KiB 的完整记录
另存为压缩附件，索引保留引用；附件按未压缩字节计入 64 MiB 预算，超限按关联操作清理。
最近单条正文超过预算时保留完整该条并标明超限；活跃操作已有历史被淘汰时，后续记录明确标明缺口。
最长留存七天，索引轮转后孤立附件一并清理。写入、维护、快照、导出和清除共享串行队列。
附件读取失败保留摘要并明确显示内容缺失；不得静默以摘要代替完整诊断。
导出为包含附件内容的单文件快照，导出副本保留最多三个、最长一天，并受总容量限制。
清除同时删除索引、附件和导出副本。

「关于」页版本号五连击解锁诊断入口，三十分钟详细模式影响控制台输出，不影响诊断正文保存。
应用内可按模块/级别筛选最近三百条匹配事件，并查看同一操作的跨模块阶段。
大正文逐步展开以限制布局开销，复制与导出使用完整内容；支持明暗主题与大字体。

## 已知架构债

如实列出，不是「规范」，是「将来要还的账」：

1. **依赖方向只有部分工具强制**。CI 只检查了 `mini_apps/*` 一侧；`shell/*` 的约定和 `core/` 的准入仍靠 review 把关。
2. **`_RefreshButton` 在七个卡片文件里各写了一份私有同名类**（`academic` / `student_info` /
   `score` / `innovation_credit` / `labor_score` / `timetable` / `electricity`），没有上收到 `core/`。
3. **`lib/core/auth/` 测试覆盖不全**。目前只有 `NuistLogin`、`PortalCookieManager` 和学号掩码有单元测试，
   `PortalSession`、`PasskeyTransfer` 等仍没有。

## 测试

`test/widget_test.dart` 是冒烟测试，守护注册约束与主要页面入口：

- 注册表 `id` 全局唯一（重复会导致 `/apps/:id` 路由冲突）
- 有入口的 manifest 恰好提供 `entry` 或 `url` 之一；仅卡片模块不进入宫格或入口索引

`test/study_registry_test.dart` 覆盖学习卡片注册、排序、增删及刷新分发，验证并发刷新会等待
全部回调，单项同步抛错不影响其余回调启动，以及仅卡片模块和未知 id 的路由兜底。

另外它还用 `findsOneWidget` 断言了若干界面文案（首页宫格、学习页五张卡片标题、我的页
「设置」「关于」等）。**副作用：新增小程序的 `label` 不能与现有重名**，否则这些断言会挂。

CI 要求依赖方向与敏感字面量检查通过、启动图标与源图一致、`cargo test` 通过、`dart format` 无差异、
`flutter analyze` 零警告、`flutter test`（含加载本机 VPN 动态库的 FFI 测试）全绿，没有覆盖率门槛。

## 相关文档

- [新增一个小程序](mini-app-guide.md)
- [统一门户登录](portal-auth.md)
- [校园地址与密钥](configuration.md)
- [路线图与架构债排期](roadmap.md)
