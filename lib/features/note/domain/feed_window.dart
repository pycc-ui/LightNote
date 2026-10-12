import '../../../core/util/app_params.dart';
import 'note_chunk.dart';

/// 卡片流取素材的规则：**从片里开一个 300 字的窗口**。
///
/// 素材是 300 字，而片是 700：片是**搜索**用的语义单元（按标题层次切，上限 700）；
/// 卡片流是**消费侧**，它的提示词、成本估算、抽取逻辑都围绕"一份素材 300 字"设计。
/// 两者用同一个切片器，但卡片流只取其中 300 字的窗口。
///
/// ⚠️ 切片**不再给 AI Agent**（Agent 改走 `sed`/`grep` 按行号读写），只服务
/// 卡片流与搜索。所以这里的窗口大小只影响卡片成本，不再影响 Agent 读片预算。
///
/// 全部是纯函数，所以可以单独测（这也是它单独成文件的原因：
/// `FeedRepository` 里那套取片流程要连数据库，测起来重得多）。
class FeedWindow {
  const FeedWindow._();

  /// 一份素材的字符数。从 400 降到 300：卡片流输入侧同步收缩，省 token。
  /// 值见 `FeedLimits.windowChars`。
  static const chars = FeedLimits.windowChars;

  /// 单批素材的字符预算。一次最多 `kGenParallelism`(4) 份 → 4 × [chars](300) = 1200 ≤ 4000。
  ///
  /// 这条预算的意义：它**依赖片的硬上限 700 不会失控**。片一旦能超过 700 很多，
  /// "4 份素材 ≤ 1200 字"这个估算就不成立了（提示词长度、token 成本、
  /// 一次请求能不能装下全都跟着崩）。所以切片器那边 700 是**硬约束**。
  static const batchBudget = FeedLimits.windowBatchBudget;

  /// 候选窗口起点（相对片起点的偏移）。
  ///
  /// 规则：`0, 300, 600, …` 一直到不超过 `len - 300`，**最后一个窗口尾部对齐**
  /// （直接取 `len - 300`），免得尾段只剩几十个字。
  ///
  /// | 片长 | 起点 |
  /// |---|---|
  /// | 350 | `[0]`（整片，不用开窗） |
  /// | 700 | `[0, 300, 400]` |
  /// | 1500 | `[0, 300, 600, 900, 1200]` |
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
