# 课表小程序

课表（timetable）小程序：教务课表同步、考试安排、手动课程与日程。主机统一从 `CampusHosts` 派生，本文不写域名，`<校园根域名>` 仅为占位。

## 教务课表接口

> **接口确认**：应用模块为 **`wdkb`**（非 wdkbby）。已确认：
> - 先访问 `…/sys/wdkb/*default/index.do`
> - 周课表 `POST …/modules/xskcb/cxxszhxqkb.do` form `XNXQDM=`
> - 未排课 `POST …/modules/xskcb/xswpkc.do` 同 form
> - 网格课序号用 **KXH**，不用 JXBID；JASMC 常为 null
> - `dqxnxq`/`dqzc`/`jc`/`cxjcs`/`cxxljc` 仅见名称，方法参数未核实（API 内 TODO stub）

### 0. 入口与会话

| 项 | 确认值 |
|---|---|
| 应用 | `wdkb` |
| 首页 | `GET https://jwxt.<校园根域名>/jwapp/sys/wdkb/*default/index.do`（可带 `EMAP_LANG`） |
| 模块前缀 | `https://jwxt.<校园根域名>/jwapp/sys/wdkb/modules/xskcb/` |
| 会话 | 复用 `PortalSession.clientFor(PortalServices.jwxt)`；校外 `vpnDio()` |
| 会话过期 | **尚未抓到样例**；若返回统一认证 HTML，按现有强制重登 |

实现：调业务接口前先访问 `*default/index.do`（与成绩/空教室一致）。

### 1. 已确认接口

#### 1.1 周/学期课表 `cxxszhxqkb.do`

| | |
|---|---|
| URL | `POST …/modules/xskcb/cxxszhxqkb.do` |
| Body | `application/x-www-form-urlencoded`：`XNXQDM=2026-2027-1` |
| 响应 | `datas.cxxszhxqkb.rows[]`，样例 70 行：`jwxt-capture/timetable_sample.json` |
| 注意 | Network Name 列曾误显成 `cxxszwqkb`，**Headers 真实名为 `cxxszhxqkb`** |

##### 主字段（解析必用）

| 字段 | 样例类型 | 含义 | 空值 |
|---|---|---|---|
| `KCM` | string | 课名 | 未见空 |
| `KCH` | string | 课程号 | |
| `KXH` | string | **课序号**（格子里的 `[02]` 用这个，**不要用 `JXBID`**） | |
| `JXBID` | string | 教学班 ID（长） | 仅作合并键，不展示 |
| `SKZC` | string | 周次位串，`'1'`=有课 | **长度不固定**：样例里 20 / 24 / 30 都有 → 按学期总周数截断或补 `0`，不要写死 20 |
| `SKXQ` | **int** | 星期 1–7 | 本样例仅见 1–5 |
| `KSJC` / `JSJC` | **string**（数字字符） | 起止节次 | 解析时 `int` 化 |
| `JASMC` | string \| **null** | 教室名 | 空多为 **`null`**，不是 `""` |
| `SKJS` | string | 教师 | 本样例课表行未见 null |
| `XF` | number | 学分 | 详情可显示 |
| `ZCMC` | string | 周次中文描述 | 可展示 |
| `XNXQDM` | string | 学年学期 | |

不要展示：`SKBJ`（班级名单极长）、完整 `JXBID`。

#### 1.2 未排课 `xswpkc.do` → App「其他课程」

| | |
|---|---|
| URL | `POST …/modules/xskcb/xswpkc.do` |
| Body | 同上 `XNXQDM=…` |
| 响应 | `datas.xswpkc.rows[]`，样例 3 行：`unscheduled_sample.json` |

特点：无 `SKXQ`/`KSJC`/`JSJC`/`JASMC`；`SKZC` 可能是 **`null` 或中文**（如 `"2-17周"`），不是位串。有 `KCM`/`KCH`/`KXH`/`JXBID`/`SKJS`/`XF`。

