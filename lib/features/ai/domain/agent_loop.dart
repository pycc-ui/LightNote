import 'dart:convert';

import '../../../core/db/app_database.dart';
import '../../../core/db/models.dart';
import '../../../core/util/app_params.dart';
import 'ask_user.dart';
import 'tool_executor.dart';
import 'tool_specs.dart';
import 'tool_types.dart';

/// **一次**模型调用的抽象。
///
/// 生产实现就是 `DeepSeekClient.streamAgent`。抽成函数类型是为了让整条循环
/// **在测试里跑得起来**：换一个假实现，就能验证"多轮 / 回灌 / 终止条件"
/// 这些最容易写错的地方，而不用真的花 API 额度。
typedef AgentRoundFn = Stream<AiEvent> Function({
  required String systemPrompt,
  required List<AgentMessage> messages,
  required List<ToolSpec> tools,
});

// ============================================================================
// 事件（UI 与仓储据此更新界面/落库）
// ============================================================================

sealed class AgentEvent {
  const AgentEvent();
}

/// 模型这一轮吐出的文字增量（直接追加到回答里）
class AgentText extends AgentEvent {
  const AgentText(this.delta);
  final String delta;
}

/// 开始执行某个工具（UI 可以显示"正在执行命令…"）
class AgentToolStarted extends AgentEvent {
  const AgentToolStarted(this.name);
  final String name;
}

/// 某个工具执行完了
class AgentToolDone extends AgentEvent {
  const AgentToolDone(
    this.name, {
    required this.ok,
    this.description,
    this.mutated = false,
  });
  final String name;
  final bool ok;

  /// UDF 给的一句话操作摘要（如「删除笔记 n1「会议记录」」）。
  final String? description;

  /// 这次调用**改了笔记数据**。仓储据此攒「本轮执行记录」写进消息末尾。
  final bool mutated;
}

/// 模型要问用户，循环**停在这里**等回答。
///
/// 待答的调用会写进 `ai_messages.pendingAction`，用户回答之后再从这里恢复 ——
/// 所以事件里带着 [toolCallId]。
class AgentAwaitingUser extends AgentEvent {
  const AgentAwaitingUser({
    required this.request,
    required this.toolCallId,
    this.asks = 1,
    this.messages = const [],
    this.rounds = 0,
    this.budget = AgentLimits.maxRounds,
  });
  final AskRequest request;
  final String toolCallId;

  /// 到这一刻为止用掉的**工具轮数**（含这一轮），以及这次运行的总预算。
  ///
  /// 调用方要把它们一起存进挂起记录：用户回答之后循环是**重新跑**的，
  /// 不把这两个数带回来，预算就永远从头开始（等于软上限失效）。
  final int rounds;
  final int budget;

  /// 这一轮里问到第几次了。**调用方要把它一起存下来** ——
  /// 用户回答之后恢复循环时得从这一次接着数，否则上限永远到不了。
  final int asks;

  /// 提问那一刻的对话。回答之后要**从这里接着跑**：
  /// 中途的工具往来只在内存里（不落库），不带上的话只能从头再来一遍。
  final List<AgentMessage> messages;
}

/// 整轮（可能多轮往返）累计的用量。
///
/// 多轮之后一次用户输入会产生**多次** API 调用，所以记账必须累计 ——
/// 只记最后一次的话，工具一多成本就被严重低估。
class AgentUsage {
  const AgentUsage({
    this.rounds = 0,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.costCents = 0,
    this.latencyMs = 0,
  });

  final int rounds;
  final int promptTokens;
  final int completionTokens;
  final double costCents;
  final int latencyMs;

  AgentUsage merge(AiDone d) => AgentUsage(
        rounds: rounds + 1,
        promptTokens: promptTokens + d.promptTokens,
        completionTokens: completionTokens + d.completionTokens,
        costCents: costCents + d.costCents,
        latencyMs: latencyMs + d.latencyMs,
      );
}

/// 整轮结束，[text] 是最终回答
class AgentFinished extends AgentEvent {
  const AgentFinished(this.text, {this.usage = const AgentUsage()});
  final String text;
  final AgentUsage usage;
}

