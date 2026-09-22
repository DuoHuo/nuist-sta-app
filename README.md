# NUIST++

南信大校园服务 App。大 APP 壳 + 小程序注册表架构，由社团共建。

> **非官方项目**，与南京信息工程大学无关。详见文末[免责声明](#免责声明)。

[![Flutter CI](https://github.com/DuoHuo/nuist-sta-app/actions/workflows/ci.yml/badge.svg)](https://github.com/DuoHuo/nuist-sta-app/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/DuoHuo/nuist-sta-app)](https://github.com/DuoHuo/nuist-sta-app/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/DuoHuo/nuist-sta-app/total)](https://github.com/DuoHuo/nuist-sta-app/releases)

## 功能

| 模块 | 说明 |
|---|---|
| **空教室查询** | 按教学楼 / 日期查教务占用，支持按时段、楼层、教室类型本地筛选，并给出逐节占用详情 |
| **宿舍电费** | 实时余额 + 历史用量折线图，支持多校区多楼栋选宿舍 |
| **学业概览** | GPA、已修学分、平均绩点、班级与专业排名 |
| **本学期** | 当前学期、周次与学期进度 |
| **双创学分** | 总分、成绩评定与已认定项目明细 |
| **劳动积分** | 官方核算总分与四个分项，详情页可与各分项实时统计对照 |

以上模块都通过**统一门户**取数：绑定一次，之后静默复用登录态，不用反复登录。

更多想法和排期见[路线图](docs/roadmap.md)。

## 下载安装

前往 **[Releases](https://github.com/DuoHuo/nuist-sta-app/releases/latest)** 下载最新 APK。

- **仅支持 Android arm64**（`arm64-v8a`）—— CI 只编译这一个 ABI
- 安装时系统会提示「未知来源应用」，需要在设置里允许
- 没有上架任何应用商店，Releases 是唯一的分发渠道

## 本地运行

```bash
flutter pub get
flutter run            # 连接设备或模拟器
flutter test           # 运行测试
flutter build apk      # 构建 APK
```

需要 **Flutter 3.47.4**（stable），与 CI 一致。

> **⚠️ 路径坑**：有队友反馈 Dart 分析服务器对含中文或 OneDrive 同步目录的路径支持不佳，
> `flutter analyze` 会直接崩溃。遇到的话把仓库挪到纯英文路径（如 `C:\dev\nuist-sta-app`）。

开发时本地构建的包名会带 `.debug` 后缀（`dev.duohuo.nuist_sta_app.debug`），
和正式包**可以共存**，不用先卸载。

## 项目结构

整体是「**壳 + 注册表 + 小程序**」三层。壳（底部页签 + 宫格首页）固定不变；
每个小程序是 `lib/mini_apps/` 下一个自包含目录，在注册表登记一行就上宫格。

```
lib/
├── core/         # 壳与所有小程序共用（含 core/auth/ 统一门户登录）
├── shell/        # 大 APP 的壳：首页 / 学习 / 我的
├── mini_apps/    # 所有小程序，每个一个目录
│   └── registry.dart    # ★ 全量注册表：新增小程序只改这里
├── app.dart      # MaterialApp.router + 主题
└── router.dart   # go_router 路由表
```

这样切分是为了让**小程序可以独立增删、并行开发、合并互不冲突**。

细节见 [架构文档](docs/architecture.md)。

## 参与贡献

欢迎社团同学一起做，不会 Flutter 也能参与（H5 小程序路线）。

- 先读 **[贡献指南](CONTRIBUTING.md)**（环境、commit 规范、代码约定）
- 想加功能？看 **[新增一个小程序](docs/mini-app-guide.md)**
- 想认领任务？看 **[路线图](docs/roadmap.md)**

## 文档

| 文档 | 内容 |
|---|---|
| [架构](docs/architecture.md) | 三层结构、路由、AppManifest、状态管理约定、已知架构债 |
| [新增一个小程序](docs/mini-app-guide.md) | 原生 / H5 两条接入路径与检查清单 |
| [统一门户登录](docs/portal-auth.md) | PortalSession 状态机、异常体系、安全边界 |
| [路线图](docs/roadmap.md) | 待开发功能、已知缺口 |

## 免责声明

- 本项目是**学生自发开发的非官方工具**，与南京信息工程大学及其任何下属部门无关
- 所有数据来自学校各业务系统的公开接口，**仅供学习交流**，请勿用于商业用途
- 你的学号、密码等凭据**不会经过本项目**：绑定门户时登录在学校自己的页面完成，
  只有 Passkey 私钥保存在本机安全存储里（Android Keystore / iOS Keychain），
  项目**不含任何遥测或数据上传**
- 使用本软件产生的任何后果由使用者自行承担
- 接口随时可能因学校系统调整而失效，恕不保证可用性

## LICENSE

To be determined.