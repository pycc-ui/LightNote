/// **LightNote 的可调参数总表**。
///
/// 凡是"改一个数字就能调成本 / 调体验 / 调行为"的常量，都集中在本文件：
/// 卡片长度、笔记与切片尺寸、卡片流池子与窗口、搜索权重、
/// AI 的 SQL 通道上限、会话历史上限……
///
/// 目的和 `ai_limits` 当初一样，只是范围扩到全部：**避免"prompt 里写 300、
/// 代码里截 500""两处上限各写各的"这种不一致**。
///
/// ## 不放进来的东西（各有各的家）
///
/// - **接口事实**（端点 / 模型名 / 超时 / 上下文与输出上限 / 计费单价）在
///   `lib/features/ai/data/deepseek_config.dart` —— 那是与 DeepSeek 的约定 +
///   价格换算，性质不同，改它要对着官方文档。
/// - **算法逻辑**留在各自模块，只把数值搬到这里。例如 `safeTruncate` 还在
///   `ai_limits.dart`、切片算法还在 `note_chunker.dart`。
/// - **UI 尺寸 / 颜色 / 字号**在 `lib/core/theme/` 下。
/// - **协议与存储标识**（`app_kv` 的 key、`ai_history_summary_` 前缀、
///   状态字符串等）不是"可调参数"，留在使用处。
///
/// ## 用法
///
/// 调用方按域引用，例如 `AiLimits.tagMaxCjk`、`FeedLimits.poolTarget`。
/// 各领域模块里那些历史遗留的 `NoteChunker.cap` / `kFeedPoolTarget` 等名字
/// 仍可用——它们现在只是指向这里的常量别名，值只在本文件定义一次。
library;

// ============================================================================
// 文本类内容的上限（标签 / 标题 / 笔记正文 / 卡片）
// ============================================================================

abstract final class AiLimits {
  // ---- 标签 ----

  /// 单个标签的汉字上限
  static const tagMaxCjk = 5;

  /// 单个标签的英文字母上限
  static const tagMaxLatin = 12;

  // ---- 卡片（AI 生成的轻笔记）----

  /// 卡片标题上限（字）。提示词要求 ≤30，两倍余量兜底。
  static const feedCardTitleMax = 60;

  /// 卡片正文上限（字）。提示词要求 200–400，两倍余量兜底。
  static const feedCardBodyMax = 800;

  /// 卡片生成的单次输出上限（token）。
  /// 从 16384 收下来是**防黑天鹅**（模型偶尔跑飞一次就烧几千 token），不是省常态成本。
  static const feedMaxOutputTokens = 2048;

  // ---- 笔记正文（软上限 + 硬保护）----

  /// 软上限：超过就轻提示"注意编辑流畅度"
  static const noteSoftBytes = 80 * 1024;

  /// 强警告线：超过就建议拆分，但仍允许保存
  static const noteWarnBytes = 90 * 1024;

  /// 硬上限：超过就拒绝保存
  static const noteHardBytes = 100 * 1024;

  /// 单行短字段的上限（字）：笔记标题、笔记库名、会话标题、卡片标题……
  /// 超出截断（不是拒绝）：这类字段会进 prompt，几万字的"标题"能撑爆一次请求。
  static const titleHardMax = 200;

  /// UTF-8 字节长度。单独放这里，让上限全按字节口径算。
  static int byteLength(String text) => utf8ByteLength(text);
}

// ============================================================================
// 卡片流（池子 / 预留 / 并发 / 冷却窗口 / 素材窗口）
// ============================================================================

abstract final class FeedLimits {
  /// 一屏显示几张卡片（骨架屏与首屏用）。屏幕上一屏就是 3 张。
  static const batchSize = 3;

  /// 无预留时首屏先只生成几张：取一屏，其余丢后台补池。
  static const firstScreenCount = batchSize;

  /// 每次下拉取几张。比一屏少，免把后台池子抽得太快。
  static const pullSize = 2;

  /// 后台常备几张（池子的目标值，不是下限）。
  static const poolTarget = 6;

  /// 补池的并发路数（≈一次最多生成几张）。
  static const genParallelism = 3;

  /// 每次启动给**下次**预留几张（存进 `feed_reserve`）。
  static const reserveSize = 3;

  /// **来源冷却窗口**：最近这么多张卡片里，同一篇笔记最多出现 1 次。
  static const recentNoteKeep = 15;

  /// **切片记忆窗口**：最近这么多块不重复取（会话内快速过滤）。
  static const recentChunkKeep = 30;

  /// **标题记忆窗口**：最近这么多张卡片的标题算「已经生成过」。
  static const recentTitleKeep = 20;

  /// 一份素材的字符数（从片里开出的窗口大小）。
  ///
  /// 400：卡片流的全部内容就是这**一段截断的原文**，窗口给足一点，
  /// 模型才有足够素材把卡片写具体。
  static const windowChars = 400;

  /// 单批素材的字符预算。依赖片的硬上限 700 不会失控。
  static const windowBatchBudget = 4000;
}

// ============================================================================
// 切片（笔记切片 / 会话历史切片）
// ============================================================================

