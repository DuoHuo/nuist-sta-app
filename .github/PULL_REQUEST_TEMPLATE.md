<!-- 提交前请逐项确认，不需要的项可以删掉。 -->

## 这个 PR 做了什么

<!-- 一两句话说清楚。如果修的是 Issue，写 Fixes #123 -->

## 检查清单

- [ ] `dart format lib test` 无改动
- [ ] `flutter analyze` 零警告
- [ ] `flutter test` 全绿
- [ ] commit 格式为 `<type>(<scope>): <中文摘要>`（type 与 scope 见 CONTRIBUTING.md）——
      前缀写错，改动会掉进 release notes 的 "Other Changes"

如果这个 PR **新增了小程序**，再确认：

- [ ] 注册表 `id` 唯一、`entry` 与 `url` 恰好提供一个
- [ ] `label` 不与现有小程序重名（会让 `widget_test.dart` 的文案断言挂掉）
- [ ] `mini_apps/<name>/` 没有 import `shell/*` 或兄弟小程序
- [ ] Store 的读写都有 `try/catch` 兜底

## 截图 (可选)

<!-- UI 改动请附上改动前后的对比图。 -->
