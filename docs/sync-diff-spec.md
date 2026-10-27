# 本地同步 Diff 口径建议

面向 NUIST 实时课表 Flutter App：教务拉取成功后，与本地缓存比对，生成变动记录并提醒用户。本文基于 `/workspace/plan/jwxt-capture/timetable_sample.json`（70 条时段）与 `jc_sample.json`（12 节，第 12 节 `SFSY=0` 不用）的实际字段。

---

## 1. 稳定 Key

### 1.1 建议 Key

```
slotKey = KCH + "|" + KXH + "|" + SKXQ + "|" + KSJC + "|" + JSJC + "|" + SKZC
```

| 组成部分 | 样例字段 | 含义 | 纳入理由 |
| --- | --- | --- | --- |
| 课程号 | `KCH` | 如 `18001299` | 同名课可能多门，号更稳 |
| 课序号 | `KXH` | 如 `70` | 区分同一课程的不同教学班 |
| 星期 | `SKXQ` | `1`–`7`（样例为数字） | 同一教学班可跨多天 |
| 起止节 | `KSJC` / `JSJC` | 如 `5`/`6` | 同一天可能有多段 |
| 周次位图 | `SKZC` | 如 `111111111111111100000000` | 同课同天同节也可能拆周段 |

样例拼接示例：

```
18001299|70|1|5|6|111111111111111100000000
```

对应「学术英语（1）」周一第 5–6 节、1–16 周。

### 1.2 取舍说明

| 候选字段 | 是否进 Key | 说明 |
| --- | --- | --- |
| `WID` / `KBID` | **不进** | 样例中 `KBID` 仅约 14/70 非空；教务侧 ID 可能随重排课重生，不稳定 |
| `KCM`（课程名） | **不进** | 改名应算「属性变动」而非「换了一门课」；用 `KCH` 已够 |
| `JASMC` / `SKJS` | **不进** | 地点、教师变更是常见调课场景，应进 diff，不能进 key |
| `ISTK` / `SFSYK` | **不进** | 调课/实验标记属于属性；用户可能本地覆盖实验展示 |
| `JXBID` | **可选备用** | 教学班 ID 较稳，但跨学期/补数据时可能缺失；主 key 仍用上表六元组 |
| `XNXQDM` | **外层作用域** | 按学期分桶比对，不塞进单条 slotKey |

**规范约定：**

- 字符串字段 trim 后比较；`KSJC`/`JSJC`/`SKXQ` 统一转字符串再拼，避免 `"5"` vs `5` 误判。
- `SKZC` 保留原始位图字符串（含尾部 `0`），不做截断；不同长度按字面不等处理。
- 同一 `KCH+KXH` 在不同星期/节次/周段各有独立 key，互不影响。

---

## 2. 哪些算「变动」

比对对象：教务最新快照 vs 本地「教务源」缓存（不含用户覆盖层）。  
匹配方式：按 `slotKey` 做集合 diff。

| 类型 | 判定 | 用户感知 |
| --- | --- | --- |
| `added` | 新快照有、旧缓存无的 key | 新增时段 |
| `removed` | 旧缓存有、新快照无的 key | 删除时段 |
| `time_changed` | key 相同，但 `SKXQ`/`KSJC`/`JSJC` 实际不可能变（已在 key 内）；**若实现上 key 不含某时间维，则该维变化落此类型**。推荐口径下时间维已在 key：时间整体迁移会表现为「旧 key removed + 新 key added」 | 换星期或换节次 |
| `weeks_changed` | key 含 `SKZC` 时，周次变化同样表现为 remove+add；若产品希望「同课同学期同学期段合并为周次变更」，可用**弱 key**（去掉 `SKZC`）做第二轮归并，见 §2.1 | 上课周变化 |
| `location_changed` | key 命中，`JASMC`（优先）或 `JXLDM_DISPLAY` 规范化后不同 | 换教室/楼 |
| `teacher_changed` | key 命中，`SKJS` 规范化后不同 | 换教师 |
| `retake_flag_changed` | key 命中，`ISTK` 不同（样例均为 `0`；`ISTK_DISPLAY` 仅展示用） | 调课标记变化 |
| `course_meta_changed` | key 命中，`KCM` 等展示名变化（少见） | 课程名变更 |

### 2.1 时间 / 周次的两种口径