/// 出错（网络、Key 没配……）。**已经收到的文字照旧留在回答里**，
/// 所以这里只给原因，不让调用方丢掉半截内容。
class AgentFailed extends AgentEvent {
  const AgentFailed(this.message, {this.usage = const AgentUsage(), this.code});
  final String message;
  final AgentUsage usage;

  /// 机器可读的错误码（`network` / `timeout` / `rounds` / …）。
  ///
  /// 消息要落进 `ai_messages.interrupt_reason` 供界面显示"为什么没写完"，
  /// 而拿 [message] 去认是不可靠的 —— 那是一句给人看的中文。
  final String? code;
}

// ============================================================================
// 循环
// ============================================================================

/// **多轮工具调用循环**：提工具 → 执行 → 回灌 → 再发一轮，直到它不再提。
///
/// 改用 SQL 之后，工具只剩 `sql`（执行一条 SQL）与 `askUser`（挂起提问）。
/// 一次用户输入通常只需要 1~3 轮：模型一条 SQL 就能把要读的读完，
/// 而不是像旧的 function calling 那样一个工具一轮、`O(N²)` 地重发历史。
///
/// ## 四条终止条件（缺一个都会挂死）
///
/// 1. `finish(...)` → **声明完成**，当场收尾（不再发一轮）
/// 2. 模型这一轮**没提工具** → 正常结束
/// 3. `askUser` → 停下来等用户（持久化挂起，见《AI接入设计》）
/// 4. **轮数预算用尽** → 强行结束
///
/// 第 4 条不是防御性代码而是必需品：模型有可能每次都提一个必然失败的调用
/// （SQL 一直写错），没有上限就是**无限烧钱**。而预算是**可以续的** ——
/// 快到上限时模型会收到一条提醒（[budgetNotice]），由它自己 `askUser` 问用户
/// 要不要继续，用户同意后预算 +[AgentLimits.roundExtension]，硬上限
/// [AgentLimits.maxRoundsHard] 兜底。
class AgentLoop {
  const AgentLoop({required this.round, required this.executor});

  final AgentRoundFn round;
  final ToolExecutor executor;

  /// 一轮用户输入最多允许几轮工具往返。
  static const maxRounds = AgentLimits.maxRounds;

  /// 一轮用户输入里 `askUser` 最多问几次。
  ///
  /// 必须封顶：模型完全可能"问一句 → 拿不到满意答案 → 再问一句"地循环下去，
  /// 而每次都要等用户动手。到上限后强制收尾，让它用现有信息回答。
  static const maxAsksPerTurn = AgentLimits.maxAsksPerTurn;

