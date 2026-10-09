import 'dart:convert';

import '../../../core/db/models.dart';

/// 提示词与 JSON 结构约定。
///
/// 两条硬性约束（来自 DeepSeek 官方文档）：
/// 1. 使用 JSON Output 时，system 或 user prompt **必须含有 "json" 字样**
///    并给出期望的输出样例，否则模型不保证输出合法 JSON。
/// 2. system prompt 保持稳定、且把「不变的指令」放在最前面，
///    这样能最大化上下文硬盘缓存的命中率（命中后输入成本降到约 1/50）。
///    因此**绝不要把时间戳、随机 ID、笔记 ID 放进 system prompt 开头**。
class AiPrompts {
  AiPrompts._();

  static const summarizeSystem = '''
你是一名中文笔记整理助手。用户会给你一段笔记原文，你需要输出结构化的整理结果。

要求：
1. 使用简体中文输出。
2. 只依据笔记原文，不要编造原文中不存在的事实。
3. 如果原文过短或信息不足，就如实给出简短结果，不要强行凑内容。
4. 输出必须是合法的 json 对象，不要包含 markdown 代码块标记，不要有任何解释性文字。

json 输出格式（严格遵守字段名与类型）：
{
  "one_line": "一句话概括这篇笔记的核心内容，40 字以内",
  "bullets": ["要点1", "要点2", "要点3"],
  "tags": ["标签1", "标签2"],
  "action_items": ["需要跟进的具体行动，没有则为空数组"]
}

字段说明：
- bullets：3 到 7 条，每条是一个完整短句，涵盖原文的关键结论或方法。
- tags：2 到 5 个，每个 2 到 6 个字的名词性短语，用于分类检索；不要用标点。
- action_items：仅提取原文中明确提到的待办、下一步或需要验证的事项。
''';

  static const cardsSystem = '''
你是一名记忆卡片（Anki 风格）设计专家。用户会给你一段笔记原文，你需要把它拆解为高质量的问答卡片。

出卡原则：
1. 使用简体中文。
2. **一张卡片只考一个知识点**。不要把多个概念塞进同一张卡。
3. 问题必须具体、可独立回答，不能依赖其他卡片的上下文。
4. 答案要简短精确，理想长度 50 字以内；答案中可以保留代码或公式。
5. 优先考察「理解与应用」，其次才是「记忆定义」。
6. 不要出答案就是问题里已有信息的垃圾卡片。
7. 只依据笔记原文，不要补充原文没有的外部知识。
8. 如果原文信息太少不足以出卡，就返回空数组，不要硬凑。
9. 输出必须是合法的 json 对象，不要包含 markdown 代码块标记，不要有任何解释性文字。

json 输出格式（严格遵守字段名与类型）：
{
  "cards": [
    {"question": "问题", "answer": "答案", "tags": ["标签"]}
  ]
}

其中 tags 为 0 到 3 个短标签。
''';

  static const askSystem = '''
你是一个基于用户个人笔记的问答助手。用户会提供若干条笔记片段作为上下文，然后提出一个问题。

要求：
1. 使用简体中文回答。
2. **只依据提供的笔记内容回答**。如果笔记中没有足够信息，就明确说明「你的笔记里没有提到这一点」，绝对不要编造。
3. 回答时用 [1] [2] 这样的编号标注引用来源，编号对应笔记片段的序号。
4. 回答尽量简洁，必要时用列表。
''';

  // ---------------------------------------------------------------------------
  // AI 页（轻笔记助手）
  // ---------------------------------------------------------------------------

  /// AI 页的系统提示词。
  ///
  /// [workspace] 为当前工作区名称，可以是 null（未选择工作区）。
  /// 注意：这里刻意**不把时间戳或会话 id 拼进 prompt**，
  /// 以保证 system 前缀稳定、最大化上下文缓存命中率（命中后输入成本约 1/50）。
  static String agentSystem(String? workspace) {
    final ws = workspace == null || workspace.isEmpty
        ? '（用户尚未选择工作区）'
        : '《$workspace》';
    return '''
你是「LightNote」App 内置的笔记助手。工作区：$ws

能力范围：
- 回答与用户笔记内容相关的问题
- 帮用户把零散内容整理成结构化笔记
- 帮用户提炼要点、起标题、拟标签

硬性要求：
1. 使用简体中文，语气简洁务实，不说客套话。
2. 回答**只依据用户提供的笔记内容**。若上下文里没有相关信息，直接说明「你提供的笔记里没有这一点」，绝不编造。
3. 你**没有直接修改数据库的权限**。如果用户要你新增、修改或删除笔记，请输出一份变更建议（用 Markdown 列出「要做什么」），并明确告诉用户需要他确认后手动执行或点确认按钮。绝不要声称你已经改好了。
4. 引用笔记内容时标注来源，格式如 [1]。
5. 需要结构化输出时用 Markdown 列表，不要输出 JSON。
''';
  }