**口径 A（推荐，严格 key）：**  
`slotKey` 含星期+起止节+`SKZC`。任何时间或周次变化 → `removed` + `added` 两条。实现简单、无歧义；提醒文案可再聚合为「原时段取消 / 新时段出现」。

**口径 B（体验向归并）：**  
主比对用弱 key `KCH|KXH|SKXQ|KSJC|JSJC`（不含周次）。弱 key 命中且仅 `SKZC` 不同 → 记一条 `weeks_changed`（带前后位图）。星期或节次变了仍用 remove+add。  
地点/教师仍用完整 key 或弱 key 命中后比属性均可。

文档默认采用 **口径 A 记账 + 提醒层可选用口径 B 聚合展示**。

### 2.2 字段规范化（比对前）

| 字段 | 规则 |
| --- | --- |
| `SKJS` | trim；中英文逗号统一为 `,`；按 `,` 分割后 trim、去空、排序再 join（教师顺序不影响相等） |
| `JASMC` | trim；空/`null` 视为 `""` |
| `JXLDM_DISPLAY` | 仅当 `JASMC` 皆空时作为地点回退比较 |
| `SKZC` | 原样字符串；不要把 `"1110"` 与 `"11100000"` 判等 |
| `ISTK` | 转 int，`null`→`0` |
| `SFSYK` | **默认不参与变动判定**（见下节）；若业务要展示，单独可选 |

---

## 3. 哪些忽略

| 项 | 原因 |
| --- | --- |
| `rows` 数组顺序 | 教务分页/排序不稳定，按 key 集合比 |
| 字段空白差异 | 仅 trim / 空串与 `null` 等价 |
| `*_DISPLAY` 冗余展示字段 | 以代码字段为准（如用 `SKXQ` 不用 `SKXQ_DISPLAY`） |
| `SKBJ`、`BJDM`、同班名单等 | 非本生课表核心展示，变动噪声大 |
| `YPSJDD`、`ZCMC` | 可由节次+周次+地点派生的摘要串，易跟源字段重复报警 |
| 用户本地自定义颜色 | 属用户覆盖层，同步不得覆盖、不得记 diff |
| 用户本地备注 / 隐藏某节 | 同上 |
| 用户覆盖的「是否实验课」展示 | 教务 `SFSYK` 可更新到源数据，但若用户手动改过展示标记，提醒可选、默认不弹；源缓存仍可静默更新 |
| 节次时间表 `jc` 微调且课程行未变 | 若仅 `jc_sample` 的 `KSSJ`/`JSSJ` 变，单独做「作息变更」通道，不与课程 slot diff 混报；当前规划可先忽略或低频提示 |
| `XH`/`XM` 等身份字段 | 与课表内容无关 |

---

## 4. 变动记录数据结构

建议持久化一条变更事件（可 JSON / Room Entity）：

```json
{
  "id": "uuid-or-snowflake",
  "detectedAt": "2026-10-27T09:00:00+08:00",
  "xnxqdm": "2026-2027-1",
  "slotKey": "18001299|70|1|5|6|111111111111111100000000",
  "type": "location_changed",
  "courseName": "学术英语（1）",
  "before": {
    "JASMC": "滨江BS413",
    "JXLDM_DISPLAY": "滨江楼",
    "SKJS": "黄晓燕",
    "SKZC": "111111111111111100000000",
    "ISTK": 0
  },
  "after": {
    "JASMC": "揽江楼N307",
    "JXLDM_DISPLAY": "揽江楼",
    "SKJS": "黄晓燕",
    "SKZC": "111111111111111100000000",
    "ISTK": 0
  },
  "fingerprint": "sha256:…",
  "notified": false
}
```

| 字段 | 说明 |
| --- | --- |
| `detectedAt` | 检出时间（设备本地时区 ISO-8601） |
| `xnxqdm` | 学期，便于归档与过滤 |
| `slotKey` | 稳定 key；`added`/`removed` 也填 |
| `type` | `added` / `removed` / `location_changed` / `teacher_changed` / `weeks_changed` / `retake_flag_changed` / `course_meta_changed` / `time_changed`（若用口径 B） |
| `courseName` | 冗余 `KCM`，方便列表展示 |
| `before` / `after` | 相关字段快照；`added` 时 `before=null`，`removed` 时 `after=null` |
| `fingerprint` | 见 §5，用于去重 |
| `notified` | 是否已向用户弹过提醒 |

一次同步可产生多条记录；UI 按 `detectedAt` 批次聚合展示。

