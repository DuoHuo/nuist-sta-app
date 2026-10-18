# 课表 fixtures

## 测试怎么用这些文件（2026-10-18 起）

- 真实样例 `*_real_sample.json` 含学生班级/专业等信息，已加入 `.gitignore`，**只留在本地，不入库**；不要把里面的内容拷到别的文件、日志或报告里。
- `timetable_models_test.dart`、`timetable_color_assign_test.dart`、`timetable_week_format_test.dart` 的主测试组**始终跑合成 mock**（下表「对应 mock」列），断言按 mock 数据写死。
- 另有「真实样例（仅本地存在时运行）」测试组：本地有真实样例时才跑，干净 checkout 里没有这些文件时整组 `skip: 'real sample not present'`，不算失败。
- 新增 mock 只能照抄真实样例的**结构**（键名、类型），值一律编造：教师写「教师N / 教师O …」，课名用「高等数学A」这类通用名，班级/学院/专业用 `BJ0001`、`示例学院`、`示例专业`，学号/姓名用占位 `2030000000`、`示例学生`。

## 真实打码样例（git-ignore，仅本地；用于单测 / 对账；App 内 debug 导入入口已删除）

| 文件 | 来源 | 对应 mock（入库） |
|---|---|---|
| `kb_real_sample.json` | 抓包 `cxxszhxqkb`，70 行 | `kb_mock.json` |
| `unscheduled_real_sample.json` | 抓包 `xswpkc`，3 行 | `unscheduled_mock.json` |
| `dqxnxq_real_sample.json` | 当前学期（`jshkcb/dqxnxq`） | `dqxnxq_mock.json` |
| `dqzc_real_sample.json` | 当前周（`ZC=6`，可反推开学日 2026-08-31） | `dqzc_mock.json` |
| `jc_real_sample.json` | 12 节作息 | `jc_mock.json` |

接口说明见 `lib/mini_apps/timetable/README.md`。

## 人造 mock（边界与联调）

| 文件 | 用途 |
|---|---|
| `kb_mock.json` | 与 `kb_real_sample.json` 同结构（全部键、类型一致），值全是编造的。15 行 / 14 门：SKZC 长度 20/24/30 混合；单周（1–15、1–17）、双周（2–8、2–16）、连续段（1–8、3–14、1–16）、多段（1–4、7、9–12）、单个周（9）；`JASMC` 有 `null`；高等数学A 两行合并成两个时段。配色用例：程序设计基础/高等数学A 同哈希 10 且相邻（后者顺延到 11），大学物理B/概率论与数理统计 同为 5 且左右相邻（后者到 6），离散数学 8 连续两步顺延到 10，线性代数B/大学物理实验B 同为 1 但单双周不相交（不顺延） |
| `jc_mock.json` | 与 `jc_real_sample.json` 同结构；12 节编造作息（08:10 起，第 12 节 `SFSY=0`） |
| `dqzc_mock.json` | 与 `dqzc_real_sample.json` 同结构；`RQ=2026-09-23`、`XQJ=3`、`ZC=4` → 开学日 2026-08-31 |
| `kb_mock_2026-1.json` | 覆盖单双周、跨节、冲突、周六晚课；`KSJC`/`JSJC` 为字符串；地点空为 `null` |
| `unscheduled_mock.json` | 未排课（`SKZC` 为 null 或中文周次） |
| `kb_mock_empty.json` | 空课表 |
| `kb_mock_edge.json` | 异常数据（见下表） |
| `dqxnxq_mock.json` / `jcs_mock.json` / `timetable_config_mock.json` | 学期/作息/静态配置占位（接口未完全确认） |
| `login_redirect_mock.html` | 会话过期 HTML 占位 |

### 真样例已确认的类型差异

- `SKXQ`：int；`KSJC`/`JSJC`：**string**
- `SKZC`：**长度可变**（真样例 20/24/30），解析按 `maxWeeks` 对齐
- 地点空：多为 **`null`**
- 格子序号用 **`KXH`**，不用 `JXBID`；不要展示 `SKBJ`

### `kb_mock_edge.json`

| KCH | 情况 | 预期 | reason |
|---|---|---|---|
| 9900 | 正常 | 显示 | |
| 9901 | 周日 7 | 排周日列 | |
| 9902 | 结束<开始 | 跳过 | bad_node |
| 9903 | 11-14 超当日最大 | 截断纠正 | bad_node, fixed |
| 9904 | 周次过短 | 补齐或跳过（实现定） | bad_weeks |
| 9905 | 周次 30 位 | 截到 maxWeeks 后显示 | bad_weeks, fixed |
| 9906 | 非法字符 | 跳过 | bad_weeks |
| 9907 | 重复两条 | 留一 | duplicate |
| 9908/9909 | 课名空/null | 跳过 | empty_name |
| 9910 | 长课名 | 显示截断 | |
| 9911 | 星期节次字符串 | 转 int 后显示 | |
| 9912 | 星期 8 | 跳过 | bad_day |
| 9913 | 开始节次 21 | 跳过 | bad_node |
| 9914 | JASMC null | 显示且不显 @ | |

> 2026-10-11：接口真实名是 `dqxnxq` / `dqzc`。新文件 `dqxnxq_real_sample.json` / `dqzc_real_sample.json` 的 `datas` 键已改名；旧的 `dg*_real_sample.json` 只为不让现有单测断掉而暂留，单测改完引用后删除。
