import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/models.dart';
import '../data/deepseek_client.dart';
import '../data/deepseek_config.dart';
import 'agent_loop.dart';
import 'agent_workspace.dart';
import 'ai_repository.dart';
import 'ask_user.dart';
import 'tool_executor.dart';
import 'tool_types.dart';
import 'prompts.dart';

/// AI 会话仓储：把《界面设计》里「AI 助手页」那一屏（工作区 / 思考强度 / 选择文件 / 指令）
/// 接到真实 DeepSeek 调用上，并持久化会话历史。
///
/// 隐私设计：
/// 2. 每次请求只发送**用户显式选中**的笔记正文，不做全库上传；
/// 3. 未选中任何文件时，只发送用户当前这条指令，不带笔记内容；
/// 4. 授权状态与「本次发送包含哪些笔记」都在 UI 上明示。
class AiChatRepository {
  AiChatRepository({required AppDatabase db, required AiRepository ai})
      : _db = db,
        _ai = ai;

  final AppDatabase _db;
  final AiRepository _ai;
  final _uuid = const Uuid();

  /// **写操作的确认入口**，由 UI 设置（它需要 `BuildContext` 才能弹层）。
  ///
  /// 为 null 时写操作**一律拒绝**（执行器 fail closed）——
  /// 反过来"默认放行"意味着漏接一次就等于"AI 能随便改用户的数据"。
  ToolConfirmFn? onConfirm;

  /// 最近一次跑循环用的执行器：撤销靠它（撤销栈在执行器里）。
  ToolExecutor? _lastExecutor;

  /// 有没有可撤销的写操作（UI 拿它决定要不要显示「撤销」）。
  ({String noteId, String title})? get undoable => _lastExecutor?.undoable;

  /// 撤销最近一次 AI 写操作。
  Future<String?> undoLast() async => _lastExecutor?.undoLast();


  /// 单次请求最多带入的笔记条数，防止一次点满导致费用失控
  static const maxContextNotes = 8;

  /// 单条笔记带正文的上限字符数
  static const maxCharsPerNote = 6000;

  /// 自动带的历史**轮数**（一轮 = 一问一答）。
  ///
  /// **必须钉死**：历史是每条消息都重发的，不设上限就是 `O(N²)` ——
  /// 聊得越久每条越贵。钉死之后总成本回到 `O(N)`。
  /// 5 轮足够覆盖"接着说""上面那个"这类指代。
  static const maxHistoryRounds = 5;

  /// 历史里**单条**消息的截断上限。
  ///
  /// 长的历史回答不原样重发 —— 那是纯浪费，模型只需要知道"刚才聊到哪"。
  /// 真要那段内容，它该去调 `readHistory`。
  static const maxHistoryChars = 500;

  AiRepository get ai => _ai;

  // ---------------------------------------------------------------------------
  // 会话
  // ---------------------------------------------------------------------------

  Stream<List<AiConversation>> watchConversations() =>
      _db.watchConversations();

  Stream<List<AiMessage>> watchMessages(String conversationId) =>
      _db.watchMessages(conversationId);

  Future<AiConversation> createConversation({
    AgentWorkspace workspace = AgentWorkspace.initial,
    String thinkingEffort = 'medium',
  }) async {
    final now = DateTime.now().toUtc();
    final id = _uuid.v4();
    await _db.upsertConversation(AiConversationsCompanion.insert(
      id: id,
      workspaceScope: Value(workspace.encode()),
      thinkingEffort: Value(thinkingEffort),
      title: const Value(''),
      createdAt: now,
      updatedAt: now,
    ));
    return (await _db.getConversation(id))!;
  }

  /// 写入这个会话的工作区（**AI 能看到哪些笔记**）。
  ///
  /// 存 JSON 而不是一个笔记库 id：工作区有三态（不选择 / 全体空间 / 选择目录），
  /// 而"选择目录"还能多选、并单独决定要不要带上「我的轻笔记」。
  Future<void> setWorkspace(
    String conversationId,
    AgentWorkspace workspace,
  ) async {
    await (_db.update(_db.aiConversations)
          ..where((t) => t.id.equals(conversationId)))
        .write(AiConversationsCompanion(
      workspaceScope: Value(workspace.encode()),
      updatedAt: Value(DateTime.now().toUtc()),
    ));
  }

