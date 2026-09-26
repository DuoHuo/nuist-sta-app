# AGENTS.md

AI 编码代理（Claude Code、Codex、Cursor、Copilot 等）在本仓库工作时必须遵守的规程。

- 「必须 / 禁止」是硬性要求；「应当」是默认做法，偏离时要向用户说明理由。
- 细节以 [CONTRIBUTING.md](CONTRIBUTING.md) 和 [docs/](docs/) 为准。这里只写代理需要照着执行的部分，红线在本文件内重复列出。
- `CLAUDE.md` 只负责让 Claude Code 导入本文件，规则只写在这里。

## 1. 优先级与责任

- 优先级：用户当次的明确指令 > 本文件 > 代理自身的默认行为。
- 代理产生的每一个提交，作者和责任人都是使用代理的人，而不是代理。

## 2. 工作方式

- 动手前必须先读 README、[架构文档](docs/architecture.md) 和要改动的模块，弄清结构再改。
- 禁止擅自新建文档或脚本。确需临时文件时放在 `.tmp*/`（已被 git 忽略）或系统临时目录，用完删除。
- 发现文档与代码不一致时，向用户报告，不要自行"修正"。
- `AGENTS.md`、`CLAUDE.md`、`CONTRIBUTING.md`、`.github/`、`.claude/`、`.codex/` 只在用户要求时修改。
- 必须如实汇报：没跑的检查、失败的测试、跳过的步骤都要直说。
- 默认用中文与用户沟通。

## 3. 身份与署名（红线）

- 禁止修改任何 git 配置（`user.name`、`user.email`、`commit.gpgsign`、`core.hooksPath` 等），local 和 global 都不行。
- 禁止以任何方式替换提交身份：`--author`、`-c user.name=…`、`-c user.email=…`、`GIT_AUTHOR_*` / `GIT_COMMITTER_*` 环境变量。
- 每次 commit 前必须检查 `git config user.name` 和 `git config user.email`。为空，或像代理 / 机器人身份（含 `codex`、`claude`、`copilot`、`cursor`、`bot` 等字样，或邮箱以 `@local` 结尾）时，停止并请用户自行配置，不得代为设置。
- 禁止在 commit 信息、PR 标题和描述中加入任何 AI 署名：`Co-Authored-By: <AI>`、`Generated with …`、`Claude-Session:` 链接、🤖 标记等。
- 禁止使用 `--no-verify`、`--no-gpg-sign`。签名或钩子失败时停下报告，不得绕过。

代理身份和 AI 署名会被 CI（`.github/workflows/commit-lint.yml`）拦下。

## 4. Git 权限

- 只有用户明确要求时才 commit。改完代码不等于可以提交。
- push、创建 PR、打 tag、发版，每次都需要用户明确指令；"提交"不包含"推送"。
- 禁止 force push（包括 `--force-with-lease`），确有必要时由用户亲自执行。
- 未经用户明确同意，禁止以下操作：
  - 改写已推送的提交（`commit --amend`、`rebase`、squash）
  - `git reset --hard`、`git clean`、`git checkout -- .`、`git restore`
  - `git branch -D`、`git stash drop`、`git stash clear`
- 禁止把同一改动分别提交到两个日后会合并的分支，否则 `main` 上会出现重复提交。
- 工作区里不属于本次任务的改动（包括用户自己未提交的改动）不碰、不暂存、不丢弃。

## 5. 提交流程：先同步，再提交

```bash
# 1. 身份自检（见第 3 节）
git config user.name
git config user.email

# 2. 同步远程
git fetch origin --prune
git status -sb                   # 看 ahead / behind
git log --oneline HEAD..@{u}     # 远程有没有新提交；新分支没有上游时对比 origin/main
git pull --rebase --autostash    # 有就先同步，未提交的改动会自动暂存再恢复
# 出现冲突：停下报告用户，不得为了"解决冲突"丢弃任何人的改动

# 3. 验证（同步后基线变了也要重跑；纯文档改动可跳过）
dart format lib test
flutter analyze
flutter test

# 4. 按路径暂存并自查
git add <路径> ...               # 禁止 git add -A / git add .
git diff --cached                # 只能包含本次任务的改动

# 5. 提交（格式见第 6 节）
git commit -m "<type>(<scope>): <中文摘要>"
```

