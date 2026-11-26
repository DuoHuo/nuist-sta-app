# 课表 fixtures

## 测试怎么用这些文件

- 真实样例 `*_real_sample.json` 含学生班级/专业等信息，已加入 `.gitignore`，**只留在本地，不入库**；不要把里面的内容拷到别的文件、日志或报告里。
- 单元测试一律只运行入库的合成 mock（下表），不依赖本地私有真实样例文件。
- 新增 mock 只能照抄真实样例的**结构**（键名、类型），值一律编造：教师写「教师N / 教师O …」，课名用「高等数学A」这类通用名，班级/学院/专业用 `BJ0001`、`示例学院`、`示例专业`，学号/姓名用占位 `202512340001`、`示例学生`。

## 真实打码样例对照（真实文件 git-ignore，仅本地参考）

| 文件 | 来源 | 对应 mock（入库） |
|---|---|---|
| `kb_lab_tuesday_sample.json` | 脱敏：仅周二「数据结构课程设计」+「体育（3）」；无学号/姓名/真教师 | 本文件 |
| `kb_real_sample.json`（勿提交，见 .gitignore） | 抓包 `cxxszhxqkb`，70 行 | `kb_mock.json` |
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
| `dqxnxq_mock.json` | 当前学期占位样例 |
| `kb_mock_2026-1.json` | 覆盖单双周、跨节、冲突、周六晚课；`KSJC`/`JSJC` 为字符串；地点空为 `null` |
| `unscheduled_mock.json` | 未排课（`SKZC` 为 null 或中文周次） |
| `exam_mock.json` / `exam_mock_empty.json` / `exam_mock_missing_fields.json` | 教务考试解析样例（正常、空列表、缺字段边界） |
| `login_redirect_mock.html` / `gateway_502.html` / `webvpn_maintenance.html` | 会话过期、网关错误与维护页 HTML 样例 |

### 真样例已确认的类型差异

- `SKXQ`：int；`KSJC`/`JSJC`：**string**
- `SKZC`：**长度可变**（真样例 20/24/30），解析按 `maxWeeks` 对齐
- 地点空：多为 **`null`**
- 格子序号用 **`KXH`**，不用 `JXBID`；不要展示 `SKBJ`
