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

  /// 生成列表页预览文本
  static String excerpt(String content, {int max = 200}) {
    final plain = toPlainText(content).replaceAll('\n', ' ');
    if (plain.length <= max) return plain;
    return '${plain.substring(0, max)}…';
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

/// 复习间隔的人类可读形式
String formatInterval(int days) {
  if (days <= 0) return '现在';
  if (days == 1) return '1 天后';
  if (days < 30) return '$days 天后';
  if (days < 365) return '${(days / 30).round()} 个月后';
  return '${(days / 365).toStringAsFixed(1)} 年后';
}