#### 1.3 学期 / 当前周 / 节次（已确认，前缀不同）

路径前缀：**`…/jwapp/sys/wdkb/modules/jshkcb/`**（注意不是 `xskcb`）

#### `dqxnxq.do` 当前学年学期

| | |
|---|---|
| 方法 | `POST`，**空 body** |
| 响应 | `datas.dqxnxq.rows[0]` |
| 关键字段 | `DM`=`2026-2027-1`，`XNDM`=`2026-2027`，`XQQM`=`1`，`MC`，`SFSY` |
| 样例 | `jwxt-capture/dqxnxq_sample.json` |

样例里 `QSSYRQ`/`ZFSXRQ`/`CLRQ` 均为 **null**，**没有直接的开学日期字段**。

#### `dqzc.do` 当前周次（兼推开学日）

| | |
|---|---|
| 方法 | `POST`，表单 `XN=2026-2027&XQ=1&RQ=2026-10-11`（`XN`/`XQ` 来自学期；`RQ` 用当天日期） |
| 响应 | `datas.dqzc.rows[0]`：`ZC` 当前周（样例 `6`），`XQJ` 星期（1=周一…7=周日，样例 `7`），`RQ` 回显 |
| 样例 | `jwxt-capture/dqzc_sample.json` |

**开学日（第 1 周周一）推算**：`week1Monday = date(RQ) - (XQJ-1)天 - (ZC-1)周`。  
用样例验算：`2026-10-11`（周日）第 6 周 → 第 1 周周一 = **2026-08-31**。接口不返回总周数，总周数的算法见 §1.4。

#### `jc.do` 节次作息

| | |
|---|---|
| 方法 | `POST`，**空 body** |
| 响应 | `datas.jc.rows[]`，样例 **12** 节；`DM` 节号（int），`KSSJ`/`JSSJ` 为 `"08:00"` 格式，`MC`=`第N节`；第 12 节 `SFSY=0`（可能未启用），显示时建议只展示 `SFSY=1` 或按设置上限 |
| 样例 | `jwxt-capture/jc_sample.json` |

课表行内若带 `KSSJ`/`JSSJ` 可覆盖对应节；否则用本表。设置上限仍可到 20，超出部分用户自定义。

#### 仍可选 / 未开

- `cxjcs.do`、`cxxljc.do`：可选，MVP 不依赖教历。
- 考试安排：需另开页面。

#### 前置：`setJwCommonAppRole.do`（如仍 403 再加）

- `POST https://jwxt.<校园根域名>/jwapp/sys/jwpubapp/pub/setJwCommonAppRole.do`（注意前缀是 `jwpubapp/pub`，不在 `wdkb` 下）
- 表单 `ROLEID=<32 位>`（具体值见 `jwxt-capture/headers-403.md`，疑为学生角色固定值，未验证是否因人而异）
- `wdkb.do` 只是页面日志配置（GET），客户端不需要调

#### 通用请求头（以上 POST 都带）

`X-Requested-With: XMLHttpRequest`、`Content-Type: application/x-www-form-urlencoded; charset=UTF-8`、`Origin: https://jwxt.<校园根域名>`、`Referer: https://jwxt.<校园根域名>/jwapp/sys/wdkb/*default/index.do?EMAP_LANG=en`

> 2026-10-11 更正：接口名是 **`dqxnxq.do` / `dqzc.do`**（q），早先记成 `dg…` 是错的，正是 403 的原因。

### 1.4 MVP 时间与周次来源（已定）

| 数据 | 来源 |
|---|---|
| 当前学期代码 | `dqxnxq.DM` → 作 `XNXQDM` 拉课表 |
| 当前周 | `dqzc.ZC` |
| 顶栏日期列 | 由 `RQ`+`XQJ`+翻周计算 |
| 开学日 | 由 `dqzc` 反推（见上），非教历 |
| 节次时刻 | `jc` 为主；行内时间优先 |
| 总周数 | 所有课程（教务课加手动课）里最晚有课的那一周；解析不出周次的「其他课程」不算；一门课都没有时取 20。当前周超过总周数时，顶栏照常显示真实周次，周视图停在最后一周 |
| 教历 | 不做主路径 |