  Future<void> setThinkingEffort(String conversationId, String effort) async {
    await (_db.update(_db.aiConversations)
          ..where((t) => t.id.equals(conversationId)))
        .write(AiConversationsCompanion(
      thinkingEffort: Value(effort),
      updatedAt: Value(DateTime.now().toUtc()),
    ));
  }
  /// 删会话时**顺手清掉它的历史摘要**。
  ///
  /// `app_kv` 里的派生数据不会跟着外键走，不清就是一条永远读不到的垃圾
  ///（会话 id 是 uuid，永远撞不上同一条）。
  Future<void> deleteConversation(String id) => deleteConversations([id]);

  /// 批量删除会话（会话记录页的「多选 → 删除」用它）。
  ///
  /// 与单条删除**共用一条路径**：单条也走这里，所以"顺手清历史摘要"这件事
  /// 不可能只在一处生效。删行本身是一条 `WHERE id IN (...)`，
  /// 而 `app_kv` 里的摘要 key 只能逐个删（它是文本 key，没有外键）。
  ///
  /// **不可恢复**：没有回收站，也没有撤销 —— 所以调用方（UI）必须先让用户确认。
  /// 返回真正删掉的条数，供提示文案用。
  Future<int> deleteConversations(Iterable<String> ids) async {
    final list = ids.toList(growable: false);
    if (list.isEmpty) return 0;

    await _db.transaction(() async {
      for (final id in list) {
        await _db.deleteSetting('$summaryKeyPrefix$id');
      }
      await _db.deleteConversations(list);
    });
    return list.length;
  }
  // ---------------------------------------------------------------------------

  /// 发送一条指令。
  ///
  /// [contextNoteIds] 是用户在「+ → 选择文件」里显式挑选的笔记；
  /// 为空时**不附带任何笔记正文**。
  /// 返回助手消息的 id，UI 可以监听该条消息的流式更新。
  Future<String> send({
    required String conversationId,
    required String userInput,
    required List<String> contextNoteIds,
    required String thinkingEffort,
    required bool thinkingEnabled,
  }) async {
    final now = DateTime.now().toUtc();

    // 1) 落用户消息
    await _db.insertAiMessage(AiMessagesCompanion.insert(
      id: _uuid.v4(),
      conversationId: conversationId,
      role: 'user',
      content: Value(userInput),
      createdAt: now,
    ));

    // 2) 首条用户消息作为会话标题
    final conv = await _db.getConversation(conversationId);
    if (conv != null && conv.title.trim().isEmpty) {
      final title = userInput.length > 20
          ? '${userInput.substring(0, 20)}…'
          : userInput;
      await _db.touchConversation(conversationId, title: title);
    }

    // 3) 组装上下文：只带用户显式选中的笔记
    final contexts = <String>[];
    for (final id in contextNoteIds.take(maxContextNotes)) {
      final note = await _db.getNote(id);
      if (note == null) continue;
      final body = note.content.length > maxCharsPerNote
          ? '${note.content.substring(0, maxCharsPerNote)}…'
          : note.content;
      contexts.add(
        '《${note.title.trim().isEmpty ? '无标题' : note.title.trim()}》\n$body',
      );
    }

    // 工作区从**会话记录**读 —— 它是唯一真相，调用方不用再传一遍。
    final workspace = AgentWorkspace.parse(conv?.workspaceScope);
    final workspaceLabel = await _workspaceLabelOf(workspace);

    // 4) 落助手占位消息，拿到 id 供流式更新
    final assistantId = _uuid.v4();
    await _db.insertAiMessage(AiMessagesCompanion.insert(
      id: assistantId,
      conversationId: conversationId,
      role: 'assistant',
      content: const Value(''),
      createdAt: DateTime.now().toUtc(),
    ));

    // 5) 组装 agent 历史
    //
    //    ⚠️ 工具的中间往来（assistant 的 `tool_calls` 与 `role: tool` 的结果）
    //    **不落库** —— 它们是本轮的临时上下文。跨轮要回看更早的内容时走
    //    `listHistory` / `readHistory` 这两个工具，它们读的正是 `ai_messages`。
    //    这也解释了设计里为什么要有这两个工具：会话历史本来就存在这张表里。
    final rows = await _db.watchMessages(conversationId).first;
    final history = historyWindowOf(rows);
    // 窗口之外的更早轮次：压成一段背景摘要拼进 system prompt
    //（**只生成一次**，之后每轮直接读库；见 `_olderHistorySummary`）
    final summary =
        await _olderHistorySummary(conversationId, olderHistoryOf(rows));

    // 本轮的**显式选中笔记**附在最后一条用户消息上。
    //
    // 落库的只有用户原话（干净、列表里好读），附带的正文只发给模型 ——
    // 两者在同一条消息里会让人以为"用户打了这么多字"。
    if (contexts.isNotEmpty && history.isNotEmpty && history.last.role == 'user') {
      history[history.length - 1] =
          AgentMessage.user(AiPrompts.agentUser(userInput, contexts));
    }

    // 6) 跑 Agent 循环：提工具 → 执行 → 回灌 → 再问，直到它不再提工具
    await _drive(
      conversationId: conversationId,
      assistantId: assistantId,
      systemPrompt: withSummary(AiPrompts.agentSystem(workspaceLabel), summary),
      history: history,
      dbHistory: rows,
      thinkingEnabled: thinkingEnabled,
      thinkingEffort: thinkingEffort,
      workspace: workspace,
      append: false,
    );

    await _db.touchConversation(conversationId);
    return assistantId;
  }

