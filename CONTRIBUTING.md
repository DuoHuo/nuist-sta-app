# 贡献指南

欢迎参与。这份文档只写**硬约束**，不搞仪式 —— 项目还在早期，流程越轻越好。

## 开始之前

需要 **Flutter 3.47.4**（stable channel），与 CI 钉的版本一致。查看本地版本：

```bash
flutter --version
```

然后拉依赖：

```bash
flutter pub get
```

## 提交前必做

```bash
flutter analyze   # 必须零警告
flutter test      # 必须全绿
```

CI 查的就是这两条，外加编译一个 debug APK（`--target-platform android-arm64`）。
本地先跑一遍能省一轮等待。

## Commit 规范

**这不是风格偏好，是工程耦合 —— 请务必遵守。**

发布时，`.github/workflows/build-release.yml` 会按 commit 前缀把提交自动分到 release
notes 的各个章节：

| 前缀 | 归入章节 |
|---|---|
| `feat:`、`feat(scope):` | **Features** |
| `fix:`、`fix(scope):` | **Fixes** |
| `docs:`、`docs(scope):` | **Documentation** |
| `refactor:`、`perf:` | Other Changes |
| 其他（含 `chore:`） | Other Changes |

写错前缀不会报错，但你的改动会掉进 "Other Changes"，用户在 release 页面上就看不到它。

示例：

```
feat(free-classroom): 支持按楼层筛选
fix(electricity): 修复折线图在只有一条记录时不显示
docs: 补充新增小程序指南
```

另外：**除发版外，禁止使用** `chore(release)` 开头的 commit

## 分支与 PR

- 从 `main` 切分支开发，不要直接推 `main`
- PR 走仓库的 PR 模板，逐项确认

## 代码约定

### 依赖方向（最重要的一条）

切分成「壳 + 小程序」的目的，是**让小程序可以独立增删、并行开发、合并互不冲突**。
为了保住这一点：

- `mini_apps/*` 只能 import `core/*` 和第三方包；**不得** import `shell/*` 或其他小程序
- 跨小程序共享的组件才进 `core/`，且尽量少加 —— 别让 `core/` 变成垃圾场

> `shell/*` 侧目前在**学习页卡片**和**门户状态页**上有几处直接 import 具体小程序的例外，
> 这是已知的架构债（见 [架构文档](docs/architecture.md#已知架构债)），**不要**把它当成
> 可以照着扩展的模式。

这些规则**没有工具强制**，纯靠 review 把关，请自觉。

### 注册表

- `id` 必须全局唯一 —— `test/widget_test.dart` 会自动守护
- `entry` 与 `url` 必须**恰好提供一个** —— 构造断言会拦
- **新增小程序的 `label` 不能与现有重名** —— `widget_test.dart` 里有若干
  `findsOneWidget` 文案断言，重名会让它们挂掉

### 新增一个小程序

见 [新增一个小程序](docs/mini-app-guide.md)。里面有一份提交前检查清单。

## 报告问题

- **Bug**：用仓库的 bug report 模板，尽量写清复现步骤和机型 / 系统版本
- **新功能想法**：可以先开 Issue 聊，也可以直接看 [路线图](docs/roadmap.md) 认领

涉及学号、Cookie、私钥等敏感信息时，**发 Issue 前务必打码**。
