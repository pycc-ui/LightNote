// 阶段 6 的端到端：`askUser` 挂起 → 用户回答 → **接着跑**。
//
// 这条链路是"持久化挂起"的最终目的：用户回答完之后，AI 要能**从提问那一刻
// 接着**把事办完，而不是从头再来一遍。
//
// 用假客户端（继承真 `DeepSeekClient`）驱动，所以不花 API 额度。
import 'dart:convert';

import 'package:dio/dio.dart' show CancelToken;
// drift 的 Value（构造 Companion）与 flutter_test 的 matcher 无冲突，直接引。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/core/db/models.dart';
import 'package:lightnote/features/ai/data/deepseek_client.dart';
import 'package:lightnote/features/ai/domain/agent_loop.dart';
import 'package:lightnote/features/ai/domain/ai_chat_repository.dart';
import 'package:lightnote/features/ai/domain/ai_repository.dart';
import 'package:lightnote/features/ai/domain/ask_user.dart';
import 'package:lightnote/features/ai/domain/tool_types.dart';

/// 按脚本回答的假客户端。**每一轮记下它收到的 messages**，供断言检查。
class FakeClient extends DeepSeekClient {
  FakeClient(this.script, {this.stream});

  /// 第 n 轮返回什么（n 从 0 起）—— 单事件、最简单的那种假模型。
  ///
  /// **可替换**：同一个测试里换脚本比重新 boot 一个库安全得多
  ///（重复 `AppDatabase.forTesting` 会留一个没关的实例）。
  AiEvent Function(int round, List<AgentMessage> messages) script;

  /// 第 n 轮返回**一串**事件（真的分片流式）。给了它就不用 [script]。
  ///
  /// 为什么需要两种：单事件的话"每个分片都重写一遍前面的内容"这类 bug
  /// 只会多出一份、看起来像正常的换行拼接；**分片**才会把它放大成
  /// 一眼可见的重复（真实模型就是分片的，所以线上更容易撞到）。
  final Stream<AiEvent> Function(int round, List<AgentMessage> messages)? stream;

  final List<List<AgentMessage>> seen = [];

  /// 每轮收到的 system prompt（轮数预算提醒就追加在它末尾）。
  final List<String> systems = [];

  int _round = 0;

  @override
  bool get hasApiKey => true;

  @override
  Stream<AiEvent> streamAgent({
    required String systemPrompt,
    required List<AgentMessage> messages,
    List<ToolSpec> tools = const [],
    String model = 'fake',
    bool thinking = false,
    String reasoningEffort = 'high',
    int? maxTokens,
    CancelToken? cancelToken,
  }) {
    seen.add(List<AgentMessage>.from(messages));
    systems.add(systemPrompt);
    final round = _round++;
    return stream?.call(round, messages) ?? Stream.value(script(round, messages));
  }
}

