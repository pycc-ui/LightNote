# AI 接入设计

这个项目怎么调 DeepSeek，以及每一步怎么把 token 花得少。

相关文档：为什么选 DeepSeek、为什么默认用 flash 见 [技术栈设计](技术栈设计.md)；分层与目录见
[架构和功能开发流程设计](架构和功能开发流程设计.md)、[目录设计](目录设计.md)；表结构细节
（`ai_calls` / `ai_messages` 等）见 [数据库设计](数据库设计.md)；省钱的依据是
[软件理念设计](软件理念设计.md) 的第二要义「得省钱，想办法节省 token 使用」。

本文数字与行为以 `lib/` 代码为准，逐条给出出处。

---

## 1. 接口事实

### 1.1 端点、模型、超时

出处：`lib/features/ai/data/deepseek_config.dart`

| 项 | 值 |
|---|---|
| Base URL | `https://api.deepseek.com` |
| 对话端点 | `POST /chat/completions` |
| 模型名 | `deepseek-flash`（`modelFlash`，默认）；`deepseek-v4-pro`（`modelPro`）。**AI 助手页按会话选**（原先是选工作区的位置），卡片流固定 flash |
| 上下文 / 最大输出（常量声明） | `maxContextTokens = 1000000` / `maxOutputTokens = 384000` |
| 连接超时 | 20 秒 |
| 读超时 | 5 分钟 |

三条值得单独记住的事实：

1. **模型名用 `deepseek-flash`。** config 注释写明：旧名 `deepseek-v4-flash` 仍可调用，但对应模型已下线，
   请求会由新模型代答。
2. **AI 助手页可以按会话选 flash / pro。** 模型存在会话记录里（复用 `workspace_scope` 列，
   语义已改为存模型名，见《数据库设计》），`AiChatRepository._drive` 把会话的模型传给 `streamAgent`。
   **卡片生成是高频成本大头，固定用 flash**，不读会话选择（避免误选 pro 把成本抬三倍）。
   历史压缩也固定 flash。
3. `maxOutputTokens = 384000` 只是声明，从不是实际用量——具体调用各自给 `max_tokens`（卡片生成 / 自检 /
   `completeJson`；对话路径不传，见 1.2 末）。

### 1.2 三种请求体

出处：`lib/features/ai/data/deepseek_client.dart`

公共部分：

- Header：`Authorization: Bearer <key>`、`Content-Type: application/json`；流式再加 `Accept: text/event-stream`。
- `validateStatus: (_) => true`——自己判状态码，才能把 401 / 402 / 429 的响应体读出来给用户看。
- 没有 API Key 时不发请求：流式立刻产出 `AiError(code: 'no_api_key')`，非流式抛 `DeepSeekException`。

**（1）`streamChat` —— system + user 两段式，流式**

```json
{
  "model": "deepseek-flash",
  "messages": [
    {"role": "system", "content": "<系统提示词>"},
    {"role": "user",   "content": "<用户提示词>"}
  ],
  "stream": true,
  "thinking": {"type": "disabled"},
  "max_tokens": 4096,
  "response_format": {"type": "json_object"}
}
```

（`max_tokens` 与 `response_format` 只在调用方传了对应参数时出现；`streamChat` 不接受 `tools`。）

**（2）`streamAgent` —— 完整消息列表 + 工具，流式**

```json
{
  "model": "deepseek-flash",
  "messages": [
    {"role": "system", "content": "<系统提示词>"},
    {"role": "user", "content": "<用户指令>"},
    {"role": "assistant", "content": "", "tool_calls": [ … ]},
    {"role": "tool", "tool_call_id": "call_1", "content": "{\"ok\":true,…}"}
  ],
  "stream": true,
  "thinking": {"type": "enabled"},
  "reasoning_effort": "medium",
  "tools": [{"type": "function", "function": {"name": "…", "description": "…", "parameters": {"type": "object", "properties": {}}}}],
  "tool_choice": "auto"
}
```

`messages` 是完整列表（不是 system + user 两段）：tool calling 要求把历史、assistant 的工具提议、
`tool` 结果按序都放进去。`tool_choice` 固定 `auto`，不设 `required`——否则模型会为了调用而调用。

**（3）`completeJson` —— 非流式，JSON Output**

`stream: false` + `response_format: {"type": "json_object"}`，`max_tokens` 默认 4096。不接受 `temperature` 参数。

**参数规则：**

| 参数 | 规则 |
|---|---|
| `thinking` | 永远显式带上 `enabled` / `disabled`，从不省略。原因见第 2 节坑 1 |
| `reasoning_effort` | 只在 `thinking: enabled` 时带（默认 `high`；AI 页实际传 `medium` / `high`） |
| `temperature` | 只在 `thinking: disabled` 且调用方显式传了才带。思考模式下传了不报错也不生效，所以代码干脆不传，避免误导后来者 |
| `max_tokens` | 实际用到：卡片生成 `2048`（`AiLimits.feedMaxOutputTokens`，从 16384 收下来防跑飞）、连通性自检 `64`、`completeJson` 默认 `4096`；`streamAgent` 不传（留给模型默认） |

`response_format` 用的是官方 JSON Output，官方要求 prompt 里出现 "json" 字样并给出输出样例——
`prompts.dart` 顶部把这条和「前缀稳定」一起写成两条硬性约束。

### 1.3 流式怎么读

出处：`deepseek_client.dart` 的 `_runStream`（唯一一份 SSE 解析实现，`streamChat` 与 `streamAgent` 共用；
两者差别只在请求体）

请求用 `ResponseType.stream` 拿响应体，然后：

