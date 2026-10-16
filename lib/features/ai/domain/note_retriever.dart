import '../../../core/db/app_database.dart';
import '../../../core/util/app_params.dart';
import '../../note/data/search_service.dart';
import '../data/rag_indexer.dart';
import '../data/text_embedder.dart';

/// 注入素材块的**首行标记**。
///
/// 单独提出来是因为它有两个用处：拼装时写在第一行，以及**判重**——
/// 挂起恢复时请求历史是重新拼的，靠它认得出"这条消息已经带过素材了"，
/// 不会叠第二遍（叠了不但白花 token，还会让模型看到两份自相矛盾的候选）。
const kRetrievalMarker = '【可能相关的笔记片段】';

/// 一条检索结果。
///
/// 三类分数**都留着**，不只留融合分：评测要看"这一条是语义找出来的还是关键词
/// 找出来的"（决定 RAG 到底有没有增量），出问题时也要能一眼看出是哪一路召回的。
class RetrievedSnippet {
  const RetrievedSnippet({
    required this.noteId,
    required this.title,
    required this.heading,
    required this.chunkIndex,
    required this.offset,
    required this.text,
    this.vectorScore,
    this.vectorRank,
    this.keywordRank,
    required this.fusedScore,
  });

  final String noteId;
  final String title;

  /// 标题路径，如「项目A / 风险」。标题命中时为空串。
  final String heading;

  /// 命中的片号；null = 标题命中（整篇相关，不是"第 0 片"）。
  final int? chunkIndex;

  /// 命中内容在原文里的起始下标 —— **给 AI 续读用**：
  /// 它可以把这个 offset 抄给 `read_note_batch` 直接读上下文。
  final int offset;

  /// 注入用的正文片段（已截到 [RagLimits.snippetChars]）。
  final String text;

  /// 语义相似度；关键词那一路召回的没有这个值。
  final double? vectorScore;

  /// 语义那一路的名次（0 起）；没进这一路就是 null。
  final int? vectorRank;

  /// 关键词那一路的名次（0 起）；没进这一路就是 null。
  final int? keywordRank;

  /// 两路融合后的分数（RRF）。
  final double fusedScore;

  /// 是哪一路找出来的（评测、排查都要看）。
  String get source {
    if (vectorRank != null && keywordRank != null) return '两路';
    if (vectorRank != null) return '语义';
    return '关键词';
  }

  @override
  String toString() => 'RetrievedSnippet($title#$chunkIndex, $source, '
      'fused=${fusedScore.toStringAsFixed(4)})';
}

/// **语义 + 关键词两路检索**。
///
/// ## 为什么要两路（而不是只上向量）
///
/// 两路各有一套"看不见"的东西，合起来才不漏：
///
/// | 路 | 强在 | 盲区 |
/// |---|---|---|
/// | 关键词（`SearchService`，现有的） | 精确、可解释、零成本 | **用词不一样就完全找不到**（实测：`会议` 搜不到正文写"参会"的《启动会》） |
/// | 语义（向量） | 换个说法也找得到 | 短查询的相似度整体偏低、边界模糊（实测命中 0.49 / 无关 0.24~0.34） |
///
/// 融合用 **RRF**（Reciprocal Rank Fusion）：`Σ 1/(k + 名次)`。
/// 用它而不是"把两种分数加权相加"是因为**两边的分数不可比** —— 关键词那边是
/// "命中几次"（可以是 1~20 的整数），语义那边是 0~1 的余弦。RRF 只看名次，
/// 天然绕开量纲问题；而且"两路都排前面"的结果会自然冒头，这正是我们要的。
///
/// ## 它不做决定，只提供候选
///
/// 检索出来的东西**不能直接当事实**用（0.35 这条线是及格线不是保证）。所以结果
/// 进上下文时会明确标成"可能相关、需自己核实"，AI 手里那些工具照旧可用。
class NoteRetriever {
  NoteRetriever(this._db)
      : _indexer = RagIndexer(_db),
        _search = SearchService(_db);

  final AppDatabase _db;
  final RagIndexer _indexer;
  final SearchService _search;

