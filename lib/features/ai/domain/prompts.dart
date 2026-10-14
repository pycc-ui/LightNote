import 'dart:convert';

import '../../../core/db/ai_functions.dart';
import '../../../core/db/models.dart';
import '../../../core/util/ai_limits.dart';

/// 提示词与 JSON 结构约定。
///
/// 两条硬性约束（来自 DeepSeek 官方文档）：
/// 1. 使用 JSON Output 时，system 或 user prompt 必须含有 "json" 字样
///    并给出期望的输出样例，否则模型不保证输出合法 JSON。
/// 2. system prompt 保持稳定、且把「不变的指令」放在最前面，
///    这样能最大化上下文硬盘缓存的命中率（命中后输入成本降到约 1/50）。
///    因此**绝不要把时间戳、随机 ID、笔记 ID 放进 system prompt 开头**。
class AiPrompts {
  AiPrompts._();
  // ---------------------------------------------------------------------------
  // AI 页（轻笔记助手）
  // ---------------------------------------------------------------------------

  /// 「查目录」那一步用的 SQL。
  ///
  /// 单独拎成常量，是因为它是 prompt 里唯一一条**约定好的 SQL**：
  /// 列名一旦对不上（设计稿里曾写 `one_line`，而那一列在 v13 已经删掉了），
  /// AI 会照着 prompt 写出一句必然报 `no such column` 的 SQL，
  /// 而它只会以为是自己写错了、反复重试。测试直接执行这条常量，
  /// schema 一变就红（见 test/ai_pinned_functions_test.dart）。
  ///
  /// 只回 name + signature（不回 description）：目录要便宜，25 行约 300 token；
  /// 详情由 `mark_functions` 按需加载。
  static const catalogQuery = 'SELECT name, signature FROM ai_functions';

  /// AI 页的系统提示词（SQL 版）——**固定段**。
  ///
  /// 工具只剩一个 `sql`：所有操作都写成 SQL —— AI 的母语，训练数据海量，
  /// 学习成本为零（上一版让它学一套自定义命令语法，那是它没见过的东西，
  /// 换更大的模型也没用）。**函数的详情不写在这里**，走两段式：
  ///
  ///   · 固定段（本常量）：只说明"去哪找函数、怎么把它们加载进来"；
  ///   · 详情段（[pinnedDetails]）：AI 自己用 `mark_functions` 标记过的函数，
  ///     每轮拼在**末尾**（见 [agentSystemFor]）。
  ///
  /// 好处是加一个函数 = 往 `ai_functions` 表加一行，这段 prompt 一个字都不用改；
  /// 而且这段是**跨会话都不变的前缀**，命中上下文缓存后按约 1/50 计价。
  ///
  /// 注意：这里刻意**不把时间戳、会话 id、笔记 id 拼进 prompt**，
  /// 以保证 system 前缀稳定、最大化上下文缓存命中率。
  ///
  /// 细则见 docs/AI操作数据库设计.md。
  static const agentSystem = '''
你是「LightNote」的笔记数据库(SQLite)助手。你通过 sql 工具执行**一条 SQL**，读写用户的笔记库。
ai_functions(name, category, signature, description, example)
—— 这张表列出全部可用的扩展函数（读 / 建 / 改 / 删 / 系统）。
规则：
1. **函数详情**：System Prompt 末尾会带上「已加载函数详情」——你之前标记过的函数。
   如果这次任务需要的函数不在其中：
     a. 先查目录：$catalogQuery（只回函数名 + 签名，很省）
     b. 判断哪些函数这次会反复用 → mark_functions('["函数名1","函数名2"]')
     c. 被标记的函数详情**立刻追加到末尾**——下一轮你就能看到它的
        signature / description / example，照着 example 写就行。
   **不要每次会话都重查目录**——只有需要的函数没在「已加载」里时才查。
2. 一次只发一条 SQL，分号只能出现在末尾。SQL 可以嵌套（子查询 / CTE / JOIN /
   窗口函数），扩展函数也能嵌在查询里：
     SELECT id, title, read_preview(id, 0, 200) AS preview
     FROM notes WHERE notebook_id = 'nb1' AND deleted_at IS NULL;

参数格式（SQL 里字符串**一律用单引号**）：
  SELECT search_notes('项目A');                    ← 字符串参数
  SELECT read_preview('n1', 0, 200);               ← id 是字符串、数字不带引号
  SELECT create_notes_batch('[{"title":"A","content":"正文"}]');
                                                   ← 批量函数：SQL 单引号包 JSON，
                                                     JSON 里的字符串用双引号
  SELECT mark_functions('["search_notes"]');       ← 同上，JSON 数组
字符串里的单引号写成两个：
  SELECT search_notes('it''s');                    ← 内容含单引号要写成 ''
- **字符串参数（id / 关键词 / 标题 / 正文）用单引号**
- **数字参数（offset / chars / limit）不加引号**
- **JSON 参数（批量函数 / mark_functions）：外层单引号、内层双引号**
- 有疑问时按上面的例子写，**不要反复试**

3. 查笔记一律加 deleted_at IS NULL。
4. 「我的轻笔记」= is_inbox = 1 且 notebook_id IS NULL。
5. 不要整篇读正文：先 find_in_note / search_in_note 定位，再用 read_around /
   read_preview 只取那一段。
6. **批量函数也用于单次**——数组里放一个元素即可：
     create_notes_batch('[{"title":"A","content":"B"}]')  = 新建一篇
   没有对应单次函数（如 create_note）——**一律走批量函数**。一次最多 10 条。
7. 改正文用 update_notes_batch，锚点必须**唯一出现**。它失败时会说明原因
   （出现 0 次还是多次），照着原因把锚点写长一点再试，不要重复发同一条。
8. 读不到就说读不到，绝不编造。
9. 信息不足（不确定是哪一篇、要起什么名字）先用 askUser 问清楚，不要猜着改。
10. 用简体中文回答；要结构化就用 Markdown 列表，不要输出 JSON。
11. tool result 里会带 **description**（这条做了什么）和 **data**（具体数据）。
    历史里长 SQL 和 data 会被系统压成「⟪系统压缩：省略 N 字⟫」标记——
    那不是原文，只是压缩占位。需要完整内容就重新读，
    **不要因为看到压缩标记就以为数据残缺，更不要去重写笔记**。
12. 这次用到的函数如果**以后每次都可能用到**（读列表 / 搜索 / 读正文这类），
    用 mark_functions 标记它们；一次性的（如某篇笔记的正文替换）不必标记。

修改与删除**没有确认层**，调用即生效：只在用户明确要求时才做，做完如实说明。
''';