  /// 跑一轮。 [history] 必须**已经包含**本轮的用户输入。
  ///
  /// [rebuildPrompt]：**每轮请求前重新拼一次 system prompt**。
  /// 动态函数标记（`mark_functions`）就靠它生效 —— 标记是这一轮的工具调用，
  /// 只有下一轮重新拼过，刚加载的函数详情才会出现在 prompt 末尾；
  /// 不传就用固定的 [systemPrompt]（测试与不需要动态详情的路径）。
  Stream<AgentEvent> run({
    required String systemPrompt,
    required List<AgentMessage> history,
    Future<String> Function()? rebuildPrompt,
    List<AiMessage> dbHistory = const [],
    int asksSoFar = 0,
    int roundsUsed = 0,
    int? roundBudget,
  }) async* {
    final messages = List<AgentMessage>.from(history);
    final tools = specsForRequest();
    final answer = StringBuffer();
    var usage = const AgentUsage();
    // ⚠️ 从 [asksSoFar] 起算：挂起恢复时调用方会把已经问过的次数带回来
    var asks = asksSoFar;

    // ---- 预算：**跨挂起累计** ----
    //
    // [roundsUsed] 是这次用户输入之前已经用掉的轮数（挂起恢复时由调用方带回来，
    // 见 PendingAsk.rounds）；[roundBudget] 是这次允许用到的总数。
    // 不传预算就按"再来一轮默认额度"算，并一律夹到硬上限 ——
    // 硬上限是最后一道闸，不能靠调用方自觉。
    final budget = (roundBudget ?? (roundsUsed + maxRounds))
        .clamp(roundsUsed, AgentLimits.maxRoundsHard);

    for (var roundNo = 0; roundNo < budget - roundsUsed; roundNo++) {
      executor.beginTurn();
      final used = roundsUsed + roundNo;
      // 快到上限时，把"还剩几轮"追加在 prompt **末尾**：
      // 不碰协议、不碰消息，也不需要改 rebuildPrompt 的签名 ——
      // 每轮本来就要重拼一次 prompt（mark_functions 的详情靠它生效）。
      final prompt =
          (await _promptFor(systemPrompt, rebuildPrompt)) +
              _budgetNotice(used, budget);

      // ---- 一次请求 ----
      var text = '';
      var calls = const <ToolCall>[];
      var errored = false;

      await for (final e in round(
        systemPrompt: prompt,
        messages: messages,
        tools: tools,
      )) {
        switch (e) {
          case AiChunk():
            text += e.text;
            yield AgentText(e.text);
          case AiReasoning():
            break; // 思维链不展示
          case AiDone():
            usage = usage.merge(e);
            // 流式累加才是真相；`fullText` 兜住"一个 chunk 都没收到"的极端情况
            if (text.trim().isEmpty && e.fullText.trim().isNotEmpty) {
              text = e.fullText;
              yield AgentText(e.fullText);
            }
            calls = e.toolCalls;
          case AiError(:final message, :final code):
            if (text.trim().isNotEmpty) answer.write(text);
            yield AgentFailed(message, usage: usage, code: code);
            errored = true;
        }
      }
      if (errored) return;

      // ---- 没提工具 → 这就是回答 ----
      if (calls.isEmpty) {
        answer.write(text);
        yield AgentFinished(answer.toString(), usage: usage);
        return;
      }

      // ---- 提了工具：先把这一轮记进历史，再逐个执行 ----
      // ---- 压缩无用信息 ----
      _slimLastToolResults(messages); 
      messages.add(AgentMessage.assistant(text, toolCalls: calls));
      _slimToolCalls(messages); 
      // 工具轮里模型偶尔会先垫一句（"我先查一下"）。写进回答让用户看到进度，
      // 但**不算进最终回答的正文**——它和结论之间要隔开。
      if (text.trim().isNotEmpty) answer.write('${text.trim()}\n\n');

      for (final call in calls) {
        // `askUser` → 停在这里等用户（工具结果等回答了再补）
        if (call.name == 'askUser') {
          if (asks >= maxAsksPerTurn) {
            // 到上限：**明确拒绝**并让模型收尾，而不是继续问
            messages.add(AgentMessage.tool(
              toolCallId: call.id,
              content: ToolResult.failure(
                '这一轮已经问过 $maxAsksPerTurn 次了，不要再问。'
                '请用现有信息给出最好的答案；确实缺关键信息就在回答里说明。',
              ).encode(),
            ));
            continue;
          }
          final req = _parseAsk(call);
          if (req == null) {
            messages.add(AgentMessage.tool(
              toolCallId: call.id,
              content: ToolResult.failure(
                'askUser 需要 `question` 与合法的 `type`'
                '（text / singleChoice / multipleChoice / confirm）。',
              ).encode(),
            ));
            continue;
          }
          asks++;
          yield AgentAwaitingUser(
            request: req,
            toolCallId: call.id,
            asks: asks,
            // 回答之后要接着跑，所以把此刻的对话一起交出去
            messages: List<AgentMessage>.from(messages),
            // 轮数也要交出去（含这一轮）—— 回答完恢复时得从它还回来
            rounds: used + 1,
            budget: budget,
          );
          return;
        }

        yield AgentToolStarted(call.name);
        final result = await executor.execute(
          call.name,
          ToolExecutor.parseArgs(call.arguments),
          history: dbHistory,
        );
        yield AgentToolDone(
          call.name,
          ok: result.ok,
          description: result.description,
          mutated: result.mutated,
        );

        // `finish()` = **声明完成**：当场收尾，不回灌、不再发一轮。
        //
        // 模型是「边写结论边调 finish」的（同一轮里），所以答案就是这一轮
        // 已经流出来的文字。按普通工具回灌的话，每个任务都要多跑一轮请求 ——
        // 而「读完笔记给结论」是最常见的路径，那等于每次收尾都多花一次钱。
        if (result.finished) {
          final said = answer.toString().trimRight();
          yield AgentFinished(
            // 兜底：只调了 finish、一个字没写（违反 prompt，但别让用户看到空白）
            said.isEmpty ? (result.description ?? '已完成。') : said,
            usage: usage,
          );
          return;
        }

        messages.add(
          AgentMessage.tool(toolCallId: call.id, content: result.encode()),
        );
      }
    }

    // 轮数用尽：把已经拿到的内容交出去，并明说可能没查完
    yield AgentFailed(
      '工具调用轮数达到上限（$budget 轮），已停止。'
      '${answer.isEmpty ? '' : '下面是已经拿到的部分内容。'}'
      '如果任务还没做完，再发一句「继续」就行。',
      usage: usage,
      // 这个原因会落进 `ai_messages.interrupt_reason`：界面上要能显示
      // "上次是被轮数上限打断的"，而不是一个笼统的"未完成"。
      code: 'rounds',
    );
  }

