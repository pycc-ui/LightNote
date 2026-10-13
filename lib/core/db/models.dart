import 'dart:convert';

export 'app_database.dart' show Note, AiCall;

/// 解析存库的 JSON 数组字符串（如某条笔记的标签数组）。
///
/// 集中在这里，避免每个页面各写一份 `jsonDecode` 并各自处理异常。
List<String> parseJsonStringList(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
    }
  } catch (_) {
    // 落库时若被截断可能不是合法 JSON，降级为按分隔符切分
  }
  // 降级路径要顺手剥掉残留的 JSON 语法字符（方括号与引号），
  // 否则会得到 '["正常项"' 这种带引号的结果。
  return raw
      .replaceAll(RegExp(r'[\[\]"]'), '')
      .split(RegExp(r'[,，\n]'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList(growable: false);
}

/// AI 流式事件：UI 拿到的是一个事件流，而不是一次性字符串。
sealed class AiEvent {
  const AiEvent();
}

/// 正文增量（用于打字机效果）
class AiChunk extends AiEvent {
  const AiChunk(this.text);
  final String text;
}

/// 思维链增量（思考模式下才出现，UI 上可折叠展示）
class AiReasoning extends AiEvent {
  const AiReasoning(this.text);
  final String text;
}

/// 一次调用结束，携带用量与成本
class AiDone extends AiEvent {
  const AiDone({
    this.fullText = '',
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.costCents = 0,
    this.latencyMs = 0,
    this.toolCalls = const [],
  });

  final String fullText;
  final int promptTokens;
  final int completionTokens;
  final double costCents;
  final int latencyMs;

  /// 模型在这一轮提出的**工具调用**（可能为空 = 普通回答）。
  ///
  /// 非空时：调用方要执行这些工具，把结果以 `role: 'tool'` 回灌，
  /// 然后**再发一轮**——直到它不再提工具为止。见 `AiAgentLoop`。
  final List<ToolCall> toolCalls;

  /// 这一轮是不是"只提了工具、没说话"
  bool get isToolOnly => fullText.trim().isEmpty && toolCalls.isNotEmpty;
}

/// 模型提出的**一次工具调用**（OpenAI / DeepSeek 的 `tool_calls` 元素）。
///
/// 放在这里而不是 `features/ai/`：它是 [AiDone] 的载荷，
/// 而 `core/` 不能反向依赖 `features/`。
class ToolCall {
  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  /// 调用 id。回灌 `role: 'tool'` 的结果时必须带上它，否则协议不认。
  final String id;

  /// 工具名。
  final String name;

  /// 参数的 **JSON 字符串**（不是解析好的 Map）。
  ///
  /// 保持字符串有两个原因：
  ///   · 流式下 `arguments` 是**分片**返回的，本来就要拼成串；
  ///   · 回灌 assistant 消息时要原样送回，解析再序列化反而可能变形状。
  final String arguments;

  /// 解析成 Map。**解析失败返回 null**（模型偶尔会给出坏 JSON）——
  /// 调用方据此回一条"参数不是合法 JSON"的工具结果，让模型自己修正。
  Map<String, dynamic>? get argsMap {
    if (arguments.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(arguments);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// 回灌给 API 的形状（echo 回 assistant 消息时用）。
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'function',
        'function': {'name': name, 'arguments': arguments},
      };

  @override
  String toString() => 'ToolCall($name, $arguments)';
}

class AiError extends AiEvent {
  const AiError(this.message, {this.code, this.isRetryable = false});
  final String message;
  final String? code;
  final bool isRetryable;
}

/// 生成一张卡片所需的素材：**一小段截断的原文**。
///
/// [chunk] 是从某篇笔记里截取的一小段原文（片内的 400 字窗口）——里面有具体数字、
/// 具体说法、具体例子，卡片才可能具体；而且它**不失真**：正文是什么，取出来就是什么。
/// （没有摘要：素材就是这一段原文。）
///
/// ## 素材是"片内的 400 字窗口"
///
/// 一份素材 = 某一篇笔记的**某一片**里开出的 400 字窗口（片本身 ≤400 就是整片）。
/// 片是搜索与卡片流用的语义单元（≤700），卡片流按 400 字消费——这样卡片流的
/// 提示词、成本估算、抽取逻辑都不用改。见 `FeedWindow`。
///
/// 同一片会被用到多次，每次窗口起点不同（**轮换**），所以"哪一片"这件事
/// 必须显式记下来（[chunkKey]），不能靠正文去认。
class FeedMaterial {
  const FeedMaterial({
    required this.title,
    required this.chunk,
    this.chunkKey = '',
  });

  final String title;

  /// 从笔记里截取的一小段原文（片内的 400 字窗口）。提示词里会说明它是截取的
  /// 片段、并禁止卡片提到这一点。
  final String chunk;

  /// 这份素材来自哪一片，`noteId:idx` 形式。
  ///
  /// **不进提示词**，只用于去重与测试断言：素材文字是窗口，同一片每次取出的
  /// 文字都不同，所以"是不是同一片"只能看这个键。
  final String chunkKey;
}

/// 一条 AI 生成的「轻笔记」——卡片流里的内容。
///
/// **它不是一个已有笔记的视图**，而是从素材里长出来的新内容。
///
/// 卡片上**只显示标题**（至多 3 行），点进去看 [body] 全文。
/// 卡片上不放"摘要/预览"：那会是"摘要是正文的前面部分"这种
/// 别扭关系；让 AI 单独生成一段摘要，又变成要维护两个内容字段。所以简化成：
/// **卡片就是标题，正文只在详情里出现。**
///
/// 所以 [title] 要写得**有信息量、能勾起好奇**——它一个人承担了
/// "让人想点进去"的全部责任，不能只是"间隔重复"这种干标签。
class FeedDraft {
  const FeedDraft({
    required this.title,
    required this.body,
    required this.tag,
  });

  /// 卡片上显示的标题（至多 3 行）。
  /// 应当是有钩子的一句话，而不是干巴巴的名词。
  final String title;

  /// 完整正文（Markdown）。卡片点进去看的就是它，也是收下后写进笔记的内容。
  final String body;

  /// **一个**短标签（卡片左下角显示的就是它）。没有就用空串，[displayTag] 会转成 null。
  ///
  /// 由生成卡片的**同一次调用**产出，而不是另外再调一次 AI——
  /// 素材已经发出去了，顺带要一个标签几乎不增加成本。
  ///
  /// 注意命名落差：这里叫 `tag`（单数），但库里的列仍叫 `feed_reserve.tags`
  /// 且存的是**单元素 JSON 数组**（见 `AppDatabase.replaceFeedReserve` 与
  /// `_decodeTag`）。那是历史遗留的列名，**不代表一次能生成多个**。
  final String tag;

  /// 标题与正文都空就丢弃——空卡片对用户毫无意义。
  bool get isValid => title.isNotEmpty && body.isNotEmpty;

  /// 卡片上展示用的标签（没有则返回 null）。
  String? get displayTag => tag.isEmpty ? null : tag;

  Map<String, dynamic> toJson() => {
        'title': title,
        'body': body,
        'tag': tag,
      };

  static FeedDraft fromJson(Map<String, dynamic> json) {
    return FeedDraft(
      title: (json['title'] ?? '').toString().trim(),
      body: (json['body'] ?? '').toString().trim(),
      tag: (json['tag'] ?? '').toString().trim(),
    );
  }

  @override
  String toString() => 'FeedDraft($title)';
}
