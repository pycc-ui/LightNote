import 'dart:convert';

import '../../../core/db/models.dart';
import '../../../core/util/ai_limits.dart';

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
        ? '**未选择**（你看不到任何笔记）'
        : '《$workspace》';
    return '''
你是「LightNote」App 内置的笔记助手。当前工作区：$ws

你可以调用工具。工作区就是你能看到的范围：
- **搜索/列笔记只在这个范围内生效**，范围之外的笔记你看不到。
- 如果用户要的东西不在范围里，**如实说明并建议他调整工作区**
  （AI 页顶部的「工作区」），不要反复用同一个关键词重试。
- 工作区是"未选择"时你一条笔记也看不到，先请用户选一个。

关于**修改**笔记：
- 你**可以**新增、修改、删除笔记，但每一步都会弹出确认层由用户点同意。
- 所以：直接调工具即可，**不要**只输出一份"变更建议"就停下。
- 也**不要**说"我已经改好了"——除非工具返回了成功结果。
  用户拒绝时工具会返回失败，照着结果如实告诉用户。
- 删除不可恢复，措辞要明确。

硬性要求：
1. 使用简体中文，语气简洁务实，不说客套话。
2. 回答**以笔记内容为依据**。要引用用户笔记时**先搜**，别凭常识替他"回忆"。
   搜不到就说搜不到，绝不编造。
3. 引用笔记内容时标注来源，格式如 [1]。
4. 需要结构化输出时用 Markdown 列表，不要输出 JSON。
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

  // ==========================================================================
  // 笔记的 AI 摘要（持久化，供卡片流当素材）
  // ==========================================================================

  /// 为一篇笔记生成**长期复用**的摘要。
  ///
  /// 它是**喂给 AI 的素材**，用户看不到。所以要求很具体——
  /// 不需要要点列表，就是一段紧凑的陈述句。
  ///
  /// > 别和早先那个「AI 整理要点」搞混：那个把结构化结果（摘要/要点/待办）
  /// > 展示给用户看并落库，用的是另一个 `summarizeSystem`，
  /// > **该功能已整体移除**。这个摘要是卡片流用的"面"。
  ///
  /// 为什么要有它：卡片流原先把**全文**发给 AI 生成卡片，
  /// token 消耗大、生成慢、单次能覆盖的素材数少。改成发摘要后，
  /// 同样的预算能覆盖多几倍的笔记。
  ///
  /// 提示词里有三件事必须写清楚，否则产出会跑偏：
  ///   1. **用途**：说"用于后续生成灵感卡片"，它才会保留可延展的点，
  ///      而不是写成流水账
  ///   2. **长度**：给区间 + 硬上限。但**实测模型不守字数**，
  ///      所以代码里还有兜底截断（见 AiLimits.summaryHardMax）
  ///   3. **格式**：明确"不要分点、不要小标题"。不然它会输出
  ///      Markdown 结构，原文变长且不好拼进 prompt
  static const noteSummarySystem = '''
你是一个笔记压缩器。用户给你一篇笔记，你要输出一段摘要。

这段摘要的用途是**后续生成灵感卡片**，所以：
- 保留核心观点与结论
- 特别保留那些**有启发性、反直觉、具体**的点（数字、反例、可操作的技巧）
- 不要泛泛而谈，不要写"本文介绍了……"这类空话

长度要求：**150~250 字**，**绝对不超过 300 字**。

格式要求：
- 只用简洁的陈述句，连成一段
- 摘要正文里**不要分点、不要小标题、不要 Markdown 标记**
- 只输出 JSON，不要任何解释：

{"summary":"摘要正文"}