  /// 快到预算上限时追加在 system prompt **末尾**的一段提醒。

  /// 只在"还剩 ≤2 轮"时出现：早一点提醒才有用（还剩 1 轮时它已经没机会收尾了）。

  /// 为什么走 prompt 而不是让 App 自己问：App 主动发起的提问没有对应的
  /// assistant `tool_calls`，而挂起恢复是把答案当 `role: tool` 回灌、要用
  /// `toolCallId` 对上那条消息 —— App 伪造提问会让整条请求被协议拒绝。
  /// 让**模型自己**调 `askUser` 就没有这个问题，恢复路径一行都不用改。
  static String _budgetNotice(int used, int budget) {
    if (budget - used > 2) return '';
    final left = budget - used;
    return '\n\n## 轮数提醒\n'
        '已经用了 $used 轮，最多 $budget 轮（还剩 $left 轮）。\n'
        '- 任务还没做完：调 askUser 问用户要不要继续（**说清继续会再发生一次调用费用**）；'
        '用户同意后上限会 +${AgentLimits.roundExtension} 轮（最多 ${AgentLimits.maxRoundsHard} 轮）。\n'
        '- 已经做完：直接给结论，并在同一轮调 finish(…) 收尾。';
  }
  /// 这一轮真正发给模型的 system prompt。
  ///
  /// 重拼失败（比如读 app_kv 出错）**不打断对话**：退回固定段继续跑 ——
  /// AI 顶多少看到几条函数详情（那几条它照样能调，只是没有内联的用法说明），
  /// 而把整轮对话炸掉是另一回事，代价完全不对等。
  static Future<String> _promptFor(
    String base,
    Future<String> Function()? rebuild,
  ) async {
    if (rebuild == null) return base;
    try {
      return await rebuild();
    } catch (_) {
      return base;
    }
  }

