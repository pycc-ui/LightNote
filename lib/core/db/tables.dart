import 'package:drift/drift.dart';

// Drift 表定义。
// 表间关系和字段含义见 docs/数据库设计.md，改表先改那份文档。
//
// 标签只剩一种：卡片级标签，存在 feed_reserve.tags（字符串），只用于卡片自身展示，
// 不做跨笔记聚合。用户手动标签的两张表（tags / note_tags）在 schema v9 删除了。
// 其余已删除的表（cards / card_decks / reviews / note_summaries /
// note_feed_state / note_ai_tags）见 docs/数据库设计.md。
//
// 领域概念是「笔记库」（Notebooks）。v2→v3 迁移把 folders 改名成 notebooks，
// folder_id / workspace_folder_id 也一并改名成 notebook_id / workspace_notebook_id，
// 所以现在全项目没有 folder_* 列。

/// 笔记库：平铺，没有层级。
///
/// 这个表原先是 folders（带 parent_id 的层级目录）。改成「笔记库」时去掉了层级：
/// 用 SQLite 而不是文件系统，本来就是为了避免目录树的复杂度，再加子目录等于绕回去。
/// v2→v3 迁移执行 `ALTER TABLE folders RENAME TO notebooks` 完成改名，
/// 备份校验同时接受新旧表名，好让老备份导入后靠迁移自动改名。
/// （Drift 由类名推导表名，所以类名一改就必须配一条迁移。）
class Notebooks extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();

  /// 用于列表展示排序。没有层级，所以不是「同层内」排序。
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// 逻辑删除：删除笔记库不删笔记，笔记回到「我的轻笔记」
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 笔记主表
class Notes extends Table {
  TextColumn get id => text()();