  // ===========================================================================
  // askUser：持久化挂起与恢复
  // ===========================================================================

  /// 当前**正在等回答**的提问；没有就返回 null。
  ///
  /// 从库里读（不是内存）：所以冷启动之后、切走再回来之后，都还能把
  /// 那张答题卡重新显示出来。
  Future<PendingAsk?> pendingAsk(String conversationId) async {
    final row = await _db.pendingAskMessage(conversationId);
    return PendingAsk.tryParse(row?.pendingAction);
  }

  /// 回答挂起中的提问，**继续**这一轮对话。
  ///
  /// 返回被续写的那条助手消息 id（UI 还在监听它）。
  ///
  /// 流程与《AI接入设计》的「挂起机制：askUser」一节一致：
  /// 把用户的选择作为 `role: tool` 的结果回灌，
  /// 然后从**提问那一刻的对话**接着跑 —— 中间的工具往来在
  /// [PendingAsk.messages] 里存着，所以重启也不影响。
  Future<String?> answerAsk({
    required String conversationId,
    required AskResult result,
    required String thinkingEffort,
    required bool thinkingEnabled,
  }) async {
    final row = await _db.pendingAskMessage(conversationId);
    if (row == null) return null;
    final pending = PendingAsk.tryParse(row.pendingAction);
    if (pending == null) {
      // 记录坏了：清掉，别让会话永远卡在"等回答"
      await _db.setPendingAction(row.id, null);
      return null;
    }

    // 先把挂起清掉（与"回灌结果"同一事务，见下）—— 用户只该答一次
    final history = <AgentMessage>[
      ...pending.messages,
      AgentMessage.tool(
        toolCallId: pending.toolCallId,
        // ⚠️ 两件事都别做错：
        //   · `encode()` 已经是 JSON 字符串，**不要再 jsonEncode 一次**
        //     （双重编码会让模型看到一段字符串化的 JSON，而不是结果本身）
        //   · 但要**包成 `ToolResult` 的形状**（`{ok, data}`）—— 模型见到的
        //     所有工具结果都长一样，它才不会因为某一个是"裸对象"而误判
        content: ToolResult.success(jsonDecode(result.encode())).encode(),
      ),
    ];

    // 工作区从**会话记录**读 —— 它是唯一真相，调用方不用再传一遍。
    final workspace = AgentWorkspace.parse(
        (await _db.getConversation(conversationId))?.workspaceScope);
    final workspaceLabel = await _workspaceLabelOf(workspace);

    final rows = await _db.watchMessages(conversationId).first;
    // 恢复时也带上更早历史的摘要（同一个键，读到的是同一份，不会重复生成）
    final summary =
        await _olderHistorySummary(conversationId, olderHistoryOf(rows));

    await _db.transaction(() async {
      // 清挂起 + 把"（等你回答）"换成正式内容，**同一个事务**：
      // 分两步做的话，中间崩一次就会留下"没有挂起记录、但也没继续跑"的死会话。
      await _db.setPendingAction(row.id, null);
      await _db.updateAiMessage(row.id, row.content);
    });

    await _drive(
      conversationId: conversationId,
      assistantId: row.id,
      systemPrompt: withSummary(AiPrompts.agentSystem(workspaceLabel), summary),
      history: history,
      dbHistory: rows,
      thinkingEnabled: thinkingEnabled,
      thinkingEffort: thinkingEffort,
      workspace: workspace,
      // 续写：用户已经看到"（等你回答）"，接下来的输出接在它后面
      append: true,
      asksSoFar: pending.asks,
    );

    await _db.touchConversation(conversationId);
    return row.id;
  }

