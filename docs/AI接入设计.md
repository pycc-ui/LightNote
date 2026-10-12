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
| 模型名 | `deepseek-flash`（`modelFlash`，App 固定使用这一个）；`deepseek-v4-pro` 官方也有，但 App 未使用（`modelPro` 常量已删） |
| 上下文 / 最大输出（常量声明） | `maxContextTokens = 1000000` / `maxOutputTokens = 384000` |
| 连接超时 | 20 秒 |
| 读超时 | 5 分钟 |

三条值得单独记住的事实：

1. **模型名用 `deepseek-flash`。** config 注释写明：旧名 `deepseek-v4-flash` 仍可调用，但对应模型已下线，
   请求会由新模型代答。
2. **所有真实业务请求目前都是 flash。** AI 助手与历史压缩在 `ai_chat_repository.dart` 里硬编码
   `DeepSeekConfig.modelFlash`；卡片生成、摘要、问答的默认参数也是 flash。设置页写的模型名
   （`SecureStore.readModel()`）只有两个读取点：设置首页显示、以及设置页的「测试连接」；也就是说
   **在设置页把模型切成 pro，不会改变任何一次真实调用**。
3. `maxOutputTokens = 384000` 只是声明，从不是实际用量——每次调用都显式给 `max_tokens`（见 1.2 末）。

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
| `max_tokens` | 实际用到：卡片生成 `16384`、单篇摘要 `1200`、连通性自检 `64`、`completeJson` 默认 `4096` |

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
`AgentFailed` / `AgentToolStarted` / `AgentToolDone` / `AgentToolsGranted`（思维链在 agent 路径被丢弃、不展示）。

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

```json
{"type": "function",
 "function": {"name": "readChunk", "description": "读某篇笔记的一片正文……", "parameters": {"type": "object", "properties": {"noteId": {"type": "string"}, "index": {"type": "integer"}}, "required": ["noteId", "index"]}}}
```

`description` 是写给模型看的：写「什么时候用它」，不是「它是干什么的」。

**流式回来的 `tool_calls` 是分片的**（同一 `index` 可能来多块，后面几块只有 `arguments`）：