如果笔记本身内容很少，就照实写短一点，不要为了凑字数而注水。
''';

  /// 解析摘要。
  ///
  /// 兼容两种返回：标准 JSON（`{"summary":"..."}`），
  /// 以及模型偶尔直接吐纯文本（没有 JSON 包装）。
  /// 后者当作摘要正文用——**比报错丢掉整次调用划算**。
  static String? parseNoteSummary(String raw) {
    final json = extractJson(raw);
    if (json != null) {
      final s = json['summary'];
      if (s is String && s.trim().isNotEmpty) return s.trim();
    }
    // 退化路径：把非空原文当摘要
    final t = raw.trim();
    if (t.isEmpty) return null;
    // 明显是一坨 JSON 却没解析出来 → 别把 `{"summary":` 当摘要存进去
    if (t.startsWith('{') || t.startsWith('[')) return null;
    return t;
  }

  /// 拼摘要的 user prompt。
  static String noteSummaryUser(String title, String content) {
    final body = _clip(content);
    return '笔记标题：${title.isEmpty ? '（无标题）' : title}\n\n'
        '笔记正文：\n"""\n$body\n"""';
  }

  // ==========================================================================
  // 轻笔记生成（卡片流的 AI 内容）
  // ==========================================================================

  /// 生成「轻笔记」——卡片流里的**新内容**，不是已有笔记的摘要。
  ///
  /// 提示词是用真实 API 反复调出来的，几条经验：
  ///
  /// 1. **卡片只显示标题**，所以标题必须一个人承担"让人想点进去"的责任。
  ///    不能是「间隔重复」这种干标签，要是一句有钩子的话。
  ///    提示词里给"好/坏"对照比给抽象要求有效（实测差别明显）。
  /// 2. **必须给具体示例**，且给长度上限。只说"短一点"模型会写到 40 字；
  ///    给一个"照这个长度写"的样例才收敛。
  /// 3. 仍然**不能指望模型严格守字数**，所以 UI 用
  ///    `maxLines: 3 + ellipsis` 兜底。
  ///
  /// 早先这里还有 `summary` 字段（让 AI 单独生成一段卡片摘要）。
  /// 已删除：摘要与正文的关系怎么定义都别扭，而卡片只放标题反而更干净。
  static const feedSystem = '''
你是笔记应用的「灵感生成器」。用户给你若干份素材，每份素材包含：
**一条摘要**（整体背景）和**一块原文切片**（具体内容）。

你要为**每一份素材**生成一张卡片，卡片必须**基于那块切片**。

输出 JSON：{"cards":[{"title":"...","body":"...","tags":["标签1","标签2"]}]}
cards 的顺序要和素材顺序一一对应，**不要合并、不要遗漏**。

## title
**这是卡片上唯一显示的文字。** 上限 30 字，理想是 12-20 字。

它必须是一句**有钩子**的话——用户只看到它，就要决定要不要点进去。
所以不能是干巴巴的名词标签，要有观点、悬念或具体数字。

好（有钩子）：
- 「抄书是最没用的努力」
- 「遗忘曲线其实是朋友」
- 「20 分钟后你会忘掉 42%」

坏（干标签，用户不会想点）：
- 「间隔重复」
- 「读书笔记方法」
- 「关于记忆的一些思考」

## body
400-800 字，Markdown 格式，有信息量、能独立阅读。

**但必须基于切片那一个具体点展开**，不是泛泛概括：

- 必须基于**切片的原文内容**，不要泛泛而谈
- 切片如果是某个数字、公式、步骤、名言、反例，
  就从那个具体内容讲起，再把它讲透、讲开
- **摘要只作为背景**，不要复述摘要里的话
- **不要编造切片里没有的信息**
- 篇幅可以长，但**内容要围绕切片那一个点**，不要摊开成一堆无关的话

这是用户点进卡片后看到的全文，也是他把这条收进笔记时保存的内容。

## tags
**2~6 个**短标签，每个是**一个词**，不超过 5 个汉字（英文不超过 12 个字母）。
不带 # 号，不加标点。用来在这条内容里做主题归类。