- 在功能分支上还要看 `git log --oneline HEAD..origin/main`（fork 场景为 `upstream/main`）；`main` 改到了同一批文件时提醒用户。
- 用户要求 push 时，push 前再 `git fetch` 一次；被拒（non-fast-forward）就 `git pull --rebase` 后重推，绝不 force。

## 6. Commit 信息

格式 `<type>(<scope>): <中文摘要>`，scope 可省略。CI 会逐个检查。

- **type**：`feat` `fix` `docs` `refactor` `perf` `test` `build` `ci` `style` `chore` `revert`。release notes 按前缀分组，只有 `feat`、`fix`、`docs` 会进入对应章节。
- **scope**：kebab-case 模块名，如 `campus-map`、`free-classroom`、`portal-bind`、`auth`（完整清单见 CONTRIBUTING）。
- **摘要**：中文，一行说清用户能感知的变化，不加句号。
- **保持简洁**：一行摘要能说清就不写正文；正文只写"为什么这么改"，几行以内，不罗列改了哪些文件。
- 一个 commit 只做一件事：不用分号串多个前缀，不夹带无关的重构、格式化或依赖升级。
- `chore(release)` 只用于发版。

```
feat(free-classroom): 支持按楼层筛选
fix(electricity): 修复只有一条记录时折线图不显示
```

## 7. 禁止入库

- 构建产物：`build/`、`*.apk`、`*.aab`
- 临时文件：`.tmp*/`、`test/failures/`、一次性调试脚本
- 凭据：`*.jks`、`*.keystore`、`key.properties`、`passkey*.json`、`*.nuistkey`、Cookie、`.env`
- 真实个人数据：学号、姓名、成绩等；测试夹具必须脱敏

## 8. 代码约定

要点如下，详见 [架构](docs/architecture.md) 和 [新增一个小程序](docs/mini-app-guide.md)。

- **依赖方向**：`lib/mini_apps/<app>/` 只能 import `lib/core/` 和第三方包，禁止 import `lib/shell/` 或其他小程序（CI 会检查）。跨小程序共享的东西才放进 `core/`。
- **分层**：小程序按 `*_models` / `*_api` / `*_store` / `*_controller` / `*_page` / `*_manifest` 拆分，照现有小程序的写法来。
- Store 的读写必须 `try/catch`，失败时退化成"没有存储"（widget 测试没有平台通道）。
- 进入小程序用 `context.push('/apps/<id>')`，禁止用 `go`。
- 门户接口一律走 `PortalSession`，不要自己实现登录；区分 `PortalNetworkError` / `PortalCredentialError` / `PortalLoginError`；`request` 的回调可能执行两次，不能放有副作用的逻辑。
- 品牌色用 `AppColors`；`colorScheme.primary` 是 M3 默认紫，不是品牌色。
- 注释和文档用中文，公开的类和方法应当写 `///` 文档注释；`lib/` 内部用相对路径 import。
- 日志只在 debug 构建输出，禁止打印 Cookie、ticket、私钥、学号等敏感值。
- 禁止引入遥测、崩溃上报、统计类 SDK；除学校自己的系统外，禁止新增网络出口（README 对用户有承诺），确有需要先问用户。
- 以下内容只在用户明确要求时改动：`pubspec.yaml` 的 `version`、Flutter 版本、`.github/workflows/`、Android 签名配置、`assets/js/vconsole.min.js`。
- 新增或升级依赖前必须先问；改了依赖要一并提交 `pubspec.lock`。

## 9. 交付前验证

- 必须通过：`dart format lib test` 后无差异、`flutter analyze` 零问题、`flutter test` 全绿（CI 查的就是这些）。
- 跑不了时如实说明，不得声称已通过（例如 README 提到的中文 / OneDrive 路径导致分析服务崩溃）。

## 10. PR（仅在用户要求时创建）

- 标题用 commit 格式，按 `.github/PULL_REQUEST_TEMPLATE.md` 填写，UI 改动可无需附截图。
- 描述中不写 AI 署名（见第 3 节）。
