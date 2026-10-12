import '../../../core/db/app_database.dart';
import '../../../core/util/app_params.dart';
import '../domain/note_chunk.dart';
import '../domain/search_result.dart';
import 'note_chunk_repository.dart';

/// 统一搜索：**搜索页与 AI 工具共用同一个入口**。
///
/// 搜索结果要能定位到片，不能只到笔记粒度，因为有两件事：
///   · 搜索页要显示**命中哪一段**（「项目A / 风险」+ 摘要），点进去定位到那儿
///   · 搜索要能定位到片，供搜索页展示与跳转
/// 两者都要求结果带**片号**。片是预先算好落库的（`note_chunks`），所以这一步
/// 只是"把命中位置映射到片"，不用重新切。
///
/// ## 不存正文也能定位到片
///
/// 1. `notes.content LIKE '%kw%'` → 命中笔记
/// 2. 在正文里找出**所有**命中位置
/// 3. 每个位置落在哪一片（用 `[start, end)` 区间判）
/// 4. 摘要 = 命中位置前后各 [snippetRadius] 字
class SearchService {
  SearchService(this._db) : _chunks = NoteChunkRepository(_db);

  final AppDatabase _db;
  final NoteChunkRepository _chunks;

  /// 默认返回条数
  static const defaultLimit = SearchLimits.defaultLimit;

  /// 摘要里命中位置前后各留多少字
  static const snippetRadius = SearchLimits.snippetRadius;

  /// 标题命中的得分
  static const titleScore = SearchLimits.titleScore;

  /// 片命中的基础得分（同一片里每多命中一次 +1）
  static const chunkScore = SearchLimits.chunkScore;

  /// 正文命中最多**看**这么多篇笔记。
  ///
  /// 给每篇都算"命中哪一片"需要它的切片。命中几千篇时不能每篇都切一遍，
  /// 而结果只会返回前 [defaultLimit] 条 —— 所以按更新时间取最近的若干篇来算，
  /// 够用且不会因为一次搜索就把整个库切一遍。
  static const contentScanCap = SearchLimits.contentScanCap;

  /// 搜索。[notebookId] 非空时只在这个笔记库里找。
  ///
  /// 返回**已排序、已截断**的列表：
  /// 先按 score 降序，同分按标题稳定排序（保证同样的库、同样的查询结果可复现）。
  Future<List<SearchResult>> search(
    String query, {
    List<String>? notebookIds,
    bool includeUnfiled = true,
    int limit = defaultLimit,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    final out = <SearchResult>[];

    // ---- 一类：标题命中（整篇相关）----
    final byTitle = await _db.notesWithTitleLike(
      q,
      notebookIds: notebookIds,
      includeUnfiled: includeUnfiled,
      limit: limit,
    );
    for (final n in byTitle) {
      out.add(SearchResult(
        noteId: n.id,
        title: n.title,
        chunkIndex: null,
        heading: '',
        snippet: n.title,
        score: titleScore,
      ));
    }

    // ---- 二类：正文命中（要定位到片）----
    final byContent = await _db.notesWithContentLike(
      q,
      notebookIds: notebookIds,
      includeUnfiled: includeUnfiled,
      limit: contentScanCap,
    );
    for (final n in byContent) {
      final hits = findHits(n.content, q);
      if (hits.isEmpty) continue;
      final chunks = await _chunks.chunksFor(n.id, n.content);
      if (chunks.isEmpty) continue;

      // 同一片里命中多次 → 合成一条，得分累加
      final perChunk = <int, List<int>>{};
      for (final at in hits) {
        perChunk.putIfAbsent(chunkIndexAt(chunks, at), () => []).add(at);
      }
      for (final e in perChunk.entries) {
        final chunk = chunks[e.key];
        out.add(SearchResult(
          noteId: n.id,
          title: n.title,
          chunkIndex: e.key,
          heading: chunk.heading,
          snippet: snippetOf(n.content, e.value.first, q.length),
          score: chunkScore + (e.value.length - 1),
        ));
      }
    }

    out.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return a.title.compareTo(b.title);
    });
    return out.length > limit ? out.sublist(0, limit) : out;
  }

  // ==========================================================================
  // 纯函数部分（不碰数据库，单独测）
  // ==========================================================================

  /// 正文里**所有**出现 [query] 的位置（不重叠、从左到右）。
  ///
  /// 大小写：SQLite 的 `LIKE` 对 ASCII 是**不区分大小写**的。如果这里区分，
  /// 就会出现"数据库说命中了、正文里却找不到位置"的矛盾（搜 `provider`
  /// 命中了一篇写着 `Provider` 的笔记，然后摘要算不出来）。
  ///
  /// 所以这里先按小写找位置。`toLowerCase()` 在极少数 Unicode 字符上会改变
  /// 长度（进而让下标错位），所以**长度变了就退回区分大小写**——
  /// 宁可少匹配几个大小写变体，也不能用错位的下标去切正文。
  static List<int> findHits(String content, String query) {
    if (query.isEmpty || content.isEmpty) return const [];
    final lowerContent = content.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final usable = lowerContent.length == content.length &&
        lowerQuery.length == query.length;
    final hay = usable ? lowerContent : content;
    final needle = usable ? lowerQuery : query;
    if (needle.isEmpty || needle.length > hay.length) return const [];

    final out = <int>[];
    var i = 0;
    while (true) {
      final at = hay.indexOf(needle, i);
      if (at < 0) break;
      out.add(at);
      i = at + needle.length; // 不重叠
    }
    return out;
  }

  /// [at] 落在哪一片。
  ///
  /// 命中位置**理论上**可能落在两片之间的空白里（片边界会把首尾空白裁掉）。
  /// 这时返回**前一片**：用户点进结果是想看命中那一段的上下文，
  /// 给前一片比给 null（假装是"标题命中"）更接近他的意图。
  static int chunkIndexAt(List<NoteChunk> chunks, int at) {
    for (var i = 0; i < chunks.length; i++) {
      if (at >= chunks[i].start && at < chunks[i].end) return i;
    }
    for (var i = chunks.length - 1; i >= 0; i--) {
      if (chunks[i].end <= at) return i;
    }
    return 0;
  }

  /// 命中位置前后各 [snippetRadius] 字的摘要。
  ///
  /// 换行压成空格：摘要在列表里只占一行，正文里的换行会让它高度跳来跳去。
  /// 两端被截断时加省略号，让用户知道"还有内容没显示"。
  static String snippetOf(String content, int at, int length) {
    final from = (at - snippetRadius).clamp(0, content.length);
    final to = (at + length + snippetRadius).clamp(0, content.length);
    final body = content.substring(from, to).replaceAll(RegExp(r'\s+'), ' ').trim();
    final head = from > 0 ? '…' : '';
    final tail = to < content.length ? '…' : '';
    return '$head$body$tail';
  }
}