```json
{"index":0,"id":"call_1","type":"function","function":{"name":"listNotebooks","arguments":""}}
{"index":0,"function":{"arguments":"{\"que"}}
{"index":0,"function":{"arguments":"ry\":\"x\"}"}}
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
轮数上限 15（防「每次都提一个必然失败的工具」导致无限烧钱；15 不是"鼓励跑满"，而是让「搜 → 看目录 →
读片 → 改 → 复查」这种多步任务不必被硬切断）。工具的中间往来不落库，跨轮要回看更早内容走 `listHistory` /
`searchHistory` / `readHistory` 工具。

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
| 单篇摘要 | 关闭 |
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
   （不静默返回空串），由调用方决定。卡片生成最多 2 次尝试，`json_empty` 也会重试；单篇摘要也是 2 次尝试，
   但 JSON 解析失败才重试，`json_empty` 与其它不可重试错误直接记录失败。

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
| system prompt 前缀稳定 | `prompts.dart` 硬性约束：不把时间戳、随机 ID、笔记 ID 放进 system prompt 开头；变化的东西一律 append 在末尾——更早历史的摘要拼在末尾（`withSummary`），工具目录拼在末尾（`_systemWithCatalog`） | 命中上下文缓存后输入价降到 1/50（flash） |
| 会话历史只带最近 5 轮 | `maxHistoryRounds = 5`（一轮 = 一问一答，从倒数第 5 条 `user` 消息起） | 历史是每条消息都重发的，不设限就是 `O(N²)`；钉死之后总成本回到 `O(N)` |
| 单条历史截断 500 字 | `maxHistoryChars = 500`，截断处显式标「…（已截断）」，让模型知道后面还有 | 长的历史回答不原样重发 |
| 更早的历史压成一段摘要 | 窗口之外的轮次压成一段摘要，存进 `app_kv`（键 `ai_history_summary_<会话id>`），只生成一次，之后每轮直接读；删会话时一并清掉 | 不再每轮重复支付更早历史的输入；也不再每轮多付一次「压缩」调用 |
| 工具中间往来不重发 | assistant 的 `tool_calls` 与 `tool` 结果不落库、跨轮不带 | 不把机器中间产物当上下文反复发送 |
| 附件可控 | AI 助手单次最多带 8 条笔记、单条正文截断 6000 字（`maxContextNotes` / `maxCharsPerNote`） | 上限是硬的，不随用户勾选数量漂移 |

一处**前缀稳定性上的例外**：`agentSystem` 把「当前工作区：…」写在第 2 行，所以切换工作区会让这段前缀
失效一次（换工作区才发生，不是每轮）。

#### （2）读笔记按需：目录先行，正文按片取

| 机制 | 具体做法 | 省在哪 |
|---|---|---|
| `listNotes` 只要元数据 | DB 侧用 `selectOnly(notes)` 只取 `id` / `title` / `notebookId` / `updatedAt` 四列（`noteBriefs`），默认 50 条、上限 100；固定 `updatedAt DESC` | 工具描述既然写「比 searchNotes 省钱」，实现就必须真的不读正文；顺序本身就是给模型的线索 |
| `listChunks` 只给目录 | 每片只回 `index` / `heading` / `level` / `charCount`，不含正文 | 5000 字的笔记直接灌进去要几千 token，目录只要几十个 |
| `readChunk` 按轮限量 | `maxChunksPerTurn = 3`、`maxChunkCharsPerTurn = 1500`，每轮 `beginTurn()` 重置 | 模型很容易连着读五片把整篇灌进来；超预算直接返回失败并提示「先用已有内容回答」 |
| 切片本身有界 | 片硬上限 700 字，不可拆散单元硬顶 1500 字 | 片若超过 1500，AI 根本读不进来，作为「片」就没意义 |
| `readHistory` 同口径 | ≤3 片、≤1500 字（`HistoryChunker.slice` 的 `maxPieces=3, maxChars=1500`） | 回看历史也不允许整段灌入 |

> 措辞上的不一致（不是行为问题）：`readChunk` 的工具描述写「一次最多 3 片」，但它的 schema 只有一个
> `index` 参数——真正生效的是「一轮最多 3 片、合计 ≤1500 字」。

#### （3）工具分层下发

工具共 22 个：核心 7 / 常用 10 / 按需 5（`tool_specs.dart`）。

| 层 | 每轮发什么 | 数量 |
|---|---|---|
| 核心层 | 完整定义（含参数 schema） | 7：`searchNotes` `listChunks` `readChunk` `createNote` `updateNote` `askUser` `requestTools` |
| 常用层 | 完整定义，但没有参数 schema（描述压成一句话） | 10：`listNotebooks` `listNotes` `getNoteMeta` `appendToNote` `deleteNote` `moveNote` `createNotebook` `replaceInNote` `listHistory` `readHistory` |
| 按需层 | 默认不发定义，只在 system prompt 末尾的「工具目录」里给「名字 + 一句话」；被 `requestTools` 批准后才进 `tools` | 5：`renameNotebook` `deleteNotebook` `batchMoveNotes` `batchDeleteNotes` `searchHistory` |

- `specsForRequest` 的实际条件是 `core || common || granted`，所以常用层是"发定义但省掉 schema"，
  不是"只发名字"；只有按需层走目录文本（`toCatalogLine()`）。
- `requestTools` 单次最多批 6 个，重复申请或不存在的名字会被拒并说明原因——省掉无效往返。
- 分层本身还是一层摩擦：按需层的 5 个工具要么危险、要么少用，先申请一次能挡掉一部分「顺手就调了」。
- 工具的执行侧约定（风险分级、参数锚点、每轮硬上限、挂起与确认）在第 4 节；这里只讲"发什么、省在哪"。

#### （4）批量、复用、输出侧兜底

| 机制 | 具体做法 | 省在哪 |
|---|---|---|
| 卡片流一批出 9 张 | `kFeedGenerateCount = 9`，`maxTokens = 16384` | 一次请求拿 9 张，比分三次各拿 3 张省两次往返，素材 prompt 只发一次；额度给足是因为截断后 JSON 解析失败 = 整批白烧 |
| 素材是 400 字的窗口 | 每份素材 400 字（`FeedWindow.chars`），9 × 400 = 3600 ≤ `batchBudget = 4000` | 提示词长度、成本估算都围绕「一份素材 400 字」设计 |
| 摘要持久化复用 | 摘要存进 `ai_note_summaries`（一篇笔记一条，新摘要覆盖旧的），卡片流下次直接用；只为真正会用到的笔记生成摘要；生成失败退回正文截断 | 摘要是长期复用的资产，不是每次重新生成；退化路径不额外花钱 |
| 摘要失效只在变化够大时 | 用源正文的 UTF-8 字节数判断是否过期，变化幅度要超过 `staleRatio = 0.20` 才重生成——不看 `updatedAt` | 用户改个错别字不会让摘要作废，避免「每次编辑都白烧一次调用」 |
| 摘要输出硬截断 | `summaryHardMax = 300` 字（目标 150–250，`max_tokens = 1200`） | 模型不守字数，要求 60 字会返回 160 字，代码必须兜底 |
| 标签只在输出侧约束 | 每张卡 2–6 个标签，每个 ≤5 个汉字 / ≤12 个英文字母 | 控制输出 token，顺带保证卡片显示不炸 |
| 卡片上只有标题，不单独生成摘要 | 提示词只要求标题是「有钩子的一句话」（早先试过单独生成卡片摘要，模型不守字数：要求 45–60 字稳定返回 116–160 字） | 每张卡少一次摘要生成，也少一个要维护的内容字段 |
| 素材不重复 | 笔记级冷却：最近 `kRecentNoteKeep = 12` 张卡片里同一篇笔记最多出现 1 次（内存，不落库） | 连着拿同一篇素材会生成高度雷同的卡片，等于白烧 |
| 同一批生成并发去重 | `refill()` 用 `_inflight` 复用同一个 future，而 `takeBatch` 取完一屏自己也会调它 | 进页面时「拉预留 + 后台补池」不会并发跑两次生成（双倍 token） |

#### （5）护栏：防「失控烧钱」

| 护栏 | 值 |
|---|---|
| 一次用户输入最多几轮工具往返 | `maxRounds = 15` |
| 一轮最多问用户几次 | `maxAsksPerTurn = 5`（到上限就明确拒绝并让它收尾） |
| 单次申请工具数 | `maxRequestTools = 6` |
| 批量工具条数 | ≤10 |
| 生成类调用的重试次数 | 2 次尝试（即最多重试 1 次），不无限重试 |
| 单条笔记正文进 prompt 的上限 | AI 助手 6000 字；`ask` 路径 4000 字（该路径当前无调用方） |
| prompt 正文上限常量 | `AiPrompts.summaryInputMaxChars = 20000`（`noteSummaryUser` 用它截单条正文）。按成本定、且真能触发：摘要是 ≤300 字的概括，2 万字够用；3 万字以上的笔记会被截断，提示里明说被截了。（早先叫 `maxBodyChars = 200000`，比"笔记 100 KB 硬上限"还大，永远触发不了；上限的完整清单见《软件理念设计》第 3 节） |

另外，写笔记侧的上限也间接保护了 AI 成本：标题超 200 字截断（标题会进 prompt）；笔记正文按 UTF-8 字节
分档 80KB / 90KB / 100KB，到 100KB 拒绝落盘（见 `ai_limits.dart`、`note_editor_page.dart`）。

> **AI 的工具写入走的是同一套上限**（`ToolExecutor._fitForSave`）：标题超 200 字截断、正文到 100 KB
> 硬上限拒绝（不是截断——截断等于悄悄删字，而 AI 可以拆成多篇）。`createNote` / `updateNote` /
> `appendToNote` 三条路都过这一关，而且拦在确认层之前，工具描述里也写了这两个数。早先 AI 写路径完全
> 不受约束（编辑页拦住的东西它全能绕过）。

### 3.3 没落地的省钱手段（别当成已有）

- ~~取消在途请求~~ → 决定不接：AI 的回答会写进已经保存的会话，用户切页再回来还能看到它；中途取消等于把
  已经付过钱的那半段扔掉，下回还得重问。所以 `CancelToken` 保持"能力就位、没有调用方"。真要接，
  应当是用户主动点"停止"，而不是切页就自动取消。
- **用户在设置页覆盖价格**：config 注释写着「如需精确对账请在设置页允许用户覆盖」——设置页没有这个入口。
- **空闲时段执行**：[软件理念设计](软件理念设计.md) 的省钱要义、以及原文档提的「建议在空闲时段执行批量任务」，
  代码里只有用量页一段静态文案（「批量整理放周末或晚上更便宜」），没有调度或提示交互。

---

## 4. AI Agent：工具约定、挂起与确认

> 出处：`tool_specs.dart`（清单 / 风险 / 分层）、`tool_executor.dart`（执行 / 上限 / 确认 / 撤销栈）、
> `agent_loop.dart`（循环 / 上限 / 事件）、`ask_user.dart` + `ask_resolver.dart`（挂起 / 选项）、
> `ai_chat_repository.dart`（窗口 / 摘要 / 挂起落库）、`history_chunker.dart`（会话切片）。
> 协议报文（`tools` / `tool_calls` / `role: tool`）见 1.4，事件类型见 1.3，省 token 的角度见 3.2（3）。

### 4.1 工具清单、风险分级与调用约定

工具共 22 个（核心 7 / 常用 10 / 按需 5），分层与"每轮发什么"已在 3.2（3）。这里写执行侧的约定：

- **风险级别是数据，不是执行器里的 `if`**：`ToolRisk` 五档 `read` / `create` / `modify` / `delete` /
  `interaction`；`needsConfirm` 对创建 / 修改 / 删除三档为真。做成工具定义的一部分，加新工具时必须显式声明
  （漏了编译器会提醒）；散在一个 `switch` 里迟早会漏掉一个。
- **每轮真正发出去的定义**是 `core || common || granted`：7 个核心 + 10 个常用 + `requestTools` 已批准的
  按需项。按需层在批准之前只出现在 system prompt 末尾的「工具目录」里（名字 + 一句话）。
- 协议要求 `tools` 数组每一项都带完整 JSON Schema，所以常用层是发完整定义、只把 `description` 压成一句话，
  不是"只发名字"；"只发名字"只存在于目录文本里。
- `requestTools`：只取前 6 个；不存在的名字、已经批准过的名字、以及核心/常用层的名字都会被拒并给出原因
  （后两类本来就有完整定义，申请它只是白跑一轮）。
- **命名约定**：`list*` 只给元数据、`read*` 给正文、`get*Meta` 给一条的元信息、`search*` 给"命中哪一片"；
  笔记与会话各一套（`listChunks` / `readChunk` 与 `listHistory` / `readHistory`，`searchNotes` 与
  `searchHistory`），模型才不会把两者混起来。
- **追加与重写分开**：往末尾加内容用 `appendToNote`（拼接在 App 侧做，输入长度只和"要加的东西"成正比），
  不要用 `updateNote` 先读全文再整体写回——后者抄漏一段是静默丢内容。追加同样走确认层与撤销栈，
  不能因为"只是追加"就免确认（那会开出一条不需要点头的写入通道）。
- **参数一律宽松接受**：`_str` / `_int` / `_asInt` 容忍"该给整数给了字符串"；`arguments` 是坏 JSON 时
  不抛错，`parseArgs` 返回空 map，让后面"缺 `query`"这类具体抱怨把模型纠正过来。
- **名字对不上**（模型编了一个工具）→ 失败并提示"需要别的工具先用 `requestTools` 申请"。
- **结果形状统一**（`ToolResult.encode()`）：成功 `{"ok":true,"data":…}`、失败 `{"ok":false,"error":"…"}`。
  失败也是"结果"，抛异常会把整轮对话打断。
- 工具**不该看到工作区之外**：`ToolExecutor.workspace` 是上限，模型自己传的 `notebookId` 只能收窄；
  要的库不在工作区时返回"空范围"（既不命中、也不偷偷放宽成整个工作区）。`AiChatRepository._drive`
  建执行器时把会话工作区传了进去（`workspace: workspace`），而 `workspace` 是从
  `ai_conversations.workspace_scope` 读的——会话记录是唯一真相，调用方不用再传一遍。默认值是「全体空间」
  （`AgentWorkspace.initial`），不是「不选择」：`none` 会把查询变成"一个目录都不含"，用户第一句话就会得到
  "我一条笔记都看不到"。老会话的空串也读成这个默认，详见 `AgentWorkspace.parse`。

### 4.2 参数锚点：改正文为什么用 `expectedText`

`updateNote` 的定位参数是原文片段，不是行号 / 偏移 / 段号：

```
updateNote(noteId, expectedText: "客户反馈很好", newContent: "用户反馈很好")
  → App 先确认 expectedText 还在
  → 不在 → 失败，一个字都不改（连确认层都不弹）
  → 在   → 替换掉 indexOf 命中的那一处 → 弹「改前 vs 改后」→ 用户同意才写
