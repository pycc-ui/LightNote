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
  static const noteSoftBytes = 30 * 1024;

  /// 强警告线：超过就建议拆分，但仍允许保存
  static const noteWarnBytes = 40 * 1024;

  /// 硬上限：超过就拒绝保存。
  ///
  /// ⚠️ **只管"增长"，不管"存在"**：老库里可能有按旧上限（100KB）写下的笔记，
  /// 一刀切会把用户卡死（改一个字都存不了，唯一的出路是"裁剪到软上限"——
  /// 那是删内容且不可撤销）。所以判定是
  /// `新字节数 ≤ max(原字节数, noteHardBytes)` 才放行，
  /// 老笔记不被锁死，但也不能再变长（见 note_editor_page.dart 与 ai_udfs.dart）。
  static const noteHardBytes = 50 * 1024;

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

  /// 首屏几张：无预留时先只生成这几张、其余丢后台补池；
  /// 有预留时取出来的也是这一批（预留 = 上次看过的那一屏）。
  static const firstScreenCount = batchSize;

  /// 每次下拉取几张。比一屏少，免把后台池子抽得太快。
  static const pullSize = 2;

  /// 后台常备几张（池子的目标值，不是下限）。
  static const poolTarget = 3;

  /// 补池的并发路数（≈一次最多生成几张）。
  static const genParallelism = 3;

  /// **来源冷却窗口**：最近这么多张卡片里，同一篇笔记最多出现 1 次。
  static const recentNoteKeep = 15;

  /// **切片记忆窗口**：最近这么多块不重复取（会话内快速过滤）。
  static const recentChunkKeep = 30;

  /// **标题记忆窗口**：最近这么多张卡片的标题算「已经生成过」。
  static const recentTitleKeep = 10;

  /// 一份素材的字符数（从片里开出的窗口大小）。
  ///
  /// 卡片流的全部内容就是这**一段截断的原文**，所以窗口大小直接决定
  /// "模型有多少素材把卡片写具体"，也直接决定每张卡片的输入成本 ——
  /// 这两个方向是相反的，调它就是在"写得具体"和"便宜"之间挪。
  ///
  /// ⚠️ 别在这里写死数字（这一行曾经写着 400，值早改成 250 了）；
  /// 取值看下面这行常量本身。
  static const windowChars = 250;

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
//   · **函数层的默认值与硬上限**（read_note_batch 单条最多 1500 字、limit 最多 50）：
//     写在函数体里，AI 传超了就被夹到上限；
//   · **回灌给模型的行李限额**（maxResultRows / maxResultChars）：
//     执行器用它截断结果集 —— 一次 SELECT 出十万行会把上下文和钱包一起烧掉。
//
// 它们都只是「成本与体验」的旋钮，不是安全边界：真正的边界是 SqlGuard
//（只放行单条 SELECT/WITH）与 UDF 里的业务校验。
abstract final class SqlLimits {
  // ---- 读 ----

  /// read_around 单次返回的字符数上限。
  ///
  /// `read_note_batch` 不共用它：那个函数读的是"整节/整篇"，另有
  /// [maxBatchReadCharsPerNote]；这个 500 字上限只约束"取关键词周围一小段"。
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

  // ---- 写 ----

  /// 批量函数一次最多几条。超了**拒绝**（不是截断）：截断会让模型以为
  /// 整批都做了，实际悄悄漏掉几条 —— 这种"看起来成功"的错最难发现。
  static const maxBatchSize = 10;

  // ---- 批量读 / 目录 ----

  /// `read_note_batch` 单条最多读多少字。
  ///
  /// 1500 而不是"整篇"：一节（按 Markdown 标题切）通常几百字，超过 1500 的是
  /// 罕见的长节 —— 那种情况返回 `next_offset`，让模型接着读，而不是一次灌一大段。
  static const maxBatchReadCharsPerNote = 1500;

  /// `read_note_batch` 一次最多读多少字 / 多少条。超了**整批拒绝**（不截断）：
  /// 与写函数的 maxBatchSize 同一原则 —— 截断会让模型以为整批都读到了。
  static const maxBatchReadChars = 15000;
  static const maxBatchReadNotes = 20;

