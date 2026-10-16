import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/models.dart';
import '../../../core/util/app_params.dart';
import '../data/deepseek_client.dart';
import '../data/deepseek_config.dart';
import 'agent_loop.dart';
import 'ai_model.dart';
import 'ai_repository.dart';
import 'ask_user.dart';
import 'tool_executor.dart';
import 'tool_types.dart';
import 'prompts.dart';
import 'result_applier.dart';

/// AI 会话仓储：把《界面设计》里「AI 助手页」那一屏（模型 / 思考强度 / 指令）
/// 接到真实 DeepSeek 调用上，并持久化会话历史。
///
/// ⚠️ 「工作区」已取消：AI 现在能看到用户的**全部**笔记（一条 SQL 就能查遍整个库）。
/// 原先选工作区的位置改成**选模型**（flash / pro）。
///
/// 隐私设计：
/// 每次请求只发送**用户这句话本身**（+ 最近几轮对话）；App **不主动附带任何笔记正文**，
/// 也不做全库上传。需要笔记内容时，由 AI 自己在 SQL 里用 search_notes / read_around
/// 按需读取，读到的片段只在该轮的工具结果里回灌。
class AiChatRepository {
  AiChatRepository({required AppDatabase db, required AiRepository ai})
      : _db = db,
        _ai = ai;

  final AppDatabase _db;
  final AiRepository _ai;
  final _uuid = const Uuid();


  /// 自动带的历史**轮数**（一轮 = 一问一答）。
  ///
  /// 必须钉死：历史是每条消息都重发的，不设上限就是 `O(N²)` ——
  /// 聊得越久每条越贵。钉死之后总成本回到 `O(N)`。
  /// 5 轮足够覆盖"接着说""上面那个"这类指代。
  static const maxHistoryRounds = AgentLimits.maxHistoryRounds;

  /// 历史里**单条**消息的截断上限。
  ///
  /// 长的历史回答不原样重发 —— 那是纯浪费，模型只需要知道"刚才聊到哪"。
  /// 真要那段内容，它该去调 `readHistory`。
  static const maxHistoryChars = AgentLimits.maxHistoryChars;

  AiRepository get ai => _ai;

  // ---------------------------------------------------------------------------
  // 会话
  // ---------------------------------------------------------------------------

  Stream<List<AiConversation>> watchConversations() =>
      _db.watchConversations();

  Stream<List<AiMessage>> watchMessages(String conversationId) =>
      _db.watchMessages(conversationId);

  /// **当前正在看的会话**（进程内记住，不落库）。
  ///
  /// 为什么放内存而不是 `app_kv`：
  ///   · 要的语义是「冷启动空、页面重建时记住」—— 而「冷启动」就是新进程，
  ///     这个字段天然为空，正好是要的结果；换成 `app_kv` 反而要多一步
  ///     「启动时清 key」，那一步漏了就永远清不掉（而且它本来就不是数据）；
  ///   · 它只是「上次看到哪」，不是笔记内容，不值得一次 IO 加一个要维护的 key。
  ///
  /// ⚠️ 它与「会话列表的第一条」**不是一回事**：列表按 `updated_at` 排，
  /// 排出来的是「最近聊过的」；而用户可能正翻着一条老会话，回来时应该还在那条上。
  String? currentConversationId;

  /// 按 id 取一条会话（`_bootstrap` 用它校验「记住的那条还在不在」）。
  Future<AiConversation?> conversationById(String id) =>
      _db.getConversation(id);

  Future<AiConversation> createConversation({
    String model = AiModel.flash,
    String thinkingEffort = 'medium',
  }) async {
    final now = DateTime.now().toUtc();
    final id = _uuid.v4();
    await _db.upsertConversation(AiConversationsCompanion.insert(
      id: id,
      // 这一列原先是「工作区」的 JSON，现在**复用**为会话选的模型名：
      // 不新增列 / 不改表结构，也就没有迁移与代码生成的负担。
      workspaceScope: Value(model),
      thinkingEffort: Value(thinkingEffort),
      title: const Value(''),
      createdAt: now,
      updatedAt: now,
    ));
    return (await _db.getConversation(id))!;
  }