```

- **为什么不用索引**：AI 读到"第 3 段"之后，用户在前面插了一段——再按 index 3 改就改错地方，
  而且改得毫无声息。锚点校验的语义是"我要改的那段原文还在不在"，对不上就让模型重新 `readChunk` 定位。
- **锚点是硬前置**：`newContent` 非空时 `expectedText` 必须给且非空，否则直接失败（"先用 `readChunk`
  读出来，把原文一字不差地放进来"）。
- **只替换第一处**（`indexOf` + `replaceRange`）：要"全部替换"走 `replaceInNote`（纯字符串 `allMatches`
  计数、不走正则，返回替换了几处）。
- **快照比对是粗筛、锚点才是精确**：`readChunk` 时记下该笔记正文的 hash（`_snapshot`），写之前比对；
  不一致只把提醒放进确认层（"这条笔记在你读到它之后被改过，确认一下是不是还改这里"），不拦——只靠快照太严，
  用户改个错别字就拦下了。
- **参数校验先于确认门**：不拿一个注定失败的操作去打扰用户，所以锚点不中时用户根本看不到确认框。
- **撤销栈存整行 `Note`**，不是"id + 正文"：`upsertNote` 要求带齐所有"非空且无默认值"的列（`createdAt`
  就是），第一版只存 id + 正文，写回时 Drift 抛 `InvalidDataException`，撤销直接坏掉。栈深 `maxUndo = 5`
  （撤销是"手滑了救一下"，不是版本历史）；撤销走 `_writeNote`，所以会重切切片（否则搜索与 `readChunk`
  会指向错位置）。

### 4.3 每轮硬上限（App 强制，不靠模型自觉）

"轮" = 一次用户输入里的一次工具往返（`AgentLoop` 的 `roundNo`）；每轮开始先 `executor.beginTurn()`
重置读片预算。

| 上限 | 值 | 出处 |
|---|---|---|
| 一次 `run()` 的工具往返轮数 | `maxRounds = 15` | `agent_loop.dart` |
| `readChunk` 每轮片数 | `maxChunksPerTurn = 3` | `tool_executor.dart` |
| `readChunk` 每轮正文合计 | `maxChunkCharsPerTurn = 1500` 字 | `tool_executor.dart` |
| `askUser` 每轮次数 | `maxAsksPerTurn = 5`（跨恢复累计） | `agent_loop.dart` |
| `requestTools` 单次 | `maxRequestTools = 6` | `agent_loop.dart` |
| 批量工具条数（移动 / 删除） | `maxBatch = 10` | `tool_executor.dart` |
| 模型自带 `askUser.options` | 取前 10 条；`limit` 默认 10、`clamp(1,10)` | `agent_loop.dart` |
| `searchNotes.limit` | 默认 20、`clamp(1,50)` | `tool_executor.dart` |
| `listNotes.limit` | 默认 50、`clamp(1,100)` | `tool_executor.dart` |
| `listHistory.limit` | 默认 20、`clamp(1,50)` | `tool_executor.dart` |
| `searchHistory.limit` | 默认 5、`clamp(1,20)` | `tool_executor.dart` |
| `readHistory` 单次 | ≤3 片、≤1500 字（复用上面两个常量） | `tool_executor.dart` |
| 撤销栈深度 | `maxUndo = 5` | `tool_executor.dart` |

`readChunk` 的两道闸顺序不同，这点值得记住：

1. **片数**在真正读之前判（`_turnChunks >= 3` → 失败）：这一片再短也读不进来；
2. **字数**在拿到正文之后判（`_turnChars + text.length > 1500` → 失败，不计数、也不返回半截）；
3. 失败信息是写给模型的下一步（"先用读到的内容回答；确实还需要更多再开新一轮"），不是给人看的报错。

口径上的一处澄清（工具描述写"一次最多 3 片"）：`readChunk` 的 schema 只有单片 `index`，
"一次 3 片"永远无法由参数表达——真正生效的是轮这一级。`listChunks` 目录则完全不受限（只有元数据）。

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
> `_drive` 每次都新建 `ToolExecutor`，所以撤销栈与读片快照也不跨 `run()`（既包括挂起恢复，也包括下一句
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

**写操作只有一个入口**（`ToolExecutor._ask`），三件事按顺序做、缺一不可：

1. **没有确认通道 → 一律拒绝**（`onConfirm == null`，fail closed）。反过来"默认放行"意味着任何一条漏接的
   回调都变成"AI 能随便改用户的数据"，而且不报错。
2. 问用户；被拒 → 返回失败结果（"用户拒绝了这次操作……不要重试同一个操作；换个做法，或者问用户想怎么做"）。
   "用户拒绝"是合法回答而不是错误，但必须让模型知道——否则它会以为改完了，静默失败比报错糟得多。
3. 同意 → 执行。

- **与模型行为解耦**：`askUser` 是模型自愿调用的，它忘了调、删除就直接执行了——所以安全不能寄托在
  "模型记得问一句"上；风险级别由执行器在动手之前查，模型绕不过去。
- **确认层要给人看的东西**：`before` / `after`（改前 vs 改后）、`warning`（快照粗筛的那句提醒）、
  `strong`（`risk == delete` 时按钮改成红色「删除」而不是「允许」，摘要里写明"删了就找不回来"）。
  摘要用 `_clip(…, max: 40)` 压扁，太长会撑爆弹层。
- **一次提议只执行一次**，两层保证：
  - **执行器**走幂等路径：`deleteNote` 见 `note == null || deletedAt != null` 就返回 `{alreadyDeleted: true}`
    （成功、不报错、不再弹确认）；`deleteNotebook` 必须判 `nb.deletedAt != null`——`getNotebook` 不筛软删，
    只看 `nb == null` 会漏掉"已经删过一次"，重复点击就会再删一遍；`batchDeleteNotes` 先筛出还活着的，
    一条都不剩就返回 `deleted: 0, alreadyDeleted: true`。
  - **UI**：确认层用 `_once` 标志挡住重复点击，并且 `barrierDismissible: false`（点外面不算同意，必须明确选）。
- **删除的代价**：`deleteNote` 确认后直接删；没有回收站、没有 `restoreNote`、也没有撤销（只有修改类有撤销：
  `LogBar.action` 的「撤销」→ `undoLast()`）。内部仍是软删除（`deletedAt` 置位、行还在）——那是防 bug、
  留后路，不是给用户的回收站。软删不触发外键级联，所以切片要显式清掉（留着会让搜索把"命中"算到已删的
  笔记头上）。
- `deleteNotebook` 的措辞必须说清"里面的笔记不会删，会退回「我的轻笔记」"——不说的话用户以为笔记也没了，
  不敢点。

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
  跨轮要回看更早的内容走 `listHistory` / `readHistory`——它们读的正是 `ai_messages`。这才是"工具调用链
  不会被从中间截断"的真正保证，再加上窗口只从"倒数第 N 条 `user`"起切（`historyWindowOf` 与
  `olderHistoryOf` 共用同一个 `_windowStart`，两边严格互补，一条不多一条不少）。

  > `HistoryChunker` 对超过 700 字的一轮会按段落 / 句子继续拆，所以"片边界 = 轮边界"只对 ≤700 字的
  > 一轮成立。这不影响协议安全——片正文是渲染后的文本，从来不会当作 `messages` 回灌。
- **摘要**（更早的轮次）：`olderHistoryOf` 取窗口之外的轮次 → 用 `streamChat`（不是 `AiRepository.ask`：
  后者会去检索用户的笔记，拿来压缩对话既跑偏又白花钱）压成一段 → 存 `app_kv` 的
  `ai_history_summary_<会话id>` → 只生成一次，之后每轮直接读；压缩失败不让整轮失败（没有摘要顶多多花点
  token）；删会话时按同一个键清掉。它拼在 system prompt 的末尾（`withSummary`），不占历史消息位置、
  也不改写历史（保缓存）。

### 4.7 验收口径与上线后要观察什么（AI 行为）

**可断言的验收口径**（这些点都有对应测试文件：`tool_executor_test` / `tool_write_test` /
`tool_delete_test` / `agent_loop_test` / `ask_user_test` / `ask_flow_test` / `history_window_test` /
`history_summary_test` / `tool_specs_test`；是否全绿以 `flutter test` 为准）：

- [x] `listChunks` 目录编码后一个字正文都没有；`listNotes` / `getNoteMeta` 真的只取元数据（不读正文）
- [x] `appendToNote` 不要求先读、仍走确认层与撤销；追加后切片重切
- [x] `readChunk` 每轮 ≤3 片且 ≤1500 字（`beginTurn()` 每轮重置）
- [x] 历史自动 5 轮、单条 ≤500 字；`readHistory` ≤3 片且 ≤1500 字；`searchHistory` 只回片号 + 片段
- [x] 更早历史的压缩摘要只生成一次（用调用次数验证）
- [x] 风险拦截在 App，与模型行为解耦（没有确认通道时写操作一律拒绝）
- [x] 锚点失败返回错误，且一个字都不改（连确认层都不弹）
- [x] 一次提议只执行一次（幂等路径 `alreadyDeleted`）
- [x] `askUser` ≤5（跨恢复累计）、`requestTools` ≤6、批量 ≤10、轮数上限 15

> **真机端到端（`agent_live_test.dart` / `agent_search_live_test.dart`）：未做。**
> 那 3 份真机测试已删除（不会真的去跑，留着只是维护负担）。代价是"协议报文形状 / 模型会不会主动调工具 /
> 真实 SSE 分片方式"三类失去自动化覆盖，回归只能靠人工；原因与"将来要加回来怎么做"见
> [测试设计](测试设计.md) 第四节。

**上线后观察**：

| 观察项 | 怎么观察 | 出问题说明什么 |
|---|---|---|
| 工具调用的 token 占比 | `ai_calls` 的 `prompt_tokens`（不含缓存命中量，见 5.4） | 分层发送没省下来，或缓存没命中 |
| `askUser` 触发频率 | 数一轮对话里的次数 | 太高 → `askUser` 工具描述里的"能推断的就别问"没生效 |
| 挂起未恢复的会话 | `ai_messages.pendingAction` 长期非空的条数 | 恢复逻辑有 bug |
| 确认层拒绝率 | 用户点「取消」的比例 | 太高 → AI 定位不准 |
| 锚点校验失败率 | `expectedText` 找不到的次数 | 太高 → 需要产品层规避（编辑时锁住那一段） |
| 崩溃 / 未捕获异步错误 | 现有 `_StartupGate` + 日志 | 工具执行器里的 async 边界（每个 `await` 之后都要查 `mounted`） |

---

## 5. 调用审计（`ai_calls`）与用量页

### 5.1 表结构

出处：`lib/core/db/tables.dart` 的 `AiCalls`

| 列 | 说明 |
|---|---|
| `id` | uuid |
| `note_id` | 可空（见 5.4） |
| `task` | `organize` / `feed_generate` / `ask` / `agent` / `note_summary` |
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
- 业务调用（`feed_generate` / `note_summary` / `ask` / `organize`）各自记一条，成功与失败都记
  （失败带 `error_code`）。
- AI 助手是另一条：`AiChatRepository._log` → `AiRepository.logChatCall`，`task = 'agent'`。它记的是整轮
  累计用量（多轮工具往返合起来记一条）——只记最后一次会让「工具用得越多、成本越低」这种假象出现。
- `task` 的 `organize` 与 `ask` 两条路径当前没有调用方，所以实际会出现的 `task` 是 `agent` /
  `feed_generate` / `note_summary`。

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
3. **`note_id` 实际上全是空。** 所有有调用方的写入点都传 `noteId: null`（`feed_generate` / `note_summary`
   显式传 null，`agent` 由 `logChatCall` 固定传 null）；唯一传了 noteId 的 `organize` 没有调用方。
   所以「按笔记对账」现在做不到。
4. **价格是代码常量、无节假日日历、无用户覆盖**：节假日会被算成高峰；官方调价后 App 里的估算不会自动跟着变。
