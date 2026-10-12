/// 一条搜索结果。
///
/// 两类结果共用一个类型：搜索页要把结果分两类展示（「笔记」/「笔记内容」），
/// 而 AI 工具只要一份排好序的列表。做成两个类型的话，两边都要写一遍排序与截断。
/// 用一个类型 + [chunkIndex] 是否为空来区分，分类是读取方的事：
///
///   · `chunkIndex == null` → 标题命中，整篇相关（点进去看整篇）
///   · `chunkIndex != null` → 正文某一片命中（点进去定位到那一片）
class SearchResult {
  const SearchResult({
    required this.noteId,
    required this.title,
    required this.chunkIndex,
    required this.heading,
    required this.snippet,
    required this.score,
  });

  final String noteId;
  final String title;

  /// 命中的片号；null = 标题命中（不是"第 0 片"）。
  final int? chunkIndex;

  /// 副标题，如「项目A / 风险」。标题命中时为空串。
  final String heading;

  /// 命中位置前后各若干字的摘要（换行压成空格）。
  final String snippet;

  /// 越大越靠前：标题命中 3，片命中 2，同一片里命中多次继续累加。
  final double score;

  bool get isTitleHit => chunkIndex == null;

  @override
  String toString() => 'SearchResult($title, chunk=$chunkIndex, '
      'head="$heading", score=$score)';
}