void main() {
  late AppDatabase db;
  late FakeClient client;
  late AiChatRepository chat;
  late String convId;

  Future<void> boot(
    AiEvent Function(int round, List<AgentMessage> messages) script, {
    Stream<AiEvent> Function(int round, List<AgentMessage> messages)? stream,
  }) async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    client = FakeClient(script, stream: stream);
    chat = AiChatRepository(
      db: db,
      ai: AiRepository(db: db, client: client),
    );
    convId = (await chat.createConversation()).id;
  }

  setUp(() async {
    // 默认脚本：先问，再答
    await boot((round, messages) {
      if (round == 0) {
        return const AiDone(toolCalls: [
          ToolCall(
            id: 'ask_1',
            name: 'askUser',
            arguments: '{"question":"你想改哪一篇？","type":"singleChoice",'
                '"source":{"kind":"search","query":"会议"}}',
          ),
        ]);
      }
      return const AiDone(fullText: '好的，我按你选的来。');
    });
  });
  tearDown(() => db.close());

  group('挂起：AI 问完之后停下来等', () {
    test('send 之后库里有待答的提问，且消息内容是"等你回答"', () async {
      await chat.send(
        conversationId: convId,
        userInput: '帮我改会议记录',
        
        thinkingEffort: 'low',
        thinkingEnabled: false,
      );

      final pending = await chat.pendingAsk(convId);
      expect(pending, isNotNull, reason: '挂起状态必须落在库里');
      expect(pending!.request.question, '你想改哪一篇？');
      expect(pending.request.type, AskType.singleChoice);
      expect(pending.request.source!.query, '会议');
      expect(pending.toolCallId, 'ask_1', reason: '恢复时要靠它对上');
      expect(pending.asks, 1);

      // 只发了**一轮**：停下来等用户，不继续烧钱
      expect(client.seen, hasLength(1));

      // 消息里看得到"等你回答"，用户不会对着空白发呆
      final rows = await db.watchMessages(convId).first;
      final last = rows.lastWhere((m) => m.role == 'assistant');
      expect(last.content, contains('等你回答'));
    });

    test('挂起记录里带着**提问那一刻的对话**（恢复要靠它）', () async {
      await chat.send(
        conversationId: convId,
        userInput: '帮我改会议记录',
        
        thinkingEffort: 'low',
        thinkingEnabled: false,
      );

      final pending = (await chat.pendingAsk(convId))!;
      expect(pending.messages, isNotEmpty);
      expect(pending.messages.any((m) => m.role == 'user'), isTrue);
      expect(pending.messages.last.toolCalls.single.name, 'askUser');
    });
  });

  group('★ 轮数预算：回答 = 继续（+15 轮），已用轮数跨挂起累计', () {
    /// 直接落一条挂起记录（模拟"循环在第 14 轮挂起"那一刻的状态）。
    Future<void> seedPending({required int rounds, required int budget}) async {
      final pending = PendingAsk(
        toolCallId: 'ask_1',
        request: const AskRequest(question: '还要继续吗？', type: AskType.confirm),
        messages: [
          AgentMessage.user('把整个库重写一遍'),
          AgentMessage.assistant('', toolCalls: [
            const ToolCall(id: 'ask_1', name: 'askUser', arguments: '{}'),
          ]),
        ],
        asks: 1,
        rounds: rounds,
        budget: budget,
      );
      await db.insertAiMessage(AiMessagesCompanion.insert(
        id: 'suspended',
        conversationId: convId,
        role: 'assistant',
        content: const Value(AiChatRepository.awaitingPlaceholder),
        pendingAction: Value(pending.encode()),
        createdAt: DateTime.now().toUtc(),
      ));
    }

    test('★ 预算 = 挂起时的预算 + 15，已用轮数也继续算', () async {
      // 回答之后每一轮都提工具，直到预算用尽
      client.script = (round, messages) => const AiDone(toolCalls: [
            ToolCall(id: 'c', name: 'sql', arguments: '{"query":"SELECT 1"}'),
          ]);
      await seedPending(rounds: 14, budget: 16);

      final resumed = await chat.answerAsk(
        conversationId: convId,
        result: AskResult.confirm(true),
        thinkingEffort: 'low',
        thinkingEnabled: false,
      );
      expect(resumed, isNotNull);

      // 预算 16 + 15 = 31，已用 14 → 还能跑 17 轮
      expect(client.systems, hasLength(17),
          reason: '预算没接上的话（每次重新给满）这里会是别的数；'
              '已用轮数没带回来的话会是 31');
      // 提醒只在"还剩 ≤2 轮"时出现 → 看最后两轮
      // 提醒挂在**消息末尾**（不碰 system 头部，保住前缀缓存）
      final tail = client.seen.last.last.content;
      expect(tail, contains('已经用了 30 轮'),
          reason: '已用轮数是连挂起前一起算的（14 + 16）');
      expect(tail, contains('最多 31 轮'),
          reason: '16 + 15 = 31（用户回答就算同意继续）');
      expect(client.systems.every((s) => !s.contains('轮数提醒')), isTrue,
          reason: 'system prompt 不该被提醒污染');

      // 用尽之后仍然收尾，并且留痕
      final rows = await db.watchMessages(convId).first;
      expect(rows.lastWhere((m) => m.role == 'assistant').interruptReason, 'rounds');
    });

    test('用户答"不用了"也不必特殊处理：预算只是"允许"，模型会自己收尾', () async {
      client.script = (round, messages) => const AiDone(fullText: '那我不做了。');
      await seedPending(rounds: 14, budget: 16);

      await chat.answerAsk(
        conversationId: convId,
        result: AskResult.confirm(false),
        thinkingEffort: 'low',
        thinkingEnabled: false,
      );

      expect(client.seen, hasLength(1), reason: '模型直接给结论就结束，不花满预算');
      final rows = await db.watchMessages(convId).first;
      expect(rows.lastWhere((m) => m.role == 'assistant').content,
          contains('那我不做了'));
    });

    test('老挂起记录（没有 rounds / budget 字段）→ 兜底成"默认额度"', () async {
      // v14 之前的记录：这两个字段不存在
      const legacy = '{"kind":"askUser","toolCallId":"ask_1",'
          '"request":{"question":"继续吗？","type":"confirm","limit":10},'
          '"messages":[],"asks":1}';
      final parsed = PendingAsk.tryParse(legacy);
      expect(parsed, isNotNull);
      expect(parsed!.rounds, 0, reason: '0 = 不知道，由调用方兜底');
      expect(parsed.budget, 0);

      client.script = (round, messages) => const AiDone(fullText: '做完了。');
      await db.insertAiMessage(AiMessagesCompanion.insert(
        id: 'legacy',
        conversationId: convId,
        role: 'assistant',
        content: const Value(AiChatRepository.awaitingPlaceholder),
        pendingAction: const Value(legacy),
        createdAt: DateTime.now().toUtc(),
      ));

      final resumed = await chat.answerAsk(
        conversationId: convId,
        result: AskResult.confirm(true),
        thinkingEffort: 'low',
        thinkingEnabled: false,
      );

      expect(resumed, isNotNull, reason: '老记录不能把会话卡死');
      expect(client.seen, hasLength(1), reason: '兜底成默认额度后照常接着跑');

      final rows = await db.watchMessages(convId).first;
      final assistant = rows.lastWhere((m) => m.role == 'assistant');
      expect(assistant.content, contains('做完了'));
      expect(assistant.pendingAction, isNull, reason: '回答完要把挂起清掉');
    });
  });

  group('★ 回答之后**接着跑**', () {
    test('用户的回答以 role:tool 回灌给模型', () async {
      await chat.send(
        conversationId: convId,
        userInput: '帮我改会议记录',
        
        thinkingEffort: 'low',
        thinkingEnabled: false,
      );

      await chat.answerAsk(
        conversationId: convId,
        result: AskResult.choice(['note_42']),
        
        thinkingEffort: 'low',
        thinkingEnabled: false,
      );

      expect(client.seen, hasLength(2), reason: '回答之后应当再发一轮');

      // 第二轮里必须有一条 tool 结果，带着 tool_call_id 与用户的选择
      final second = client.seen[1];
      final toolMsg = second.lastWhere((m) => m.role == 'tool');
      expect(toolMsg.toolCallId, 'ask_1');
      final payload = jsonDecode(toolMsg.content) as Map<String, Object?>;
      final data = (payload['data'] as Map).cast<String, Object?>();
      expect(data['status'], AskResult.statusAnswered);
      expect(data['selections'], ['note_42']);

      // 而且**提问那一刻的对话还在**（不是从头再来）
      expect(second.any((m) => m.content == '帮我改会议记录'), isTrue);
      expect(second.where((m) => m.role == 'assistant'), isNotEmpty);
    });

    test('回答之后挂起被清掉，续写进同一条助手消息', () async {
      await chat.send(
        conversationId: convId,
        userInput: 'x',
        
        thinkingEffort: 'low',
        thinkingEnabled: false,
      );
      await chat.answerAsk(
        conversationId: convId,
        result: AskResult.choice(['a']),
        
        thinkingEffort: 'low',
        thinkingEnabled: false,
      );

      expect(await chat.pendingAsk(convId), isNull,
          reason: '用户只该答一次；挂起不清掉会反复弹');

      final rows = await db.watchMessages(convId).first;
      final assistant = rows.where((m) => m.role == 'assistant').toList();
      expect(assistant, hasLength(1), reason: '续写同一条，不是新建一条');
      // **精确相等**，不是 contains：占位符要被顶掉、正文只出现一次。
      // 写成 contains 的话，"好的，我按你选的来。\n\n好的，我按你选的来。"
      // （同一句话被写两遍）也能通过 —— 那正是曾经漏掉的 bug。
      expect(assistant.single.content, '好的，我按你选的来。');
      expect(assistant.single.pendingAction, isNull);
    });

    test('★ 流式分片续写：每个分片只"长出来"，不把前面写过的再写一遍', () async {
      await boot(
        (round, messages) => const AiDone(fullText: '（不该走这条）'),
        stream: (round, messages) {
          if (round == 0) {
            // 先垫一句话再问 —— 于是续写时行里**已经有内容**，
            // 走的正是"接在已有内容之后"那条分支（出问题的那条）
            return Stream.fromIterable([
              const AiChunk('我先确认一下：'),
              const AiDone(toolCalls: [
                ToolCall(
                  id: 'ask_1',
                  name: 'askUser',
                  arguments: '{"question":"哪一篇？","type":"text"}',
                ),
              ]),
            ]);
          }
          // 续写的这一轮真的分片（真实模型就是这样）
          return Stream.fromIterable([
            const AiChunk('已'),
            const AiChunk('删除，'),
            const AiChunk('「我的轻笔记」现在是空的。'),
            const AiDone(),
          ]);
        },
      );

      await chat.send(
        conversationId: convId,
        userInput: 'x',
        thinkingEffort: 'low',
        thinkingEnabled: false,
      );

      // 挂起时：垫的那句话要留在消息里（用户过几天回来还得知道自己问的是什么）
      final suspended = (await db.watchMessages(convId).first)
          .where((m) => m.role == 'assistant')
          .single;
      expect(suspended.content, '我先确认一下：');

      await chat.answerAsk(
        conversationId: convId,
        result: AskResult.input('第一篇'),
        thinkingEffort: 'low',
        thinkingEnabled: false,
      );

      final assistant = (await db.watchMessages(convId).first)
          .where((m) => m.role == 'assistant')
          .single;

      // 曾经的 bug：每写一个分片都把"当前累计文本"重新拼到行尾，于是内容变成
      // 「已」+「已删除，」+「已删除，「我的轻笔记」…」……按字数递增地重复上百遍
      // （用户看到的就是这种锯齿）。续写必须是"起点 + 累计文本"的**替换式**写入，
      // 重复写同一个累计文本要幂等。
      expect(
        assistant.content,
        '我先确认一下：\n\n已删除，「我的轻笔记」现在是空的。',
      );
      // 兜一道粗筛：万一将来又退化成追加，长度会按字数平方级膨胀
      expect(assistant.content.length, lessThan(60));
    });

    test('取消也是合法回答：以 cancelled 回灌，循环照常继续', () async {
      await chat.send(
        conversationId: convId,
        userInput: 'x',
        
        thinkingEffort: 'low',
        thinkingEnabled: false,
      );

      await chat.answerAsk(
        conversationId: convId,
        result: AskResult.cancelled(),
        
        thinkingEffort: 'low',
        thinkingEnabled: false,
      );

      final payload = jsonDecode(
        client.seen[1].lastWhere((m) => m.role == 'tool').content,
      ) as Map<String, Object?>;
      final data = (payload['data'] as Map).cast<String, Object?>();
      expect(data['status'], AskResult.statusCancelled);
    });

    test('没有挂起时 answerAsk 什么都不做（返回 null）', () async {
      final r = await chat.answerAsk(
        conversationId: convId,
        result: AskResult.input('随便'),
        
        thinkingEffort: 'low',
        thinkingEnabled: false,
      );
      expect(r, isNull);
      expect(client.seen, isEmpty, reason: '不该凭空发一轮');
    });

    test('★ 挂起记录坏掉时清掉它，不让会话永远卡住', () async {
      await chat.send(
        conversationId: convId,
        userInput: 'x',
        
        thinkingEffort: 'low',
        thinkingEnabled: false,
      );
      // 人为写坏
      final row = await db.pendingAskMessage(convId);
      await db.setPendingAction(row!.id, '{坏掉的 json');

      final r = await chat.answerAsk(
        conversationId: convId,
        result: AskResult.input('x'),
        
        thinkingEffort: 'low',
        thinkingEnabled: false,
      );

      expect(r, isNull);
      expect(await chat.pendingAsk(convId), isNull,
          reason: '不清掉的话这个会话永远显示"等你回答"');
    });
  });

  group('askUser 的上限跨恢复累计', () {
    test(
        '问到第 ${AgentLoop.maxAsksPerTurn} 次之后，'
        '第 ${AgentLoop.maxAsksPerTurn + 1} 次会被拒并让模型收尾', () async {
      var asks = 0;
      await boot((round, messages) {
        // 每轮都问；模型永远不满意
        asks++;
        if (asks > 6) return const AiDone(fullText: '好吧，我直接答。');
        return AiDone(toolCalls: [
          ToolCall(
            id: 'ask_$asks',
            name: 'askUser',
            arguments: '{"question":"还问一次","type":"text"}',
          ),
        ]);
      });
      final c = (await chat.createConversation()).id;

      var answered = 0;
      for (var i = 0; i < 8; i++) {
        final first = i == 0;
        if (first) {
          await chat.send(
            conversationId: c,
            userInput: 'x',
            
            thinkingEffort: 'low',
            thinkingEnabled: false,
          );
        } else {
          await chat.answerAsk(
            conversationId: c,
            result: AskResult.input('答'),
            
            thinkingEffort: 'low',
            thinkingEnabled: false,
          );
        }
        if (await chat.pendingAsk(c) == null) break;
        answered++;
      }

      expect(answered, AgentLoop.maxAsksPerTurn,
          reason: '上限是 ${AgentLoop.maxAsksPerTurn}：到顶之后强制收尾，'
              '不能让模型"问一句 → 不满意 → 再问一句"地一直问下去');
    });
  });
}
