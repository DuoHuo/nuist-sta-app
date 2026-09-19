# nuist-sta-app

NUIST赛博分院帽 - 众社团共建

## TO-DO

- [x] 首页框架（Flutter，Android 优先）
  - 顶栏居中标题（`NUIST STA` 为占位，定稿后改 `lib/core/app_info.dart` 里的 `kAppName` 一处即可）
  - 应用宫格卡片：按小程序注册表渲染、数据驱动（见下文「前端架构」）
  - 底部双页签：首页 / 我的
- [ ] 校园地图页面（入口链路已打通，页面为占位）
- [x] 我的页面（基础版：用户登录卡片 + 我的社团/我的活动/设置/关于）
- [x] 绑定统一门户（我的 → 内嵌门户登录 → 自动注册软件 Passkey → 私钥存本机安全存储，
      凭据格式与 `authserver_login/passkey.local.json` 一致；后续 APP 内免二次验证登录靠它）
  - 状态页显示绑定学号/设备名/绑定时间，支持重新绑定与解除绑定，
    debug 构建下多一个「测试登录」按钮可验证凭据是否仍有效
- [x] 统一门户登录服务（`core/auth/`，`authserver_login/NuistLogin.py` 的 Dart 移植）：
      纯网络层 Passkey 登录，不开 WebView；会话落盘复用、CAS 票根复用、失效自动重登，
      壳与所有小程序共用，见下文「取用门户登录态」
- [x] 前端架构：大 APP 壳 + 小程序注册表（原生 Flutter 为主，预留 H5/WebView 小程序）
- [ ] 分院帽
- [ ] 成绩查询/通知
- [ ] 教务实时课表显示 -> 能抄早期开源的wakeup吗...?
      考试安排也进课表
- [ ] 小公交位置实时显示
- [x] 实时电费/历史电费
- [ ] 空教室显示/更易用的筛选
- [ ] 南信大邮箱(虽然好像用处不是非常大 而且推送是个问题 或者不做推送 拉取到未读邮件的话直接显示在首页)
- [ ] 以关键词/类目订阅信息公告栏
- [ ] 安卓桌面小组件 -> 显示课表/电费等？

## 前端架构：大 APP + 小程序

整体是「壳 + 注册表 + 小程序模块」三层。壳（底部页签 + 宫格首页）固定不变；
每个小程序是 `lib/mini_apps/` 下一个自包含目录，在注册表登记一行即上宫格，
点击进入全屏路由 `/apps/<id>`（小程序内不显示底部页签，返回键退回宫格）。

```
lib/
├── main.dart                  # 入口，仅 runApp
├── app.dart                   # NuistApp：MaterialApp.router + 主题
├── router.dart                # go_router：双页签壳 + /apps/:appId 全屏小程序路由
├── core/                      # 壳与所有小程序共用（尽量少放）
│   ├── app_info.dart          # kAppName
│   ├── colors.dart            # AppColors 设计稿色板
│   ├── wip.dart               # showWipSnackBar 开发中占位反馈
│   ├── app_manifest.dart      # AppManifest：小程序描述（id/名称/图标/入口）
│   └── auth/                  # 统一门户：Passkey 凭据 + 安全存储 + 登录服务（PortalSession）
├── shell/                     # 大 APP 的壳（社团一般不用动）
│   ├── root_page.dart         # 底部双页签
│   ├── home/                  # 首页宫格
│   └── profile/               # 我的页面（含 portal_bind/ 绑定统一门户）
└── mini_apps/                 # 所有小程序，每个一个目录
    ├── registry.dart          # ★ 全量注册表：新增小程序只改这里
    ├── campus_map/            # 校园地图（原生示例）
    └── web/                   # H5 小程序通用 WebView 承载页
```

### 如何新增一个小程序

**原生（推荐，体验统一、可离线）**

1. 建 `lib/mini_apps/<name>/` 目录，写入口页面 `<name>_page.dart`；
2. 同目录建 `<name>_manifest.dart`，导出一个 `AppManifest` 常量（`id` 全表唯一），
   参考 `campus_map/campus_map_manifest.dart`；
3. 在 `lib/mini_apps/registry.dart` 加一行。完事，宫格自动多一个图标。

**H5（不会 Flutter 的社团用任意 Web 技术栈交付）**

只需在 `registry.dart` 加一条带 `url` 的 `AppManifest`，点击后由
`mini_apps/web/mini_web_view_page.dart` 通用承载页打开。

### 取用门户登录态

需要教务、电费这类登录后才能访问的接口时，不要自己搓登录流程，用
`core/auth/portal_session.dart` 的全局会话。它首次调用时用本机 Passkey 登录，
之后复用会话（换 service 走 CAS 票根快路径，省掉一次签名）；会话落盘保存，
重开 APP 一般不用重登；万一过期会自动重登一次并重放请求。

原生小程序：

```dart
final response = await PortalSession.instance.request(
  PortalServices.jwxt,                    // CAS 的 service 参数，按精确匹配校验
  (http) => http.get(Uri.parse('https://jwxt.campus.invalid/...')),
);
```

H5 小程序：在注册表那条 `AppManifest` 上加 `requiresPortal: true`，承载页会先把
会话 Cookie 灌进 WebView 再加载页面，网页里直接就是登录态。

失败分三类，按 `PortalException` 的子类判断：`PortalNetworkError`（网络问题，
可重试）、`PortalCredentialError`（通行密钥被吊销，需引导用户重新绑定）、
`PortalLoginError`（其他）。请务必把前两类区分开——把没网说成「需要重新绑定」
会让用户白跑一趟去重绑。

### 依赖规则（协作约定）

- `mini_apps/*` 只能 import `core/*` 和第三方包；**不得** import `shell/*` 或其他小程序
  ——保证任何小程序可以独立增删，合并互不冲突；
- `shell/*` 只 import `core/*` 和 `mini_apps/registry.dart`，不感知具体小程序；
- 跨小程序共享的组件才进 `core/`，且尽量少加，避免 core 变垃圾场；
- 注册表 `id` 唯一性由 `test/widget_test.dart` 自动守护。

## 如何运行

```bash
flutter pub get
flutter run          # 连接设备或模拟器
flutter test         # 运行测试
flutter build apk    # 构建 release APK
```

> 注意：Dart 分析服务器对含中文/OneDrive 同步目录的路径支持不佳
> （`flutter analyze` 在此类路径下会直接崩溃），
> 建议将仓库克隆/复制到纯英文本地路径（如 `C:\dev\nuist-sta-app`）再开发。

## 设计稿

`design/home.op` 为设计稿（OpenPencil 格式），含「首页」「我的」两个页面。