1. `utf8.decoder`（`allowMalformed: true`）+ `LineSplitter` 逐行读。
2. 跳过空行与 `:` 开头的注释行；只处理 `data:` 开头（取 `substring(5).trim()`）。
3. `data: [DONE]` → 置 `finished = true` 并结束。
4. 单行 `jsonDecode` 失败 → `continue`（半行、心跳）。
5. `json['error']` 非空 → 流中间的错误，产出 `AiError` 后返回。
6. `choices` 为空数组/缺失 → 可能只有 `usage`（usage 常常只出现在最后一块），记下用量后 `continue`。
7. `choices.first.delta`：`content` → `AiChunk`；`reasoning_content`（与 `content` 同级）→ `AiReasoning`；
   `tool_calls` → 累加。
8. 结束产出 `AiDone`：`fullText`、`promptTokens`、`completionTokens`、`costCents`、`latencyMs`、`toolCalls`。

事件类型（UI 消费的就是这几个）：`AiChunk`（增量正文）、`AiReasoning`（思维链）、`AiDone`、`AiError`。
AI 助手页拿到的再上一层是 `AgentEvent`：`AgentText` / `AgentFinished` / `AgentAwaitingUser` /
`AgentFailed` / `AgentToolStarted` / `AgentToolDone`（思维链在 agent 路径被丢弃、不展示）。

三个容易写错的边界：

- **usage 只在最后一块**，所以每块都尝试解析一次，最后一次生效。
- **空内容才报错**：`正文为空 && 没有 tool_calls && 没收到 [DONE]` → `AiError(code: 'empty_content')`。
  「只提工具、没有正文」是正常情况，不能当成空内容——那样 tool calling 会在第一轮就死掉。
- 错误映射：`401 → unauthorized`、`402 → insufficient_balance`、`422 → invalid_params`、
  `429 → rate_limited`、`≥500 → server_error`，都换成人话（如「API Key 无效或已过期」「账户余额不足」）；
  `429` / `5xx` / 超时 / 断网标记 `isRetryable`。

### 1.4 tool calling 的报文形状

出处：`tool_types.dart`、`deepseek_client.dart`、`agent_loop.dart`、`tool_executor.dart`、`tool_specs.dart`

**工具定义（`tools` 数组元素）**

`tools` 里只有两个：`run`（执行命令脚本）与 `askUser`（挂起提问）。`run` 的定义长这样：

```json
{"type": "function",
 "function": {"name": "run", "description": "在用户的笔记库上执行命令脚本……", "parameters": {"type": "object", "properties": {"script": {"type": "string"}}, "required": ["script"]}}}
```

`description` 是写给模型看的：写「什么时候用它」，不是「它是干什么的」。命令的**语法与清单**写在
system prompt 里（约 400 token），不塞进工具 schema —— 这样原来 22 个工具的定义开销收敛成两个。

**流式回来的 `tool_calls` 是分片的**（同一 `index` 可能来多块，后面几块只有 `arguments`）：

```json
{"index":0,"id":"call_1","type":"function","function":{"name":"run","arguments":""}}
{"index":0,"function":{"arguments":"{\"scr"}}
{"index":0,"function":{"arguments":"ipt\":\"stat 会议记录\"}"}}
```

解析侧按 `index` 聚合、把 `arguments` 片段拼起来，最后按 index 排序输出；`id` 缺失时兜底为
`call_<index>`；丢掉没有名字的残片（让模型下一轮重来，比执行一个空名字的工具安全）。

**回灌（`messages` 里的两个角色）**

- `assistant`：带 `tool_calls`（只提工具、不说话时 `content` 允许为空串）。
- `tool`：必须带 `tool_call_id`，否则协议拒绝整条请求。

工具结果统一走一个形状（`ToolResult.encode()`）：成功 `{"ok":true,"data":…}`，失败 `{"ok":false,"error":"…"}`。
失败也是「结果」，模型据此换方案，而不是让整轮请求崩掉。

**循环**（`AgentLoop.run`，`maxRounds = 15`）：提工具 → 执行 → 回灌 → 再发一轮，直到模型不再提工具。
三条终止条件缺一个都会挂死：没提工具（正常结束）、`askUser`（挂起等用户，对话存进数据库，重启后可续）、
轮数上限 15（防「每次都提一段必然失败的脚本」导致无限烧钱；15 不是"鼓励跑满"，而是让「读 → 改 → 复查」
这种多步任务不必被硬切断）。命令语言的初衷就是**一轮脚本批处理**，多数任务 1~2 轮就够。工具的中间往来
不落库。

---

## 2. 三个容易踩的坑

### 坑 1：思考模式默认是开的，且 effort 默认 `high`

官方行为。若不管它，每一次「帮我加个标签」的轻量请求都会走完整推理链——又慢又贵。
代码里有两处印证：`deepseek_client.dart` 的 `thinking` 字段注释、`secure_store.dart` 的
`readThinkingEnabled` 注释。

本项目的处理：

| 路径 | 思考模式 |
|---|---|
| AI 助手页 | 用户在页面选思考强度：`低` → 关闭；`中` / `高` → 开启（`thinkingEnabled: _effort != 'low'`） |
| 卡片生成 | 关闭（`deepThinking: false` 默认） |
| 更早历史的压缩摘要 | 关闭（`streamChat` 不传 `thinking`） |
| 连通性自检 | 关闭 |
| ~~`organize` / `ask`~~ | 两条路径都已不在代码里（`organize` 的 prompt 与调用都已删除；`ask` 只剩 `askUser` 提示词、无调用方），所以不再有"默认值"可列 |

### 坑 2：思考模式下 `temperature` 失效

