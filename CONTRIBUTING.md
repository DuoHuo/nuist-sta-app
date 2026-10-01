# 贡献指南

欢迎参与 NUIST++。项目采用“壳 + 注册表 + 小程序”的结构，功能可以由不同成员独立开发，
再通过注册表接入主应用。本文只保留开发、检查和协作所需的约定。

## 开始之前

### 环境要求

- Flutter 3.47.4，stable channel
- Android SDK 和 NDK，NDK 版本跟随 Flutter 工程配置
- Rust 1.90.0，通过 `rustup` 安装
- Android 开发需要 Android arm64 设备或 arm64 模拟器，不支持 x86 模拟器
- Windows 本机运行 Rust 测试还需要 Visual Studio C++ Build Tools 和 Windows SDK

首次进入 `native/vpn` 并运行 `cargo --version` 时，`rustup` 会按照
`rust-toolchain.toml` 安装固定工具链和 `aarch64-linux-android` target；首次安装需要联网。

检查 Flutter 版本并拉取依赖：

```bash
flutter --version
flutter pub get
```

开发构建的包名带 `.debug` 后缀（`dev.duohuo.nuist_sta_app.debug`），可以与正式包共存。

### 运行与构建

```bash
flutter run
flutter test
flutter build apk --target-platform android-arm64
```

Android 构建会通过 NDK 从源码编译并打包校园 VPN 动态库。

### Rust 和 FFI

在 `native/vpn` 下执行 Rust 命令，以使用项目固定的工具链：

```bash
cd native/vpn
cargo test --locked --target-dir ../../build/rust-host
cargo build --locked --target-dir ../../build/rust-host
cd ../..
```

第二条命令生成本机动态库。使用以下命令启用默认跳过的真实 FFI 测试：

```bash
# Linux
flutter test --dart-define=VPN_NATIVE_LIBRARY=build/rust-host/debug/libnuist_vpn.so

# Windows
flutter test --dart-define=VPN_NATIVE_LIBRARY=build/rust-host/debug/nuist_vpn.dll

# macOS
flutter test --dart-define=VPN_NATIVE_LIBRARY=build/rust-host/debug/libnuist_vpn.dylib
```

这些测试使用合成网关，只验证本地协议和 FFI，不代表学校真实 VPN 一定可用。

## 项目结构

```text
lib/
├── core/               # 壳与所有小程序共用的能力，如统一门户登录
├── shell/              # 首页、学习页、我的页等大 APP 壳
├── mini_apps/          # 每个小程序一个自包含目录
│   └── registry.dart   # 全量注册表：新增小程序通常只需登记一行
├── app.dart            # MaterialApp.router 和主题
└── router.dart         # go_router 路由表
```

详细的路由、状态管理、网络和架构债说明见[架构文档](docs/architecture.md)。

## 新增小程序

优先阅读[新增一个小程序](docs/mini-app-guide.md)。小程序有两条接入路径：

- 原生 Flutter：适合需要统一体验、复杂交互或离线能力的功能
- H5：适合 Web 技术栈开发，由通用 WebView 承载

必须遵守以下边界：

- `lib/mini_apps/<app>/` 只能依赖 `lib/core/` 和第三方包
- 小程序不得 import `lib/shell/` 或其他小程序
- 需要登录的接口统一使用 `PortalSession`，不要自行实现登录
- `entry` 与 `url` 必须恰好提供一个
- `id` 全局唯一，`label` 不要与已有小程序重名
- Store 的读写必须 `try/catch`，失败时退化为没有存储
- 进入小程序使用 `context.push('/apps/<id>')`，不要使用 `go`

## 提交前检查

CI 要求以下检查通过：

```bash
dart format lib test
flutter analyze
flutter test
```

此外，CI 还会检查小程序依赖方向、commit 格式，并编译 Android arm64 debug APK。
提交前本地跑完这些命令，可以尽早发现问题。

## 代码约定

- 遵循 `dart format` 默认风格
- 注释和公开 API 文档使用中文；公开的类和方法写 `///` 文档注释
- `lib/` 内部使用相对路径 import
- 品牌色使用 `AppColors`，不要把 Material 3 默认的 `colorScheme.primary` 当作品牌色
- Controller 使用 `ChangeNotifier` 单例和幂等的 `ensureStarted()`
- API 层负责网络和解析，Store 层负责本地 JSON，页面层不直接处理这些细节
- 日志只允许在 debug 构建输出，不得打印 Cookie、ticket、私钥、学号等敏感信息
- 不新增遥测、崩溃上报、统计 SDK 或学校业务系统之外的网络出口

新增或升级第三方依赖前，先在 PR 中说明理由，并同时提交 `pubspec.yaml` 和 `pubspec.lock`。
不要顺手执行 `flutter pub upgrade`。

## Commit 与分支

一个 commit 只做一件事，格式如下：

```text
<type>(<scope>): <中文摘要>
```

常用 `type`：

| type | 用途 |
|---|---|
| `feat` | 新功能或用户可感知的改进 |
| `fix` | 修复问题 |
| `docs` | 只改文档 |
| `refactor` | 不改变行为的重构 |
| `test` | 只改测试 |
| `build` / `ci` | 构建、依赖或 CI 配置 |
| `chore` | 其他维护工作 |

摘要使用中文，简洁说明用户能感知的变化，不加句号。发版以外不要使用 `chore(release)`。

示例：

```text
feat(free-classroom): 支持按楼层筛选
fix(electricity): 修复只有一条记录时折线图不显示
docs: 补充新增小程序指南
```

分支名建议使用 `<type>/<简述>`，例如 `feat/score-query`、`fix/electricity-chart`。
默认从 `main` 切分支并通过 PR 合并；小改动也要保持同样的检查和提交格式。

## PR 与安全

- 一个 PR 只处理一个主题，标题使用 commit 格式
- PR 描述写清动机、行为变化、测试结果和已知限制
- 发现安全漏洞不要公开 Issue，请先私下联系维护者
- 签名密钥、`*.nuistkey`、Cookie、`.env` 和真实个人数据不得进入仓库
- 测试夹具必须脱敏，涉及学号、姓名、成绩等内容时使用合成数据

## 发版

仅维护者执行：

1. 将 `pubspec.yaml` 的版本改为 `x.y.z+N`，每次发版递增 `N`
2. 提交 `chore(release): vX.Y.Z`
3. 创建并推送 tag：`git tag vX.Y.Z && git push origin main vX.Y.Z`
4. `build-release.yml` 会自动构建、生成 release notes 并发布到 Releases

## 相关文档

- [架构文档](docs/architecture.md)：目录、路由、状态管理、网络和已知架构债
- [新增一个小程序](docs/mini-app-guide.md)：原生与 H5 的接入步骤
- [统一门户登录](docs/portal-auth.md)：登录状态、异常类型和安全边界
- [路线图](docs/roadmap.md)：待开发功能和排期