### 2. 客户端映射

```
ensureIndex()        → GET  wdkb/*default/index.do
fetchCurrentTerm()   → POST jshkcb/dqxnxq.do   (empty body) → DM/XNDM/XQQM
fetchCurrentWeek()   → POST jshkcb/dqzc.do     XN=&XQ=&RQ=
fetchNodes()         → POST jshkcb/jc.do       (empty body)
fetchSchedule(term)  → POST xskcb/cxxszhxqkb.do XNXQDM=
fetchUnscheduled(t)  → POST xskcb/xswpkc.do     XNXQDM=
# 开学日 = 由 dqzc 的 RQ/XQJ/ZC 反推；cxxljc 可选
```

格子文案：`KCM` + `[KXH]` +（`JASMC != null` 时）`@JASMC`。详情学分用 `XF`。

### 3. 解析注意（已对照真样例）

1. `KSJC`/`JSJC` 是字符串，先转 int。
2. `SKZC` 变长（20/24/30）：对齐 `maxWeeks`（默认 20）——超长截断并 `tt_parse_skip` + `fixed:true`；过短右侧补 `0` 或按位解释到实际长度。
3. 地点空：`JASMC is null`（也可能将来有 `""`，两种都当空）。
4. 未排课整表进「其他课程」，不要因 `SKZC` 非位串就当 `bad_weeks` 丢掉。
5. 合并键建议：`KCH` + `KXH` + `SKXQ` + `KSJC` + `JSJC`（或加 `JXBID`）。

### 3.1 失败分类（客户端 `TimetableSyncFailure`，已定）

按以下顺序判断，前一条命中就不再往下看：

1. 超时或断网 → `network`（提示「重试」）。
2. HTTP 5xx（包括 WebVPN 或 nginx 返回的 HTML 错误页）→ `server`（提示「重试」），**不自动重登**。即使页面里出现 `authserver`，也按 5xx 处理。
3. 401；或 Dio 跟随跳转后，最终 URL 含 `authserver/login`；或返回 200 的 HTML 页面里含 `casLoginForm` 或 `authserver` → 先自动重登一次，仍然失败才判为 `sessionExpired`（提示「重新登录」）。
4. 其他返回 200 的 HTML 页面（如 WebVPN 维护页）；或返回 JSON 但 `code` 不是 `"0"` → `unknown`（提示「同步失败，请稍后再试」，不带按钮）。

注意：Dio 默认会跟随跳转，所以登录失效时一般拿到的是 200，而不是 302。所有失败都不清已缓存的课表。
对应的 fixture：`login_redirect_mock.html`、`gateway_502.html`、`webvpn_maintenance.html`（后两份是示例页）。

### 3.2 教务课调课记录（拖动调课，已定，数据层由移动端开发实现）

同步会整表覆盖教务课，所以拖动后的位置不改教务课本身，单独存一份调课记录（`timetable/overrides.json`，`schemaVersion: 1`），每次同步完再套上去。

每条记录存：
- `id`：记录 id；
- `courseId`：原课 `KCH|KXH`（同 §3 第 5 条的合并键）；
- `origDay` / `origStart` / `origEnd`：原 `SKXQ` / `KSJC` / `JSJC`；
- `origWeeks`：拖动时原课的 `SKZC` 位串（按 `maxWeeks` 对齐后的值）；
- `weeks`：这条记录移动的周（显式列表）。「只改本周」= `[w]`；「改以后所有周」= 原时段里第 w 周及以后实际有课的周（w 之前的周不动，与 UI 规范 §13.2 一致）；
- `scope` / `fromWeek`：拖动时选的范围和第几周，只作记录，**不参与失效判断**；
- `toDay` / `toStart` / `toEnd`：新的星期、起止节次；
- `createdAt`：创建时间。