  /// 写入这个会话选的**模型**（flash / pro）。
  ///
  /// 列名仍是 `workspaceScope`（见 [createConversation] 的说明）。
  Future<void> setModel(String conversationId, String model) async {
    await (_db.update(_db.aiConversations)
          ..where((t) => t.id.equals(conversationId)))
        .write(AiConversationsCompanion(
      workspaceScope: Value(AiModel.parse(model)),
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
  /// 只发用户这句话本身 —— 笔记内容一律由 AI 用 SQL 自己按需读取
  /// （search_notes / read_around），App **不主动附带任何笔记正文**。
  /// 返回助手消息的 id，UI 可以监听该条消息的流式更新。
  Future<String> send({
    required String conversationId,
    required String userInput,
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

    // 3) 模型从**会话记录**读 —— 它是唯一真相，调用方不用再传一遍。
    final model = AiModel.parse(conv?.workspaceScope);

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
    //    **不落库** —— 它们是本轮的临时上下文，跨轮不重发。
    //    落库的只有用户原话与助手回答（`ai_messages`），自动带的是"最近 5 轮"。
    final rows = await _db.watchMessages(conversationId).first;
    final history = historyWindowOf(rows);
    // 窗口之外的更早轮次：压成一段背景摘要拼进 system prompt
    //（**只生成一次**，之后每轮直接读库；见 `_olderHistorySummary`）
    final summary =
        await _olderHistorySummary(conversationId, olderHistoryOf(rows));

    // 6) 跑 Agent 循环：提工具 → 执行 → 回灌 → 再问，直到它不再提工具
    await _drive(
      conversationId: conversationId,
      assistantId: assistantId,
      summary: summary,
      history: history,
      dbHistory: rows,
      thinkingEnabled: thinkingEnabled,
      thinkingEffort: thinkingEffort,
      model: model,
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

    // 模型从**会话记录**读 —— 它是唯一真相，调用方不用再传一遍。
    final model = AiModel.parse(
        (await _db.getConversation(conversationId))?.workspaceScope);

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

    // ---- 预算：用户回答 = 任务还要继续 ----
    //
    // 所以预算 +[AgentLimits.roundExtension]（硬上限兜住）。那多半是模型在
    // "轮数快用完"时问的"要不要继续"，但**不判断问题内容**：
    //   · 猜问题文本不可靠（是模型自己组织的话）；
    //   · 用户会回答一个澄清问题，本身就说明他还想让这件事做完。
    // 用户答"不用了"也不用特殊处理：prompt 要求模型收到否定就直接收尾，
    // 多给的那点预算是"允许"而不是"要求"，它不会自己用掉。
    final baseBudget =
        pending.budget > 0 ? pending.budget : AgentLimits.maxRounds;
    final budget = (baseBudget + AgentLimits.roundExtension)
        .clamp(AgentLimits.maxRounds, AgentLimits.maxRoundsHard);

    await _drive(
      conversationId: conversationId,
      assistantId: row.id,
      summary: summary,
      history: history,
      dbHistory: rows,
      thinkingEnabled: thinkingEnabled,
      thinkingEffort: thinkingEffort,
      model: model,
      // 续写：用户已经看到"（等你回答）"，接下来的输出接在它后面
      append: true,
      asksSoFar: pending.asks,
      roundsUsed: pending.rounds,
      roundBudget: budget,
    );

    await _db.touchConversation(conversationId);
    return row.id;
  }

  /// 跑一次 [AgentLoop] 并把事件写进 [assistantId] 这条消息。
  ///
  /// [append] 决定新文字是**替换**还是**接在**消息现有内容后面：
  /// 新一轮对话是替换，回答挂起后继续是接在后面。
  ///
  /// system prompt 由这里按轮**重拼**（[rebuildPrompt]）：AI 这一轮调
  /// `mark_functions` 之后，下一轮就能看到刚加载的函数详情。
  /// [summary] 是"更早历史"的背景摘要（见 [_olderHistorySummary]）。
  Future<void> _drive({
    required String conversationId,
    required String assistantId,
    required String summary,
    required List<AgentMessage> history,
    required List<AiMessage> dbHistory,
    required bool thinkingEnabled,
    required String thinkingEffort,
    required String model,
    required bool append,
    int asksSoFar = 0,
    int roundsUsed = 0,
    int? roundBudget,
  }) async {
    // ---- 续写起点：**在本次 run 开始时就定死** ----
    //
    // 形状必须是「起点固定，每次写入都写成『起点 + 本次已产生的文本』」，
    // 也就是替换而不是接龙 —— 这样重复写入同一段文本是幂等的。
    //
    // ⚠️ 不能每写一次都重新读一遍行内容再拼（`before + '\n\n' + text`），因为
    // 流式事件送进来的 `text` 是整段的累计文本：那样第 k 个分片会把前 k-1 个
    // 分片再写一遍 —— 一段 700 字的回答能滚成几十 KB 的重复，用户看到的是一句话
    // 按字数递增地重复上百遍（"已/已删/已删除/已删除，/…"这种锯齿）。
    final base = append
        ? _baseForAppend((await _db.aiMessageById(assistantId))?.content ?? '')
        : '';

    /// 写入"本次 run 已经产生的文本"（[base] 之后的部分）。
    Future<void> writeText(String text) =>
        _db.updateAiMessage(assistantId, _joined(base, text));

    // AI 的操作面是**整个库**：一条 SQL 就能读遍或改遍所有笔记。
    // 没有工作区、也没有确认层 —— 约束由 UDF 与 SqlGuard 把关（见 tool_executor.dart）。
    final executor = ToolExecutor(_db);

    /// 每次请求前重拼 prompt（固定段 + 更早历史的摘要）。
    ///
    /// 函数文档现在**全量常驻固定段**（不再有"标记后才加载"那套），
    /// 所以重拼只需要带上摘要 —— prompt 的前缀因此**整轮、整会话都不变**，
    /// 前缀缓存能一直命中。
    Future<String> rebuildPrompt() async =>
        AiPrompts.agentSystemFor(summary: summary);

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
        model: model,
        thinking: thinkingEnabled,
        reasoningEffort: thinkingEffort,
        // **必须显式设**：不设就走服务端默认（聊天模型 4096），模型想写一篇长笔记
        // 会被硬切断 —— 而切断的表现是 JSON 不完整 → 解析失败 → 整轮白跑。
        maxTokens: AgentLimits.maxOutputTokens,
      ),
      executor: executor,
    );

    // 「本轮执行记录」：只收**改了笔记**的那些 description（见 ToolResult.mutated）。
    // 两个用处：用户能翻回去看 AI 到底改了哪些笔记；「继续」时模型知道
    // 哪些已经做完了，**不要重复做**。
    final ops = <String>[];

    // 先盖一个「正在生成」的戳：成功时清掉、失败时换成具体原因。
    // 冷启动还看到它 → 上次是被系统杀掉的（那是唯一能观测到被杀的办法）。
    await _db.setMessageInterrupt(assistantId, inFlightReason);

    final buffer = StringBuffer();
    await _consume(
        loop: loop,
        history: history,
        dbHistory: dbHistory,
        asksSoFar: asksSoFar,
        roundsUsed: roundsUsed,
        roundBudget: roundBudget,
        rebuildPrompt: rebuildPrompt,
        assistantId: assistantId,
        base: base,
        writeText: writeText,
        ops: ops,
        model: model,
        thinkingEnabled: thinkingEnabled,
        buffer: buffer,
      );
  }

  /// 产出落库失败时，最多再修几轮。
  ///
  /// 封顶的理由与 `askUser` 一样：模型可能每次都"修"成另一种错，
  /// 而没有上限就是一直烧钱。两轮足够覆盖"正文太长 / 锚点不唯一"这类可自纠的错。
  static const maxRepairRounds = 2;

  /// 回答里有没有"事情已经做了"的**声明**（完成体，或对未来时态的承诺）。
  ///
  /// 只用来抓"说了但没给产出块"这一种情况 —— 所以模式取得很窄，两条原则：
  ///   · **必须是完成体/承诺**（`已写好` / `已落库` / `都会放进`），不收裸的"写过"，
  ///     否则"你写过关于 X 的笔记"这种**描述用户过去行为**的正常回答会被误判；
  ///   · **宁漏勿误**：多花一轮去问"你到底落库了没有"是有成本的，
  ///     而漏掉一次只是回到"用户以为做好了"的老状态（提示词规则 11 才是主要防线）。
  static final _completionClaim = RegExp(
    // 完成体：已 + 动词
    r'已(写好|写成|写入|保存|落库|新建|创建|生成|整理成|放进|存入|添加|修改|删除|为你写|为你建'
    // 「已把…（怎么处理了）」：中间夹宾语，但**限长、不跨句**，免得误抓一整段
    r'|把[^。！？\n]{0,12}(整理成|落库|新建|创建|写好|写入|保存|放进|存入))'
    // 承诺（实测抓到的那句是这一种："三篇都会放进…"）
    r'|会放(进|入)|都会存(进|入)|已经为你',
  );

  static bool claimsCompletionForTest(String text) =>
      _completionClaim.hasMatch(text);

  /// 跑一轮**修复**：只收集它的最终回答，不逐段写库。
  ///
  /// 为什么不像主循环那样流式落库：修复轮的回答要**替换**原回答的产出块，
  /// 逐段写会把原回答冲掉（`writeText` 是替换式写入）。所以这里先攒起来，
  /// 由调用方合并后再一次性写。
  Future<String> _repairOnce({
    required AgentLoop loop,
    required Future<String> Function()? rebuildPrompt,
    required List<AiMessage> dbHistory,
    required List<AgentMessage> history,
    required int roundBudget,
  }) async {
    final buf = StringBuffer();
    await for (final e in loop.run(
      // 修复轮也要**每轮重拼 prompt**（与主循环一致：轮数提醒挂在消息末尾）
      systemPrompt: await _safeRebuild(rebuildPrompt),
      rebuildPrompt: rebuildPrompt,
      history: history,
      dbHistory: dbHistory,
      roundBudget: roundBudget,
    )) {
      switch (e) {
        case AgentText(:final delta):
          buf.write(delta);
        case AgentFinished(:final text):
          return text.trim().isEmpty ? buf.toString() : text;
        // 修复轮里出任何别的岔子（提问 / 失败 / 轮数用尽）就放弃修复，
        // 把已经落成的部分如实报给用户，不要继续纠缠。
        case AgentAwaitingUser():
        case AgentFailed():
          return '';
        case AgentToolStarted():
        case AgentToolDone():
          break;
      }
    }
    return buf.toString();
  }

  /// 重拼一次 prompt；重拼失败不该打断修复（顶多少看到几条详情）。
  static Future<String> _safeRebuild(Future<String> Function()? rebuild) async {
    if (rebuild == null) return '';
    try {
      return await rebuild();
    } catch (_) {
      return '';
    }
  }

  /// 消费 [AgentLoop] 的事件流，把每条事件落成库里的写入。
  ///
  /// 拆成独立方法是为了让 [_drive] 的"准备工作"（算续写起点、拼 prompt、
  /// 盖 in_flight 戳）与"消费事件"两段各自读得清楚。
  Future<void> _consume({
    required AgentLoop loop,
    required List<AgentMessage> history,
    required List<AiMessage> dbHistory,
    required int asksSoFar,
    required int roundsUsed,
    required int? roundBudget,
    required Future<String> Function() rebuildPrompt,
    required String assistantId,
    required String base,
    required Future<void> Function(String text) writeText,
    required List<String> ops,
    required String model,
    required bool thinkingEnabled,
    required StringBuffer buffer,
  }) async {
    await for (final event in loop.run(
      systemPrompt: await rebuildPrompt(),
      rebuildPrompt: rebuildPrompt,
      history: history,
      dbHistory: dbHistory,
      asksSoFar: asksSoFar,
      // 轮数**跨挂起累计**：用户回答之后循环重新跑，不带回来的话
      // 预算每问一次就重置一次（软上限等于不存在）。
      roundsUsed: roundsUsed,
      roundBudget: roundBudget,
    )) {
      switch (event) {
        case AgentText(:final delta):
          buffer.write(delta);
          // ⚠️ 写的是**累计文本**（`buffer.toString()`），不是 `delta` ——
          // 因为 `writeText` 是"替换式"写入，字幕才会一段段长出来而不是拼接。
          await writeText(buffer.toString());

        case AgentFinished(:final text, :final usage):
          // ---- A 类任务的产出：解析 json 块 → 逐条落库 ----
          //
          // B 类问答没有 json 块 → `hadPayload == false` → 这里什么都不做。
          final applier = AiResultApplier(_db);
          var applied = await applier.apply(text);
          var display = text;

          // ⚠️ **"只说不做"**：实测抓到过 —— 模型写一段"三篇都会放进我的轻笔记"、
          // 然后直接 finish，**一个 json 块都没给**，结果库里一篇没有，而用户以为做好了。
          // 这比"报错"更糟（它是静默的）。所以这里检测一次并把话挑明，让它补上。
          for (var attempt = 0;
              attempt < maxRepairRounds &&
                  !applied.hadPayload &&
                  claimsCompletionForTest(text);
              attempt++) {
            final nudged = await _repairOnce(
              loop: loop,
              rebuildPrompt: rebuildPrompt,
              dbHistory: dbHistory,
              history: [
                ...history,
                AgentMessage.assistant(display),
                AgentMessage.user(
                  '你的回答里说"已经新建 / 已经整理成几篇"，但**没有给出 json 产出块** —— '
                  '按约定，没有 json 块就等于**什么都没有落库**。'
                  '请现在把要落库的内容整理成 json 代码块给出（格式见系统提示第四节）；'
                  '如果你其实不需要落库，就直接说明。',
                ),
              ],
              roundBudget: roundsUsed + 2,
            );
            if (nudged.trim().isEmpty) break;
            display = nudged;
            final again = await applier.apply(nudged);
            applied = applied.merge(again);
            if (again.hadPayload) break;
          }

          // 校验失败 → 最多再给 2 次修复机会。
          // 回灌里**带上已落库的 id**，否则模型会把建好的再建一遍（用户看到重复笔记）。
          for (var attempt = 0;
              attempt < maxRepairRounds && applied.failed.isNotEmpty;
              attempt++) {
            final repaired = await _repairOnce(
              loop: loop,
              rebuildPrompt: rebuildPrompt,
              dbHistory: dbHistory,
              history: [
                ...history,
                AgentMessage.assistant(display),
                AgentMessage.user(applied.repairMessage()),
              ],
              roundBudget: roundsUsed + 2,
            );
            if (repaired.trim().isEmpty) break;
            final again = await applier.apply(repaired);
            applied = applied.merge(again);
            display = repaired;
            if (again.failed.isEmpty) break;
          }

          // 展示时**去掉 json 块**（那是管道，不是给用户读的），换成一句话的落库摘要。
          final body = AiResultApplier.stripPayload(display);
          final receipt = applied.hasWork ? '\n\n---\n*${applied.summary}*' : '';

          // 「写最终正文」与「清 in_flight」**必须同一个事务**。
          //
          // 分两次写的话，中间被杀就会留下"正文完整、却标着未完成"的假中断 ——
          // 用户看到一条写完的回答下面挂着「上次生成中断（App 被系统中断）」，
          // 而他再点「继续」会让模型把同一件事再做一遍。
          // 事务保证这两个状态**不会只落地一半**。
          await _db.transaction(() async {
            await writeText('$body$receipt${_opsBlock(ops)}');
            await _db.setMessageInterrupt(assistantId, null);
          });
          await _log(usage,
              model: model, thinkingEnabled: thinkingEnabled, success: true);

        case AgentAwaitingUser(
            :final request,
            :final toolCallId,
            :final asks,
            :final messages,
            :final rounds,
            :final budget
          ):
          // 挂起：把"等回答"写进**数据库**（不是内存状态），
          // 用户随时回答 —— 哪怕重启 App 之后。
          //
          // ⚠️ 消息内容与挂起记录**同一个事务**：分开写的话，
          // 中间崩一次会留下"有挂起记录但没有问题文本"（用户看到空白卡片）
          // 或者"有问题文本但已挂起失效"（点了没反应）。两种都很难查。
          final saidBody = _joined(base, buffer.toString());
          final said = (saidBody.isEmpty ? awaitingPlaceholder : saidBody) +
              _opsBlock(ops);
          await _db.transaction(() async {
            await _db.updateAiMessage(assistantId, said);
            // 挂起不是"中断"：状态由 pendingAction 表达（界面显示答题卡）。
            // 不清的话，用户在挂起期间重开 App 会同时看到"未完成"和答题卡。
            await _db.setMessageInterrupt(assistantId, null);
            await _db.setPendingAction(
              assistantId,
              PendingAsk(
                toolCallId: toolCallId,
                request: request,
                // ⚠️ 用**事件带回来的** messages，不是 `_drive` 收到的 `history`：
                // 后者是这一轮开始前的对话，缺了本轮的工具往来。
                // 用错的话用户回答完就没法接着跑。
                messages: messages,
                asks: asks,
                // 轮数与预算一起存：恢复时要把它们带回循环（见 answerAsk）
                rounds: rounds,
                budget: budget,
              ).encode(),
            );
          });

        case AgentFailed(:final message, :final usage, :final code):
          await writeText(
            (buffer.isEmpty ? '⚠️ $message' : '${buffer.toString()}\n\n⚠️ $message') +
                _opsBlock(ops),
          );
          // 记下"为什么没写完"：界面据此显示「未完成 + 继续」。
          // 没有错误码的失败（例如轮数用尽）也要留痕 —— 否则用户看到的
          // 是一条正常的回答加上一句⚠️，而按钮不会出现。
          await _db.setMessageInterrupt(
              assistantId, code ?? interruptUnknownReason);
          await _log(usage,
              model: model, thinkingEnabled: thinkingEnabled, success: false);

        case AgentToolDone(:final description, :final mutated):
          // 只有**改了笔记**的调用进执行记录：读函数每轮都会调，攒起来是噪音。
          if (mutated && description != null && description.trim().isNotEmpty) {
            ops.add(description.trim());
          }

        case AgentToolStarted():
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

  /// 「正在生成」的中断标记（`ai_messages.interrupt_reason`）。
  ///
  /// 每轮开始前写上、成功/挂起时清掉。于是**冷启动还看到它**只有一种解释：
  /// 上次生成被系统杀掉或 App 崩了 —— 那是我们唯一能观测到"进程没了"的办法
  /// （`foreground_killed` 那种事没有任何回调会告诉我们）。
  static const inFlightReason = 'in_flight';

  /// 失败但**没有错误码**时用的兜底原因（例如轮数用尽）。
  static const interruptUnknownReason = 'interrupted';

  /// 中断原因（错误码）→ **给人看的一句话**。
  ///
  /// 放在这里而不是界面里：这些码是上面几条路径写进库的（[inFlightReason]、
  /// [interruptUnknownReason] 以及客户端给的 `AiError.code`），
  /// 文案跟着它们走，才不会出现"加了一个码、界面显示『没写完』"。
  ///
  /// 认不出来就笼统说"没写完" —— 宁可含糊，也别编一个原因。
  static String interruptLabel(String? code) => switch (code) {
        'network' => '网络断开',
        'timeout' => '等待超时',
        'rate_limited' => '被限流',
        'server_error' => '服务端错误',
        'unauthorized' => 'API Key 无效',
        'insufficient_balance' => '余额不足',
        'cancelled' => '已取消',
        'rounds' => '轮数到上限',
        'in_flight' => 'App 被系统中断',
        'interrupted' => '没写完',
        _ => '没写完',
      };

  /// 清掉某条消息的中断标记（界面上点「知道了」）。
  Future<void> clearInterrupt(String messageId) =>
      _db.setMessageInterrupt(messageId, null);

  /// 「本轮执行记录」那段文本。没有改动过笔记时返回空串。
  ///
  /// 追加在助手消息**末尾**，而不是单独一列：
  ///   · 用户翻回去就能看见 AI 到底改了哪些笔记（现在只有底部提示条一闪而过）；
  ///   · 它是助手消息的一部分，所以「继续」时模型天然看得到——
  ///     这正是"别把已经做过的再做一遍"的依据。
  static String _opsBlock(List<String> ops) {
    if (ops.isEmpty) return '';
    return '\n\n---\n*本轮执行：${ops.join('；')}*';
  }

  /// 续写模式下，把"行里已有的内容"翻译成**续写起点**。
  ///
  /// 只有一种情况要当空：行里还是 [awaitingPlaceholder]（AI 只是提了个问题、
  /// 还没说任何话）。那时续写的输出应当**顶掉**占位符，而不是接在它后面 ——
  /// 否则回答会以"（等你回答）"开头。
  /// 用 `startsWith` 而不是 `==`：挂起时我们还会在占位符后面追加一段
  /// 「本轮执行记录」，那种行同样要当空（否则回答会以"（等你回答）"开头）。
  static String _baseForAppend(String rowContent) =>
      rowContent.startsWith(awaitingPlaceholder) ? '' : rowContent;

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
    required String model,
    required bool thinkingEnabled,
    required bool success,
  }) =>
      _ai.logChatCall(
        model: model,
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
  ///   · 上一轮的**工具结果不重发** —— 它们本来就不落库，这里天然满足
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

  /// 把更早的轮次压成一段背景摘要。只生成一次，之后一直复用。
  ///
  /// 每轮都重新压的话，省下的历史 token 又被这次压缩调用吃回去了，白忙一场。
  /// 所以是「生成 → 落库 → 之后每轮直接读」。
  ///
  /// 代价是摘要不会随着对话继续而更新（它覆盖的是"生成那一刻更早的内容"）。
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

}
