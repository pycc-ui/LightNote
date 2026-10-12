import 'package:drift/drift.dart';

import '../../../core/db/app_database.dart';
import '../../../core/util/ai_limits.dart';

/// 笔记 AI **摘要**的**数据访问**。
///
/// 它不是"缓存"：产品要求把它**存在数据库里长期复用**（以后还要用于语义搜索、
/// 让 AI 读取笔记）。所以这不是一个可以随时丢弃的缓存，而是一份持久化资产 ——
/// 只是当笔记内容变了之后需要重新生成。
///
/// ## 标签链路已在 v8 / v9 删除
///
/// `note_ai_tags`（每篇笔记的 AI 标签，与摘要配套生成）只写不读：唯一的读侧
/// 链路 `get()` → `FeedRepository.tagsOf()` 零调用方，而卡片上显示的那个标签
/// 其实来自卡片自己的 `FeedDraft.tag`（见 `displayTag`），与它无关。
/// v8 把那张表和整条链路（含 `NoteAiAsset.tags`、`get()`、`tagsOf()`）一起删了；
/// v9 又删掉了「用户手动标签」的 `tags` / `note_tags` 两张表。
///
/// 现在唯一的标签是**卡片级**的（`FeedDraft.tag`，单个），规整函数
/// `sanitizeTag` 也已挪到 `core/util/ai_limits.dart`——它本来就是个纯文本工具，
/// 让 `prompts.dart` 为了它依赖一个 repository 是别扭的。
///
/// 为什么不和展示型摘要合并：`note_summaries` 是用户点「AI 整理要点」的产物，
/// 一次一条、不覆盖历史、主键是 UUID，还带 tokens/cost 审计字段；
/// 这里要的是"一篇笔记一条、新结果覆盖旧的、需要失效判断"，语义相反。
///
/// `note_summaries` **已在 schema v7 删除**（只写不读的死表，功能入口也没了），
/// 但这个语义差异仍然成立：这里的摘要**用户看不到**，只是卡片流的素材。
class NoteAiAssetRepository {
  NoteAiAssetRepository(this._db);

  final AppDatabase _db;

  /// 内容变化超过这个比例才认为摘要过期。
  ///
  /// **为什么要防抖**：笔记的 `updatedAt` 只要写一次就变，
  /// 用户改个错别字也会让摘要作废 = 白烧一次 token。
  /// 用"字节数变化比例"衡量"改了多少"，比时间戳贴合意图得多。
  static const staleRatio = AiLimits.summaryStaleRatio;

  // ==========================================================================
  // 读
  // ==========================================================================

  /// 只要摘要（卡片流素材用）。
  ///
  /// 返回 null 表示"没有或已过期"，调用方应当去生成。
  Future<String?> getFreshSummary(String noteId) async {
    final s = await (_db.select(_db.aiNoteSummaries)
          ..where((t) => t.noteId.equals(noteId)))
        .getSingleOrNull();
    if (s == null) return null;
    if (await _isStale(noteId, s.sourceBytes)) return null;
    return s.summary.isEmpty ? null : s.summary;
  }

  /// 批量取新鲜摘要，一次查完（卡片流一屏要问好几篇）。
  ///
  /// 返回 Map：noteId → 摘要。**只包含新鲜且非空的**，
  /// 调用方看到某篇不在 Map 里就知道要生成。
  Future<Map<String, String>> freshSummaries(Iterable<String> noteIds) async {
    final ids = noteIds.toList(growable: false);
    if (ids.isEmpty) return const {};

    final rows = await (_db.select(_db.aiNoteSummaries)
          ..where((t) => t.noteId.isIn(ids)))
        .get();

    // 一次查完这些笔记的字节数，避免逐条查
    final bytes = await _sourceBytes(ids);

    final out = <String, String>{};
    for (final r in rows) {
      if (r.summary.isEmpty) continue;
      if (_differsTooMuch(bytes[r.noteId], r.sourceBytes)) continue;
      out[r.noteId] = r.summary;
    }
    return out;
  }

  // ==========================================================================
  // 写
  // ==========================================================================

  /// 写入摘要（覆盖旧值）。
  ///
  /// [summary] 会先按硬上限截断——AI 不守字数，兜底必须在写入口。
  Future<void> putSummary(
    String noteId,
    String summary, {
    String model = '',
  }) async {
    final now = DateTime.now().toUtc();
    final text = safeTruncate(summary.trim(), AiLimits.summaryHardMax);
    final bytes = await _sourceByteOf(noteId);

    await _db.into(_db.aiNoteSummaries).insertOnConflictUpdate(
          AiNoteSummariesCompanion.insert(
            noteId: noteId,
            summary: text,
            model: Value(model),
            sourceBytes: Value(bytes),
            createdAt: now,
            updatedAt: now,
          ),
        );
  }

  /// 笔记被删除时一并清掉（外键有 CASCADE，这里只是显式入口）。
  Future<void> deleteFor(String noteId) async {
    await (_db.delete(_db.aiNoteSummaries)
          ..where((t) => t.noteId.equals(noteId)))
        .go();
  }

  // ==========================================================================
  // 过期判断
  // ==========================================================================

  Future<bool> _isStale(String noteId, int cachedBytes) async {
    final now = await _sourceByteOf(noteId);
    return _differsTooMuch(now, cachedBytes);
  }

  /// 变化幅度是否超过 [staleRatio]。
  ///
  /// 注意**缓存为 0 字节也算变化**：那说明当初是空笔记生成的摘要，
  /// 现在有内容了，显然该重来。
  static bool _differsTooMuch(int? current, int cached) {
    if (current == null) return true; // 笔记没了
    if (cached <= 0) return current > 0;
    final diff = (current - cached).abs();
    return diff / cached > staleRatio;
  }

  Future<int> _sourceByteOf(String noteId) async {
    final row = await (_db.select(_db.notes)
          ..where((t) => t.id.equals(noteId)))
        .getSingleOrNull();
    if (row == null) return -1;
    return utf8ByteLength(row.content);
  }

  Future<Map<String, int>> _sourceBytes(List<String> noteIds) async {
    final rows = await (_db.select(_db.notes)
          ..where((t) => t.id.isIn(noteIds)))
        .get();
    return {
      for (final r in rows) r.id: utf8ByteLength(r.content),
    };
  }
}