读写都保留未知键：记录里的未知字段、文件顶层未知键、解析不了的条目，写回时原样保留。

套用与失效规则：
1. 套用：按 `courseId` + `origDay/origStart/origEnd` + `origWeeks`（须与原时段 SKZC 完全一致）找教务原时段，找到就把 `weeks` 里的周移到新位置。格子上不加标记，详情页显示原时间和「恢复原位置」。对不上的记录不渲染。
2. 失效（教务优先，产品经理已定）：**只在教务同步成功后**，对每条记录比较最新教务数据，满足任一条就删除这条记录、课按教务数据显示：
   - 原课已不存在；
   - 原课的 `SKZC` 与 `origWeeks` 不同；
   - 原时段的星期 / 起止节变了；
   - 旧记录缺 `origWeeks`：视为未知，同样删除（保守做法，避免套到错误位置）。
   其余记录保留。用户想调可以再拖。日志里不展示原课内容。删除后照常触发 `scheduleChanged`（reason = sync）。
3. 同一时段同一周有多条记录时，按写入顺序后写的生效；再次拖动同一时段会先从旧记录里扣掉本次涉及的周，周次扣空的记录删除。
4. 「恢复原位置」一次全部还原到教务原时间：删掉这个时段的所有记录（不是只撤销最后一次）。拖回原位置视为没拖，不写记录。
5. 冲突判断（`courseConflicts`）用套用后的位置算，选完范围后提示、不拦：「只改本周」查本周；「改以后所有周」查所有受影响的周，提示「与 X 等 N 门课时间冲突」。
6. 解绑时保留调课记录（产品经理已定），解绑本身**不触发删除**（此时记录暂不渲染）；同步失败也不删。重新绑定并同步成功后按第 1、2 条处理。
7. 手动课不走调课记录：拖动直接改手动课自己的时段，不受上述失效规则影响。

### 3.3 周次与提醒（配合设置第 9、11、13 项）

- 「每周第一天」选周日时只改周视图列的顺序；第几周仍按教务的周一到周日算（开学日为第 1 周周一，见 §1.3）。周日那天仍属于当周，不提前算到下一周。
- 上课提醒和首页「明天的课」用 `actualWeek(date)`（不夹到总周数范围内），不用 `currentWeek`。
- 提醒时刻取 `jc.do` 的 `KSSJ`（课表行内带时间时以行内为准，同 §1.4），不需要用户手填节次时间；调过的课按套用后的节次取时间。（本版不做）
- 解绑后学期信息被删，算不出周次：已排的提醒全部取消，开关保持原样，重新绑定并同步完再重排（产品经理已定）。（本版不做）节次接口里 `SFSY=0` 的节次不提醒。（本版不做）

### 4. Fixtures

| 文件 | 说明 |
|---|---|
| `kb_mock_*.json` 等 | 仍保留作边界用例；字段类型已向真样例对齐 |

单测只用 `test/fixtures/timetable/` 下的合成夹具；真实样例不入库（App 已无 debug 导入入口）。

## 教务考试安排接口（第 11 条）

主机统一用 `CampusHosts.jwxt`（hex 集中存储），本文不写域名。

### 1. 调用顺序