---

## 5. 只弹一次提醒的去重

目标：同一实质变动不因反复拉教务而多次打扰。

### 5.1 fingerprint

```
fingerprint = hash(
  type + "\n" +
  slotKey + "\n" +
  canonical(before) + "\n" +
  canonical(after)
)
```

- `canonical`：对参与比对的字段做有序 JSON（键排序、教师已规范化）。
- `added`：`before` 固定为空串；`removed`：`after` 固定为空串。

### 5.2 去重规则

1. 同步结束得到候选 diff 列表。
2. 对每条算 `fingerprint`；若本地「已通知指纹表」或历史记录中已存在且 `notified=true`，则**静默写入/跳过弹窗**（可选：仍 upsert 记录但 `notified` 保持 true）。
3. 仅对「新 fingerprint」弹一次汇总提醒（一条通知可包含 N 条新变动）。
4. 若同一 `slotKey` 再次变化（例如地点 A→B 已通知，后又 B→C），fingerprint 不同 → **再弹一次**（这是新变动，不是重复）。
5. 若变动回滚（B→A）且 fingerprint 与历史某条相同，可不再弹；产品也可选择「回滚也提醒」，则在 fingerprint 中加入批次号或「相对上一版缓存」的方向位。

### 5.3 批次去重键（可选）

通知层再用：

```
notifyBatchKey = hash( sorted(newFingerprints) )
```

防止同一轮内多次重建通知；与 fingerprint 表互补。

---

## 6. 样例举例（基于 timetable_sample.json）

### 例 1：地点变更 → `location_changed`

旧缓存（样例第 0 行）：

- key: `18001299|70|1|5|6|111111111111111100000000`
- `KCM`=学术英语（1），`JASMC`=`滨江BS413`，`SKJS`=`黄晓燕`

新快照：同 key，仅 `JASMC`→`滨江BS401`。

| 字段 | 值 |
| --- | --- |
| type | `location_changed` |
| before.JASMC | `滨江BS413` |
| after.JASMC | `滨江BS401` |
| 提醒 | 「学术英语（1）周一 5-6 节：滨江BS413 → 滨江BS401」 |
| 再拉一次仍为 BS401 | 同 fingerprint → **不再弹** |

### 例 2：教师多值顺序 / 更换 → `teacher_changed` 或忽略

样例中存在 `SKJS`=`许川川,杨宇涵`。

- 若教务改为 `杨宇涵,许川川`：规范化排序后相同 → **忽略**。
- 若改为 `许川川`：规范化后不同 → `teacher_changed`，before=`许川川,杨宇涵`，after=`许川川`，弹一次。

### 例 3：周次位图变化 → 口径 A 下 remove + add

旧：`SKZC`=`111111111111111100000000`（1–16 周）  
新：`SKZC`=`101010101010101000000000`（单周）

完整 key 已变：

1. `removed`：旧 key（含旧 `SKZC`），`after=null`
2. `added`：新 key（含新 `SKZC`），`before=null`

提醒层可聚合文案：「学术英语（1）周一 5-6 节上课周次有变（1-16周 → 单周）」。  
两 fingerprint 均未通知过则各记一条、合并弹一次；之后教务不变则不再弹。

### 例 4（补充）：纯新增实验课时段

新快照出现此前没有的 key（例如某 `SFSYK=1` 实验分段），旧缓存无：

- type=`added`
- `before=null`，`after` 含 `KCM`/`JASMC`/`SKJS`/`SKZC`/`ISTK` 等
- `SFSYK` 可写入 `after` 供展示，但不单独作为 diff 类型（除非产品要求）

---

## 7. 实现备忘

1. **源数据 vs 用户覆盖分层存储**：diff 只打在「教务源」副本上；合并展示时再叠颜色/备注。
2. **学期桶**：先按 `XNXQDM` 过滤再 diff，避免跨学期串 key。
3. **空地点**：样例约 2/70 无 `JASMC`；比较时用 `""`，展示可用「地点待定」，不要用 `JXLDM_DISPLAY` 误当成完整教室除非 `JASMC` 为空回退。
4. **调课**：当前样例 `ISTK` 全为 `0`；仍保留 `retake_flag_changed` 类型以备教务标记调课行。
5. **节次表**：`jc` 共 12 行，`DM=12` 且 `SFSY=0` 不参与排课；课程 `KSJC`/`JSJC` 应落在 1–11。