  /// 跑一次 [AgentLoop] 并把事件写进 [assistantId] 这条消息。
  ///
  /// [append] 决定新文字是**替换**还是**接在**消息现有内容后面：
  /// 新一轮对话是替换，回答挂起后继续是接在后面。
  Future<void> _drive({
    required String conversationId,
    required String assistantId,
    required String systemPrompt,
    required List<AgentMessage> history,
    required List<AiMessage> dbHistory,
    required bool thinkingEnabled,
    required String thinkingEffort,
    required AgentWorkspace workspace,
    required bool append,
    int asksSoFar = 0,
  }) async {
    // ---- 续写起点：**在本次 run 开始时就定死** ----
    //
    // ⚠️ 这里曾经不是这样：`_write` 每写一次都**重新读一遍行内容**再拼
    // （`before + '\n\n' + text`），而流式事件送进来的 `text` 是**整段的累计文本**。
    // 于是第 k 个分片会把前 k-1 个分片再写一遍 —— 一段 700 字的回答能滚成
    // 几十 KB 的重复：用户看到的是一句话按字数递增地重复上百遍
    // （"已/已删/已删除/已删除，/…"这种锯齿），越流式越明显。
    //
    // 正确的形状是：起点固定，每次写入都写成「起点 + 本次已产生的文本」，
    // 也就是**替换**而不是接龙。这样重复写入同一个文本是幂等的。
    final base = append
        ? _baseForAppend((await _db.aiMessageById(assistantId))?.content ?? '')
        : '';

    /// 写入"本次 run 已经产生的文本"（[base] 之后的部分）。
    Future<void> writeText(String text) =>
        _db.updateAiMessage(assistantId, _joined(base, text));

    // 记下来：撤销要靠它（撤销栈在执行器里）。
    // 确认回调也从这里传进去 —— 没接上时执行器会**拒绝**全部写操作。
    final executor = ToolExecutor(
      _db,
      onConfirm: onConfirm,
      // ★ 工作区在这里生效：AI 的 searchNotes / listNotes 只能看到这个范围
      workspace: workspace,
    );
    _lastExecutor = executor;

    final loop = AgentLoop(
      round: ({
        required String systemPrompt,
        required List<AgentMessage> messages,
        required List<ToolSpec> tools,
      }) =>
          _ai.client.streamAgent(
        systemPrompt: systemPrompt,
        messages: messages,
        tools: tools,
        model: DeepSeekConfig.modelFlash,
        thinking: thinkingEnabled,
        reasoningEffort: thinkingEffort,
      ),
      executor: executor,
    );

    final buffer = StringBuffer();
    await for (final event in loop.run(
      systemPrompt: systemPrompt,
      history: history,
      dbHistory: dbHistory,
      asksSoFar: asksSoFar,
    )) {
      switch (event) {
        case AgentText(:final delta):
          buffer.write(delta);
          // ⚠️ 写的是**累计文本**（`buffer.toString()`），不是 `delta` ——
          // 因为 `writeText` 是"替换式"写入，字幕才会一段段长出来而不是拼接。
          await writeText(buffer.toString());

        case AgentFinished(:final text, :final usage):
          await writeText(text);
          await _log(usage, thinkingEnabled: thinkingEnabled, success: true);

        case AgentAwaitingUser(
            :final request,
            :final toolCallId,
            :final asks,
            :final messages
          ):
          // 挂起：把"等回答"写进**数据库**（不是内存状态），
          // 用户随时回答 —— 哪怕重启 App 之后。
          //
          // ⚠️ 消息内容与挂起记录**同一个事务**：分开写的话，
          // 中间崩一次会留下"有挂起记录但没有问题文本"（用户看到空白卡片）
          // 或者"有问题文本但已挂起失效"（点了没反应）。两种都很难查。
          final said = _joined(base, buffer.toString());
          await _db.transaction(() async {
            await _db.updateAiMessage(
              assistantId,
              said.isEmpty ? awaitingPlaceholder : said,
            );
            await _db.setPendingAction(
              assistantId,
              PendingAsk(
                toolCallId: toolCallId,
                request: request,
                // ⚠️ 用**事件带回来的** messages，不是 `_drive` 收到的 `history`：
                // 后者是这一轮开始前的对话，缺了本轮的工具往来。
                // 用错的话用户回答完就没法接着跑（实测踩到）。
                messages: messages,
                asks: asks,
              ).encode(),
            );
          });

        case AgentFailed(:final message, :final usage):
          await writeText(
            buffer.isEmpty ? '⚠️ $message' : '${buffer.toString()}\n\n⚠️ $message',
          );
          await _log(usage, thinkingEnabled: thinkingEnabled, success: false);

        case AgentToolStarted():
        case AgentToolDone():
        case AgentToolsGranted():
          break; // 工具活动不写进正文（进度由 UI 的 LogBar 承担）
      }
    }
  }

