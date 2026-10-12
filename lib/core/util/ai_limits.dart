/// 按 [AppParams] 里的长度参数做**截断 / 规整**的文本工具。
///
/// ⚠️ **数值不在这里，在 `app_params.dart`**。这个文件只留"怎么截"的算法，
/// 参数统一从 [AppParams]（及其子域 `AiLimits` / `ChunkLimits` …）读。
/// 这样"prompt 里写 300、代码里截 500"这类不一致不可能再发生。
///
/// 本文件同时 `export 'app_params.dart'`，让老代码里 `import 'ai_limits.dart'`
/// 后直接用 `AiLimits.xxx` 仍然成立，避免一次性改一圈 import。
library;

import 'app_params.dart';

export 'app_params.dart';

/// 一个字符占几字节（用于按字节预算反推字符数）。
int _bytesOfRune(int rune) {
  if (rune <= 0x7F) return 1;
  if (rune <= 0x7FF) return 2;
  if (rune <= 0xFFFF) return 3;
  return 4;
}

/// 安全截断到 [maxChars] 个字符。
///
/// "安全"指：
///   1. 不切断代理对（emoji 这类字符由两个 UTF-16 码元组成，
///      直接 `substring` 会切出半个字符，渲染成乱码/方框）
///   2. 尽量不在 Markdown 语法中间切断——若截断点前面还有未闭合的
///      `**` 或反引号，就把它们补上，避免整段样式失效
///
/// 超出时在末尾加省略号。
String safeTruncate(String text, int maxChars) {
  if (maxChars <= 0) return '';
  if (text.length <= maxChars) return text;

  // 1) 先按字符数切，并把切点挪到不成半个代理对的位置
  var end = maxChars;
  if (end < text.length &&
      _isHighSurrogate(text.codeUnitAt(end - 1)) &&
      _isLowSurrogate(text.codeUnitAt(end))) {
    end -= 1;
  }
  var cut = text.substring(0, end);

  // 2) 补上被切开的 Markdown 行内标记，避免样式整段失效
  cut = _closeInlineMarkdown(cut);

  return '$cut…';
}

bool _isHighSurrogate(int c) => c >= 0xD800 && c <= 0xDBFF;
bool _isLowSurrogate(int c) => c >= 0xDC00 && c <= 0xDFFF;

/// 若截断点留下了未闭合的 `**` / `*` / `` ` ``，就地补全。
///
/// 只处理行内标记，不碰代码块（那需要成对处理整块，代价大于收益）。
String _closeInlineMarkdown(String text) {
  var out = text;

  // 反引号：奇数个则补一个
  if (_countUnescaped(out, '`').isOdd) out = '$out`';

  // 粗体：`**` 计数为奇数则补一对的一半
  final boldCount = _countUnescaped(out, '**');
  if (boldCount.isOdd) out = '$out**';

  return out;
}

/// 统计 [pattern] 在 [text] 中出现的次数（粗略，不处理转义与嵌套）。
int _countUnescaped(String text, String pattern) {
  var count = 0;
  var index = 0;
  while (true) {
    final i = text.indexOf(pattern, index);
    if (i < 0) break;
    count++;
    index = i + pattern.length;
  }
  return count;
}

/// 把标签规整成"一个短词"。
///
/// 规则：不超过 [AiLimits.tagMaxCjk] 个汉字 / [AiLimits.tagMaxLatin] 个英文字母。
/// 超出按字符安全截断；同时去掉首尾的 `#`、空格、标点。
String normalizeTag(String raw) {
  var t = raw.trim();
  // 去掉常见的包装字符。
  const wrappers = r'[#`"“”「」『』【】\[\]\s]+';
  t = t.replaceAll(RegExp('^$wrappers'), '');
  t = t.replaceAll(RegExp('$wrappers\$'), '');
  if (t.isEmpty) return '';

  // 按"汉字 5 个 / 拉丁 12 个"估算允许的字符数：
  // 逐字符累加，汉字算 1 个配额、拉丁字母算 5/12 个配额。
  var cjk = 0;
  var latin = 0;
  final buf = StringBuffer();
  for (final ch in t.characters) {
    final code = ch.runes.first;
    final isCjk = code >= 0x4E00 && code <= 0x9FFF;
    if (isCjk) {
      if (cjk >= AiLimits.tagMaxCjk) break;
      cjk++;
    } else {
      if (latin >= AiLimits.tagMaxLatin) break;
      latin++;
    }
    buf.write(ch);
  }
  return buf.toString();
}

/// 把 AI 给的标签规整成可入库的**单个**标签（卡片只生成一个标签）。
String sanitizeTag(String raw) => normalizeTag(raw);

/// `String.characters` 的最小实现。
///
/// 只处理 BMP + 代理对，对标签这种短文本足够。
///
/// 不直接 import `characters` 包，是因为它只是 flutter 带进来的传递依赖：
/// 直接 import 传递依赖，上游一改版本就编译不过，要用就得在 `pubspec.yaml`
/// 里显式声明。为一个 15 行的扩展多一条直接依赖不划算，所以留着手写版本。
extension _Runes on String {
  Iterable<String> get characters {
    final out = <String>[];
    for (var i = 0; i < length; i++) {
      final c = codeUnitAt(i);
      if (_isHighSurrogate(c) && i + 1 < length) {
        out.add(substring(i, i + 2));
        i++;
      } else {
        out.add(substring(i, i + 1));
      }
    }
    return out;
  }
}

/// 按字节预算反推可以保留多少字符。
///
/// 用于笔记硬上限：我们要按**字节**限制，但截断要按**字符**做。
int charsForBytes(String text, int maxBytes) {
  var bytes = 0;
  var i = 0;
  for (final rune in text.runes) {
    final b = _bytesOfRune(rune);
    if (bytes + b > maxBytes) break;
    bytes += b;
    i++;
  }
  return i;
}

/// 笔记篇幅的档位。
///
/// 放在这里而不是编辑页内部，是为了**能被测试直接覆盖**——
/// 分档逻辑只有几行，但边界（正好 80KB 算哪一档）最容易出错，
/// 藏在私有 UI 代码里就只能靠手点验证。
enum NoteSizeLevel {
  /// 正常
  ok,

  /// 到软上限：轻提示
  soft,

  /// 到强警告线：醒目提示，仍允许保存
  warn,

  /// 到硬上限：拒绝保存
  hard,
}

/// 按 UTF-8 字节数给笔记分档。
///
/// 边界是**闭区间下界**（`>=` 即进入该档）：正好 80KB 就算"较长"，
/// 正好 100KB 就拒绝保存。这样阈值与文案里的数字一致，
/// 不会出现"显示 100.0 KB 却还能保存"的矛盾。
NoteSizeLevel noteSizeLevel(String text) {
  final b = AiLimits.byteLength(text);
  if (b >= AiLimits.noteHardBytes) return NoteSizeLevel.hard;
  if (b >= AiLimits.noteWarnBytes) return NoteSizeLevel.warn;
  if (b >= AiLimits.noteSoftBytes) return NoteSizeLevel.soft;
  return NoteSizeLevel.ok;
}