  /// 所属笔记库。为空表示「我的轻笔记」（未归档）
  TextColumn get notebookId =>
      text().nullable().references(Notebooks, #id, onDelete: KeyAction.setNull)();

  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get content => text().withDefault(const Constant(''))();

  /// 前 200 字纯文本，列表页预览用，避免列表页读全文
  TextColumn get excerpt => text().withDefault(const Constant(''))();

  /// 数据来源：local / import / share / ai
  TextColumn get source => text().withDefault(const Constant('local'))();

  /// 未归档标记（「我的轻笔记」）。
  /// true  = 还没归档，出现在笔记库页的「我的轻笔记」区块
  /// false = 已归档到某个笔记库
  BoolColumn get isInbox => boolean().withDefault(const Constant(false))();

  BoolColumn get pinned => boolean().withDefault(const Constant(false))();

  IntColumn get wordCount => integer().withDefault(const Constant(0))();

  DateTimeColumn get lastAiAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// 逻辑删除：非空即视为已删除，配合回收站与同步
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// AI 调用审计：成本可见性 + 故障排查
/// 隐私约束：本表不存 prompt / 响应全文。
class AiCalls extends Table {
  TextColumn get id => text()();
  TextColumn get noteId => text().nullable()();

  /// organize / feed_generate / ask / agent / note_summary
  TextColumn get task => text()();
  TextColumn get model => text()();
  BoolColumn get thinkingEnabled => boolean().withDefault(const Constant(false))();

  IntColumn get promptTokens => integer().withDefault(const Constant(0))();
  IntColumn get completionTokens => integer().withDefault(const Constant(0))();
  RealColumn get costCents => real().withDefault(const Constant(0.0))();
  IntColumn get latencyMs => integer().withDefault(const Constant(0))();
  BoolColumn get success => boolean().withDefault(const Constant(true))();

  /// 401 / 429 / timeout / json_empty / ...
  TextColumn get errorCode => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// AI 会话（见《数据库设计》的「ai_conversations / ai_messages」一节）
class AiConversations extends Table {
  TextColumn get id => text()();

  /// 工作区（**AI 能看到哪些笔记**），JSON。
  ///
  /// 工作区有三态：**不选择 / 全体空间 / 选择目录**，而"选择目录"还能多选、
  /// 并且单独决定要不要带上「我的轻笔记」—— 一个笔记库 id 表达不了，
  /// 所以这里存一个描述范围的 JSON。
  ///
  /// 形状（`AgentWorkspace.toJson`）：
  /// ```json
  /// { "mode": "none" | "all" | "pick",
  ///   "notebookIds": ["…"],       // 仅 pick
  ///   "includeUnfiled": false }   // 仅 pick
  /// ```
  ///
  /// 三态的含义：
  ///   · `none` —— 不选择，AI 看不到任何笔记（只能靠用户显式附上的文件）
  ///   · `all`  —— **全部笔记库 + 我的轻笔记**
  ///   · `pick` —— 指定的若干笔记库，`includeUnfiled` 另外决定要不要带上轻笔记
  ///
  /// 空串 = 还没设过 → 按 [WorkspaceMode.none] 处理（**保守**：
  /// 老会话不给 AI 任何笔记范围，而不是突然让它看见全部）。
  ///
  /// ⚠️ 这个范围**同时是 AI 工具的范围**：`searchNotes` / `listNotes`
  /// 会被它限制。否则"选了库 A"却还能搜到库 B，工作区就只是个标签。
  TextColumn get workspaceScope => text().withDefault(const Constant(''))();

  /// 思考强度：low / medium / high
  TextColumn get thinkingEffort => text().withDefault(const Constant('medium'))();

  TextColumn get title => text().withDefault(const Constant(''))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// AI 会话消息（见《数据库设计》的「ai_conversations / ai_messages」一节）
class AiMessages extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId =>
      text().references(AiConversations, #id, onDelete: KeyAction.cascade)();

  /// user / assistant / system
  TextColumn get role => text()();
  TextColumn get content => text().withDefault(const Constant(''))();

  /// 用于「操作前预览变更」：AI 提议的写操作以 JSON 形式暂存，
  /// 用户确认后才执行。null 表示纯聊天消息。
  TextColumn get pendingAction => text().nullable()();

  /// 与其他表保持一致，统一用 DateTime（UTC 存储）。
  /// 时间列在 SQL 里是 INTEGER，Drift 会自动按 Unix 时间戳存取，等价。
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 通用 key-value 表，真实表名 `app_kv`（见《数据库设计》的「app_kv」一节）。
///
/// 原先叫 `settings`，但里面 10 个 key 有 6 个根本不是"设置"——
/// `search_history`、`feed_source_excluded`、`feed_include_unfiled`、
/// 会话级的工作区范围、卡片流的来源配置等等。
/// 与其让后来的人对着 `settings` 表找一个搜索历史，不如正名成"应用的键值对"。
///
/// 改名靠改类名（Drift 由类名推导表名），所以 v8→v9 迁移里有
/// `ALTER TABLE settings RENAME TO app_kv`——漏了它老库升级会**丢数据**。
///
/// 卡片流来源只存排除集 `feed_source_excluded`：不在排除集里就是包含，
/// 于是"默认全选、新建的笔记库自动加入"是构造性成立的 —— 无歧义，
/// 也不需要任何"对账"（否则还得去分辨"一个 id 没出现过"还是"用户取消的"）。
///
/// 旧的一套（`feed_source_notebooks` 包含集 + `feed_source_initialized`
/// + `feed_source_customized`）已停用：新 key 必须换名字，否则老的"包含集"
/// 被当成"排除集"读，语义正好反过来，会把来源整个清空。
class AppKv extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// 轻笔记的**跨启动预留**：几张已生成好的卡片，下次打开先拿出来当屏。
///
/// 用户希望每次打开卡片流都秒出，不能等一次 AI 生成（那要几秒）。做法是后台
/// **单独生成**最多 `kFeedReserveSize`（6）张存进这张表；下次启动先把表里的取出来
/// 当首屏（秒出），再后台生成新的一批、重新写回来。上一批被取出后就从表里删掉
/// （消费即清）。
///
/// （相关常量在 `feed_repository.dart` 顶部：`kFeedReserveSize` / `kFeedFirstScreenCount` /
/// `kFeedPullSize` / `kGenParallelism` / `kFeedPoolTarget`，改那里就要改这里。）
///
/// 这些是真正的卡片内容，该有自己的表（而不是塞进 `app_kv` 的 JSON）：
///   · 能单独查询 / 清理，不跟配置混在一起
///   · 结构显式（标题、正文、标签各一列），不靠 JSON 约定
///
/// ## 这张表不影响列表是替换还是追加
///
/// 它只影响"进来时先拿哪 **6** 张"。列表行为在 UI 层
/// （`InboxPage._loadBatch`）：**首次进入是替换，下拉刷新是前向追加**。
/// 所以这里无论有多少张，都不会让列表自己往后长。
class FeedReserve extends Table {
  TextColumn get id => text()();

  TextColumn get title => text()();

  /// 完整正文（Markdown）
  TextColumn get body => text()();

  /// 标签，JSON 数组字符串（只整体读写）
  TextColumn get tags => text().withDefault(const Constant('[]'))();

  /// 取出顺序。0 是最先展示的那张。
  IntColumn get position => integer()();

  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 笔记的 **AI 摘要**（持久化，不是临时缓存）。
///
/// 它与展示型的 `note_summaries` 语义相反，所以没有合并。`note_summaries`
/// 是用户点「AI 整理要点」的产物：一次一条、不覆盖历史（便于对比不同模型/时间
/// 的结果），主键是 UUID，还带 tokens / cost / raw_response 这些审计字段。
/// （那张表已在 schema v7 删除：读侧 `watchLatestSummary` 从来没有界面调用过，
/// 属于只写不读的死表，功能入口也一并移除了。）
///
/// 这张表则相反：
///   · 一篇笔记一条（主键就是 noteId），新摘要覆盖旧的
///   · 只为"喂给 AI 当素材"服务，用户看不到
///   · 不需要审计字段，但需要失效判断（笔记改了就该重生成）
///
/// 混在一张表里会让两边的查询都要加过滤条件，迟早出错。
///
/// ## 缓存了什么
///
/// 生成卡片流素材时，把**摘要而不是全文**发给 AI，省 token、也快得多。
/// 一篇笔记摘要生成一次、长期复用。
///
/// 表名 `ai_note_summaries`：原先叫 `note_ai_summaries`，v8→v9 迁移里
/// `ALTER TABLE note_ai_summaries RENAME TO ai_note_summaries`。
/// 改名只是为了跟同族的 `ai_calls` / `ai_conversations` 对齐命名——
/// 内容是同一份，一个字都没动。
class AiNoteSummaries extends Table {
  TextColumn get noteId =>
      text().references(Notes, #id, onDelete: KeyAction.cascade)();

  /// 摘要正文。**硬上限 300 字**，写入前已截断（见 AiRepository.summarizeNote）。
  TextColumn get summary => text()();

  /// 生成时用的模型，便于以后判断是否需要因换模型而重生成。
  TextColumn get model => text().withDefault(const Constant(''))();

  /// 生成时笔记正文的 **UTF-8 字节数**。
  ///
  /// 用它而不是 `updatedAt` 判断过期：`updatedAt` 只要写一次就变，
  /// 用户改个错别字也会让摘要作废，等于每次编辑都白烧一次 token。
  /// 字节数够用来判断"内容变了多少"，配合 [AiRepository] 里的
  /// 20% 阈值就实现了防抖。
  IntColumn get sourceBytes => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {noteId};
}

/// 笔记的**切片**：把正文按标题层次切成一片片"原文区间"。
///
/// ## 只存结构，不存正文
///
/// 存正文等于把全部笔记文本**再存一份**（库里的文本量翻倍）。
/// 这里只存 `[start_offset, end_offset)`，读片时从 `notes.content` 现取——
/// 于是永远和正文一致，不存在"片正文过期"这种状态。
///
/// 代价：正文改了偏移就错了。但那错的是**位置**不是**内容**，而且能被检出：
/// 读片时比对 `content_hash`，不符就当场重切一次写回（见 `NoteChunkRepository`）。
///
/// 切片本身不含新增信息，所以不落库（现切现算）也是可行的。之所以要落库，
/// 是因为有下面三个只有持久化才能满足的需求：
///
///   · 搜索要返回"命中哪一片"（`chunkIndex` / `heading`）
///   · AI 的 `readChunk(noteId, index)` 需要稳定的片索引
///   · 搜索结果要能跳到原文那一段
///
/// 代价就是要维护重切链路（防抖、阈值、事务、自愈），这一条在设计里是明确认下的。
///
/// ## 两个"卡片流专用"的列
///
/// [lastUsedAt] / [nextWindowStart] 服务卡片流的取素材：
///
///   · 卡片流用的是**片内 400 字窗口**（片本身可以到 700 字），
///     窗口位置**轮换**，[nextWindowStart] 就是下次该从哪个偏移开窗口；
///   · [lastUsedAt] 记这片上次被用掉的时间，取片时
///     `ORDER BY last_used_at ASC NULLS FIRST` —— 把"用过的片"持久化下来。
///
/// 为什么必须记：一次要取 9 份素材，一篇 10 片的笔记等于每批用掉 90%，
/// 不记就会重复。只在内存里记（`_recentChunks`）重启即失效，落库之后
/// 跨会话也不会重复。
///
/// 表名 `note_chunks`（Drift 由类名推导）。
///
/// 数据类必须改名：Drift 默认生成一个叫 `NoteChunk` 的 row 类，而领域层
/// `features/note/domain/note_chunk.dart` 里已经有一个 `NoteChunk` ——
/// 它描述"原文的哪一段"，是切片器与仓储之间传递的对象。两者同名的话，
/// 任何同时用到数据库与切片器的文件都无法编译，所以生成的 row 类叫
/// `NoteChunkRow`。
@DataClassName('NoteChunkRow')
class NoteChunks extends Table {
  TextColumn get noteId =>
      text().references(Notes, #id, onDelete: KeyAction.cascade)();

  /// 顺序号，0 起。**AI 的 `readChunk(noteId, idx)` 用的就是它。**
  IntColumn get idx => integer()();

  /// 标题路径，如 `工作 / 项目A / 风险`。无标题时为空串。
  ///
  /// 给 AI 当上下文、给搜索页当副标题。切片时按标题层次递归切的，
  /// 所以这一串是"这一片落在哪个话题里"的准确描述。
  TextColumn get heading => text().withDefault(const Constant(''))();

  /// 这一片来自几级标题（1~6；0 = 不在任何标题下）。
  IntColumn get level => integer().withDefault(const Constant(0))();

  /// 在 `notes.content` 上的起始下标（**含**）。
  IntColumn get startOffset => integer()();

  /// 结束下标（**不含**）。左闭右开。
  IntColumn get endOffset => integer()();

  /// `endOffset - startOffset`。冗余存一份便于排序/统计，写入时算好。
  IntColumn get charCount => integer()();

  /// 这一片正文的 hash，**自愈用**：读片时比对，不符说明正文变了。
  IntColumn get contentHash => integer()();

  /// 卡片流上次用掉这片的时间（null = 还没用过）。
  DateTimeColumn get lastUsedAt => dateTime().nullable()();

  /// 卡片流下次开窗口的起始偏移（片内相对位置，用于轮换）。
  IntColumn get nextWindowStart => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {noteId, idx};
}