只输出 JSON，不要任何解释。
''';

  /// 把素材拼成用户消息：**摘要（面）+ 切片（点）+ 任务**。
  ///
  /// 三部分缺一不可：
  ///   · 只给摘要 → 卡片大而空（试过，AI 只能再概括一遍）
  ///   · 只给切片 → 缺整体背景，容易理解偏
  ///   · 两者都要，再用任务说明约束"基于切片、具体、不编造"
  ///
  /// [count] 是**要几张卡片**，它和素材份数是**两件事**：
  /// 素材够就一份一张；素材不够（库里笔记少）时让模型从同一份素材的
  /// 不同角度补足张数——否则"笔记少 → 卡片少"，用户等半天只拿到几张。
  ///
  /// [avoidTitles] 是**已经生成过的卡片标题**（池子里还没看的、上次预留的）。
  /// 库里笔记少的时候，切片会被反复取到，光靠换块治不了重复；
  /// 把已有标题列出来让模型**主动避开**，是同一段素材也能写出不同角度的关键。
  static String feedUser(
    List<FeedMaterial> materials, {
    int? count,
    List<String> avoidTitles = const [],
  }) {
    final sb = StringBuffer();

    for (var i = 0; i < materials.length; i++) {
      final m = materials[i];
      sb.writeln('【素材 ${i + 1}】');
      sb.writeln('标题：${m.title.isEmpty ? '（无标题）' : m.title}');
      sb.writeln('摘要（整体背景，仅作参考）：');
      sb.writeln(_clip(m.summary, limit: 800));
      sb.writeln('原文切片（卡片必须基于它）：');
      sb.writeln(_clip(m.chunk, limit: 1200));
      sb.writeln();
    }

    final n = count ?? materials.length;
    if (materials.length >= n) {
      sb.writeln('请为上面每一份素材各生成一张卡片，共 $n 张，顺序一一对应。');
    } else {
      // 素材少于张数：明说可以从同一份素材多写几张。
      // 不加这句的话模型会只按素材数产出，张数就补不上了。
      sb.writeln(
        '请生成 $n 张卡片。上面只有 ${materials.length} 份素材，不够一份一张，'
        '所以**同一份素材可以写出多张卡片**——但要各自抓住切片里'
        '**不同的具体内容**（不同的一句话、数字、步骤、例子各写一张），'
        '不要几张都在讲同一个点、也不要把同一句话换个说法重复。',
      );
    }

    if (avoidTitles.isNotEmpty) {
      sb.writeln();
      sb.writeln('下面这些标题**已经生成过了**，用户可能已经看过：');
      for (final t in avoidTitles) {
        sb.writeln('- $t');
      }
      sb.writeln(
        '本次的标题不要和它们重复，**也不要把同一句话换个说法再写一遍**。'
        '换一个真正不同的切入角度。',
      );
    }

    sb.writeln();
    sb.writeln('另外：本次这几张卡片的标题必须**互不相同**，'
        '不要出现"标题不同但说的是同一件事"的情况。');
    return sb.toString();
  }

  /// 解析轻笔记生成结果。
  static List<FeedDraft>? parseFeedCards(String raw) {
    final json = extractJson(raw);
    if (json == null) return null;

    final list = json['cards'];
    if (list is! List) return null;

    final drafts = <FeedDraft>[];
    for (final item in list) {
      if (item is! Map) continue;
      final d = FeedDraft.fromJson(Map<String, dynamic>.from(item));
      if (!d.isValid) continue;
      // 标签做规整：模型不守长度，5 汉字 / 12 字母的约束必须在代码里兜底，
      // 否则卡片上会出现一长串文字当"标签"。
      drafts.add(FeedDraft(
        title: d.title,
        body: d.body,
        tags: sanitizeTags(d.tags),
      ));
    }
    return drafts.isEmpty ? null : drafts;
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

  /// 把**更早的对话**压成一段背景摘要（§8.6）。
  ///
  /// 要求写成"背景材料"而不是"摘要"：模型拿到的这段会被当上下文用，
  /// 它得知道这是**过去发生的事**，不是用户现在说的话。
  static String historySummaryQuestion() => '把下面这段更早的对话压成一段简洁的背景摘要，'
      '供之后的对话参考。要求：\n'
      '1. 只保留**之后可能会用到**的事实：用户的身份/偏好、已经做过的决定、'
      '正在处理的事情、明确说过的约束。\n'
      '2. 丢掉寒暄、重复、以及已经结束的一次性问答。\n'
      '3. 用第三人称陈述（"用户想要…""之前已经确定…"），不要写成对话。\n'
      '4. 不要编造对话里没有的信息；不确定的就不要写。\n'
      '5. 控制在 300 字以内。\n'
      '直接输出摘要正文，不要任何前缀或标题。';

  static String _clip(String content, {int limit = maxBodyChars}) {
    if (content.length <= limit) return content;
    return '${content.substring(0, limit)}\n\n'
        '（注：原文过长，以上为前 $limit 字，已被截断）';
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
}