  /// `outline_notes` 一次最多给多少篇的目录。
  /// 回的是目录不是正文，所以可以比 maxBatchReadNotes 大得多。
  static const maxOutlineNotes = 50;

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
  /// **软上限**：一次用户输入的默认工具往返预算。也用作"每次续多少轮"。
  ///
  /// 到最后一轮之前模型会收到一条提醒（走 system prompt 尾部），让它自己决定：
  /// 没做完就 `askUser` 问用户要不要继续，做完了就 `finish`。
  static const maxRounds = 15;

  /// 用户同意"继续"时，预算一次加多少轮。
  static const roundExtension = 15;

  /// **硬上限**：无论用户点多少次"继续"都不会超过它。
  ///
  /// 它防的不是模型，而是"用户手滑连点继续"和"模型每次都问一遍" ——
  /// 每一次续都是真金白银（每轮都会重发历史）。
  static const maxRoundsHard = 45;

  /// 一轮用户输入里 `askUser` 最多问几次（跨恢复累计）。
  static const maxAsksPerTurn = 5;


  /// **本轮素材的字符预算**（读回来的正文 + 检索注入的片段）。
  ///
  /// 超了就从**最旧**的开始折叠（折成一行"指针"，见 agent_loop.dart），
  /// 而不是像以前那样"除最近一轮外全压"。
  ///
  /// 为什么定 30000：按 1 元/百万 token（flash 低谷）算，3 万中文字 ≈ 2.2 万 token
  /// ≈ 2.2 分 —— 一次复杂任务能接受的量级；而它换来的是"模型不会因为忘了
  /// 刚读的东西而重读"（重读一轮要 0.4–2.7 分，且白烧一轮的思考）。
  static const materialBudgetChars = 30000;

  /// agent 单轮请求的输出上限（含思维链）。
  ///
  /// **必须显式设**：不设的话走服务端默认（聊天模型 4096），模型想写一篇长笔记
  /// 会被硬切断 —— 而切断的表现是 JSON 不完整 → 解析失败 → 整轮白跑。
  /// 16384 够写一篇两三千字的笔记，也给思维链留了余量；
  /// 要生成 50KB 的长文时改用**分节**（批 3），每轮只要写一节。
  static const maxOutputTokens = 16384;

  /// 自动带的历史**轮数**（一轮 = 一问一答）。
  static const maxHistoryRounds = 5;

  /// 历史里**单条**消息的截断上限。
  static const maxHistoryChars = 500;
}

// ============================================================================
// 语义检索（RAG）
//
// 这一组是**实测**出来的，不是拍脑袋定的：模型用 bge-small-zh-v1.5 int8，
// 拿中文笔记片段两两算余弦，得到的两类典型值：
//
//   相关的（问"会议"命中「启动会」正文里的"参会/目标"）   0.49
//   不相关的（同一句问"牛肉面"）                        0.34
//   同主题两篇                                            0.70
//   完全无关两篇                                          0.20 ~ 0.44
//
// ⚠️ 注意最后一行：**无关的两篇也能到 0.44**，所以余弦阈值只当"及格线"用，
// 真正的排序靠两路融合（RRF）。设计稿里当初写的 0.5 是错的 —— 它会把真实
// 命中（0.49）挡在门外。
// ============================================================================