官方行为：思考模式不支持 `temperature`、`presence_penalty`、`frequency_penalty`，设置了不报错也不生效。
所以别指望「调低 temperature 让输出更稳定」，稳定性靠 prompt 约束 + JSON Output。代码里对应处理是：
思考模式下根本不传这些字段。

### 坑 3：JSON Output 有概率返回空的 `content`

官方承认。解析层实际是两级处理：

1. **解析侧三级降级**（`AiPrompts.extractJson`）：直接 `jsonDecode` → 剥掉 ```` ```json ```` 围栏后重试 →
   花括号配对截取第一个完整对象。
2. **调用侧重试**：`completeJson` 遇到空正文直接抛 `DeepSeekException(code: 'json_empty')`
   （不静默返回空串），由调用方决定。卡片生成最多 2 次尝试：`json_empty`、可重试错误、以及 JSON 解析
   失败都会重试，其它不可重试错误直接记录失败。

失败就是失败，只留一条 `ai_calls` 审计记录，没有「保留原文给用户手动确认」这条路。

---

## 3. 费用模型与省钱策略

### 3.1 价格与计价

出处：`deepseek_config.dart` 的 `DeepSeekPricing`。单位：元 / 百万 tokens。价格来源是官方价格页
（code 注释里给了链接），属于 2026 年档位且变动频繁。

| 时段 | 模型 | 输入·缓存命中 | 输入·未命中 | 输出 |
|---|---|---|---|---|
| 空闲 | `deepseek-flash` | 0.02 | 1.0 | 4.0 |
| 高峰 | `deepseek-flash` | 0.04 | 2.0 | 8.0 |
| 空闲 | `deepseek-v4-pro` | 0.15 | 4.5 | 13.5 |
| 高峰 | `deepseek-v4-pro` | 0.30 | 9.0 | 27.0 |

- **空闲时段价格是高峰的一半。** 高峰 = 北京时间周一至周五（非法定节假日）9:00–12:00、14:00–18:00。
- `isPeakHour` 只按星期 + 小时判断，不含中国法定节假日日历（config 注释明说），所以节假日会被算成高峰。
  用于估算够用，精确对账以官方账单为准。
- **缓存命中折扣**：flash 是 1/50，pro 是 1/30。

计价公式（代码原样）：

```
cached   = clamp(cachedPromptTokens, 0, promptTokens)
uncached = promptTokens - cached
元       = (cached×命中价 + uncached×未命中价 + completionTokens×输出价) / 1e6
分       = 元 × 100
```

缓存命中量怎么来：`usage` 里兼容三种命名——`prompt_cache_hit_tokens`、`cache_read_input_tokens`、
`prompt_tokens_details.cached_tokens`。

### 3.2 每一步省在哪

#### （1）输入侧：前缀稳定 + 历史钉死

| 机制 | 具体做法 | 省在哪 |
|---|---|---|
| system prompt 前缀稳定 | `prompts.dart` 硬性约束：不把时间戳、随机 ID、笔记 ID 放进 system prompt 开头；变化的东西一律 append 在末尾——更早历史的摘要拼在末尾（`withSummary`） | 命中上下文缓存后输入价降到 1/50（flash） |
| 会话历史只带最近 5 轮 | `maxHistoryRounds = 5`（一轮 = 一问一答，从倒数第 5 条 `user` 消息起） | 历史是每条消息都重发的，不设限就是 `O(N²)`；钉死之后总成本回到 `O(N)` |
| 单条历史截断 500 字 | `maxHistoryChars = 500`，截断处显式标「…（已截断）」，让模型知道后面还有 | 长的历史回答不原样重发 |
| 更早的历史压成一段摘要 | 窗口之外的轮次压成一段摘要，存进 `app_kv`（键 `ai_history_summary_<会话id>`），只生成一次，之后每轮直接读；删会话时一并清掉 | 不再每轮重复支付更早历史的输入；也不再每轮多付一次「压缩」调用 |
| 工具中间往来不重发 | assistant 的 `tool_calls` 与 `tool` 结果不落库、跨轮不带 | 不把机器中间产物当上下文反复发送 |
| 不主动带笔记 | AI 助手只发用户这句话本身；笔记原文由 AI 用 `run` 命令（`sed`/`grep`）按需读取，读到的行也只在**本轮**内回灌 | 没有"整库上传"这条路径 |

`agentSystem` 是**常量**、不含任何每会话变化的东西（工作区已取消），所以 system 前缀永远稳定，
上下文缓存能一直命中。

#### （2）读笔记按需：命令脚本，按行号读写

| 机制 | 具体做法 | 省在哪 |
|---|---|---|
| `ls` 只要名字 | 列笔记库 / 列某库内笔记，只给名字，不给正文 | 让模型先廉价地知道"有什么" |
| `stat` 给行数 | 行数、字数、大小、修改时间、所属库 | 行数是 `sed` 定位的基础，模型据此决定要不要分次读 |
| `sed -n 'A,Bp'` 按段读 | 单次最多读 200 行，超限截断并提示缩小范围 | 读长笔记先 `stat` 看行数、`grep` 定位，再 `sed -n` 只读那几行 |
| `grep` 返回行号 | 命中行返回「路径:行号: 片段」，单次最多 50 条 | 去掉「片」之后，行号是定位长笔记的唯一途径 |
| 切片**不再给 Agent** | Agent 走行号（`sed` / `grep`）；切片只服务卡片流与搜索 | Agent 拿到的永远是原文按行，不需要片索引；也少一层 `note_chunks` 依赖 |

#### （3）工具：1 个 `run` + 1 个 `askUser`

22 个 function-calling 工具收敛成 1 个「执行脚本」工具 `run`（+ 保留 `askUser` 作挂起载体）。
详细设计见 [命令语言设计](命令语言设计.md)。

| 工具 | 作用 | 风险 |
|---|---|---|
| `run` | 参数是一段 shell 风格脚本（`ls`/`stat`/`sed`/`grep`/`echo`/`rm`/`mkdir`/`mv`），可写多行、用 `set`/`for`/`if` 批处理 | 单条命令在 `NoteCommandHost` 里逐条判定（只读直接执行，写命令逐条弹确认） |
| `askUser` | 信息不足时问用户，会**挂起**，用户回答后继续 | `interaction`，不碰数据 |

- 工具定义每轮固定开销从约 3000–5000 token 降到约 250；命令语法写在 system prompt 里（约 400 token）。
- 没有分层、没有 `requestTools`、没有工具目录 —— 只有两个工具，全部完整下发。
- 工具的执行侧约定（命令粒度风险、确认、撤销、执行上限）在第 4 节。

#### （4）批量、复用、输出侧兜底

| 机制 | 具体做法 | 省在哪 |
|---|---|---|
| 卡片流并发单卡 | 一路一个请求、只要 1 张（`kGenParallelism = 4` 路），各分配不同素材 | 实测一个请求要 N 张是 O(N)（N=5 约 12s），而并行单卡只要 ~4s；额度从 `16384` 收到 `AiLimits.feedMaxOutputTokens = 2048`（正常远用不到，纯防跑飞——一次跑飞就是几千 token）。无预留时首屏只先生成 3 张（`kFeedFirstScreenCount`），其余后台补 |
| 素材是 400 字的窗口 | 每份素材 400 字（`FeedWindow.chars` = `FeedLimits.windowChars`），一次最多 4 份 → 4 × 400 = 1600 ≤ `FeedWindow.batchBudget = 4000`（= `FeedLimits.windowBatchBudget`） | 提示词长度、成本估算都围绕「一份素材 400 字」设计 |
| 标签只在输出侧约束 | 每张卡 1 个标签，≤5 个汉字 / ≤12 个英文字母 | 控制输出 token，顺带保证卡片显示不炸 |
| 卡片上只有标题，不单独生成摘要 | 提示词只要求标题是「有钩子的一句话」（早先试过单独生成卡片摘要，模型不守字数：要求 45–60 字稳定返回 116–160 字） | 每张卡少一次摘要生成，也少一个要维护的内容字段 |
| 素材不重复 | 笔记级冷却：最近 `kRecentNoteKeep = 15` 张卡片里同一篇笔记最多出现 1 次（内存，不落库） | 连着拿同一篇素材会生成高度雷同的卡片，等于白烧 |
| 同一批生成并发去重 | `refill()` 用 `_inflight` 复用同一个 future，而 `takeBatch` 取完一屏自己也会调它 | 进页面时「拉预留 + 后台补池」不会并发跑两次生成（双倍 token） |

#### （5）护栏：防「失控烧钱」

> **所有可调参数集中在一处**：`lib/core/util/app_params.dart`（其下 `AiLimits` / `FeedLimits` /
> `ChunkLimits` / `SearchLimits` / `CommandLimits` / `AgentLimits`）。下面这些值都从那里读，
> 本表只是汇总说明，改值请改 `app_params.dart`。

| 护栏 | 值 |
|---|---|
| 一次用户输入最多几轮工具往返 | `maxRounds = 15` |
| 一轮最多问用户几次 | `maxAsksPerTurn = 5`（到上限就明确拒绝并让它收尾） |
| 单次脚本命令条数 / 循环次数 / 总耗时 | 50 条 / 100 次 / 10 秒 |
| 单次 `sed -n` 读行数 / `grep` 返回条数 | 200 行 / 50 条 |
| 生成类调用的重试次数 | 2 次尝试（即最多重试 1 次），不无限重试 |

另外，写笔记侧的上限也间接保护了 AI 成本：标题超 200 字截断（标题会进 prompt）；笔记正文按 UTF-8 字节
分档 80KB / 90KB / 100KB，到 100KB 拒绝落盘（见 `app_params.dart`、`note_editor_page.dart`）。

> **AI 的命令写入走的是同一套上限**（`NoteCommandHost._checkBytes` / 标题截断）：标题超 200 字截断、
> 正文到 100 KB 硬上限拒绝（不是截断——截断等于悄悄删字，而 AI 可以拆成多篇）。`echo` 新建/覆盖、
> `sed` 的 c·d·i·a 都过这一关，而且拦在确认层之前。早先 AI 写路径完全不受约束（编辑页拦住的东西它全能绕过）。

### 3.3 没落地的省钱手段（别当成已有）

- ~~取消在途请求~~ → 决定不接：AI 的回答会写进已经保存的会话，用户切页再回来还能看到它；中途取消等于把
  已经付过钱的那半段扔掉，下回还得重问。所以 `CancelToken` 保持"能力就位、没有调用方"。真要接，
  应当是用户主动点"停止"，而不是切页就自动取消。
- **用户在设置页覆盖价格**：config 注释写着「如需精确对账请在设置页允许用户覆盖」——设置页没有这个入口。
- **空闲时段执行**：[软件理念设计](软件理念设计.md) 的省钱要义、以及原文档提的「建议在空闲时段执行批量任务」，
  代码里只有用量页一段静态文案（「批量整理放周末或晚上更便宜」），没有调度或提示交互。

---

## 4. AI Agent：工具约定、挂起与确认

> 出处：`tool_specs.dart`（清单 / 风险）、`tool_executor.dart`（执行 / 上限 / 确认 / 撤销栈）、
> `agent_loop.dart`（循环 / 上限 / 事件）、`ask_user.dart` + `ask_resolver.dart`（挂起 / 选项）、
> `ai_chat_repository.dart`（窗口 / 摘要 / 挂起落库）、`history_chunker.dart`（会话切片）。
> 协议报文（`tools` / `tool_calls` / `role: tool`）见 1.4，事件类型见 1.3，省 token 的角度见 3.2（3）。

### 4.1 工具清单、风险分级与调用约定

工具只有 2 个：`run`（执行命令脚本）与 `askUser`（挂起提问）。完整设计见
[命令语言设计](命令语言设计.md)。这里写执行侧的约定：

- **命令的风险在命令粒度上判**：`ToolRisk` 五档保留，但由 `NoteCommandHost` 对**每条命令**判定 ——
  `ls`/`stat`/`sed -n`/`grep` 是只读（直接执行），`echo`/`sed` 的 c·d·i·a/`mkdir` 是创建/修改，
  `rm` 是删除（二次确认、写明不可恢复），`mv` 是修改。
- **写命令逐条弹确认**：脚本里混了写命令时，前面的只读命令先跑，遇到写命令就暂停弹框；用户允许才执行，
  拒绝则**跳过这一条、继续下一条**（不中断整个脚本）。
- **没有确认通道 → 写命令一律拒绝**（fail closed，与原来同一条规则，只是下沉到了命令粒度）。
- **参数即脚本**：`run` 的参数只有一个 `script` 字符串；不需要把参数做成 JSON Schema 的字段。
- **结果形状统一**（`ToolResult.encode()`）：成功 `{"ok":true,"data":"<执行记录文本>"}`、失败
  `{"ok":false,"error":"…"}`。语法错误整段拒绝；单条命令失败只影响那一条。
- **不再有工作区**：命令直接作用于**整个笔记库根目录**（`AiChatRepository` 建执行器时不再传范围）。
  这也意味着 `system prompt` 是常量、前缀永远稳定，上下文缓存一直能命中。
- **参数一律宽松接受**：`parseArgs` 在 `arguments` 是坏 JSON 时返回空 map，让"缺 `script`"这类具体抱怨
  把模型纠正过来，而不是抛异常打断整轮。

### 4.2 改正文：`sed` 行号 + 读改连续

命令语言下改正文靠 `sed` 按**行号**，不再是 `expectedText` 锚点：

```
stat 工作笔记/会议记录            ← 先看有多少行
sed -n '10,14p' 工作笔记/会议记录  ← 读出目标行、确认行号
sed '12c 新的第 12 行' 工作笔记/会议记录   ← 按行号替换（弹确认）
sed '12a 补充一句' 工作笔记/会议记录        ← 在某行后插入（弹确认）
```

- **行号怎么保证不漂移**：`system prompt` 要求"要改笔记必须**在同一个脚本里**先用 `sed -n` 读出目标行、
  拿到行号后再改"。读改在同一脚本里连续执行，行号就是当时那一份；单用户本地场景下用户不可能在
  两次命令之间手改笔记。
- **越界就是失败**：`sed '100c …'` 在一篇 45 行的笔记上会失败并提示"先用 stat 确认行数"，
  绝不静默改到别处。
- **撤销栈存整行 `Note`**，不是"id + 正文"：`upsertNote` 要求带齐所有"非空且无默认值"的列（`createdAt`
  就是），只存 id + 正文会在写回时被 Drift 抛 `InvalidDataException`。栈深 `maxUndo = 5`
  （撤销是"手滑了救一下"，不是版本历史）；撤销走 `_writeNote`，所以会重切切片（否则搜索会指向错位置）。
- **写命令都进撤销栈**：`echo` / `sed` 的 c·d·i·a 都 `rememberUndo`（`mv` 的重命名也记；纯移动不记）。

### 4.3 执行上限（App 强制，不靠模型自觉）

上限从"每轮几片"改成了**单次脚本**级别（见 [命令语言设计](命令语言设计.md) §8.6）。

| 上限 | 值 | 出处 |
|---|---|---|
| 一次 `run()` 的工具往返轮数 | `maxRounds = 15` | `agent_loop.dart` |
| 单次脚本命令条数 | `CommandLimits.maxCommands = 50` | `command_interpreter.dart` |
| 单次 `sed -n` 读行数 | `NoteCommandHost.maxSedReadLines = 200` | `note_command_host.dart` |
| 单次 `grep` 返回条数 | `NoteCommandHost.maxGrepHits = 50` | `note_command_host.dart` |
| 单次 `for` 循环次数 | `CommandLimits.maxIterations = 100` | `command_interpreter.dart` |
| 单次脚本总耗时 | `CommandLimits.budget = 10 秒` | `command_interpreter.dart` |
| `askUser` 每轮次数 | `maxAsksPerTurn = 5`（跨恢复累计） | `agent_loop.dart` |
| 模型自带 `askUser.options` | 取前 10 条；`limit` 默认 10、`clamp(1,10)` | `agent_loop.dart` |
| 撤销栈深度 | `maxUndo = 5` | `tool_executor.dart` |

超限一律**截断并提示"结果已截断，请缩小范围"**。语法错误（如 `if` 没有配对的 `end`）整段拒绝并给出
出错行号；引用未定义变量则中止整段脚本。

### 4.4 挂起机制：`askUser`

**循环在 `askUser` 处直接 `return`**，不是"等一会儿再继续"：`AgentLoop` 产出 `AgentAwaitingUser`
（带 `toolCallId`、`asks`、以及提问那一刻的整段对话）后停下，工具结果等用户答完再补。

**状态存哪**：`ai_messages.pendingAction`，内容是 `PendingAsk` 的 JSON 字符串。写它和写提问文本在同一个
事务里——分开写会留下两种都很难查的状态：有挂起没提问文本（用户看到一张空白卡片）／有文本但挂起失效
（点了没反应）。

**为什么没有超时**（`askUser` 这条路径上没有任何计时器）：

1. 超时等于让 App 凭空造一个用户从没给过的回答；
2. 手机上"前台等 5 分钟"本来就不现实；
3. 和"本地优先"的定位不搭。

所以用户三小时后回答、甚至重启 App 之后回答都行，也没有"超时之后又回答"的竞态。只有用户主动取消
（或回答）才清挂起标记。

**跨重启怎么恢复**：

```
pendingAsk(会话id)   → 从库里读那条消息的 pendingAction（不是内存状态）
answerAsk(...)       → history = pending.messages + 一条 role: tool 的结果
                     → 同一个事务：清 pendingAction + 把"（等你回答）"换成正式内容
                     → _drive(..., append: true, asksSoFar: pending.asks)