1. `GET /jwapp/sys/studentWdksapApp/*default/index.do`：先进一次应用首页，建立该应用的会话（和课表应用的做法一致）。
2. 学年学期：直接复用课表同步已拿到的 `XNXQDM`。如需单独取，可调本应用的 `POST /jwapp/sys/studentWdksapApp/modules/wdksap/dqxnxq.do`，字段同课表那边（`DM` 即 `XNXQDM`）。
3. **考试列表**：`POST /jwapp/sys/studentWdksapApp/WdksapController/cxxsksap.do`
   - `Content-Type: application/x-www-form-urlencoded; charset=UTF-8`，带 `X-Requested-With`、`Referer`（应用首页）。
   - 表单只有一个参数 `requestParamStr`，值是 JSON 字符串：`{"XNXQDM":"<学年学期>","*order":"-KSRQ,-KSSJMS"}`。
   - 请求里没有分页参数，响应 `totalSize` 为 `-1`，按一次返回全部处理。

其余请求（`cxxtcs`、`cxryywzt`、`cxxsjbxx`、`cxdqfwqsj`、`cxkssjct`、`cxwapdksrwtj`、日志/角色类）本版**都不调**。

`cxyxkwapkwdkc.do`（参数 `XNXQDM`，返回 `KCH`/`KCM`/`ZJJSXM`）是「已选课、考试还没排」的课程列表。本版没有考试列表页，**不调**；以后要做「待安排考试」再接。

### 2. 响应结构

`datas.cxxsksap.rows[]`，所有值都是字符串或 null。成功判断：顶层 `code == "0"`。

| 字段 | 含义 | 映射到 `ScheduleEvent` |
|---|---|---|
| `KCH` | 课程号 | `courseCode`，examKey 的一部分 |
| `KCM` | 课程名 | `title` |
| `KSRQ` | 考试日期 `yyyy-MM-dd` | `date`，examKey 的一部分 |
| `KSKSSJ` | 开始 `HH:mm` | `start`，examKey 的一部分 |
| `KSJSSJ` | 结束 `HH:mm` | `end` |
| `JASMC` | 教室名 | `location`（为空时用 `JXLMC`） |
| `ZWH` | 座位号 | 拼进 `note`：「座位号 N」 |
| `BZ` | 备注 | 拼进 `note` |
| `KSMC` | 考试批次名（如期末） | 不显示，可放详情 |
| `SFAPSJ` | 是否已安排时间（`"1"`=是） | 过滤条件 |
| `KSSJMS` | 时间描述串 | 仅作兜底解析，不作主数据 |

`kind=exam`、`source=jwxt`。examKey = `KCH + KSRQ + KSKSSJ`。

**不入库**：`XH`、`XSBH`（学号）、`ZJJSXM`（监考/主讲教师）、`KSDM`、`KSRWID` 等内部 ID。学号绝不写盘、不打日志。

### 3. 过滤与容错

- `SFAPSJ != "1"`，或 `KSRQ`/`KSKSSJ`/`KSJSSJ` 任一为空：跳过（考试还没排时间）。
- 日期或时间格式不对：跳过这一条并记一条脱敏日志（只记 KCH），不让整批失败。
- 同一 examKey 出现两次：只保留第一条。
- 接口失败（非 200、`code != "0"`、会话失效跳登录页）：沿用课表同步的失败分类，**不清空**已有考试。
- 成功且 rows 为空：视为本学期没有考试，整批替换为空。

### 4. Mock

`test/fixtures/timetable/exam_mock.json`：全部合成数据（学号用守卫白名单 `202500000000`）。含 2 条正常考试（同一天上下午）和 1 条 `SFAPSJ="0"` 的未排时间记录。第 3 条的 null 写法是推断的边界用例，真实响应里只有已排时间的记录。

#### 4.1 边界样例

- `exam_mock_empty.json`：`rows: []`，`totalSize: "0"`。期望：成功，本学期教务考试整批替换为空，手动考试不动。（空列表时真实 `totalSize` 写法未抓到，按 `"0"` 合成。）
- `exam_mock_missing_fields.json`：4 条。期望只入库第 4 条（庚，地点和 note 为空）；缺 `KSKSSJ`、日期格式不对、缺 `KCH` 的 3 条都跳过，整批不失败。
- 缺 `KCH` 也跳过：examKey 拼不出来，无法和覆盖记录对应。
