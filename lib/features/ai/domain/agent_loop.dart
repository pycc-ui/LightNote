import '../../../core/db/app_database.dart';
import '../../../core/db/models.dart';
import 'ask_user.dart';
import 'tool_executor.dart';
import 'tool_specs.dart';
import 'tool_types.dart';

/// **一次**模型调用的抽象。
///
/// 生产实现就是 `DeepSeekClient.streamAgent`。抽成函数类型是为了让整条循环
/// **在测试里跑得起来**：换一个假实现，就能验证"多轮 / 回灌 / 申请工具 /
/// 终止条件"这些最容易写错的地方，而不用真的花 API 额度。
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

/// 开始执行某个工具（UI 可以显示"正在搜索…"）
class AgentToolStarted extends AgentEvent {
  const AgentToolStarted(this.name);
  final String name;
}

/// 某个工具执行完了
class AgentToolDone extends AgentEvent {
  const AgentToolDone(this.name, {required this.ok});
  final String name;
  final bool ok;
}

/// 模型申请了更多工具，[approved] 是这次批准的
class AgentToolsGranted extends AgentEvent {
  const AgentToolsGranted(this.approved);
  final List<String> approved;
}

/// 模型要问用户，循环**停在这里**等回答。
///
/// 阶段 6 会把这条待答的调用写进 `ai_messages.pendingAction`，
/// 用户回答之后再从这里恢复 —— 所以事件里带着 [toolCallId]。
class AgentAwaitingUser extends AgentEvent {
  const AgentAwaitingUser({
    required this.request,
    required this.toolCallId,
    this.asks = 1,
    this.messages = const [],
  });
  final AskRequest request;
  final String toolCallId;

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
  const AgentFailed(this.message, {this.usage = const AgentUsage()});
  final String message;
  final AgentUsage usage;
}

// ============================================================================
// 循环
// ============================================================================

/// **多轮工具调用循环**：提工具 → 执行 → 回灌 → 再发一轮，直到它不再提。
///
/// ## 三条终止条件（缺一个都会挂死）
///
/// 1. 模型这一轮**没提工具** → 正常结束
/// 2. `askUser` → 停下来等用户（阶段 6 恢复）
/// 3. **轮数上限** [maxRounds] → 强行结束
///
/// 第 3 条不是防御性代码而是必需品：模型有可能每次都提一个必然失败的工具
/// （参数一直写错、id 一直是编的），没有上限就是**无限烧钱**。
class AgentLoop {
  const AgentLoop({required this.round, required this.executor});

  final AgentRoundFn round;
  final ToolExecutor executor;

  /// 一轮用户输入最多允许几轮工具往返
  static const maxRounds = 6;

  /// `requestTools` 单次最多批几个（协议里定的）
  static const maxRequestTools = 5;

  /// 一轮用户输入里 `askUser` 最多问几次。
  ///
  /// **必须封顶**：模型完全可能"问一句 → 拿不到满意答案 → 再问一句"地循环下去，
  /// 而每次都要等用户动手。用户被问第三次时已经烦了，第四次就会直接关掉。
  /// 到上限后强制收尾，让它用现有信息回答。
  static const maxAsksPerTurn = 3;

  /// 跑一轮。 [history] 必须**已经包含**本轮的用户输入。
  ///
  /// [dbHistory] 只有 `listHistory` / `readHistory` 用得到：那是本会话存下来的
  /// 消息行，工具的活数据在调用方手里。
  Stream<AgentEvent> run({
    required String systemPrompt,
    required List<AgentMessage> history,
    List<AiMessage> dbHistory = const [],
    int asksSoFar = 0,
  }) async* {
    final messages = List<AgentMessage>.from(history);
    final granted = <String>{};
    var tools = specsForRequest(granted: granted);
    final answer = StringBuffer();
    var usage = const AgentUsage();
    // ⚠️ 从 [asksSoFar] 起算：挂起恢复时调用方会把已经问过的次数带回来
    var asks = asksSoFar;

    for (var roundNo = 0; roundNo < maxRounds; roundNo++) {
      executor.beginTurn();

      // ---- 一次请求 ----
      var text = '';
      var calls = const <ToolCall>[];
      var errored = false;

      await for (final e in round(
        systemPrompt: _systemWithCatalog(systemPrompt, granted),
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
          case AiError(:final message):
            if (text.trim().isNotEmpty) answer.write(text);
            yield AgentFailed(message, usage: usage);
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
      messages.add(AgentMessage.assistant(text, toolCalls: calls));
      // 工具轮里模型偶尔会先垫一句（"我先查一下"）。写进回答让用户看到进度，
      // 但**不算进最终回答的正文**——它和结论之间要隔开。
      if (text.trim().isNotEmpty) answer.write('${text.trim()}\n\n');

      for (final call in calls) {
        // `requestTools` 不碰数据，由循环自己处理（它要改 tools 列表）
        if (call.name == 'requestTools') {
          final (approved, result) = _grant(call, granted);
          if (approved.isNotEmpty) {
            tools = specsForRequest(granted: granted);
            yield AgentToolsGranted(approved);
          }
          messages.add(
            AgentMessage.tool(toolCallId: call.id, content: result.encode()),
          );
          continue;
        }

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
          );
          return;
        }

        yield AgentToolStarted(call.name);
        final result = await executor.execute(
          call.name,
          ToolExecutor.parseArgs(call.arguments),
          history: dbHistory,
        );
        yield AgentToolDone(call.name, ok: result.ok);
        messages.add(
          AgentMessage.tool(toolCallId: call.id, content: result.encode()),
        );
      }
    }

    // 轮数用尽：把已经拿到的内容交出去，并明说可能没查完
    yield AgentFailed(
      '工具调用轮数达到上限（$maxRounds 轮），已停止。'
      '${answer.isEmpty ? '' : '下面是已经拿到的部分内容。'}',
      usage: usage,
    );
  }

  /// system prompt 末尾附上"还没发给你的工具目录"。
  ///
  /// 只列**按需层且没批准过的**：核心层与常用层的完整定义已经在 `tools` 里了，
  /// 再列一遍是重复占 token。
  static String _systemWithCatalog(String base, Set<String> granted) {
    final catalog = toolCatalogText(granted: granted);
    return catalog.isEmpty ? base : '$base\n\n$catalog';
  }

  /// 处理 `requestTools`。返回（这次批准的，给模型的回执）。
  (List<String>, ToolResult) _grant(ToolCall call, Set<String> granted) {
    final raw = ToolExecutor.parseArgs(call.arguments)['names'];
    final names = raw is List ? raw.map((x) => '$x').toList() : const <String>[];
    if (names.isEmpty) {
      return (
        const [],
        ToolResult.failure('requestTools 需要 `names`（工具名数组）。'),
      );
    }

    final approved = <String>[];
    final rejected = <String>[];
    for (final n in names.take(maxRequestTools)) {
      final tool = toolByName(n);
      if (tool == null) {
        rejected.add('$n（没有这个工具）');
        continue;
      }
      if (granted.contains(n) || tool.layer != ToolLayer.onDemand) {
        // 核心/常用层本来就有完整定义，再申请是浪费一轮往返
        rejected.add('$n（已经有了，不用申请）');
        continue;
      }
      granted.add(n);
      approved.add(n);
    }

    return (
      approved,
      ToolResult.success({
        'approved': approved,
        'rejected': rejected,
        if (approved.isEmpty)
          'hint': '这次没有批准任何新工具。已有的工具里挑一个用，或者直接回答用户。'
        else
          'hint': '新工具的完整定义已经给你了，现在可以调用它们。',
      }),
    );
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
