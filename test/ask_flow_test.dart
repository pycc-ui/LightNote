// 阶段 6 的端到端：`askUser` 挂起 → 用户回答 → **接着跑**。
//
// 这条链路是"持久化挂起"的最终目的：用户回答完之后，AI 要能**从提问那一刻
// 接着**把事办完，而不是从头再来一遍。
//
// 用假客户端（继承真 `DeepSeekClient`）驱动，所以不花 API 额度。
import 'dart:convert';

import 'package:dio/dio.dart' show CancelToken;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/core/db/models.dart';
import 'package:lightnote/features/ai/data/deepseek_client.dart';
import 'package:lightnote/features/ai/domain/ai_chat_repository.dart';
import 'package:lightnote/features/ai/domain/ai_repository.dart';
import 'package:lightnote/features/ai/domain/ask_user.dart';
import 'package:lightnote/features/ai/domain/tool_types.dart';

/// 按脚本回答的假客户端。**每一轮记下它收到的 messages**，供断言检查。
class FakeClient extends DeepSeekClient {
  FakeClient(this.script);

  /// 第 n 轮返回什么（n 从 0 起）
  final AiEvent Function(int round, List<AgentMessage> messages) script;

  final List<List<AgentMessage>> seen = [];
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
    return Stream.value(script(_round++, messages));
  }
}

void main() {
  late AppDatabase db;
  late FakeClient client;
  late AiChatRepository chat;
  late String convId;

  Future<void> boot(
    AiEvent Function(int round, List<AgentMessage> messages) script,
  ) async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    client = FakeClient(script);
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
        contextNoteIds: const [],
        
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
        contextNoteIds: const [],
        
        thinkingEffort: 'low',
        thinkingEnabled: false,
      );

      final pending = (await chat.pendingAsk(convId))!;
      expect(pending.messages, isNotEmpty);
      expect(pending.messages.any((m) => m.role == 'user'), isTrue);
      expect(pending.messages.last.toolCalls.single.name, 'askUser');
    });
  });

  group('★ 回答之后**接着跑**', () {
    test('用户的回答以 role:tool 回灌给模型', () async {
      await chat.send(
        conversationId: convId,
        userInput: '帮我改会议记录',
        contextNoteIds: const [],
        
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
        contextNoteIds: const [],
        
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
      expect(assistant.single.content, contains('我按你选的来'));
      expect(assistant.single.pendingAction, isNull);
    });

    test('取消也是合法回答：以 cancelled 回灌，循环照常继续', () async {
      await chat.send(
        conversationId: convId,
        userInput: 'x',
        contextNoteIds: const [],
        
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
        contextNoteIds: const [],
        
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
    test('问到第 3 次之后，第 4 次会被拒并让模型收尾', () async {
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
            contextNoteIds: const [],
            
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

      expect(answered, lessThanOrEqualTo(3),
          reason: '上限是 3 —— 用户被问第三次时已经烦了，第四次会直接关掉 App');
    });
  });
}