  /// 助手消息里"正在等用户回答"的占位内容。
  ///
  /// 它**不是内容**：续写开始时要用真正的输出把它顶掉，而判断"这一行还是占位符"
  /// 只能靠认这个字符串 —— 所以抽成常量。写死两处的话，改一处漏一处就会出现
  /// "（等你回答）这几个字永远粘在回答开头"。
  static const awaitingPlaceholder = '（等你回答）';

  /// 续写模式下，把"行里已有的内容"翻译成**续写起点**。
  ///
  /// 只有一种情况要当空：行里还是 [awaitingPlaceholder]（AI 只是提了个问题、
  /// 还没说任何话）。那时续写的输出应当**顶掉**占位符，而不是接在它后面 ——
  /// 否则回答会以"（等你回答）"开头。
  static String _baseForAppend(String rowContent) =>
      rowContent == awaitingPlaceholder ? '' : rowContent;

  /// 「续写起点 + 本次已产生的文本」。两段之间空一行（与工具轮的垫话同一套观感）。
  static String _joined(String base, String text) {
    if (base.isEmpty) return text;
    if (text.isEmpty) return base;
    return '$base\n\n$text';
  }

  /// 把整轮的**累计**用量记进审计表。
  ///
  /// 多轮之后一次用户输入会有多次 API 调用，所以这里记的是累计值 ——
  /// 只记最后一次会让"工具用得越多、成本越低"这种假象出现。
  Future<void> _log(
    AgentUsage usage, {
    required bool thinkingEnabled,
    required bool success,
  }) =>
      _ai.logChatCall(
        model: DeepSeekConfig.modelFlash,
        thinking: thinkingEnabled,
        promptTokens: usage.promptTokens,
        completionTokens: usage.completionTokens,
        costCents: usage.costCents,
        latencyMs: usage.latencyMs,
        success: success,
      );