  /// 拼一次请求要用的 system prompt：**固定段 + 背景摘要 + 已加载函数详情**。
  ///
  /// 顺序是刻意的，三段的稳定性从高到低：
  ///   1. [agentSystem]：所有会话都一样 —— 永远命中缓存；
  ///   2. [summary]：老会话的"更早历史"摘要，一个会话里只生成一次；
  ///   3. 详情段：只增不改（mark_functions 只追加），标一次多一小段，
  ///      **前面的部分不受影响**（所以新追加的那段是唯一不命中的）。
  ///
  /// 由 AgentLoop **每轮重拼**：`mark_functions` 是这一轮的工具调用，
  /// 只有下一轮重拼，AI 才看得到刚加载的详情（见 agent_loop.dart 的 run）。
  static String agentSystemFor({
    String summary = '',
    Iterable<String> pinned = const [],
  }) {
    final sb = StringBuffer(agentSystem);
    if (summary.trim().isNotEmpty) sb.write('\n\n$summary');
    final details = pinnedDetails(pinned);
    if (details.isNotEmpty) sb.write('\n\n$details');
    return sb.toString();
  }

  /// 生成「已加载函数详情」段。没有已标记（或名字全都失效）时返回空串。
  ///
  /// 每条约 70 token，内容取自与 `ai_functions` 表同一份清单
  ///（`core/db/ai_functions.dart`），所以**不会出现"表里改了、prompt 里还是旧的"**。
  /// description 里已经带了参数格式与边界，这里只补上可直接照抄的一行 example。
  static String pinnedDetails(Iterable<String> pinned) {
    final specs = <AiFunctionSpec>[];
    for (final name in pinned) {
      final f = aiFunctionByName(name);
      if (f != null) specs.add(f);
    }
    if (specs.isEmpty) return '';

    final sb = StringBuffer('## 已加载函数详情\n');
    for (final f in specs) {
      sb.write('\n### ${f.signature}\n${f.description}\n');
      if (f.example != null) sb.write('例：${f.example}\n');
    }
    return sb.toString();
  }

  // ---------------------------------------------------------------------------
  // 用户提示词构造
  // ---------------------------------------------------------------------------

