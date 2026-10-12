/// AI 相关内容的**硬性上限**。
///
/// ## 核心原则
///
/// **对 AI 消费的内容要狠，对用户生产的内容要软。**
///
/// - 摘要 / 标签：**硬上限**，强制截断。因为它们是喂给 AI 的素材，
///   长度直接决定 token 成本；而且用户看不到，截断不会伤害体验。
/// - 笔记：**软上限 + 硬保护**。那是用户亲手写的东西，
///   截断等于毁掉他的内容——所以只警告，最后一道才拒绝保存。
///
/// 所有数值集中在这里，避免"prompt 里写 300、代码里截 500"这种不一致。
class AiLimits {
  AiLimits._();

  // ---- 摘要 ----

  /// 摘要目标长度（字）
  static const summaryTargetMin = 150;
  static const summaryTargetMax = 250;

  /// 摘要**硬上限**（字）。超过就截断。
  ///
  /// 提示词里也要求不超过这个数，但**不能只靠提示词**——
  /// 实测模型基本不守字数（要求 60 字会返回 160 字），
  /// 所以代码里必须兜底。
  static const summaryHardMax = 300;

  // ---- 标签 ----

  /// 单个标签的**汉字**上限
  static const tagMaxCjk = 5;

  /// 单个标签的**英文字母**上限
  static const tagMaxLatin = 12;

  // ---- 卡片（AI 生成的轻笔记）----

  /// 卡片**标题**上限（字）。提示词要求 ≤30，这里给一倍余量兜底。
  ///
  /// 与 [titleHardMax] 分开：卡片标题是"卡片上唯一显示的文字"，
  /// 30 字和 200 字在卡片上完全是两种东西，不能共用一个上限。
  static const feedCardTitleMax = 60;

  /// 卡片**正文**上限（字）。提示词要求 400–800，这里给两倍余量。
  ///
  /// 为什么必须有：正文会被收进笔记、也会进 prompt。模型偶尔会跑飞
  /// （实测有返回几千字的），`feed_reserve` 表不该被一张卡片塞满。
  static const feedCardBodyMax = 2000;

  // ---- 笔记正文（软上限 + 硬保护）----

  /// 软上限：超过就轻提示"注意编辑流畅度"
  static const noteSoftBytes = 80 * 1024;

  /// 强警告线：超过就建议拆分，但仍允许保存
  static const noteWarnBytes = 90 * 1024;

  /// 硬上限：超过就拒绝保存
  static const noteHardBytes = 100 * 1024;

  /// 单行短字段的上限（字）：笔记标题、笔记库名、会话标题、卡片标题……
  ///
  /// 超出**截断**（不是拒绝）：这类字段进 prompt、也上界面，一个几万字的
  /// "标题"能直接把一次请求撑爆，而用户真正想表达的早就写完了。
  /// 凡是"名字/标题"类字段都该走这一个常量，别各写各的数字。
  static const titleHardMax = 200;

  /// 按 UTF-8 字节数计算长度。
  ///
  /// 用字节而不是字符数：中文一个字 3 字节，用字符数算会**低估三倍**，
  /// 而数据库与 token 成本都跟字节数更相关。
  static int byteLength(String text) => utf8ByteLength(text);
}

/// UTF-8 字节长度。
///
/// 单独抽出来是为了能在不引入 dart:convert 的地方也能用，
/// 并让 `AiLimits.byteLength` 有一个明确的实现锚点。
int utf8ByteLength(String text) {
  var bytes = 0;
  for (final rune in text.runes) {
    if (rune <= 0x7F) {
      bytes += 1;
    } else if (rune <= 0x7FF) {
      bytes += 2;
    } else if (rune <= 0xFFFF) {
      bytes += 3;
    } else {
      bytes += 4;
    }
  }
  return bytes;
}

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
///
/// 注意：这是**字符数**截断。摘要另有一条字节数无关的 300 字上限，
/// 两条都走这里。
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
/// 规则（来自产品要求）：不超过 5 个汉字 / 12 个英文字母。
/// 超出按字符安全截断；同时去掉首尾的 `#`、空格、标点。
String normalizeTag(String raw) {
  var t = raw.trim();
  // 去掉常见的包装字符。
  //
  // 覆盖的种类比想象的广：模型会用 #话题、`代码`、引号、
  // 以及中日式括号「」『』把标签裹起来。少了任何一种，
  // 生成的标签都会带着壳进库，在卡片上显示成「「记忆」」那种。
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

/// 把 AI 给的标签规整成可入库的**单个**标签。
///
/// 规则（产品要求）：一个标签，不超过 5 汉字 / 12 英文字母。
/// 空串、纯空白、超长的都按 [normalizeTag] 的规则清理。
///
/// 卡片**只生成一个**标签，所以这里不再有"去重、截断到 N 个"那套逻辑
/// （早先的 `sanitizeTags(List)` 是给"生成 2~6 个"的旧设计用的，已删除）。
/// 它和 [normalizeTag] 一样是纯文本工具，所以放在这里，
/// 而不是让 `prompts.dart` 反向依赖一个 repository。
String sanitizeTag(String raw) => normalizeTag(raw);

/// `String.characters` 的最小实现。
///
/// 只处理 BMP + 代理对，对标签这种短文本足够。
///
/// ## 为什么不直接用 `characters` 包
///
/// 早先这里的注释写的是"避免为一个扩展引入 characters 包"，**那个理由是错的**：
/// `characters` 本来就在 `pubspec.lock` 里（flutter 带进来的**传递**依赖）。
/// 真正的理由是**别直接 import 传递依赖** —— 那样上游一改版本就编译不过，
/// 要 import 就得在 `pubspec.yaml` 里显式声明（本项目对
/// `path_provider_platform_interface` 就是这么做的）。
/// 为一个 15 行的扩展多一条直接依赖不划算，所以留着手写版本；
/// 但**理由要写对**，否则下一个人会以为"这个包不存在"。
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