  // ===========================================================================
  // 历史窗口
  // ===========================================================================

  /// 从本会话**全部**消息里取出"自动带的那一段"。
  ///
  /// 规则（见《AI接入设计》的「会话历史：切片、窗口、摘要」一节）：
  ///   · 最近 [maxHistoryRounds] 轮（一轮 = 一问一答）
  ///   · 单条截断 [maxHistoryChars] 字
  ///   · 上一轮的**工具结果不重发** —— 它们本来就不落库，这里天然满足；
  ///     要让模型回看更早的内容，它该去调 `readHistory`
  ///
  /// 提成纯函数是为了单独测得到：这条规则直接决定**每条消息的成本**，
  /// 写错了会随着聊天变长越来越贵，而且**不会报错**。
  static List<AgentMessage> historyWindowOf(
    List<AiMessage> rows, {
    int rounds = maxHistoryRounds,
    int maxChars = maxHistoryChars,
  }) {
    final usable = [
      for (final m in rows)
        if (m.content.trim().isNotEmpty) m,
    ];
    if (usable.isEmpty) return const [];

    // 从后往前数第 `rounds` 个 user 消息，从它开始带
    var seen = 0;
    var start = 0;
    for (var i = usable.length - 1; i >= 0; i--) {
      if (usable[i].role != 'user') continue;
      start = i;
      seen++;
      if (seen >= rounds) break;
    }

    return [
      for (final m in usable.skip(start))
        if (m.role == 'user')
          AgentMessage.user(_clipHistory(m.content, maxChars))
        else
          AgentMessage.assistant(_clipHistory(m.content, maxChars)),
    ];
  }

  /// 截断时**明确标出来**：模型看到"…（已截断）"就知道后面还有内容，
  /// 而不是以为当时就说了这么点。
  static String _clipHistory(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}…（已截断）';

  /// 窗口**之外**的那些轮次（要被压成一段摘要的）。
  ///
  /// 与 [historyWindowOf] 严格互补：两者合起来等于全部可用消息，
  /// 一条不多一条不少。分开算两边很容易错位（比如窗口少算了半轮），
  /// 所以两边共用同一个"从第几个 user 开始"的定位逻辑。
  static List<AiMessage> olderHistoryOf(
    List<AiMessage> rows, {
    int rounds = maxHistoryRounds,
  }) {
    final usable = [
      for (final m in rows)
        if (m.content.trim().isNotEmpty) m,
    ];
    if (usable.isEmpty) return const [];
    final start = _windowStart(usable, rounds);
    return usable.take(start).toList(growable: false);
  }

  /// 窗口起点：从后往前数第 [rounds] 个 `user` 消息的下标。
  static int _windowStart(List<AiMessage> usable, int rounds) {
    var seen = 0;
    var start = 0;
    for (var i = usable.length - 1; i >= 0; i--) {
      if (usable[i].role != 'user') continue;
      start = i;
      seen++;
      if (seen >= rounds) break;
    }
    return start;
  }

  // ===========================================================================
  // 更早历史的压缩摘要（规则见《AI接入设计》的「会话历史」一节）
  // ===========================================================================

  /// 摘要存 `app_kv`，键前缀 + 会话 id。
  ///
  /// 为什么不加一列到 `ai_conversations`：那要一次 v11 迁移，
  /// 而这里存的是一条**可以随时重算的派生文本** —— 丢了顶多再花一次调用。
  /// 派生数据不值得为它动表结构。
  static const summaryKeyPrefix = 'ai_history_summary_';

