import 'dart:typed_data';

import '../../../core/db/app_database.dart';
import '../../../core/util/app_params.dart';
import '../../note/data/note_chunk_repository.dart';
import '../../note/domain/note_chunk.dart';
import 'text_embedder.dart';

/// **给笔记切片补向量**（语义检索的"索引"那一半）。
///
/// ## 什么时候跑
///
/// 三个时机，都是**后台**、都是限量：
///
/// | 时机 | 做什么 |
/// |---|---|
/// | 笔记保存后（防抖完） | 只补这一篇（通常一两片，几十毫秒） |
/// | App 启动后空闲时 | `indexMissing` 补一批老笔记 |
/// | 检索前发现索引太空 | `indexMissing` 补一小批，再检索 |
///
/// **绝不在保存路径上同步等**：74ms/片的 CPU 会让编辑卡顿，而向量晚几秒
/// 生效没有任何影响（检索本来就是"锦上添花"那一路，AI 手里还有工具）。
///
/// ## 为什么不用"删除失效向量"这套
///
/// 向量的有效性由**两个字段对齐**决定（`content_hash` + `model`），不对齐就
/// 查不出来 —— 所以正文一改，旧向量自动失效，**不需要任何一方去清理**。
/// 这跟 `note_chunks` 用 `contentHash` 自愈是同一个思路，两处不用互相通知。
///
/// 代价是表里会攒下死行（改一次正文攒一批）。它们不影响检索结果，只在索引时
/// 被跳过；攒多了由 [pruneStale] 清一次。
class RagIndexer {
  RagIndexer(this._db) : _chunks = NoteChunkRepository(_db);

  final AppDatabase _db;
  final NoteChunkRepository _chunks;

  /// 当前用的模型标识（存进 `note_vectors.model`）。
  static const modelId = TextEmbedder.modelId;

  /// 还缺多少片没索引（给"要不要现在就补一批"做判据）。
  Future<int> pendingCount() async {
    // 总片数 - 有效向量数：两个都是 COUNT，不必把行读出来
    final total = await _db.chunkTotalCount();
    final done = await _db.validVectorCount(modelId);
    final left = total - done;
    return left < 0 ? 0 : left;
  }

  /// 判断"索引是不是空得没法用"（比如刚装完、或者换过模型）。
  ///
  /// 判据是**覆盖率**而不是绝对条数：10 篇笔记里索引了 9 篇就够了，
  /// 1000 篇里索引了 9 篇则形同没有 —— 这种时候检索就不该被当成可信通道。
  Future<bool> isIndexThin({int minVectors = 8}) async {
    final done = await _db.validVectorCount(modelId);
    return done < minVectors;
  }

  /// 补一批缺向量的笔记。返回这次补了**几片**。
  ///
  /// [budgetChunks] 是这次最多算几片（嵌入是纯 CPU，得有止损）。
  ///
  /// ## 顺序不能反：先补片，再补向量
  ///
  /// 这两层都是**懒回填**的，而向量那层的调度又是"从 `note_chunks` 里挑笔记"
  /// —— 新库/刚建的笔记一片都还没有，直接去挑就会**永远挑到空**
  /// （实测踩过：跑完一条向量都没建出来，还以为是模型的问题）。
  /// 所以第一句必须先复用切片那一层的懒回填，把片补出来。
  Future<int> indexMissing({
    int maxNotes = RagLimits.indexNotesPerRun,
    int budgetChunks = RagLimits.indexChunksPerRun,
  }) async {
    if (budgetChunks <= 0) return 0;

    // 先把片补出来（一个片都没有的笔记，在向量那条 SQL 里是看不见的）
    await _chunks.backfillMissing(limit: maxNotes);

    final ids = await _db.noteIdsMissingVectors(modelId, limit: maxNotes);
    var done = 0;
    for (final id in ids) {
      if (done >= budgetChunks) break;
      done += await indexNote(id, budgetChunks: budgetChunks - done);
    }
    return done;
  }

