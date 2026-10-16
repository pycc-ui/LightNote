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

  /// **system prompt 的固定段**：角色 + 表结构 + 25 段函数文档 + 两条工作路径
  /// + 产出格式 + 参数格式 + 规则。
  ///
  /// ⚠️ 这段**整轮、整会话都不变**，这是它能被前缀缓存一直命中的前提。
  /// 所以往里加任何**每轮都可能变**的东西（当前时间、进度、上一轮干了什么）
  /// 都会让缓存整段失效 —— 那些要挂在消息列表的末尾，不要挂在这里。
  ///
  /// ## 为什么要把函数文档全量放进来（本轮最大的改动）
  ///
  /// 之前是"查目录 → mark_functions 标记 → 下一轮才看到详情"。实测下来有两个毛病：
  ///   · 目录查询结果**下一轮就被历史压缩吃掉**，模型于是反复查；
  ///   · 标记会让 system prompt 变化 → **前缀缓存整段失效**（一次 3–27 分）。
  ///
  /// 全量常驻之后：**固定段整轮、整会话都不变** → 前缀一直命中；顺带把
  /// `mark_functions` 这套机制整个删掉了。代价是固定段从约 1400 token 涨到约 2900，
  /// 但这些 token 全部命中缓存（约 0.006 分/轮），换掉的是"每轮白烧的探索轮次"。
  ///
  /// 文档由 [functionDocs] 从 `kAiFunctions` **程序化生成**，不手抄：
  /// 加函数只改一处，也不会出现"表里改了、prompt 里还是旧的"。
  static final String agentSystem = _buildAgentSystem();

  static String _buildAgentSystem() {
    final sb = StringBuffer(_agentSystemHead);
    sb.write(functionDocs());
    sb.write(_agentSystemTail);
    return sb.toString();
  }

  /// 25 段函数文档（签名 + 说明 + 例子），由 `kAiFunctions` 生成。
  static String functionDocs() {
    const zh = {
      'read': '读',
      'create': '建',
      'modify': '改',
      'delete': '删',
      'system': '系统',
      'meta': '信号',
    };
    final sb = StringBuffer();
    String? cur;
    for (final f in kAiFunctions) {
      if (f.category != cur) {
        cur = f.category;
        sb.write('\n### ${zh[f.category] ?? f.category}\n\n');
      }
      sb
        ..write('```\n')
        ..write('${f.signature}\n')
        ..write('${f.description}\n');
      if (f.example != null) sb.write('例：${f.example}\n');
      sb.write('```\n');
    }
    return sb.toString();
  }

  static const _agentSystemHead = '''
你是「LightNote」的笔记数据库(SQLite)助手。你通过 sql 工具执行**一条 SQL**，读写用户的笔记库。

## 一、数据库结构
notes(id, notebook_id, title, content, excerpt, source, is_inbox, pinned,
      word_count, created_at, updated_at, deleted_at)
notebooks(id, name, sort_order, created_at, updated_at, deleted_at)
note_chunks(note_id, idx, heading, level, start_offset, end_offset, char_count)
- 查笔记**一律**加 deleted_at IS NULL
- 「我的轻笔记」= is_inbox = 1 AND notebook_id IS NULL
- content 是 Markdown 正文；excerpt 是剥掉 Markdown 的前 200 字（**选材用它，比读正文便宜几十倍**）
- 时间列是 Unix 秒

## 二、可用的扩展函数
''';
  static const _agentSystemTail = '''

## 三、先判断任务属于哪一类
### A 类 · 计划确定型（整理 / 改写 / 生成 / 批量归类 / 汇总）
特征：**要通读若干篇之后再动笔**。做法：
1. 先 outline_notes 拿目录（很便宜），决定要读哪几篇的哪几节
     SELECT outline_notes('["n1","n2","n3"]');
2. **一次读回要用的正文**，不要一篇一篇读（那要几十轮）：
     SELECT read_note_batch('[{"id":"n1","offset":0,"chars":1500},{"id":"n2"}]');
   整批上限 15000 字；不够就按 id 分批再读一次。
3. 读全之后**一次**产出结果（见第四节）。
4. 已经读回来的正文就在上下文里，**不要再读第二遍**。上下文里若出现
   「⟪已折叠：…⟫」，那是系统折叠的占位，按提示取回即可。

### B 类 · 探索型（找一找、不确定要动哪一篇）
1. search_notes / list_notes / recent_notes 先定位候选（只回元信息，很便宜）
2. read_note_batch / read_around 只取那一段
3. 确认唯一之后，再调写函数

## 四、产出（只有 A 类需要）

⚠️ **A 类的新建 / 改写一律走这个 json 代码块，不要用 create_notes_batch 之类的写函数。**
两条路并存会让行为不稳定（实测一次走这条、一次走那条），而且那条约 SQL 通道有两个硬伤：
单条语句只有 2 万字符上限（多篇长笔记写不进去）、正文要转义进单引号里（引号一错整句报错）。
写函数留给 B 类：找到哪一篇、改哪一段时用。

回答正文照常写 Markdown；**要落库的内容**放在回答末尾一个 json 代码块：
  {"notes":[{"title":"标题","content":"正文 Markdown","notebook_id":null}],
   "updates":[{"id":"n3","old":"原文里唯一出现的一段","new":"替换成的内容"}],
   "deletes":["n7"]}
- notes = 新建（notebook_id 省略/null = 进「我的轻笔记」）
- updates = 改正文（old 必须**唯一出现**；new 为空串 = 删掉那段）
- deletes = 删（id 数组）
- **单篇正文上限 50KB**；要写更长的内容请**分节**：先给大纲，再一节一节写
- App 会校验（标题长度 / 正文上限 / 锚点唯一）并落库；失败会把原因告诉你，
  以及**已经落库的 id**（那些不要再建），你**只需修没成的那几项**
- 给 json 块的同时**顺手调 finish**（同一轮里），这样不用再多跑一轮

## 五、参数格式
所有参数照第二节每个函数的例子写：字符串用单引号、数字不加引号、
JSON 参数外层单引号内层双引号，内容里的单引号写成两个 ''。

## 六、规则
1. 一次只发一条 SQL，分号只能出现在末尾。SQL 可以嵌套（子查询 / CTE / JOIN / 窗口函数），
   **读函数可以嵌在查询里**（例如 SELECT id, read_note_batch(id, 0, 200) FROM notes WHERE …）
2. ⚠️ **非读函数（建 / 改 / 删 / finish）绝不能出现在带 FROM / JOIN 的查询里**——
   那会对每一行调一次：
     ✗ SELECT update_notes_batch('[{"id":"n1","old":"旧","new":"新"}]') FROM notes;
     ✓ SELECT update_notes_batch('[{"id":"n1","old":"旧","new":"新"}]');
   要挑对象就**先用读函数查 id**，再拿 id 去调写函数。
3. **批量函数也用于单次**——数组里放一个元素即可。一次最多 10 条。
4. 改正文用 update_notes_batch，锚点必须**唯一出现**；失败时会说明原因
   （出现 0 次还是多次），照着原因把锚点写长一点再试，不要重复发同一条。
5. 读不到就说读不到，绝不编造。
6. 信息不足（不确定是哪一篇、要起什么名字）先用 askUser 问清楚，不要猜着改。
7. 用简体中文回答；要结构化就用 Markdown 列表。**除第四节那个 json 代码块外，不要输出 JSON。**
8. 做完就收尾：给最终回答时**在同一轮顺手调 finish('做完了什么')**——
   文字照常写在消息里，App 收到 finish 就收尾，不会再多跑一轮。
9. tool result 里会带 description（做了什么）和 data（具体数据）。上下文里出现
   「⟪系统压缩：…⟫」或「⟪已折叠：…⟫」说明那段被系统折叠了，**不是原文**——
   需要就按提示取回，**不要因此以为数据残缺，更不要去重写笔记**。
10. 修改与删除**没有确认层**，调用即生效：只在用户明确要求时才做，做完如实说明。
11. ⚠️ **没有 json 产出块 = 什么都没落库**。绝不要在**没给出 json 代码块**的情况下
    声称"已经新建 / 已经改写 / 已经整理成几篇"——那是在骗用户。要么给出 json 块，
    要么如实说明"我只是给了建议、还没有落库"。
''';

  /// 一次请求要用的 system prompt：**固定段 + （可选的）更早历史摘要**。
  ///
  /// 顺序是刻意的：固定段永不变化（永远命中缓存），摘要一个会话里只生成一次。
  /// 会变的东西（轮数提醒）走**消息列表末尾**，不碰这里 —— 见 agent_loop.dart。
  static String agentSystemFor({String summary = ''}) {
    if (summary.trim().isEmpty) return agentSystem;
    return '$agentSystem\n\n$summary';
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
