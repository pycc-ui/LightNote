/// 纯文本抽取 + 统计工具。
/// 列表页预览与阅读时长估算都依赖这里，保持纯函数便于单测。
class TextUtils {
  TextUtils._();

  static final _mdNoise = RegExp(
    r'```[\s\S]*?```'      // 代码块
    r'|!\[[^\]]*\]\([^)]*\)' // 图片
    r'|\[([^\]]*)\]\([^)]*\)' // 链接保留文字
    r'|^\s{0,3}#{1,6}\s*'   // 标题标记
    r'|[*_~`>|-]+',         // 强调/引用/列表符号
    multiLine: true,
  );

  static final _linkPattern = RegExp(r'\[([^\]]*)\]\([^)]*\)');

  /// 把 Markdown 粗加工成纯文本，用于 excerpt 与字数统计。
  ///
  /// 用 `replaceAllMapped` 而不是 `replaceAll`：后者只接受字符串替换值，
  /// 传回调会报 argument_type_not_assignable（这是最初的编译错误之一）。
  static String toPlainText(String markdown) {
    final s = markdown.replaceAllMapped(_mdNoise, (m) {
      // 链接只保留显示文字
      final link = _linkPattern.firstMatch(m.group(0)!);
      if (link != null) return link.group(1) ?? '';
      return '';
    });
    return s.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  /// 中文按字计，英文按词计 —— 直接按空格切会把整段中文算成 1 个词。
  static int wordCount(String text) {
    final cjk = RegExp(r'[\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]')
        .allMatches(text)
        .length;
    final latin = RegExp(r'[A-Za-z0-9]+')
        .allMatches(text.replaceAll(
          RegExp(r'[\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]'),
          ' ',
        ))
        .length;
    return cjk + latin;
  }

  /// **Markdown 正文的字数**（先剥 Markdown 再数）。
  ///
  /// ## 为什么必须只有这一个入口
  ///
  /// `notes.wordCount` 有三个写入方（编辑页保存、AI 的 `createNote` / `updateNote`）。
  /// 早先编辑页走的是"剥 Markdown 后中文按字 + 英文按词"，而 AI 那条路写的是
  /// `content.length`（UTF-16 码元数，连代码块里的符号都算）—— 同一篇笔记，
  /// 手写和 AI 写出来的字数口径不一样，列表里显示的数字就没法比。
  ///
  /// 所以字数这件事收敛到这一个函数：**先 [toPlainText]，再 [wordCount]**。
  static int wordCountOfMarkdown(String markdown) =>
      wordCount(toPlainText(markdown));

  /// 生成列表页预览文本
  static String excerpt(String content, {int max = 200}) {
    final plain = toPlainText(content).replaceAll('\n', ' ');
    if (plain.length <= max) return plain;
    return '${plain.substring(0, max)}…';
  }

  /// 组装「复制全文」的内容：标题（若有）+ 正文，便于粘到别处。
  ///
  /// **只收字符串、不收 `Note`**：这里是纯文本工具，不该反向依赖数据库模型。
  ///
  /// > 早先它在 `core/export/markdown_export_service.dart` 里（那个文件同时
  /// > 管 Markdown 导出）。导出功能删除后只剩这一个函数有用，就搬到这里。
  static String noteCopyText({
    required String title,
    required String content,
  }) {
    final t = title.trim();
    if (t.isEmpty) return content;
    return '$t\n\n$content';
  }

  /// 中文阅读速度约 300 字/分钟（保守取值，便于估算阅读时长）
  static Duration estimatedReadingTime(int words) {
    final minutes = (words / 300).ceil();
    return Duration(minutes: minutes < 1 ? 1 : minutes);
  }

  static String formatDuration(Duration d) {
    if (d.inMinutes < 1) return '不到 1 分钟';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    return m == 0 ? '$h 小时' : '$h 小时 $m 分钟';
  }
}

/// 搜索结果里高亮关键词时用的文本切片工具。
///
/// 它和 [TextUtils] 一样是纯文本处理，所以放在这里；早先它和 Markdown 导出
/// 挤在同一个文件里（`core/export/markdown_export_service.dart`），
/// 导出功能删除后搬了过来。
class HighlightUtils {
  HighlightUtils._();

  /// 把文本按关键词切成若干片段，供 RichText 拼装高亮。
  /// 返回 (片段, 是否命中) 的列表。大小写不敏感。
  static List<(String, bool)> split(String text, String keyword) {
    if (keyword.trim().isEmpty) return [(text, false)];
    final lowerText = text.toLowerCase();
    final lowerKey = keyword.trim().toLowerCase();

    final out = <(String, bool)>[];
    var start = 0;
    while (true) {
      final idx = lowerText.indexOf(lowerKey, start);
      if (idx < 0) break;
      if (idx > start) out.add((text.substring(start, idx), false));
      out.add((text.substring(idx, idx + lowerKey.length), true));
      start = idx + lowerKey.length;
    }
    if (start < text.length) out.add((text.substring(start), false));
    return out.isEmpty ? [(text, false)] : out;
  }

  /// 从正文里截一段包含关键词的上下文，用于结果列表展示
  static String snippet(String content, String keyword, {int radius = 40}) {
    final plain = TextUtils.toPlainText(content).replaceAll('\n', ' ');
    if (keyword.trim().isEmpty) {
      return plain.length > radius * 2
          ? '${plain.substring(0, radius * 2)}…'
          : plain;
    }
    final idx = plain.toLowerCase().indexOf(keyword.trim().toLowerCase());
    if (idx < 0) {
      return plain.length > radius * 2
          ? '${plain.substring(0, radius * 2)}…'
          : plain;
    }
    final from = (idx - radius).clamp(0, plain.length);
    final to = (idx + keyword.length + radius).clamp(0, plain.length);
    final prefix = from > 0 ? '…' : '';
    final suffix = to < plain.length ? '…' : '';
    return '$prefix${plain.substring(from, to)}$suffix';
  }
}

/// 相对时间显示（刚刚 / 5 分钟前 / 昨天 / 3 月 12 日）
String formatRelativeTime(DateTime utc, {DateTime? now}) {
  final local = utc.toLocal();
  final ref = now ?? DateTime.now();
  final diff = ref.difference(local);

  if (diff.inSeconds < 60) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24 && local.day == ref.day) return '${diff.inHours} 小时前';

  final yesterday = ref.subtract(const Duration(days: 1));
  if (local.year == yesterday.year &&
      local.month == yesterday.month &&
      local.day == yesterday.day) {
    return '昨天';
  }

  if (local.year == ref.year) return '${local.month} 月 ${local.day} 日';
  return '${local.year} 年 ${local.month} 月 ${local.day} 日';
}