  /// AI 页的用户提示词：当前指令 + 显式选中的笔记上下文。
  ///
  /// [contexts] 为空时**不拼接任何笔记正文**——这是隐私设计的一部分：
  /// 未选择文件就只发指令本身。
  static String agentUser(String instruction, List<String> contexts) {
    if (contexts.isEmpty) {
      return '$instruction\n\n（本次未选择任何笔记文件，请仅就指令本身回答。）';
    }
    final sb = StringBuffer();
    sb.writeln('以下是用户显式选择的笔记（共 ${contexts.length} 条）：');
    sb.writeln();
    for (var i = 0; i < contexts.length; i++) {
      sb.writeln('[${i + 1}] ${contexts[i]}');
      sb.writeln();
    }
    sb.writeln('---');
    sb.writeln();
    sb.writeln('用户指令：$instruction');
    return sb.toString();
  }

  static const organizeSystem = '''你是一名知识结构整理专家。用户会给你一段笔记原文，你需要重新组织它的结构，使其更清晰易读。

要求：
1. 使用简体中文。
2. **不得改变原文的事实与含义**，只调整结构、去除冗余、补充小标题。
3. 保留 Markdown 格式（标题、列表、代码块）。
4. 直接输出整理后的 Markdown 正文，不要输出任何解释、前言或结语。
5. 不要用 ``` 包裹整篇内容。
''';

  // ---------------------------------------------------------------------------
  // 用户提示词构造
  // ---------------------------------------------------------------------------

  /// 单次请求的正文上限（字符）。超过则先截断并提示用户分段，
  /// 避免请求体过大导致超时或费用失控。
  static const maxBodyChars = 200000;

  static String summarizeUser(String title, String content) {
    final body = _clip(content);
    return '笔记标题：${title.isEmpty ? '（无标题）' : title}\n\n'
        '笔记原文：\n"""\n$body\n"""';
  }

  static String cardsUser(String title, String content, {int maxCards = 15}) {
    final body = _clip(content);
    return '笔记标题：${title.isEmpty ? '（无标题）' : title}\n\n'
        '笔记原文：\n"""\n$body\n"""\n\n'
        '请最多生成 $maxCards 张卡片。';
  }

  static String organizeUser(String title, String content) {
    final body = _clip(content);
    return '笔记标题：${title.isEmpty ? '（无标题）' : title}\n\n'
        '笔记原文：\n"""\n$body\n"""';
  }

  static String askUser(String question, List<String> contexts) {
    final sb = StringBuffer();
    for (var i = 0; i < contexts.length; i++) {
      sb.writeln('[${i + 1}] ${contexts[i]}');
      sb.writeln();
    }
    sb.writeln('问题：$question');
    return sb.toString();
  }

  static String _clip(String content) {
    if (content.length <= maxBodyChars) return content;
    return '${content.substring(0, maxBodyChars)}\n\n'
        '（注：原文过长，以上为前 $maxBodyChars 字，已被截断）';
  }

  // ---------------------------------------------------------------------------
  // 解析
  // ---------------------------------------------------------------------------

  /// 从模型返回里抽取 JSON 对象。
  ///
  /// 三级降级，因为 JSON Output 存在偶发不规范的情况：
  ///   1. 直接 jsonDecode
  ///   2. 剥掉 ```json 代码块围栏后重试
  ///   3. 用括号配对截取第一个完整对象
  static Map<String, dynamic>? extractJson(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;

    // 1. 直接解析
    final direct = _tryDecode(text);
    if (direct != null) return direct;

    // 2. 去代码块围栏
    final fenced = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(text);
    if (fenced != null) {
      final inner = _tryDecode(fenced.group(1)!.trim());
      if (inner != null) return inner;
    }

    // 3. 括号配对截取
    final start = text.indexOf('{');
    if (start == -1) return null;
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < text.length; i++) {
      final ch = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch.codeUnitAt(0) == 0x5C) {
          // 反斜杠：用码点比较，而不是构造一个「单引号 raw 字符串 + 反斜杠」的字面量。
          // 后者在 Dart 里是语法错误（raw 字符串不能以反斜杠结尾）。
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
      } else if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) {
          return _tryDecode(text.substring(start, i + 1));
        }
      }
    }
    return null;
  }

  static Map<String, dynamic>? _tryDecode(String s) {
    try {
      final decoded = jsonDecode(s);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 把模型返回解析为整理结果。解析失败返回 null，由上层决定重试。
  static NoteAiResult? parseSummary(String raw) {
    final json = extractJson(raw);
    if (json == null) return null;
    return NoteAiResult.fromJson(json, raw: raw);
  }

  /// 把模型返回解析为卡片草稿。无效草稿在 CardDraft.isValid 处被过滤。
  static List<CardDraft>? parseCards(String raw) {
    final json = extractJson(raw);
    if (json == null) return null;

    final list = json['cards'];
    if (list is! List) return null;

    final drafts = <CardDraft>[];
    for (final item in list) {
      if (item is! Map) continue;
      final draft = CardDraft.fromJson(Map<String, dynamic>.from(item));
      if (draft.isValid) drafts.add(draft);
    }
    return drafts;
  }
}
