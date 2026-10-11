import 'package:drift/drift.dart';

import '../../../core/db/app_database.dart';
import '../domain/note_chunk.dart';
import '../domain/note_chunker.dart';

/// 笔记切片的仓储：**切、存、读、自愈**都在这里。
///
/// ## 三条路径，一条比一条"贵"
///
/// | 场景 | 做什么 | 成本 |
/// |---|---|---|
/// | 笔记保存后 | 只在"长度变化超过阈值"或"还没有片"时重切 | 一次切片 |
/// | 读片时（`readChunk` / 搜索定位） | 校验 `contentHash`，不符才重切 | 一次 hash |
/// | 后台补 | `backfillMissing` 给"从没切过"的老笔记补上 | 限量 |
///
/// ## 为什么"小改动可以不重切"
///
/// 保存后如果每次都重切，用户每敲一个字（防抖 500ms 后）就会切一遍全文。
/// 而**偏移失效是能被检出的**（`contentHash`），所以完全可以等到"真的有人要读"
/// 时再重切 —— 那正是 [chunksFor] 做的事。
///
/// 换句话说：**保存路径求快、读取路径求准**，两者靠 hash 兜在一起。
class NoteChunkRepository {
  NoteChunkRepository(this._db);

  final AppDatabase _db;

  /// 正文长度变化超过这个比例就**主动**重切。
  ///
  /// 与摘要资产的失效阈值同一个思路（那边也是 20%）：小改动靠读时自愈，
  /// 大改动才值得在保存那一刻多花一次切片。
  static const staleRatio = 0.20;

  // ==========================================================================
  // 读
  // ==========================================================================

  /// 取某篇笔记的切片，**保证它们与当前正文一致**。
  ///
  /// 三种情况：
  ///   · 一片都没有（老库升上来的）→ 现切一遍写回（**懒回填**）
  ///   · 有片但 `contentHash` 对不上（正文改过、偏移失效）→ 重切（**自愈**）
  ///   · 有片且都对得上 → 直接用，**零写入**
  Future<List<NoteChunk>> chunksFor(String noteId, String content) async {
    final rows = await _db.chunksOf(noteId);
    if (rows.isEmpty) {
      if (content.trim().isEmpty) return const [];
      return rebuild(noteId, content);
    }
    if (_isConsistent(rows, content)) {
      return [for (final r in rows) _toDomain(r)];
    }
    return rebuild(noteId, content);
  }

  /// 只给目录用的轻量版：不校验、不重切（调用方只关心片数与标题路径时用）。
  Future<List<NoteChunk>> cachedChunks(String noteId) async {
    final rows = await _db.chunksOf(noteId);
    return [for (final r in rows) _toDomain(r)];
  }

  /// 读一片的**正文**。偏移失效时自愈重切后再取。
  ///
  /// 返回 null 表示这篇笔记在这个 index 上确实没有片（越界或空笔记），
  /// 与"取到了空串"是两回事 —— 调用方要能区分，否则会以为笔记没内容。
  Future<String?> readChunk(String noteId, String content, int index) async {
    if (index < 0) return null;
    final chunks = await chunksFor(noteId, content);
    if (index >= chunks.length) return null;
    final text = chunks[index].textOf(content);
    return text.isEmpty ? null : text;
  }

  // ==========================================================================
  // 写
  // ==========================================================================

  /// 无条件重切并写回（事务内先删后插）。
  Future<List<NoteChunk>> rebuild(String noteId, String content) async {
    final chunks = NoteChunker.chunk(content);
    final now = DateTime.now().toUtc();
    await _db.replaceNoteChunks(noteId, [
      for (final c in chunks) _toRow(noteId, c, now),
    ]);
    return chunks;
  }

  /// 笔记保存后调用。**大多数时候什么都不做**（见类注释）。
  ///
  /// 返回 true 表示这次真的重切了。
  Future<bool> onNoteSaved(String noteId, String content) async {
    final rows = await _db.chunksOf(noteId);

    // 还没切过 → 必须切（不然搜索/读片都拿不到片）
    if (rows.isEmpty) {
      if (content.trim().isEmpty) return false;
      await rebuild(noteId, content);
      return true;
    }

    // 正文变空了 → 把片清掉（否则会留着一堆指向空文本的偏移）
    if (content.trim().isEmpty) {
      await _db.replaceNoteChunks(noteId, const []);
      return true;
    }

    // 长度变化够大才主动重切；小改动留给读时自愈
    final covered = rows.last.endOffset;
    final before = covered <= 0 ? 0 : covered;
    final delta = (content.length - before).abs();
    final ratio = before == 0 ? 1.0 : delta / before;
    if (ratio > staleRatio) {
      await rebuild(noteId, content);
      return true;
    }
    return false;
  }

  /// 给"从没切过片"的笔记补切片，一次最多 [limit] 篇。返回补了几篇。
  ///
  /// 这一步**不做全量回填**（那会在升级那一刻卡住启动、中断了还只补一半），
  /// 而是每次启动/进入搜索页时慢慢补。
  Future<int> backfillMissing({int limit = 50}) async {
    final ids = await _db.noteIdsWithoutChunks(limit: limit);
    var done = 0;
    for (final id in ids) {
      final note = await _db.getNote(id);
      if (note == null) continue;
      if (note.content.trim().isEmpty) continue;
      await rebuild(id, note.content);
      done++;
    }
    return done;
  }

  /// 删笔记时清掉它的片。
  ///
  /// ⚠️ 外键已经带 `ON DELETE CASCADE`，但项目用的是**软删除**
  /// （`deletedAt` 置位，行还在），级联**不会触发** —— 软删的笔记如果还留着片，
  /// 搜索的"命中哪一片"就会把已删的笔记也算进去。所以软删时显式清一次。
  Future<void> clearFor(String noteId) => _db.replaceNoteChunks(noteId, const []);

  // ==========================================================================
  // 内部
  // ==========================================================================

  /// 每一片的 hash 都对得上、且范围没越界 → 偏移仍然有效。
  bool _isConsistent(List<NoteChunkRow> rows, String content) {
    for (final r in rows) {
      if (r.startOffset < 0 || r.endOffset > content.length) return false;
      if (r.endOffset <= r.startOffset) return false;
      if (r.endOffset - r.startOffset != r.charCount) return false;
      if (NoteChunk.hashOf(content, r.startOffset, r.endOffset) != r.contentHash) {
        return false;
      }
    }
    return true;
  }

  NoteChunk _toDomain(NoteChunkRow r) => NoteChunk(
        index: r.idx,
        heading: r.heading,
        level: r.level,
        start: r.startOffset,
        end: r.endOffset,
        contentHash: r.contentHash,
        // 卡片流的状态跟着一起带出来，避免调用方再按 (noteId, idx) 查一次
        lastUsedAt: r.lastUsedAt,
        nextWindowStart: r.nextWindowStart,
      );

  NoteChunksCompanion _toRow(String noteId, NoteChunk c, DateTime now) =>
      NoteChunksCompanion.insert(
        noteId: noteId,
        idx: c.index,
        startOffset: c.start,
        endOffset: c.end,
        charCount: c.charCount,
        contentHash: c.contentHash,
        createdAt: now,
        heading: Value(c.heading),
        level: Value(c.level),
      );
}