abstract final class ChunkLimits {
  // ---- 笔记切片 ----
  /// 片长硬上限。除了不可拆散单元，任何一片都不超过它。
  static const noteCap = 700;

  /// 片长下限（**期望值**，不参与合并判断；合并是"填到上限为止"）。
  static const noteFloor = 300;

  /// 短笔记（无标题）整篇一片的长度阈值。
  static const noteShortLimit = 400;

  /// 不可拆散单元的硬顶，超过就按行拆。
  static const noteAtomicCeiling = 1500;

  /// 切片防抖：正文变了**总是重切**（`0.0` = 不防抖）。
  static const noteStaleRatio = 0.0;

  // ---- 会话历史切片 ----
  /// 历史片长硬上限 / 下限（与笔记切片同一套量级）。
  static const historyCap = 700;
  static const historyFloor = 300;

  /// 目录里 `userSnippet` 取多少字。
  static const historyUserSnippetChars = 40;
}

// ============================================================================
// 搜索
// ============================================================================

abstract final class SearchLimits {
  /// 默认返回条数。
  static const defaultLimit = 20;

  /// 命中点前后各取多少字拼成片段。
  static const snippetRadius = 40;

  /// 排序权重：标题命中 / 正文命中。
  static const titleScore = 3.0;
  static const chunkScore = 2.0;

  /// 正文扫描的篇数上限（算"命中哪一片"很贵，先按更新时间取最近的若干篇）。
  static const contentScanCap = 80;
}

// ============================================================================
// AI 的 SQL 通道（`sql` 工具 + 25 个 UDF）的上限
// ============================================================================
//
// 这批数字有两个读法，别混：
//   · **函数层的默认值与硬上限**（read_preview 一次最多 500 字、limit 最多 50）：
//     写在函数体里，AI 传超了就被夹到上限；
//   · **回灌给模型的行李限额**（maxResultRows / maxResultChars）：
//     执行器用它截断结果集 —— 一次 SELECT 出十万行会把上下文和钱包一起烧掉。
//
// 它们都只是「成本与体验」的旋钮，不是安全边界：真正的边界是 SqlGuard
//（只放行单条 SELECT/WITH）与 UDF 里的业务校验。
abstract final class SqlLimits {
  // ---- 读 ----

  /// read_preview / read_around 单次返回的字符数上限。
  static const maxReadChars = 500;

  /// 不传 chars 时的默认值。
  static const defaultReadChars = 200;

  /// find_in_note 最多回几个位置（count 仍是真实次数）。
  static const maxFindPositions = 200;

  /// search_notes 的默认 / 上限条数。默认值直接沿用 SearchLimits，
  /// 免得「搜索页默认 20 条、AI 默认别的数」变成两个真相。
  static const defaultSearchLimit = SearchLimits.defaultLimit;
  static const maxSearchLimit = 50;

  /// search_in_note 的默认 / 上限条数。
  static const defaultSnippetLimit = 10;
  static const maxSnippetLimit = 20;

  /// recent_notes 的默认条数（上限与 search_notes 共用）。
  static const defaultRecentLimit = 10;

  /// 片段半径：命中位置前后各多少字（与搜索页同一个数字）。
  static const snippetRadius = SearchLimits.snippetRadius;

  // ---- 回灌给模型的结果 ----

  /// 一次查询最多回灌几行。
  static const maxResultRows = 200;

  /// 一次查询回灌的字符上限（超了就截断并告诉模型截了多少）。
  static const maxResultChars = 8000;

  // ---- 安全校验 ----

  /// 单条 SQL 的字符上限。防的是「模型把整篇笔记塞进 SQL 字符串」这种意外，
  /// 不是防攻击（那由 SqlGuard 的关键字与语句数规则负责）。
  static const maxStatementChars = 20000;
}

// ============================================================================
// AI Agent（多轮循环 / 上下文 / 历史窗口 / 撤销 / 确认层）
// ============================================================================

abstract final class AgentLimits {
  /// 一次用户输入最多允许几轮工具往返。
  static const maxRounds = 15;

  /// 一轮用户输入里 `askUser` 最多问几次（跨恢复累计）。
  static const maxAsksPerTurn = 5;


  /// 自动带的历史**轮数**（一轮 = 一问一答）。
  static const maxHistoryRounds = 5;

  /// 历史里**单条**消息的截断上限。
  static const maxHistoryChars = 500;
}

// ============================================================================
// 文本工具（按上面的长度参数做截断 / 规整）
//
// 它们和本文件的参数是同一件事的两面：`normalizeTag` 要读 `tagMaxCjk`、
// `noteSizeLevel` 要读笔记字节档位——放一起才不会"参数改了工具没跟上"。
// ============================================================================

/// UTF-8 字节长度。
int utf8ByteLength(String text) {
  var bytes = 0;
  for (final rune in text.runes) {
    if (rune <= 0x7F) {
      bytes += 1;
    } else if (rune <= 0x7FF) {
      bytes += 2;
    } else if (rune <= 0xFFFF) {
      bytes += 3;
    } else {
      bytes += 4;
    }
  }
  return bytes;
}