abstract final class RagLimits {
  /// 语义那一路的及格线。低于它的候选**直接丢掉**，不参与融合。
  ///
  /// ## 0.45 是**扫出来的**，不是估的（`test/rag_eval_test.dart` 里有全套数据）
  ///
  /// 20 篇语料 / 60 条向量 / 20 条查询，每条查询的最高分：
  ///
  /// | 及格线 | 有答案的漏掉 | 无答案的误报 |
  /// |---|---|---|
  /// | 0.35 | 0 / 15 | **5 / 5** |
  /// | 0.40 | 0 / 15 | 4 / 5 |
  /// | **0.45** | **1 / 15** | **1 / 5** |
  /// | 0.48 | 4 / 15 | 1 / 5 |
  /// | 0.50 | 5 / 15 | 0 / 5 |
  ///
  /// 关键在于"有答案的最低分（0.423）"和"无答案的最高分（0.495）"**是有重叠的**
  /// —— 没有任何一条线能两全。0.45 是两个错误各犯一次的那个点：宁可能漏一条
  /// （AI 手里还有工具能兜），也不要每次都塞一堆不相关的进去。
  ///
  /// ⚠️ 0.35 那版是错的：当初只拿几对样本比了一下就定了，实测在 60 条候选里
  /// **误报 5/5** —— 候选一多，从"全都不相关"里挑最大值总有冒上线的。
  ///
  /// ⚠️ 也别指望"相对判据"（比全库中位数高多少）能救：实测有答案的落差最低
  /// 0.122、无答案的最高 0.143，重叠得更厉害，那条路走不通。
  ///
  /// ⚠️ 20 条查询的样本**偏小，有过拟合风险**：它的作用是"少误报"，不是"消除误报"。
  static const vectorMinScore = 0.45;

  /// 每一路各取几条候选去融合。**只排序、不进上下文**，所以可以放宽。
  static const candidatesPerChannel = 10;

  /// 关键词那一路的门槛：至少要有 1 片命中才算候选。
  ///
  /// （LIKE 命中没有"相似度"只有"命中几次"，所以要设门槛也只能按命中数设。）
  static const keywordMinHits = 1;

  /// **自动注入**的及格线：只有最高分到了这里，才把检索结果塞给 AI。
  ///
  /// 比 [vectorMinScore]（0.45，检索那一路的门槛）更严，因为这两件事的代价不同：
  ///   · 0.45 是"进候选池、参与排序"，混进一条不相关的只是排后面；
  ///   · 而注入是**每一轮都塞进上下文**，塞错了模型会照着错的素材推理。
  ///
  /// 按实测（`test/rag_eval_test.dart`）：
  ///
  /// | 线 | 有答案的召回（15 条） | 无答案的误报（5 条） |
  /// |---|---|---|
  /// | 0.45 | 11 | 1 |
  /// | **0.50** | **10** | **0** |
  ///
  /// 用 10 换 0：**宁可少给一条，也不给一条错的** —— 少给的那条 AI 手里还有
  /// `search_notes` / `outline_notes` 能兜，给错的那条它没法自己发现。
  static const injectMinScore = 0.50;

  /// 融合后的正式候选数（真正进上下文的）。
  static const fusedTop = 3;

  /// **同一篇笔记最多占几个位置**。
  ///
  /// 取 1：实测"会议记录"那条查询，前三条全是同一篇的不同片 —— 白占两个名额。
  /// 三个位置给**三篇不同的笔记**，AI 能看到的"面"更宽；真要深挖某一篇，
  /// 它手里有 `read_note_batch`，按注入里带的 offset 接着读就行。
  static const maxChunksPerNote = 1;

  /// 每一段注入的字符上限。
  ///
  /// ⚠️ 是**从片段开头截**，不是"命中位置前后取窗口" —— 片本身就是按标题切出来的
  /// 语义单元，从中间开个窗口反而把话截断了（`NoteRetriever._clip`）。
  static const snippetChars = 400;

  /// 整块注入的字符预算。**硬上限**：宁可少给一段，也不要挤掉别的素材。
  static const materialBudgetChars = 1200;

  /// RRF 的平滑常数。60 是常规取值，不用调。
  static const rrfK = 60;

  /// 一次索引最多补几篇笔记的向量。
  ///
  /// 按**篇**调度是因为"一篇的正文要一次读出来、所有缺向量的片一起算"。
  static const indexNotesPerRun = 10;

  /// 一次索引最多补几片向量（嵌入是 74ms/片的纯 CPU，得有个止损）。
  static const indexChunksPerRun = 120;

  /// 每次嵌一批的上限。批太大中途被杀就白算了。
  static const embedBatchSize = 32;
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
