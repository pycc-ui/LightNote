// 断线续传：内容**一直没丢**（每个 chunk 都落库），缺的只是「这条写完了没有」。
//
// 所以这一层要钉住的是 `ai_messages.interrupt_reason` 的**状态机**：
//
//   开始生成 → in_flight
//   成功     → null
//   askUser  → null（挂起不是中断：状态由 pendingAction 表达）
//   出错     → 错误码（network / timeout / …）
//   轮数用尽 → rounds
//
// ⚠️ 其中 in_flight 有个特殊用途：**冷启动还看到它，就说明上次是被系统杀掉或
// App 崩了** —— 那是唯一能观测到"进程没了"的办法（没有任何回调会告诉我们
// foreground_killed）。所以它必须"一开始生成就写"，不能等出错才写。
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' show CancelToken;
// drift 导出的 isNull / isNotNull 与 flutter_test 的 matcher 同名，这里从 drift 侧隐藏。
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/core/db/ai_udfs.dart';
import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/core/db/models.dart';
import 'package:lightnote/features/ai/data/deepseek_client.dart';
import 'package:lightnote/features/ai/domain/ai_chat_repository.dart';
import 'package:lightnote/features/ai/domain/ai_repository.dart';
import 'package:lightnote/features/ai/domain/tool_types.dart';

/// 假客户端，两种模式：
///   · **自动**（[auto]）：第 n 轮直接吐这些事件 —— 用来跑多轮脚本；
///   · **手动**（[rounds]）：每轮给一个 controller，测试自己决定什么时候结束 ——
///     用来在"生成到一半"的时刻读库（不然观察不到 `in_flight`）。
class FakeClient extends DeepSeekClient {
  List<AiEvent> Function(int round)? auto;
  final List<StreamController<AiEvent>> rounds = [];
  int _calls = 0;

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
    bool jsonMode = false,
    double? temperature,
    CancelToken? cancelToken,
  }) {
    final n = _calls++;
    final scripted = auto;
    if (scripted != null) return Stream.fromIterable(scripted(n));
    final c = StreamController<AiEvent>();
    rounds.add(c);
    return c.stream;
  }

  @override
  Stream<AiEvent> streamChat({
    required String systemPrompt,
    required String userPrompt,
    String model = 'fake',
    bool thinking = false,
    String reasoningEffort = 'high',
    int? maxTokens,
    bool jsonMode = false,
    double? temperature,
    CancelToken? cancelToken,
  }) =>
      Stream.value(const AiDone(fullText: ''));

  /// 提一个 sql 调用。
  static List<AiEvent> tool(String query, {String id = 'c1'}) => [
        AiDone(
          fullText: '',
          toolCalls: [
            ToolCall(id: id, name: 'sql', arguments: jsonEncode({'query': query})),
          ],
        ),
      ];
}

