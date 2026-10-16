import '../../../core/util/app_params.dart';
import 'note_chunk.dart';

/// 卡片流取素材的规则：**从片里开一个窗口**（大小见 `FeedLimits.windowChars`）。
///
/// 素材比片小，而片是**搜索、卡片流、语义检索**共用的语义单元
///（按标题层次切，上限见 `ChunkLimits.noteCap`）。卡片流是**消费侧**，
/// 它的提示词、成本估算、抽取逻辑都围绕"一份素材多大"设计。
/// 几处用同一个切片器，但卡片流只取其中一小段窗口。
///
/// ⚠️ 别在这里写死窗口和片长的数字 —— 它们调过好几轮（窗口从 400 收到 250）。
/// 看当前值去 `FeedLimits` / `ChunkLimits`。
///
/// ⚠️ 以前这里写着"切片不再给 AI Agent"：那在 **RAG 语义检索**上线之后就不成立了
/// —— `note_vectors` 就是**一片一行**，检索命中之后读出来的也正是片正文
///（见 `NoteRetriever`）。Agent 用 SQL 按关键词定位是另一条路，两者并存。
///
/// 全部是纯函数，所以可以单独测（这也是它单独成文件的原因：
/// `FeedRepository` 里那套取片流程要连数据库，测起来重得多）。
class FeedWindow {
  const FeedWindow._();

  /// 一份素材的字符数（从片里开出的窗口大小）。值见 `FeedLimits.windowChars`。
  static const chars = FeedLimits.windowChars;

  /// 单批素材的字符预算。实际用量由两个常量决定（都在 `FeedLimits` 里）：
  /// 一次最多 `genParallelism` 份 × 每份 `windowChars` 字。
  ///
  /// ⚠️ **具体数字别抄在这里** —— 它们调过好几轮（并发从 4 降到 3、
  /// 窗口从 400 收到 250），抄进注释就会在下次调整时变成一句假话。
  /// 要看当前值就去看 `FeedLimits`。
  ///
  /// 这条预算的意义：它**依赖片的硬上限不会失控**（`ChunkLimits.noteCap`）。
  /// 片一旦能超过那个上限很多，"几份素材 ≤ 预算"这个估算就不成立了
  ///（提示词长度、token 成本、一次请求能不能装下全都跟着崩）。
  /// 所以切片器那边那个上限是**硬约束**。
  static const batchBudget = FeedLimits.windowBatchBudget;

  /// 候选窗口起点（相对片起点的偏移）。
  ///
  /// 规则：`0, chars, 2*chars, …` 一直到不超过 `len - chars`，**最后一个窗口尾部对齐**
  /// （直接取 `len - chars`），免得尾段只剩几十个字。
  ///
  /// ⚠️ 下表按**当前** `chars`（`FeedLimits.windowChars` = 250）算出来的 ——
  /// `chars` 一改这些数就全变了，别照抄，跑一下 `starts` 最省事。
  ///
  /// | 片长 | 起点 |
  /// |---|---|
  /// | 350 | `[0, 100]` |
  /// | 700 | `[0, 250, 450]` |
  /// | 1500 | `[0, 250, 500, 750, 1000, 1250]` |
  static List<int> starts(int len) {
    if (len <= chars) return const [0];
    final out = <int>[];
    for (var s = 0; s <= len - chars; s += chars) {
      out.add(s);
    }
    final tail = len - chars;
    if (out.last != tail) out.add(tail);
    return out;
  }

  /// 用完起点 [current] 之后，下一个该用哪个（**环形**）。
  ///
  /// 环形而不是从头再来：这样一片的每个窗口都会轮到，
  /// 不会出现"后半段永远不出卡片"。
  ///
  /// [current] 不在 [starts] 里时（正文改过、候选变了）回到第一个 ——
  /// 这是唯一安全的落点，猜一个下标可能越界。
  static int nextStart(List<int> starts, int current) {
    if (starts.isEmpty) return 0;
    final at = starts.indexOf(current);
    if (at < 0) return starts.first;
    return starts[(at + 1) % starts.length];
  }

  /// 取素材正文：片内从 [start] 起 [chars] 个字，**不越出片**。
  ///
  /// 越界一律收敛到片边界（而不是抛错或返回空串）：偏移失效的那一刻
  /// 上层会发现"取出来比预期短"，由仓储那边自愈重切。
  static String textOf(String content, NoteChunk chunk, int start) {
    final chunkText = chunk.textOf(content);
    if (chunkText.isEmpty) return '';
    if (start <= 0 && chunkText.length <= chars) return chunkText;
    final from = start.clamp(0, chunkText.length);
    final to = (from + chars).clamp(from, chunkText.length);
    return chunkText.substring(from, to);
  }
}