  /// 把更早的轮次压成一段背景摘要。**只生成一次**，之后一直复用。
  ///
  /// ## 为什么"只生成一次"
  ///
  /// 每轮都重新压的话，省下的历史 token 又被这次压缩调用吃回去了 ——
  /// 白忙一场。所以：**生成 → 落库 → 之后每轮直接读**。
  ///
  /// 代价是摘要**不会随着对话继续而更新**（它覆盖的是"生成那一刻更早的内容"）。
  /// 这是刻意的取舍：更新的收益很小，而每轮一次额外调用的成本是确定的。
  /// 真需要更早的细节，模型该去调 `readHistory`。
  Future<String> _olderHistorySummary(
    String conversationId,
    List<AiMessage> older,
  ) async {
    if (older.isEmpty) return '';
    final key = '$summaryKeyPrefix$conversationId';
    final cached = await _db.readSetting(key);
    if (cached != null && cached.trim().isNotEmpty) return cached;

    // 拼成一份"更早的对话"文本（这里**不截断** —— 摘要的目的就是把它压小，
    // 截断会让模型漏掉中间的内容）
    final transcript = StringBuffer();
    for (final m in older) {
      transcript.writeln(m.role == 'user' ? '【用户】${m.content}' : '【我】${m.content}');
    }

    try {
      // 用 `streamChat` 而不是 `AiRepository.ask`：后者是"问我的笔记"那个功能，
      // 它会去检索用户的笔记再回答 —— 拿它压缩对话既跑偏又白花钱。
      // 这里只需要一次朴素的补全。
      final buf = StringBuffer();
      await for (final e in _ai.client.streamChat(
        systemPrompt: '你负责把一段更早的对话压缩成简洁的背景摘要。'
            '只输出摘要正文，不要任何前缀、标题或解释。',
        userPrompt: transcript.toString(),
        model: DeepSeekConfig.modelFlash,
      )) {
        switch (e) {
          case AiChunk():
            buf.write(e.text);
          case AiError(:final message):
            throw DeepSeekException(message);
          case AiDone():
          case AiReasoning():
            break;
        }
      }
      final trimmed = buf.toString().trim();
      if (trimmed.isNotEmpty) {
        await _db.writeSetting(key, trimmed);
        return trimmed;
      }
    } catch (_) {
      // 压缩失败**不该让整轮对话失败**：没有摘要顶多多花点 token
    }
    return '';
  }

  /// 摘要那一段拼进 system prompt 的**末尾**。
  ///
  /// 拼末尾而不是开头：`prompts.dart` 明确写着"绝不要把变化的东西放进
  /// system prompt 开头" —— 前缀一致才命中上下文缓存（输入成本降到约 1/50）。
  static String withSummary(String systemPrompt, String summary) =>
      summary.trim().isEmpty ? systemPrompt : '$systemPrompt\n\n$summary';

  /// 「+ → 选择笔记库」时列出候选笔记：优先工作区，其次全部
  /// 「+ → 选择笔记」的候选列表：**只列工作区内的笔记**。
  ///
  /// 把工作区翻成给用户与模型看的一句话。
  ///
  /// 笔记库被删掉之后，标签里不该还留着一个 uuid —— 查不到名字的直接丢掉。
  Future<String> _workspaceLabelOf(AgentWorkspace w) async {
    if (w.mode == WorkspaceMode.none) return '';
    final all = await _db.allNotebooks();
    final byId = {for (final n in all) n.id: n.name};
    return w.label((id) => byId[id]);
  }

  /// 「+ → 选择笔记」的候选列表：**只列工作区内的笔记**。
  ///
  /// ⚠️ 旧实现是"这个库里没有就返回全部笔记"—— 那会**越出工作区**，
  /// 用户选了"工作"却在候选里看到别的库的笔记。范围必须是硬边界。
  Future<List<Note>> candidateNotes(AgentWorkspace workspace) async {
    final scope = workspace.resolve();
    return _db.notesInScope(
      notebookIds: scope.notebookIds,
      includeUnfiled: scope.includeUnfiled,
    );
  }
}