void main() {
  late AppDatabase db;
  late FakeClient client;
  late AiChatRepository chat;

  setUp(() {
    // 装 UDF：要跑真的 SQL（create_notes_batch / finish），才能验「本轮执行记录」
    db = AppDatabase.forTesting(NativeDatabase.memory(setup: installAiUdfs));
    client = FakeClient();
    chat = AiChatRepository(
      db: db,
      ai: AiRepository(db: db, client: client),
    );
  });
  tearDown(() => db.close());

  Future<String> ask(String conversationId, String text) => chat.send(
        conversationId: conversationId,
        userInput: text,
        thinkingEffort: 'medium',
        thinkingEnabled: false,
      );

  /// 助手占位消息（`send` 一开始就落库了，所以能拿到它的 id）。
  Future<AiMessage> assistantRow(String conversationId) async {
    for (var i = 0; i < 200; i++) {
      final rows = await db.watchMessages(conversationId).first;
      for (final m in rows) {
        if (m.role == 'assistant') return m;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('等不到助手消息');
  }

  /// 轮询等条件成立（真异步，不用 fakeAsync —— 这一层测的是真实时序）。
  Future<void> waitFor(
    Future<bool> Function() cond, {
    String what = '条件',
  }) async {
    for (var i = 0; i < 200; i++) {
      if (await cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('等待超时：$what');
  }

  group('★ in_flight：一开始生成就盖章', () {
    test('生成中 → in_flight；成功 → 清成 null', () async {
      final conv = await chat.createConversation();
      final sending = ask(conv.id, '你好'); // 不 await：它要等这一轮跑完

      final msg = await assistantRow(conv.id);
      await waitFor(
        () async =>
            (await db.aiMessageById(msg.id))?.interruptReason ==
            AiChatRepository.inFlightReason,
        what: '生成开始后应当盖上 in_flight',
      );

      // 这一轮还没结束 —— 冷启动在这个时刻被杀，下回就能看出来
      expect(client.rounds, hasLength(1));

      client.rounds.last.add(const AiDone(fullText: '好了'));
      await client.rounds.last.close();
      await sending;

      // 「写最终正文」与「清 in_flight」在**同一个事务**里（见 _consume）——
      // 分两次写的话，中间被杀就会留下"正文完整、却标着未完成"的假中断。
      // 事务的原子性本身没法在单测里注入崩溃来验，这里验的是它的**结果**：
      // 成功之后两件事都算数（正文写了、戳清了）。
      final done = (await db.aiMessageById(msg.id))!;
      expect(done.content, '好了', reason: '正文写了');
      expect(done.interruptReason, isNull,
          reason: '戳清了 —— 否则界面会一直显示「未完成」');
    });

    test('冷启动残留的 in_flight 只可能是"上次被杀了"（没有别的代码路径会留下它）',
        () async {
      // 模拟上次进程被杀：写一条带 in_flight 的助手消息，不再有人管它
      final conv = await chat.createConversation();
      await db.insertAiMessage(AiMessagesCompanion.insert(
        id: 'killed',
        conversationId: conv.id,
        role: 'assistant',
        content: const Value('写到一半就被系统杀了'),
        interruptReason: const Value(AiChatRepository.inFlightReason),
        createdAt: DateTime.now().toUtc(),
      ));

      final row = await db.aiMessageById('killed');
      expect(row!.interruptReason, AiChatRepository.inFlightReason);
      expect(row.content, '写到一半就被系统杀了',
          reason: '内容一直在（每个 chunk 都落过库），丢的只是"写完了没有"');
    });
  });

  group('失败：把原因落库，内容与执行记录都留下', () {
    test('网络断开 → network，正文带 ⚠️', () async {
      final conv = await chat.createConversation();
      final sending = ask(conv.id, '帮我整理');
      final msg = await assistantRow(conv.id);
      await waitFor(
        () async => client.rounds.isNotEmpty,
        what: '第一轮请求发出',
      );

      client.rounds.last.add(const AiChunk('我已经看了前两篇，'));
      client.rounds.last.add(const AiError('连接中断了', code: 'network'));
      await client.rounds.last.close();
      await sending;

      final row = (await db.aiMessageById(msg.id))!;
      expect(row.interruptReason, 'network',
          reason: '界面靠这个码显示「上次生成中断（网络断开）」');
      expect(row.content, contains('我已经看了前两篇'),
          reason: '已经生成的内容一个字都不能丢');
      expect(row.content, contains('⚠️'), reason: '正文里也要能看出没写完');
    });

    test('没有错误码的失败也要留痕（否则按钮不出现）', () async {
      final conv = await chat.createConversation();
      client.auto = (n) => [
            const AiError('说不清的一类错'),
          ];

      await ask(conv.id, 'x');

      final rows = await db.watchMessages(conv.id).first;
      final assistant = rows.lastWhere((m) => m.role == 'assistant');
      expect(assistant.interruptReason, AiChatRepository.interruptUnknownReason,
          reason: '只写 ⚠️ 不写码的话，用户看到的是一条普通回答，而没有「继续」按钮');
    });

    test('★ 轮数用尽 → rounds（不是笼统的 interrupted）', () async {
      final conv = await chat.createConversation();
      // 永远提工具、永远不收尾
      client.auto = (n) => FakeClient.tool('SELECT 1', id: 'c$n');

      await ask(conv.id, '把整个库重写一遍');

      final rows = await db.watchMessages(conv.id).first;
      final assistant = rows.lastWhere((m) => m.role == 'assistant');
      expect(assistant.interruptReason, 'rounds',
          reason: '「轮数到上限」和「网络断了」要给用户不同的说法');
      expect(assistant.content, contains('继续'),
          reason: '文案里要给出下一步怎么办');
    });
  });

  group('挂起 ≠ 中断', () {
    test('askUser 挂起时清掉中断标记（否则重开 App 会又见答题卡又见"未完成"）',
        () async {
      final conv = await chat.createConversation();
      client.auto = (n) => [
            AiDone(
              fullText: '我需要先问一句。',
              toolCalls: [
                ToolCall(
                  id: 'ask1',
                  name: 'askUser',
                  arguments: jsonEncode({
                    'question': '要改哪一篇？',
                    'type': 'text',
                  }),
                ),
              ],
            ),
          ];

      await ask(conv.id, '帮我改一下');

      final rows = await db.watchMessages(conv.id).first;
      final assistant = rows.lastWhere((m) => m.role == 'assistant');
      expect(assistant.interruptReason, isNull, reason: '挂起由 pendingAction 表达');
      expect(assistant.pendingAction, isNotNull);
      expect((await chat.pendingAsk(conv.id))?.request.question, '要改哪一篇？');
    });
  });

  group('继续：模型要看得见"已经做过什么"', () {
    test('★ 改过笔记的调用会攒成「本轮执行：」，追加在回答末尾', () async {
      final conv = await chat.createConversation();
      client.auto = (n) => n == 0
          ? FakeClient.tool(
              "SELECT create_notes_batch('[{\"title\":\"会议纪要\"}]')")
          : [const AiDone(fullText: '建好了一篇《会议纪要》。')];

      await ask(conv.id, '把刚才聊的整理成一篇');

      final rows = await db.watchMessages(conv.id).first;
      final assistant = rows.lastWhere((m) => m.role == 'assistant');
      expect(assistant.content, contains('本轮执行：'),
          reason: '工具往来不落库，模型只看得见自己的文字 —— 不写这段它就不知道做过什么');
      expect(assistant.content, contains('会议纪要'));
      expect(assistant.interruptReason, isNull);
    });

    test('只读的调用**不**进执行记录（每轮都读，攒起来是噪音）', () async {
      final conv = await chat.createConversation();
      client.auto = (n) => n == 0
          ? FakeClient.tool('SELECT list_notebooks()')
          : [const AiDone(fullText: '你有 1 个笔记库。')];

      await ask(conv.id, '我有几个库？');

      final rows = await db.watchMessages(conv.id).first;
      final assistant = rows.lastWhere((m) => m.role == 'assistant');
      expect(assistant.content, isNot(contains('本轮执行：')));
    });

    test('「继续」= 把一句带上下文的话发出去（走的是同一条发送路径）', () async {
      final conv = await chat.createConversation();
      client.auto = (n) => [const AiDone(fullText: '接着做完了。')];

      // 界面上的「继续」只是把这句话放进输入框再调 send（见 ai_page.dart）
      const continueText = '（继续）上次的回答被中断了（网络断开），请接着上面的内容继续。';
      await ask(conv.id, continueText);

      final rows = await db.watchMessages(conv.id).first;
      expect(rows.first.content, continueText);
      expect(rows.last.content, '接着做完了。');
    });
  });


  group('中断原因 → 给人看的一句话', () {
    test('每个码都有说法（界面上的「上次生成中断（…）」）', () {
      const expected = {
        'network': '网络断开',
        'timeout': '等待超时',
        'rate_limited': '被限流',
        'server_error': '服务端错误',
        'unauthorized': 'API Key 无效',
        'insufficient_balance': '余额不足',
        'cancelled': '已取消',
        'rounds': '轮数到上限',
        AiChatRepository.inFlightReason: 'App 被系统中断',
        AiChatRepository.interruptUnknownReason: '没写完',
      };
      for (final e in expected.entries) {
        expect(AiChatRepository.interruptLabel(e.key), e.value, reason: e.key);
      }
    });

    test('认不出来的码 / null → 笼统说「没写完」，绝不编原因', () {
      for (final code in [null, '', 'future_code_from_a_newer_client']) {
        expect(AiChatRepository.interruptLabel(code), '没写完');
      }
    });

    test('★ 客户端可能给的码都被覆盖到了（别加码不加文案）', () {
      // 这几个是 DeepSeek 客户端会塞进 AiError.code 的取值。
      // 新增一个时，要么在这里补一行、要么确认它走"没写完"兜底 ——
      // 但"没写完"对用户是没有信息量的，所以列出来逼自己看一眼。
      const clientCodes = [
        'network',
        'timeout',
        'rate_limited',
        'server_error',
        'unauthorized',
        'insufficient_balance',
        'cancelled',
      ];
      for (final c in clientCodes) {
        expect(AiChatRepository.interruptLabel(c), isNot('没写完'),
            reason: '$c 有专门的文案，别被兜底吃掉');
      }
    });
  });

  group('「知道了」= 清掉标记', () {
    test('clearInterrupt 之后界面不再把它当未完成', () async {
      final conv = await chat.createConversation();
      client.auto = (n) => [const AiError('超时了', code: 'timeout')];
      await ask(conv.id, 'x');

      final rows = await db.watchMessages(conv.id).first;
      final assistant = rows.lastWhere((m) => m.role == 'assistant');
      expect(assistant.interruptReason, 'timeout');

      await chat.clearInterrupt(assistant.id);

      expect((await db.aiMessageById(assistant.id))!.interruptReason, isNull);
      expect((await db.aiMessageById(assistant.id))!.content,
          assistant.content,
          reason: '清标记只动那一列，正文一个字都不该变');
    });
  });
}