  /// 给**一篇**笔记补上缺的向量。返回补了几片。
  ///
  /// 已经对得上的片会跳过（不会重复嵌入）。
  Future<int> indexNote(String noteId, {int budgetChunks = 64}) async {
    final note = await _db.getNote(noteId);
    if (note == null || note.content.trim().isEmpty) return 0;

    // 先让片是"当前的"：`chunksFor` 会做懒回填与 hash 自愈。
    // 直接读 `note_chunks` 表是不行的 —— 表里的片可能对应的还是旧正文。
    final chunks = await _chunks.chunksFor(noteId, note.content);
    if (chunks.isEmpty) return 0;

    final existing = {
      for (final v in await _db.vectorsOf(noteId, modelId)) v.idx: v.contentHash,
    };

    // 挑出「没算过」或「算过但正文已变」的片
    final todo = <NoteChunk>[];
    for (final c in chunks) {
      if (existing[c.index] == c.contentHash) continue;
      if (c.textOf(note.content).trim().isEmpty) continue;
      todo.add(c);
      if (todo.length >= budgetChunks) break;
    }
    if (todo.isEmpty) return 0;

    final now = DateTime.now().toUtc();
    var done = 0;

    // 分批嵌入：批太大中途被杀就白算了；批也别太小（每批都有一次 isolate 往返）
    for (var at = 0; at < todo.length; at += RagLimits.embedBatchSize) {
      final slice = todo.sublist(
        at,
        (at + RagLimits.embedBatchSize).clamp(0, todo.length),
      );
      final texts = [
        for (final c in slice) _textFor(c, note.content),
      ];
      final vecs = await TextEmbedder.instance.embedBatch(texts);
      if (vecs.length != slice.length) {
        throw StateError('嵌入了 ${vecs.length} 条，期望 ${slice.length} 条');
      }

      await _db.putNoteVectors(noteId, [
        for (var i = 0; i < slice.length; i++)
          NoteVectorsCompanion.insert(
            noteId: noteId,
            idx: slice[i].index,
            contentHash: slice[i].contentHash,
            model: modelId,
            dim: vecs[i].length,
            vec: VectorBytes.fromFloats(vecs[i]),
            createdAt: now,
          ),
      ]);
      done += slice.length;
    }
    return done;
  }

  /// 软删笔记时清掉向量。
  ///
  /// 外键带 `ON DELETE CASCADE` 但项目用软删除（行还在），级联不触发 ——
  /// 和 `note_chunks` 是同一个坑，所以要显式清（检索那边也有一道
  /// `deleted_at IS NULL` 兜底，两道都留着）。
  Future<void> clearFor(String noteId) => _db.clearNoteVectors(noteId);

  /// 清掉死行（`content_hash` 已经对不上、或者模型已经换了）。
  ///
  /// **不是必须的**：留着不影响任何结果（检索时 JOIN 就把它们过滤掉了）。
  /// 只是让表别无限长大 —— 顺带释放那些 BLOB（每片 2KB）。
  Future<int> pruneStale({int limit = 500}) async {
    final rows = await _db.staleVectorIds(modelId, limit: limit);
    if (rows.isEmpty) return 0;
    await _db.deleteVectors(rows);
    return rows.length;
  }

  /// 这一片送进模型的**文本**：`标题路径 + 正文`。
  ///
  /// 带上 `heading` 是因为片正文常常以"1. xxx"这种断开的形式开始，单看它
  /// 不知道在讲什么话题；标题路径（"工作 / 项目A / 风险"）正好补上这个上下文，
  /// 而且它本来就存在库里、不额外花成本。
  static String _textFor(NoteChunk c, String content) {
    final head = c.heading.trim();
    final text = c.textOf(content);
    return head.isEmpty ? text : '$head\n$text';
  }
}

/// 向量与字节之间的转换。
///
/// 存的是 **Float32 小端字节**（`dim * 4` 字节/条，512 维 = 2KB）。
/// 不引原生扩展、也不存 JSON 数组：JSON 会膨胀 5~10 倍，而 Float32 正好是
/// 模型吐出来的原始形状。
abstract final class VectorBytes {
  /// `Float32List` → 可直接写进 BLOB 的字节。
  ///
  /// ⚠️ 用显式视图而不是 `vec.buffer.asUint8List()`：`Float32List` 可能是
  /// 别人 buffer 上的一个切片（比如从 isolate 收到的那种），直接取整个 buffer
  /// 会把相邻数据也带进去。
  static Uint8List fromFloats(Float32List vec) => Uint8List.view(
        vec.buffer,
        vec.offsetInBytes,
        vec.lengthInBytes,
      );

  /// BLOB → `Float32List`。长度不是 4 的倍数（数据坏了）时返回空。
  ///
  /// **要的是视图不是拷贝**：检索要把上千条向量全读出来算点积，拷贝一遍就多
  /// 一份等量的内存。
  static Float32List toFloats(Uint8List bytes) {
    if (bytes.lengthInBytes % 4 != 0) return Float32List(0);
    return bytes.buffer.asFloat32List(bytes.offsetInBytes, bytes.length ~/ 4);
  }

  /// 两个都已归一化的向量做点积（= 余弦相似度）。
  ///
  /// 长度不一致时按短的算并**返回 0**：那是"模型换了但旧行还在"的信号，
  /// 这种数据不该参与排序（算出来的数没有意义）。
  static double dot(Float32List a, Float32List b) {
    if (a.length != b.length || a.isEmpty) return 0;
    var s = 0.0;
    for (var i = 0; i < a.length; i++) {
      s += a[i] * b[i];
    }
    return s;
  }
}