```

- 冷启动、切页回来都能把答题卡重新显示出来，不用先发一句话。
- 记录损坏（JSON 解析失败）→ 当成没有挂起并清掉，而不是让会话永远卡在"等回答"。

**流式写入必须是"替换式"，不能是"接龙式"**：

`AgentText` 事件带的是这一段该怎么显示的累计文本（不是本次增量），所以把它写进消息时用的是
「续写起点 + 累计文本」整体覆盖那一行。续写起点（`_drive` 的 `base`）在本次 `run()` 开始时读一次就定死，
行里如果是「（等你回答）」占位符则起点为空——那第一段输出就会顶掉占位符，而不是接在它后面。

如果每写一次都重新读一遍行内容再 `before + '\n\n' + text`，就等于把上一次刚写进去的累计文本又当成前缀：
第 k 个分片会把前 k-1 个分片重写一遍，一段几百字的回答滚成几十 KB 的重复，用户看到的是同一句话按字数递增地
重复上百遍（`已` / `已删除，` / `已删除，「我的轻笔记」…` 这种锯齿）。单事件（一次 `fullText`）时只多出
一份，看着像正常的换行拼接；真流式（多分片）才会放大成一眼可见的垃圾——所以它只在"挂起 → 回答 → 接着跑"
这条路径上出现。由此推出一条通用规矩：**流式渲染写库要幂等**——把同一个累计文本写两次，结果必须和写一次一样。
回归用例见 `ask_flow_test.dart` 的「流式分片续写」（它用多分片的假客户端把这条钉住）。

**`askUser` 次数为什么必须跨恢复累计**：循环在 `askUser` 处 `return`，用户回答后是新的一次 `run()`；
计数只活在新循环里的话每次都从 0 起，`maxAsksPerTurn = 5` 永远到不了，用户会被反复问。所以 `asks` 存进挂起
记录（`PendingAsk.asks`，解析时 `clamp(1,99)`），恢复时用 `asksSoFar` 带回来。到上限不是简单丢弃，
而是回一条明确的失败："这一轮已经问过 5 次了，不要再问。请用现有信息给出最好的答案……"。

> 只有 `askUser` 的次数被带回来了：`maxRounds` 在每次 `run()` 里重新从 0 数，挂起恢复后轮数预算会重置；
> `_drive` 每次都新建 `ToolExecutor`，所以撤销栈也不跨 `run()`（既包括挂起恢复，也包括下一句
> 用户输入）。

**选项为什么由 App 现查**（`AskResolver`）：模型只给筛选条件
`source: {kind: 'search' | 'notebooks' | 'recentNotes', query?, notebookId?}`，清单由 App 现查现填：

- 库里 200 条笔记时模型塞不进 prompt，也记不住 id（会编）；
- 模型给的清单会变旧——用户刚删掉的笔记还在选项里，点下去就是"找不到这条笔记"；现查的清单永远和库一致；
- 搜索命中同一篇笔记的多片时只留一条（用户选的是"哪一篇"，不是"哪一片"）；`query` 为空退化成"最近笔记"；
  未知 `kind` 也走搜索（比直接失败有用）；
- 选项是打开答题层那一刻才查的（`AiPage._answerPendingIfAny` 拿挂起记录里的 `request` 现查，发送前后各查一次）：
  挂起期间用户删了笔记、改了库，他看到的也是最新清单；
- 模型直接给 `options` 仍允许（不用 `source` 时的兜底）：丢掉没有 `id` 的项，取前 `limit` 条；
- 单选 / 多选在语义上"必须要有选项"，但解析层没有强制这一条（`AskType.needsOptions` 定义了却没有调用点）；
  选项为空时答题层显示「没有找到可选项。可以取消，然后用一句话告诉我该怎么做。」

**结果形状固定成一种**（`AskResult.encode()`）：`status` / `selections` / `text` / `confirmed`，
用不到的给 `null`——形状多变最容易让模型解析出错。另外：

- **空串也算"答了"**（要不要重问交给模型判断，而不是 App 替它决定）；
- **取消 = 拒绝**；确认题取消时会补 `confirmed: false`，让模型少做一次推断；
- `allowCancel` 永远是 `true`：一是"拒绝"本身就是合法回答，二是禁掉之后用户直接关掉 App 会让对话永久挂起。

三条实现时踩到的坑：

1. **不要双重编码**：回灌 `askUser` 结果时 `AskResult.encode()` 已经是 JSON 字符串，不要再 `jsonEncode`
   一次（模型会看到一段"字符串化的 JSON"）；但要包成 `ToolResult` 的形状（`{ok, data}`），否则模型见到的
   某个工具结果是"裸对象"，它会误判。
2. **`tool_calls` 必须一起还原**：`PendingAsk.tryParse` 重建 assistant 消息时要带 `tool_calls`——协议要求
   `role: tool` 的结果必须被前一条 assistant 的 `tool_calls` 引用，丢掉的话用户一回答整条请求就被拒
   （而且还是接口层面的错，很难查）。
3. **存提问那一刻的 `messages`，不是这一轮开始前的 `history`**：工具往来不落库，用错 `history` 就缺了本轮的
   工具调用，用户回答完没法接着跑。

### 4.5 确认流程：风险拦截在 App

**写命令只有一个确认入口**（`NoteCommandHost._confirm`），三件事按顺序做、缺一不可：

1. **没有确认通道 → 一律拒绝**（`onConfirm == null`，fail closed）。反过来"默认放行"意味着任何一条漏接的
   回调都变成"AI 能随便改用户的数据"，而且不报错。
2. 弹框问用户；被拒 → 返回失败结果（"用户拒绝了这次操作……不要重试同一个操作；换个做法，或者问用户想怎么做"）。
   "用户拒绝"是合法回答而不是错误，但必须让模型知道——否则它会以为改完了，静默失败比报错糟得多。
   **拒绝只跳过这一条命令，脚本继续跑**。
3. 同意 → 执行。

- **与模型行为解耦**：风险由 `NoteCommandHost` 对**每条命令**判定，模型绕不过去 —— `rm` 一定弹二次确认，
   与它是否"记得问用户"无关。
- **确认层要给人看的东西**：`before` / `after`（改前 vs 改后；`sed` 传整篇前后对照）、`strong`
  （删除时按钮改成红色「删除」而不是「允许」，摘要里写明"删了就找不回来"）。摘要压扁到 40 字，
  太长会撑爆弹层。
- **删除的代价**：`rm` 确认后直接删；没有回收站、没有恢复入口。内部仍是软删除（`deletedAt` 置位、
  行还在）——那是防 bug、留后路，不是给用户的回收站。软删不触发外键级联，所以切片要显式清掉
  （留着会让搜索把"命中"算到已删的笔记头上）。
- **一次提议只执行一次**：UI 的确认层用 `_once` 标志挡住重复点击，并且 `barrierDismissible: false`
  （点外面不算同意，必须明确选）。

### 4.6 会话历史：切片、窗口、摘要

这一节只补机制；"最近 5 轮 / 单条 500 字 / 更早的压成一段摘要且只生成一次"这三条省 token 的手段与理由
已在 3.2（1）。

```dart
HistoryChunker.chunk(messages)   // 一片 = 一轮；上限 700 / 下限 300，与笔记切片同一套；不落库，每次现算
HistoryChunker.catalog(...)      // 目录：默认最近 20 片、上限 50，userSnippet 40 字，不含正文
HistoryChunker.slice(indexes)    // 正文：≤3 片、≤1500 字；越界 index 跳过而不是抛错
```

- **不落库**：会话每问一句就追加，落库会让表跟着对话无限增长，而几十轮现算是毫秒级。因为不落库，片里直接
  带正文，省掉"偏移"那一层间接和随之而来的"偏移过期"问题（笔记切片相反：`note_chunks` 只存偏移，
  正文永远从 `notes.content` 现取）。
- **`tool` 消息的正文不进片**：机器中间产物对"回看我们聊了什么"没有价值，放进去只是烧 token；
  但轮次的边界仍然包含它们。
- **索引只往后追加**：新的一轮只追加新片，旧片的 `index` / `text` 不变（会话是只增的）。
- **工具中间往来不落库**（assistant 的 `tool_calls` 与 `tool` 结果只活在本轮内存里），所以它不可能出现在窗口里；
  窗口只从"倒数第 N 条 `user`"起切（`historyWindowOf` 与 `olderHistoryOf` 共用同一个 `_windowStart`，
  两边严格互补，一条不多一条不少）。

  > ⚠️ 命令语言改造后，工具只剩 `run` / `askUser`，**会话历史的 `listHistory` / `readHistory` /
  > `searchHistory` 三个工具已移除**。`HistoryChunker` 类与其测试暂留，但当前无调用方；
  > 对话窗口仍按上面规则工作。

  > `HistoryChunker` 对超过 700 字的一轮会按段落 / 句子继续拆，所以"片边界 = 轮边界"只对 ≤700 字的
  > 一轮成立。这不影响协议安全——片正文是渲染后的文本，从来不会当作 `messages` 回灌。
- **摘要**（更早的轮次）：`olderHistoryOf` 取窗口之外的轮次 → 用 `streamChat`（不是 `AiRepository.ask`：
  后者会去检索用户的笔记，拿来压缩对话既跑偏又白花钱）压成一段 → 存 `app_kv` 的
  `ai_history_summary_<会话id>` → 只生成一次，之后每轮直接读；压缩失败不让整轮失败（没有摘要顶多多花点
  token）；删会话时按同一个键清掉。它拼在 system prompt 的末尾（`withSummary`），不占历史消息位置、
  也不改写历史（保缓存）。

### 4.7 验收口径与上线后要观察什么（AI 行为）

**可断言的验收口径**（这些点都有对应测试文件：`agent_loop_test` / `agent_dialogs_test` /
`deepseek_tool_calling_test` / `ask_user_test` / `ask_flow_test` / `history_window_test` /
`history_summary_test` / `history_chunker_test`；是否全绿以 `flutter test` 为准）：

- [x] `run` 的脚本能读能写：`ls`/`stat`/`sed -n`/`grep` 批量执行、一次性回灌
- [x] 写命令逐条弹确认；用户拒绝则**跳过这一条、继续下一条**
- [x] 语法错误整段拒绝并给出出错行号；未定义变量中止整段
- [x] 历史自动 5 轮、单条 ≤500 字；更早历史压缩摘要只生成一次（用调用次数验证）
- [x] 风险拦截在 App，与模型行为解耦（没有确认通道时写命令一律拒绝）
- [x] `sed` 行号越界返回错误，且一个字都不改（连确认层都不弹）
- [x] `askUser` ≤5（跨恢复累计）、轮数上限 15

> 旧的验收项（`listChunks` / `readChunk` 预算、`expectedText` 锚点、`requestTools`、批量工具）随
> 命令语言改造已作废；对应的旧测试文件（`tool_specs_test` / `tool_executor_test` / `tool_delete_test` /
> `tool_write_test` / `agent_workspace_test` 等）已不在仓库里，验收改由上面列出的测试承担。

> **真机端到端（`agent_live_test.dart` / `agent_search_live_test.dart`）：未做。**
> 那 3 份真机测试已删除（不会真的去跑，留着只是维护负担）。代价是"协议报文形状 / 模型会不会主动调工具 /
> 真实 SSE 分片方式"三类失去自动化覆盖，回归只能靠人工；原因与"将来要加回来怎么做"见
> [测试设计](测试设计.md) 第四节。

**上线后观察**：

| 观察项 | 怎么观察 | 出问题说明什么 |
|---|---|---|
| 工具调用的 token 占比 | `ai_calls` 的 `prompt_tokens`（不含缓存命中量，见 5.4） | 命令语言没省下来，或缓存没命中 |
| `askUser` 触发频率 | 数一轮对话里的次数 | 太高 → `askUser` 工具描述里的"能推断的就别问"没生效 |
| 挂起未恢复的会话 | `ai_messages.pendingAction` 长期非空的条数 | 恢复逻辑有 bug |
| 确认层拒绝率 | 用户点「取消」的比例 | 太高 → AI 定位不准（`sed` 行号读错） |
| 脚本语法错误率 | `run` 返回"脚本语法错误"的次数 | 太高 → system prompt 里的语法说明需要加强 |
| 单条命令失败率 | 脚本执行记录里 `ok:false` 的比例 | 太高 → 错误信息没有教会模型怎么改 |
| 崩溃 / 未捕获异步错误 | 现有 `_StartupGate` + 日志 | 工具执行器里的 async 边界（每个 `await` 之后都要查 `mounted`） |

---

## 5. 调用审计（`ai_calls`）与用量页

### 5.1 表结构

出处：`lib/core/db/tables.dart` 的 `AiCalls`

| 列 | 说明 |
|---|---|
| `id` | uuid |
| `note_id` | 可空（见 5.4） |
| `task` | 实际会出现：`feed_generate` / `agent`；`organize` / `ask` / `note_summary` 已无调用方 |
| `model` | 模型名 |
| `thinking_enabled` | 思考模式是否开启 |
| `prompt_tokens` / `completion_tokens` | 用量 |
| `cost_cents` | 估算成本（分） |
| `latency_ms` | 耗时 |
| `success` | 成功与否 |
| `error_code` | `401` / `429` / `timeout` / `json_empty` / … |
| `created_at` | 时间 |

**隐私约束（表注释）：本表不存 prompt / 响应全文，无条件、没有开关。**

### 5.2 谁写、写什么

- 统一入口是 `AiRepository._logCall`；写库失败静默吞掉，审计不能影响主流程。
- 业务调用（`feed_generate` 等）各自记一条，成功与失败都记（失败带 `error_code`）。
- AI 助手是另一条：`AiChatRepository._log` → `AiRepository.logChatCall`，`task = 'agent'`。它记的是整轮
  累计用量（多轮工具往返合起来记一条）——只记最后一次会让「工具用得越多、成本越低」这种假象出现。
- `task` 的 `organize` / `ask` / `note_summary` 三条路径当前没有调用方（`note_summary` 随笔记摘要
  一起删除），所以实际会出现的 `task` 是 `agent` / `feed_generate`。

### 5.3 用量页怎么对上

出处：`lib/features/settings/ui/pages/usage_settings_page.dart`、`app_database.dart`

- 页面上的数字 = `watchTotalCostCents()` = `SELECT SUM(cost_cents) FROM ai_calls`，随表变化自动刷新。
  没有按时间/按任务的分组统计。
- 显示格式：< 0.01 分显示「＜0.01 分」，< 100 分显示「x.xx 分」，否则换算成「x.xx 元」。
- 「清空 AI 历史」在设置 → 存储页（`clearAiHistory()`），清空后这个累计值一并归零；页面文案已经写明这一点。
- 页面文案自己声明了边界：价格按官方公布价格估算、区分高峰/空闲（空闲是高峰的一半）、实际扣费以官方账单为准。

### 5.4 对不上的地方（需要知道，不要拿它当账单）

1. **`ai_calls` 不存缓存命中 token。** 表里只有 `prompt_tokens` / `completion_tokens`，所以从表里无法核对
   缓存是否真的命中。`cost_cents` 在写入时按当次 usage（含命中量）算出，但事后不可复算、不可审计。
2. **`agent` 那条的成本会偏高。** `logChatCall` 收下了当轮带缓存折扣的 `costCents`，却把它丢掉，只用
   `TokenUsage(prompt, completion)` 重新估算（`cachedPromptTokens` 留空）——等于按未命中价计价。缓存命中越多，
   这条记录越偏高。已无调用方的 `ask` 路径同样把命中量丢掉了。
3. **`note_id` 实际上全是空。** 所有有调用方的写入点都传 `noteId: null`（`feed_generate` 显式传
   null，`agent` 由 `logChatCall` 固定传 null）；传了 noteId 的 `organize` 没有调用方。
   所以「按笔记对账」现在做不到。
4. **价格是代码常量、无节假日日历、无用户覆盖**：节假日会被算成高峰；官方调价后 App 里的估算不会自动跟着变。
