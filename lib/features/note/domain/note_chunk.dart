/// 一片切片：只是"原文的哪一段"的描述，不存正文副本。
///
/// 不存正文的原因：存正文等于把全部笔记文本再存一份（库里的文本量翻倍）。
/// 只存偏移的话，读片 = 用 `[start, end)` 从 `notes.content` 切出来，
/// 永远和正文一致，不存在"片正文过期"这种状态。
///
/// 代价：正文改了偏移就错了。但那错的是位置、不是内容，而且可以被检出
/// （比 `contentHash`），不符就当场重切一次（见 `NoteChunkRepository`）。
///
/// 字段：
///
/// | 字段 | 用途 |
/// |---|---|
/// | [index] | 顺序号。AI 的 `readChunk(noteId, index)` 与搜索结果的"定位到这片"都用它 |
/// | [heading] | 标题路径（`工作 / 项目A / 风险`），给 AI 当上下文、给搜索页当副标题 |
/// | [level] | 这一片来自几级标题（0 = 无标题） |
/// | [start] / [end] | 左闭右开，偏移基于原始 `content`（不归一化） |
/// | [charCount] | `end - start`，即 `content.substring(start, end).length` |
/// | [contentHash] | 自愈用：读片时比对，不符说明正文变了、偏移失效 |
/// | [lastUsedAt] | 卡片流上次把这一片做成素材的时间（null = 从没用过） |
/// | [nextWindowStart] | 卡片流下次开窗口的起点（相对本片起点），见 `FeedWindow` |
///
/// 后两个字段是卡片流的状态，不属于"片是什么"。放在这里是因为它们就存在
/// `note_chunks` 表的同一条记录上（同一行、同一生命周期），单独拆一个类型的话
/// 每次取片都要按 `(noteId, idx)` 去别处查状态。
class NoteChunk {
  const NoteChunk({
    required this.index,
    required this.heading,
    required this.level,
    required this.start,
    required this.end,
    required this.contentHash,
    this.lastUsedAt,
    this.nextWindowStart = 0,
  });

  final int index;
  final String heading;
  final int level;
  final int start;
  final int end;
  final int contentHash;

  /// 卡片流上次用掉这一片的时间。null = 从没用过（排序时排最前）。
  final DateTime? lastUsedAt;

  /// 卡片流下次开窗口的起点（相对 [start] 的偏移）。0 = 从头开始。
  final int nextWindowStart;

  int get charCount => end - start;

  /// 在 `note_chunks` 里的唯一标识（一片 = 一篇笔记 + 一个片号）。
  ///
  /// 卡片流记"用过哪些片"用的是它，而不是片正文的 hash ——
  /// 正文改成 400 字窗口之后，同一片每次取出的文字都不一样，按 text hash
  /// 去重等于完全失效。
  String keyOf(String noteId) => '$noteId:$index';

  NoteChunk withFeedState({DateTime? lastUsedAt, int? nextWindowStart}) =>
      NoteChunk(
        index: index,
        heading: heading,
        level: level,
        start: start,
        end: end,
        contentHash: contentHash,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
        nextWindowStart: nextWindowStart ?? this.nextWindowStart,
      );

  /// 从**原文**里取出这一片的正文。
  ///
  /// 越界时返回空串而不是抛错：偏移失效的那一刻不该让整个页面崩掉，
  /// 上层会发现"读出来是空的"从而触发自愈重切。
  String textOf(String content) {
    if (start < 0 || end > content.length || start >= end) return '';
    return content.substring(start, end);
  }

  /// 这一片的正文 hash（必须与 [contentHash] 同算法）。
  ///
  /// 用 Dart 的 `String.hashCode` 而不是加密 hash：这里只需要"变了没有"，
  /// 不需要抗碰撞，而 `hashCode` 零成本。
  static int hashOf(String content, int start, int end) {
    if (start < 0 || end > content.length || start >= end) return 0;
    return content.substring(start, end).hashCode;
  }

  @override
  String toString() =>
      'NoteChunk(#$index, $start..$end, $charCount 字, "$heading")';
}