  // ==========================================================================
  // 轻笔记生成（卡片流的 AI 内容）
  // ==========================================================================

  /// 生成「轻笔记」——卡片流里的**新内容**，不是已有笔记的摘要。
  ///
  /// 提示词是用真实 API 反复调出来的，几条经验：
  ///
  /// 1. **卡片只显示标题**，所以标题必须一个人承担"让人想点进去"的责任。
  ///    不能是「间隔重复」这种干标签，要是一句有钩子的话。
  ///    提示词里给"好/坏"对照比给抽象要求有效。
  /// 2. 必须给具体示例，且给长度上限。只说"短一点"模型会写到 40 字；
  ///    给一个"照这个长度写"的样例才收敛。
  /// 3. 仍然**不能指望模型严格守字数**，所以 UI 用
  ///    `maxLines: 3 + ellipsis` 兜底。
  ///
  /// 素材只有**一段截断的原文**（没有摘要）。所以提示词里要做两件事：
  /// 告诉模型"这是截取的片段、可能不完整"，同时**禁止卡片提到这一点**——
  /// 否则标题/正文会冒出「这段文字说…」这种指向素材本身的话。
  static const feedSystem = '''
生成灵感卡片。素材是一篇笔记的一小段原文。
输出JSON：{"title":"","body":"","tag":""}
title：≤30 字，有钩子（观点/悬念/数字）。例：「抄书是最没用的努力」。
body：200-400 字 Markdown，围绕原文一个具体点展开，不编造。不要写「这段文字」「原文提到」这类话。
tag：1 个词，≤5 汉字（英文 12 字母）。
只输出JSON。
''';

  /// 把一份素材拼成用户消息：**一段截断的原文 + 任务**。
  ///
  /// **一次请求只生成一张卡片**：一份素材 = 一段截断的原文（片内的窗口，
  /// 可能不完整），调用方「一路一份素材、每路只出 1 张」并发跑（见
  /// `FeedRepository._generateCardsParallel`）。所以这里收**单个** [FeedMaterial]，
  /// 没有"要几张"的参数——想多出卡就多给素材，而不是让模型对着一份素材写多张。
  ///
  /// [avoidTitles] 是**已经生成过的卡片标题**（池子里还没看的、上次预留的）。
  /// 库里笔记少的时候，切片会被反复取到，光靠换块治不了重复；
  /// 把已有标题列出来让模型**主动避开**。
  static String feedUser(
    FeedMaterial material, {
    List<String> avoidTitles = const [],
  }) {
    final sb = StringBuffer();
    sb.writeln('【素材】');
    sb.writeln('标题：${material.title.isEmpty ? '（无标题）' : material.title}');
    sb.writeln('原文片段（卡片必须基于它）：');
    sb.writeln(_clip(material.chunk, limit: 400));
    sb.writeln();
    sb.writeln('请为这段素材生成 1 张卡片。');

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
    return sb.toString();
  }

  /// 解析**一张**轻笔记生成结果。
  ///
  /// 正常形状是 `{"title":…,"body":…,"tag":…}`。为兼容模型偶发地包一层
  /// （`{"cards":{…}}` 或 `{"cards":[{…}]}`），这里也接受这两种退化形状，
  /// 取里面的那张——比直接判失败、白烧一次调用划算。
  static FeedDraft? parseFeedCard(String raw) {
    final json = extractJson(raw);
    if (json == null) return null;

    final Object? raw2 = (json['title'] is String || json['body'] is String)
        ? json
        : json['cards'];
    final Map? card = switch (raw2) {
      Map m => m,
      List l when l.isNotEmpty && l.first is Map => l.first as Map,
      _ => null,
    };
    if (card == null) return null;

    final d = FeedDraft.fromJson(Map<String, dynamic>.from(card));
    if (!d.isValid) return null;
    // 标题与正文兜底：提示词要求"标题 ≤30 字、正文 200–400 字"，
    // 但模型偶尔会跑飞，而卡片正文会被收进笔记、也会进 prompt。
    // 与标签同一套思路：模型的自我约束不算约束，代码里兜底才算。
    return FeedDraft(
      title: safeTruncate(d.title.trim(), AiLimits.feedCardTitleMax),
      body: safeTruncate(d.body.trim(), AiLimits.feedCardBodyMax),
      tag: sanitizeTag(d.tag),
    );
  }

  static String _clip(String content, {int limit = 20000}) {
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
