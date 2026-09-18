# nuist-sta-app

NUIST赛博分院帽 - 众社团共建

## TO-DO

- [x] 首页框架（Flutter，Android 优先）
  - 顶栏居中标题（`APP名称` 为占位，定稿后改 `lib/core/app_info.dart` 里的 `kAppName` 一处即可）
  - 应用宫格卡片：按小程序注册表渲染、数据驱动（见下文「前端架构」）
  - 底部双页签：首页 / 我的
- [ ] 校园地图页面（入口链路已打通，页面为占位）
- [x] 我的页面（基础版：用户登录卡片 + 我的社团/我的活动/设置/关于）
- [x] 前端架构：大 APP 壳 + 小程序注册表（原生 Flutter 为主，预留 H5/WebView 小程序）
- [ ] 分院帽
- [ ] 成绩查询/通知
- [ ] 教务实时课表显示 -> 能抄早期开源的wakeup吗...?
      考试安排也进课表
- [ ] 小公交位置实时显示
- [ ] 实时电费/历史电费
- [ ] 空教室显示/更易用的筛选
- [ ] 南信大邮箱(虽然好像用处不是非常大 而且推送是个问题 或者不做推送 拉取到未读邮件的话直接显示在首页)
- [ ] 以关键词/类目订阅信息公告栏

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
│   └── app_manifest.dart      # AppManifest：小程序描述（id/名称/图标/入口）
├── shell/                     # 大 APP 的壳（社团一般不用动）
│   ├── root_page.dart         # 底部双页签
│   ├── home/                  # 首页宫格
│   └── profile/               # 我的页面
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
