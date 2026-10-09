import 'package:drift/drift.dart';

// ============================================================================
// Drift 表定义
// 字段含义与索引说明见 docs/02-数据模型设计.md —— 改表先改文档。
//
// 与 docs/界面设计.md 的对应关系：
//   Folder          -> folders
//   Note            -> notes（folderId / isInbox / source / tags）
//   AIConversation  -> ai_conversations
//   AIMessage       -> ai_messages
//   settings        -> settings（key-value）
//
// 说明：设计稿中 Note.tags 写作「逗号分隔字符串」。这里改用 tags 连接表
// （已经跑通且有 usageCount 热度计数），卡片级标签仍按字符串存于 cards.tags。
// ============================================================================

/// 目录：支持父子层级（parentId 为空表示顶层）
class Folders extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();

  /// 顶层目录为 NULL。自引用外键，删除父目录时子目录上浮为顶层。
  TextColumn get parentId =>
      text().nullable().references(Folders, #id, onDelete: KeyAction.setNull)();

  /// 手动排序用；同层内升序
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// 逻辑删除：删除目录不删笔记，笔记回到轻笔记（收件箱）
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 笔记主表
class Notes extends Table {
  TextColumn get id => text()();

  /// 所属目录。为空表示「轻笔记」（未归档的速记）
  TextColumn get folderId =>
      text().nullable().references(Folders, #id, onDelete: KeyAction.setNull)();

  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get content => text().withDefault(const Constant(''))();

  /// 前 200 字纯文本，列表页预览用，避免列表页读全文
  TextColumn get excerpt => text().withDefault(const Constant(''))();

  /// 数据来源：local / import / share / ai
  TextColumn get source => text().withDefault(const Constant('local'))();

  /// 轻笔记（收件箱）标记。
  /// true  = 速记，出现在「轻笔记」页，等待整理
  /// false = 已归档到笔记库，出现在「笔记库 / 目录」页
  BoolColumn get isInbox => boolean().withDefault(const Constant(false))();

  BoolColumn get pinned => boolean().withDefault(const Constant(false))();

  /// 阅读进度 0.0–1.0
  RealColumn get readingProgress => real().withDefault(const Constant(0.0))();
  IntColumn get readingSeconds => integer().withDefault(const Constant(0))();
  IntColumn get wordCount => integer().withDefault(const Constant(0))();

  DateTimeColumn get lastAiAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// 逻辑删除：非空即视为已删除，配合回收站与同步
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 标签
class Tags extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();

  /// 小写去空格，UNIQUE —— 防止 "Flutter" / "flutter " 分裂成两个标签
  TextColumn get normalizedName => text().unique()();
  IntColumn get colorValue => integer().nullable()();

  /// 冗余计数：标签列表按热度排序时避免 COUNT(*)。增删关联时必须同步维护。
  IntColumn get usageCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 笔记 ↔ 标签（复合主键天然去重）
class NoteTags extends Table {
  TextColumn get noteId =>
      text().references(Notes, #id, onDelete: KeyAction.cascade)();
  TextColumn get tagId =>
      text().references(Tags, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {noteId, tagId};
}

/// 卡组（可选分组维度）
class CardDecks extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get description => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 记忆卡片（含 SM-2 调度状态）
class Cards extends Table {
  TextColumn get id => text()();
  TextColumn get noteId => text()
      .nullable()
      .references(Notes, #id, onDelete: KeyAction.cascade)();
  TextColumn get deckId => text()
      .nullable()
      .references(CardDecks, #id, onDelete: KeyAction.setNull)();

  TextColumn get question => text()();
  TextColumn get answer => text()();

  /// ai = AI 生成（经用户确认后写入）/ manual = 手动创建
  TextColumn get source => text().withDefault(const Constant('manual'))();
  TextColumn get aiModel => text().nullable()();

  /// 卡片级轻量标签，逗号分隔（按设计稿保持字符串，不占用 tags 表）
  TextColumn get tags => text().nullable()();

  // ---- SM-2 调度状态 ----
  DateTimeColumn get dueAt => dateTime()();
  IntColumn get intervalDays => integer().withDefault(const Constant(0))();

  /// 难度因子 EF，取值 1.3–2.8
  RealColumn get ease => real().withDefault(const Constant(2.5))();

  /// 连续答对次数；0 表示新卡
  IntColumn get repetitions => integer().withDefault(const Constant(0))();
  IntColumn get lapses => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastReviewedAt => dateTime().nullable()();
  IntColumn get reviewCount => integer().withDefault(const Constant(0))();
  BoolColumn get suspended => boolean().withDefault(const Constant(false))();

  // ---- 预留：FSRS 迁移用，当前算法不写 ----
  RealColumn get stability => real().withDefault(const Constant(0.0))();
  RealColumn get difficulty => real().withDefault(const Constant(0.0))();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 复习流水：追加写、永不更新。将来拟合 FSRS 参数与做学习曲线都靠它。
class Reviews extends Table {
  TextColumn get id => text()();
  TextColumn get cardId =>
      text().references(Cards, #id, onDelete: KeyAction.cascade)();
  IntColumn get quality => integer()();
  RealColumn get easeBefore => real()();
  RealColumn get easeAfter => real()();
  IntColumn get intervalBefore => integer()();
  IntColumn get intervalAfter => integer()();

  /// 从看到卡片到评分耗时（毫秒），可用于识别"瞎点"
  IntColumn get elapsedMs => integer().withDefault(const Constant(0))();
  DateTimeColumn get reviewedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// AI 整理结果：一次整理一条记录，不覆盖历史，便于对比不同模型/时间的结果
class NoteSummaries extends Table {
  TextColumn get id => text()();
  TextColumn get noteId =>
      text().references(Notes, #id, onDelete: KeyAction.cascade)();
  TextColumn get model => text()();
  TextColumn get oneLine => text().withDefault(const Constant(''))();

  /// 以下三个都是 JSON 数组字符串（只整体读写，不单独查询，故不拆子表）
  TextColumn get bullets => text().withDefault(const Constant('[]'))();
  TextColumn get suggestedTags => text().withDefault(const Constant('[]'))();
  TextColumn get actionItems => text().withDefault(const Constant('[]'))();

  TextColumn get rawResponse => text().nullable()();
  IntColumn get promptTokens => integer().withDefault(const Constant(0))();
  IntColumn get completionTokens => integer().withDefault(const Constant(0))();

  /// 估算成本（分）
  RealColumn get costCents => real().withDefault(const Constant(0.0))();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// AI 调用审计：成本可见性 + 故障排查
/// 隐私约束：本表不存 prompt / 响应全文。
class AiCalls extends Table {
  TextColumn get id => text()();
  TextColumn get noteId => text().nullable()();

  /// summarize / generate_cards / ask / organize / agent
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

/// AI 会话（设计稿 §6.3）
class AiConversations extends Table {
  TextColumn get id => text()();

  /// 工作区：这里存目录 id（应用内工作区），而不是 SAF 的 content:// URI。
  /// 选择器只列出本 App 的目录，因此不需要持久化 URI 权限。
  TextColumn get workspaceFolderId =>
      text().nullable().references(Folders, #id, onDelete: KeyAction.setNull)();

  /// 思考强度：low / medium / high
  TextColumn get thinkingEffort => text().withDefault(const Constant('medium'))();

  TextColumn get title => text().withDefault(const Constant(''))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// AI 会话消息（设计稿 §6.3）
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
  /// 设计稿 SQL 里写的是 INTEGER，Drift 会自动转成 Unix 时间戳存储，等价。
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 简单 key-value 配置表（设计稿 §6.4）
/// 用于放搜索历史、主题、字号、自动保存开关这类轻量偏好，
/// 避免为它们再引入 shared_preferences。
class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}