  /// 精简末尾所有连续的 tool 消息（一轮可能有多个 tool_calls）。
  ///
  /// 在 add 新的 assistant(tool_calls) **之前**调用——此时末尾是上一轮的 tool 结果。
  /// 从后往前扫，遇到非 tool 就停。
  ///
  /// 效果：tool 结果从
  ///   {"ok":true,"data":[{"id":"n1","title":"…三千字…"}]}
  /// 压成
  ///   {"ok":true,"data":"⟪系统压缩：省略 2900 字⟫"}
  /// 保留 JSON 结构，AI 知道"发生了什么"，只是不记得具体内容。
  void _slimLastToolResults(List<AgentMessage> messages) {
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.role != 'tool' || m.toolCallId == null) break;
      messages[i] = AgentMessage.tool(
        toolCallId: m.toolCallId!,
        content: _compressToolResult(m.content),
      );
    }
  }
  
  /// 精简**最后一个** assistant(tool_calls) 的 arguments。
  ///
  /// 在 add 新的 assistant(tool_calls) **之后**调用——压缩刚加的那个。
  ///
  /// 效果：query 从
  ///   INSERT INTO notes (...) VALUES ('n1', 'nb1', '三千字正文', ...)
  /// 压成
  ///   左 35 字⟪系统压缩：省略 N 字⟫右 35 字
  /// 保留 SQL 结构，AI 知道在做什么，只是不记得具体参数。
  void _slimToolCalls(List<AgentMessage> messages) {
    final i = messages.lastIndexWhere(
      (m) => m.role == 'assistant' && m.toolCalls.isNotEmpty,
    );
    if (i < 0) return;
  
    final m = messages[i];
    messages[i] = AgentMessage(
      role: m.role,
      content: m.content,
      toolCalls: [
        for (final c in m.toolCalls)
          ToolCall(
            id: c.id,
            name: c.name,
            arguments: _compressSqlArgs(c.arguments),
          ),
      ],
    );
  }
  
  /// arguments 是 JSON 字符串 `{"query": "SELECT ..."}`。
  /// 解析出 query，压缩中间部分，再拼回 JSON。
  ///
  /// 解析失败（不是 JSON、缺 query 字段）就不动——不做多余处理。
  String _compressSqlArgs(String args) {
    try {
      final map = jsonDecode(args) as Map<String, dynamic>;
      final query = map['query'];
      if (query is String) {
        map['query'] = _compressMiddle(query);
      }
      return jsonEncode(map);
    } catch (_) {
      return args;
    }
  }
  /// 压缩 tool result 的 content：
  /// 解析 JSON，只压缩 `data` 字段，其他字段（ok / description 等）原样保留。
  ///
  /// 例：
  ///   {"ok":true,"description":"查询了笔记库","data":[{...三千字...}]}
  ///   →
  ///   {"ok":true,"description":"查询了笔记库","data":"...省略 2900 字..."}
  ///
  /// 不是 JSON（UDF 直接返回文本）就整体用 _compressMiddle。
  String _compressToolResult(String content) {
    try {
      final map = jsonDecode(content) as Map<String, dynamic>;
      if (map.containsKey('data')) {
        map['data'] = _compressMiddle(jsonEncode(map['data']));
      }
      return jsonEncode(map);
    } catch (_) {
      return _compressMiddle(content);
    }
  } 
  /// 保留开头和结尾各 [keep] 字符，中间压成标记。
  ///
  /// 为什么不做正则匹配"单引号字符串"：SQL / JSON / 纯文本结构各异，
  /// 真正有信息量的是**开头**（操作类型、表名、关键字段）
  /// 和**结尾**（WHERE 条件、主要参数）——中间的大段内容压掉即可。
  ///
  /// 省得少就不压（`omitted < 80`）：为省几十个字符插一个标记，
  /// 反而让模型分神、还可能误以为内容被砍掉。
  static String _compressMiddle(String text, {int keep = 35}) {
    final omitted = text.length - keep * 2;
    if (omitted < 80) return text;
    return '${text.substring(0, keep)}'
        '⟪系统压缩：省略 $omitted 字⟫'
        '${text.substring(text.length - keep)}';
  }

  /// 解析 `askUser` 的参数。缺关键字段返回 null（调用方给模型一句可读的抱怨）。
  static AskRequest? _parseAsk(ToolCall call) {
    final args = ToolExecutor.parseArgs(call.arguments);
    final question = args['question'];
    if (question is! String || question.trim().isEmpty) return null;
    final type = AskType.parse(args['type']);
    if (type == null) return null;

    final options = <AskOption>[];
    final raw = args['options'];
    if (raw is List) {
      for (final o in raw.take(10)) {
        final parsed = AskOption.tryParse(o);
        if (parsed != null) options.add(parsed);
      }
    }

    final limitRaw = args['limit'];
    final limit = limitRaw is int ? limitRaw.clamp(1, 10) : 10;

    return AskRequest(
      question: question.trim(),
      type: type,
      options: options,
      source: AskSource.tryParse(args['source']),
      defaultValue: args['default'] is String ? args['default'] as String : null,
      limit: limit,
    );
  }
}
