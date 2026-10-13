import 'dart:convert';

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

  /// AI 页的系统提示词（命令语言版）。
  ///
  /// 工具只剩一个 `run(script)`：所有操作都写成脚本里的 shell 风格命令，
  /// 语法用 `set` / `:`（for/if）/ `end` 明确区别于 bash。命令语法写在这里，
  /// 让模型零学习成本（`ls`/`sed`/`grep` 是海量训练数据）。
  ///
  /// 注意：这里刻意**不把时间戳、会话 id、笔记 id 拼进 prompt**，
  /// 以保证 system 前缀稳定、最大化上下文缓存命中率（命中后输入成本约 1/50）。
  ///
  /// 命令与语法细则见 docs/命令语言设计.md。
  static const agentSystem = '''
你是「LightNote」App 内置的笔记助手。

你可以在用户的笔记库上执行命令。屏幕上的「笔记库」是文件夹、「笔记」是文件，
路径写作 `笔记库/笔记`。根目录固定有一个「我的轻笔记」，存放未归档的笔记。

## 执行方式
- 通过 `run` 工具提交**一段命令脚本**，一次可以写多行。
- 能一次做完的事不要拆成多轮。
- 只读命令（ls/stat/sed -n/grep）批量执行、一次性返回；
  写命令（echo / sed 的 c/d/i/a / rm / mkdir / mv）**逐条弹确认框**，
  用户允许才执行，拒绝则跳过这一条、继续下一条。
- 读长笔记：先 stat 看行数，再 grep 定位，最后 sed -n 读那几行。
- 要改笔记：必须先用 `sed -n` 读出目标行、确认行号，**在同一脚本里**再改。

## 脚本语法
  set 名字 = 值            定义变量
  \$名字                   引用变量（引用不存在的变量会报错）
  for x in 列表            循环；列表可以是命令结果，也可以是 "a" "b" "c"
    ...
  end
  if 命令                  条件；命令成功（退出码 0）才执行
    ...
  end
  # 这一行是注释

## 命令
  ls [库]                  列笔记库 / 列某库内的笔记（只给名字）
  stat <笔记>              行数、字数、大小、时间、所属库
  sed -n 'A,Bp' <笔记>     读第 A-B 行
  sed 'A,Bc 新内容' <笔记>  替换第 A-B 行
  sed 'A,Bd' <笔记>        删除第 A-B 行
  sed 'Ai 新内容' <笔记>    在第 A 行前插入一行
  sed 'Aa 新内容' <笔记>    在第 A 行后追加一行
  grep "词" [路径]         搜索，返回行号 + 片段
  echo "内容" > <笔记>     新建 / 覆盖整篇
  echo "内容" >> <笔记>    追加到末尾
  rm <笔记>                删除（不可恢复）
  mkdir <库>               新建笔记库
  mv <笔记或库> <目标>     移动 / 重命名

## 不支持（写了就报错）
管道、命令替换、反引号、通配符、正则、算术、字符串函数、函数定义、
嵌套循环 / 嵌套条件、else / elif、while、break / continue / return、
`&&` / `||`、环境变量、多行字符串、行尾注释。

## 硬性要求
1. 使用简体中文，语气简洁务实，不说客套话。
2. 回答以笔记内容为依据。要引用用户笔记时**先用 grep / sed -n 读出来**，
   别凭常识替他"回忆"；读不到就说读不到，绝不编造。
3. 修改类命令一定会弹确认：直接发脚本即可，**不要**只输出一份"变更建议"就停下；
   也**不要**说"我已经改好了"——除非命令返回了成功结果。
   用户拒绝时命令会返回失败，照着结果如实告诉用户，不要重试同一个操作。
4. 删除不可恢复，措辞要明确。
5. 需要结构化输出时用 Markdown 列表，不要输出 JSON。
''';

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
生成灵感卡片。每份素材是一篇笔记的一小段原文，为每份生成一张卡片。
输出 JSON：{"cards":[{"title":"","body":"","tag":""}]}
顺序对应素材，不合并不遗漏。
title：≤30 字，有钩子（观点/悬念/数字）。例：「抄书是最没用的努力」。
body：200-400 字 Markdown，围绕原文一个具体点展开，不编造。不要写「这段文字」「原文提到」这类话。
tag：1 个词，≤5 汉字（英文 12 字母），不带 #。
只输出 JSON。
''';

  /// 把素材拼成用户消息：**一段截断的原文 + 任务**。
  ///
  /// 素材只有一样东西——从笔记里截取的一小段原文（片内的窗口，可能不完整）。
  /// 提示词里会说明它是截取的原文、并要求卡片**不要提及**这一点。
  ///
  /// 一份素材生成一张卡片：调用方是"一路一份素材、每路只出 1 张"的并发单卡
  /// （见 `FeedRepository._generateCardsParallel`）。所以这里没有"要几张"的参数。
  ///
  /// [avoidTitles] 是**已经生成过的卡片标题**（池子里还没看的、上次预留的）。
  /// 库里笔记少的时候，切片会被反复取到，光靠换块治不了重复；
  /// 把已有标题列出来让模型**主动避开**。
  static String feedUser(
    List<FeedMaterial> materials, {
    List<String> avoidTitles = const [],
  }) {
    final sb = StringBuffer();

    for (var i = 0; i < materials.length; i++) {
      final m = materials[i];
      sb.writeln('【素材 ${i + 1}】');
      sb.writeln('标题：${m.title.isEmpty ? '（无标题）' : m.title}');
      sb.writeln('原文片段（卡片必须基于它）：');
      sb.writeln(_clip(m.chunk, limit: 400));
      sb.writeln();
    }

    sb.writeln('请为上面每一份素材各生成一张卡片，共 ${materials.length} 张，顺序一一对应。');

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
      // 标题与正文也要兜底：提示词要求"标题 ≤30 字、正文 200–400 字"，
      // 但模型偶尔会跑飞（有返回几千字的情况），而卡片正文会被收进笔记、
      // 也会进 prompt，`feed_reserve` 不该被一张卡片塞满。
      // 与标签同一套思路：模型的自我约束不算约束，代码里兜底才算。
      drafts.add(FeedDraft(
        title: safeTruncate(d.title.trim(), AiLimits.feedCardTitleMax),
        body: safeTruncate(d.body.trim(), AiLimits.feedCardBodyMax),
        tag: sanitizeTag(d.tag),
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

  /// 把**更早的对话**压成一段背景摘要（见《AI接入设计》的「会话历史」一节）。
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