  /// 两路融合检索（正式入口）。
  Future<List<RetrievedSnippet>> retrieve(
    String query, {
    int limit = RagLimits.fusedTop,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    final vec = await byVector(q);
    final kw = await byKeyword(q);
    if (vec.isEmpty && kw.isEmpty) return const [];

    // ---- RRF 融合 ----
    // 同一篇的**同一片**才算同一条：`noteId#idx` 做 key。
    // 标题命中（chunkIndex == null）单独一个 key，它和"某一片命中"不是一回事。
    final fused = <String, double>{};
    final byKey = <String, RetrievedSnippet>{};

    for (final s in vec) {
      final key = _keyOf(s.noteId, s.chunkIndex);
      fused[key] = (fused[key] ?? 0) + _rrf(s.vectorRank!);
      byKey[key] = s;
    }
    for (final s in kw) {
      final key = _keyOf(s.noteId, s.chunkIndex);
      fused[key] = (fused[key] ?? 0) + _rrf(s.keywordRank!);
      // 两路都有的：保留语义那条（它带 vectorScore/offset），只把名次补上
      final prev = byKey[key];
      byKey[key] = prev == null
          ? s
          : RetrievedSnippet(
              noteId: prev.noteId,
              title: prev.title,
              heading: prev.heading,
              chunkIndex: prev.chunkIndex,
              offset: prev.offset,
              text: prev.text,
              vectorScore: prev.vectorScore,
              vectorRank: prev.vectorRank,
              keywordRank: s.keywordRank,
              fusedScore: 0, // 下面统一重算
            );
    }

    final keys = fused.keys.toList()
      ..sort((a, b) {
        final byScore = fused[b]!.compareTo(fused[a]!);
        if (byScore != 0) return byScore;
        // 同分稳定：按 key 排，保证同样的库同样的查询结果可复现
        return a.compareTo(b);
      });

    final out = <RetrievedSnippet>[];
    final perNote = <String, int>{};
    var chars = 0;
    for (final k in keys) {
      if (out.length >= limit) break;
      final s = byKey[k]!;
      // 一篇最多占 [RagLimits.maxChunksPerNote] 个位置（见那个常数的说明）
      if ((perNote[s.noteId] ?? 0) >= RagLimits.maxChunksPerNote) continue;
      // 字符预算：宁可少给一条，也不要挤掉别的素材（这是硬上限）
      if (out.isNotEmpty && chars + s.text.length > RagLimits.materialBudgetChars) {
        continue;
      }
      perNote[s.noteId] = (perNote[s.noteId] ?? 0) + 1;
      chars += s.text.length;
      out.add(_withFused(s, fused[k]!));
    }
    return out;
  }

  /// 只跑**语义**那一路（评测与排查用，正式流程走 [retrieve]）。
  ///
  /// 返回的每一条都带 `vectorRank`，但 `fusedScore` 只是这一路的分（没融合）。
  Future<List<RetrievedSnippet>> byVector(
    String query, {
    int limit = RagLimits.candidatesPerChannel,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    final rows = await _db.validVectors(RagIndexer.modelId);
    if (rows.isEmpty) return const [];

    // 查询向量也走 worker isolate（模型只在那一边加载）
    final qv = (await TextEmbedder.instance.embedBatch([q])).first;
    if (qv.length != TextEmbedder.dim) return const [];

    // ---- 全量算点积 ----
    // 两边都归一化过，点积就是余弦。实测 2 万条 512 维 = 11ms，够用；
    // 真要几万条以上再考虑换索引结构（那之前不值得引原生扩展）。
    final scored = <(double, NoteVector)>[];
    for (final r in rows) {
      final v = VectorBytes.toFloats(r.vec);
      final s = VectorBytes.dot(qv, v);
      if (s < RagLimits.vectorMinScore) continue;
      scored.add((s, r));
    }
    if (scored.isEmpty) return const [];
    scored.sort((a, b) {
      final byScore = b.$1.compareTo(a.$1);
      if (byScore != 0) return byScore;
      // 同分稳定（分数一样时按 id/片号，保证可复现）
      final byId = a.$2.noteId.compareTo(b.$2.noteId);
      return byId != 0 ? byId : a.$2.idx.compareTo(b.$2.idx);
    });

    final out = <RetrievedSnippet>[];
    for (var rank = 0; rank < scored.length && out.length < limit; rank++) {
      final (score, row) = scored[rank];
      // 取正文时**重新比对 hash**：算完余弦到这里隔着几次 await，
      // 期间用户可能刚改了正文，那这条就不能用了（片内容对不上向量）。
      final chunk = await _db.chunkAt(row.noteId, row.idx, expectHash: row.contentHash);
      if (chunk == null) continue;
      final note = await _db.getNote(row.noteId);
      if (note == null) continue;

      out.add(RetrievedSnippet(
        noteId: row.noteId,
        title: note.title,
        heading: chunk.heading,
        chunkIndex: chunk.idx,
        offset: chunk.startOffset,
        text: _clip(_textOf(chunk.startOffset, chunk.endOffset, note.content)),
        vectorScore: score,
        vectorRank: rank,
        keywordRank: null,
        fusedScore: _rrf(rank),
      ));
    }
    return out;
  }

  /// 只跑**关键词**那一路（就是现有的 `SearchService`，没有任何改动）。
  Future<List<RetrievedSnippet>> byKeyword(
    String query, {
    int limit = RagLimits.candidatesPerChannel,
  }) async {
    final results = await _search.search(query, limit: limit);
    if (results.isEmpty) return const [];

    final out = <RetrievedSnippet>[];
    // 同一篇可能出现多条（不同片都命中），按名次依次编；命名次用**结果列表下标**
    for (var rank = 0; rank < results.length && out.length < limit; rank++) {
      final r = results[rank];
      final note = await _db.getNote(r.noteId);
      if (note == null) continue;

      // 标题命中：整篇相关，取开头一段；片命中：取那一片的正文
      final int offset;
      final String raw;
      if (r.chunkIndex == null) {
        offset = 0;
        raw = note.content;
      } else {
        final chunk = await _db.chunkAt(r.noteId, r.chunkIndex!);
        if (chunk == null) {
          offset = 0;
          raw = r.snippet;
        } else {
          offset = chunk.startOffset;
          raw = _textOf(chunk.startOffset, chunk.endOffset, note.content);
        }
      }

      out.add(RetrievedSnippet(
        noteId: r.noteId,
        title: r.title,
        heading: r.heading,
        chunkIndex: r.chunkIndex,
        offset: offset,
        text: _clip(raw),
        vectorScore: null,
        vectorRank: null,
        keywordRank: rank,
        fusedScore: _rrf(rank),
      ));
    }
    return out;
  }

  /// **自动注入用的素材块**：不确定就返回 null（什么都不给）。
  ///
  /// "确定"的判据是**语义那一路的最高分 ≥ [RagLimits.injectMinScore]**：
  ///   · 只看语义那一路，不看关键词 —— 关键词命中是"字面对得上"，
  ///     本来就有 `search_notes` 工具能拿，没必要每轮白塞；
  ///   · 一条都没过线 → null。**这是常态**，不是异常（实测 5 条无答案的查询
  ///     里 5 条都会走到这里）。
  ///
  /// 索引还没建好时也返回 null：那时候能召回的只是"索引里仅有的几篇"，
  /// 不是"最相关的几篇"，亮给 AI 反而是误导（见 [isUsable]）。
  Future<String?> autoInjectBlock(String query) async {
    final q = query.trim();
    if (q.isEmpty) return null;

    final hits = await byVector(q);
    if (hits.isEmpty) return null;
    final top = hits.first.vectorScore;
    if (top == null || top < RagLimits.injectMinScore) return null;

    return formatMaterial(hits);
  }

  /// 把检索结果拼成注入给模型的那段文字。
  ///
  /// 三件事必须在文案里说清，否则模型会把它当事实用：
  ///   1. 这是**系统猜的**，可能不相关，用之前自己核实；
  ///   2. 每条都带 `id` 和 `offset` —— 它可以**抄给 `read_note_batch` 接着读**，
  ///      不必从头把整篇读一遍（这正是分层读取那套设计的用法）；
  ///   3. 要改笔记就走正常工具，别以为这段文字是什么"既成事实"。
  static String formatMaterial(List<RetrievedSnippet> items) {
    final buf = StringBuffer()
      ..writeln(kRetrievalMarker)
      ..writeln('下面这些是系统按语义猜的，**可能不相关**，用之前请自己核实；')
      ..writeln('要看上下文就把 id 和 offset 抄给 read_note_batch，不用从头读整篇。');
    for (var i = 0; i < items.length; i++) {
      final s = items[i];
      final at = s.chunkIndex == null ? '（标题命中）' : '（第 ${s.chunkIndex} 片'
          '${s.heading.isEmpty ? '' : ' · ${s.heading}'}）';
      buf
        ..writeln()
        ..writeln('${i + 1}. 《${s.title}》$at id=${s.noteId} offset=${s.offset}')
        ..writeln(s.text);
    }
    return buf.toString().trimRight();
  }

  /// 当前全部有效向量与 [query] 的相似度（**按高到低排好**）。
  ///
  /// **给评测用**：要定"及格线该是多少"，必须能看到完整的分数分布 ——
  /// 只看过了线的那几条，永远发现不了"线定低了"（详见 `test/rag_eval_test.dart`）。
  Future<List<double>> rawVectorScores(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final rows = await _db.validVectors(RagIndexer.modelId);
    if (rows.isEmpty) return const [];

    final qv = (await TextEmbedder.instance.embedBatch([q])).first;
    if (qv.length != TextEmbedder.dim) return const [];

    final out = <double>[];
    for (final r in rows) {
      out.add(VectorBytes.dot(qv, VectorBytes.toFloats(r.vec)));
    }
    out.sort((a, b) => b.compareTo(a));
    return out;
  }

  /// 补一批索引（检索前发现索引太空时调）。返回补了几片。
  Future<int> warmUp({int budgetChunks = RagLimits.indexChunksPerRun}) =>
      _indexer.indexMissing(budgetChunks: budgetChunks);

  // ==========================================================================
  // 内部
  // ==========================================================================

  /// 这一趟搜索的"信任度"够不够（索引太空或一条都没召回时为假）。
  ///
  /// 调用方可以据此**决定要不要把结果亮给 AI** —— 索引还没建好的时候硬塞几条
  /// 反而误导（那不是"最相关的"，只是"索引里仅有的"）。
  Future<bool> isUsable() async => !(await _indexer.isIndexThin());

  static double _rrf(int rank) => 1.0 / (RagLimits.rrfK + rank + 1);

  static String _keyOf(String noteId, int? idx) =>
      idx == null ? '$noteId#t' : '$noteId#$idx';

  static RetrievedSnippet _withFused(RetrievedSnippet s, double fused) =>
      RetrievedSnippet(
        noteId: s.noteId,
        title: s.title,
        heading: s.heading,
        chunkIndex: s.chunkIndex,
        offset: s.offset,
        text: s.text,
        vectorScore: s.vectorScore,
        vectorRank: s.vectorRank,
        keywordRank: s.keywordRank,
        fusedScore: fused,
      );

  static String _textOf(int start, int end, String content) {
    if (start < 0 || end > content.length || start >= end) return '';
    return content.substring(start, end);
  }

  /// 截到 [RagLimits.snippetChars]。
  ///
  /// **从片段开头截**（不是"命中位置前后取窗口"）：命中位置那套是给搜索页做
  /// 高亮用的，注入给 AI 时更应该给它一段**完整连贯**的上下文 —— 片本身就是按
  /// 标题切的语义单元，从中间开个窗口反而把话截断了。
  static String _clip(String text) {
    final t = text.trim();
    if (t.length <= RagLimits.snippetChars) return t;
    return '${t.substring(0, RagLimits.snippetChars)}…';
  }
}
