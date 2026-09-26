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

建议把 `git pull` 默认改成 rebase，免得本地有提交时 pull 出一个无意义的合并提交：

```bash
git config pull.rebase true
```

## 提交前必做

```bash
dart format lib test   # 格式化，CI 会检查有没有遗漏
flutter analyze        # 必须零警告
flutter test           # 必须全绿
```

CI 查的就是这三条，另外还会：

- 检查小程序的依赖方向（见[依赖方向](#依赖方向最重要的一条)）
- 逐个检查 commit 的格式与提交身份（见 [Commit 规范](#commit-规范)）
- 编译一个 debug APK（`--target-platform android-arm64`），在 Actions 运行页的 **Artifacts** 里可以下载，保留 14 天

本地先跑一遍能省一轮等待。

## Commit 规范

**这不是风格偏好，是工程耦合 —— 请务必遵守。** CI 会逐个检查，不合格直接红。

```
<type>(<scope>): <中文摘要>
```

### type

发布时，`.github/workflows/build-release.yml` 会按前缀把提交自动分到 release notes 的各个章节：

| type | 用途 | 归入章节 |
|---|---|---|
| `feat` | 新功能、用户能感知的改进 | **Features** |
| `fix` | 修 bug | **Fixes** |
| `docs` | 只改文档 | **Documentation** |
| `refactor` | 不改变行为的重构 | Other Changes |
| `perf` | 性能优化 | Other Changes |
| `test` | 只改测试 | Other Changes |
| `build` | 依赖、构建脚本、Android / iOS 工程配置 | Other Changes |
| `ci` | `.github/workflows/` | Other Changes |
| `style` | 纯格式调整 | Other Changes |
| `chore` | 其他杂项 | Other Changes |
| `revert` | 回滚 | Other Changes |

写错前缀，改动就会掉进 "Other Changes"，用户在 release 页面上就看不到它。

另外：**除发版外，禁止使用** `chore(release)` 开头的 commit（CI 会跳过这类提交）。

### scope

可以省略。要写就用 **kebab-case** 的模块名：

| 位置 | scope |
|---|---|
| 小程序 | `electricity` `free-classroom` `campus-map` `academic` `score` `student-info` `innovation-credit` `labor-score` `web`（有注册表 `id` 的与 `id` 一致，其余用目录名改 kebab-case） |
| 壳 | `home` `study` `profile` `portal-bind` `router` |
| 公共 | `auth`（`core/auth/`）、`core` |
| 工程 | `android` `ios` `deps` |

新模块照此类推。

### 摘要与正文

- 摘要用**中文**，一行说清**用户能感知的变化**，不加句号
- 一个 commit 只做一件事；不要用分号把多个前缀串在一条里（release 脚本只认第一个前缀）
- 保持简洁：一行摘要说得清就不写正文；正文只写"为什么这么改"
- 关联 Issue 时在正文末尾写 `Fixes #12`
- **在 GitHub 网页上直接编辑文件时，也要把默认的 `Update xxx.md` 改成规范格式**

示例：

```
feat(free-classroom): 支持按楼层筛选
fix(electricity): 修复折线图在只有一条记录时不显示
docs: 补充新增小程序指南
```

## 同步与分支

- **先同步，再提交**：commit 前先 `git fetch`，远程有新提交就 `git pull --rebase` 同步后再提交
- 分支名用 `<type>/<简述>`，如 `feat/score-query`、`fix/electricity-chart`
- 默认从 `main` 切分支开发、走 PR。目前不强制，小改动可以直接推 `main`，但同样要先同步再提交
- **不要改写别人可能已经拉取的提交**：`main` 禁止强推和删除（仓库规则已开启）；自己 PR 分支上的提交需要整理时（比如 CI 提示 commit 信息不合格），可以 rebase 后 `git push --force-with-lease`
- **同一个改动只提交一次**：不要既直推 `main`、又在功能分支上再提交一遍，分支合并后 `main` 上会出现两份

fork 的同学把主仓库加为 `upstream`，从它同步：

```bash
git remote add upstream https://github.com/DuoHuo/nuist-sta-app
git fetch upstream
git rebase upstream/main   # 分支还没推送过时；已经推送过就用 git merge upstream/main
```

## PR

- 走仓库的 PR 模板，逐项确认
- 标题同样用 commit 格式；一个 PR 只做一个主题
- PR 以 merge commit 方式合并（合并提交不会进入 release notes）

## 代码约定

### 依赖方向（最重要的一条）

切分成「壳 + 小程序」的目的，是**让小程序可以独立增删、并行开发、合并互不冲突**。
为了保住这一点：

- `mini_apps/*` 只能 import `core/*` 和第三方包；**不得** import `shell/*` 或其他小程序
- 跨小程序共享的组件才进 `core/`，且尽量少加 —— 别让 `core/` 变成垃圾场

> `shell/*` 侧目前在**学习页卡片**和**门户状态页**上有几处直接 import 具体小程序的例外，
> 这是已知的架构债（见 [架构文档](docs/architecture.md#已知架构债)），**不要**把它当成
> 可以照着扩展的模式。

`mini_apps/*` 这一条由 CI 检查，违反会直接红；`shell/*` 侧仍靠 review 把关，请自觉。

### 注册表

- `id` 必须全局唯一 —— `test/widget_test.dart` 会自动守护
- `entry` 与 `url` 必须**恰好提供一个** —— 构造断言会拦
- **新增小程序的 `label` 不能与现有重名** —— `widget_test.dart` 里有若干
  `findsOneWidget` 文案断言，重名会让它们挂掉

### 格式与写法

- 用 `dart format` 的默认风格（CI 会检查）
- 注释和文档用中文，公开的类和方法写 `///` 文档注释
- `lib/` 内部用相对路径 import
- 品牌色用 `AppColors`；`colorScheme.primary` 是 M3 默认紫，不是品牌色

### 日志与隐私

- 日志只在 debug 构建输出，**禁止**打印 Cookie、ticket、私钥、学号等敏感值
- **禁止**引入遥测、崩溃上报、统计类 SDK；除学校自己的系统外，不新增网络出口 —— README 对用户承诺过这一点

### 依赖

- 新增或升级第三方包要在 PR 里说明理由，`pubspec.yaml` 和 `pubspec.lock` 一起提交
- 不要顺手 `flutter pub upgrade`

### 新增一个小程序

见 [新增一个小程序](docs/mini-app-guide.md)。里面有一份提交前检查清单。

## AI 辅助开发

可以用 AI 写代码，但：

- **必须用你自己的 git 身份提交**，不能出现 `Codex <codex@local>` 这类代理身份
- commit 和 PR 里不要带 `Co-Authored-By: <AI>`、`Generated with …` 之类的署名，CI 会拦
- 提交前逐行审过，你对改动负全部责任

给代理的规程在 [`AGENTS.md`](AGENTS.md)：Codex、Cursor、Copilot 等会自动读取，Claude Code 通过
`CLAUDE.md` 导入。另外两份配置会拦截强推、跳过钩子等危险命令：

- `.claude/settings.json`：Claude Code 自动加载，还会关掉它的提交署名
- `.codex/rules/git.rules`：Codex 需要先把本项目标为「信任」才会加载

## 安全与隐私

- 凭据（签名密钥、导出的通行密钥 `*.nuistkey`、Cookie、`.env`）和真实个人数据（学号、姓名、成绩）**不能**进仓库；测试夹具必须脱敏
- 发现安全漏洞**不要**公开发 Issue，请先私下联系维护者

## 发版（仅维护者）

1. 把 `pubspec.yaml` 的 `version` 改成 `x.y.z+N`（`N` 每次发版 +1）
2. 提交 `chore(release): vX.Y.Z`
3. 在这个提交上打 tag 并推送：`git tag vX.Y.Z && git push origin main vX.Y.Z`
4. `build-release.yml` 会自动编译、生成 release notes 并发布到 Releases

## 报告问题

- **Bug**：用仓库的 bug report 模板，尽量写清复现步骤和机型 / 系统版本
- **新功能想法**：可以先开 Issue 聊，也可以直接看 [路线图](docs/roadmap.md) 认领

涉及学号、Cookie、私钥等敏感信息时，**发 Issue 前务必打码**。
