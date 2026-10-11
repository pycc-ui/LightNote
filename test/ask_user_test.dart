// 阶段 6：`askUser` 的持久化挂起。
//
// 三件事必须成立，否则这个功能是坏的：
//   · 选项**来自 App 的查询**（模型编的清单会变旧、会给出已删除的 id）
//   · 挂起状态在**数据库**里（杀掉 App 重开还能继续回答）
//   · 问不过 3 次（模型会"问一句 → 不满意 → 再问一句"地循环下去）
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/core/db/models.dart';
import 'package:lightnote/features/ai/data/deepseek_client.dart';
import 'package:lightnote/features/ai/domain/agent_loop.dart';
import 'package:lightnote/features/ai/domain/ai_chat_repository.dart';
import 'package:lightnote/features/ai/domain/ai_repository.dart';
import 'package:lightnote/features/ai/domain/ask_resolver.dart';
import 'package:lightnote/features/ai/domain/ask_user.dart';
import 'package:lightnote/features/ai/domain/tool_executor.dart';
import 'package:lightnote/features/ai/domain/tool_types.dart';
import 'package:lightnote/features/note/data/notebook_repository.dart';
import 'package:lightnote/features/note/data/note_repository.dart';

void main() {
  group('PendingAsk：挂起记录能跨重启还原', () {
    test('编码 → 解析一圈，字段都在', () {
      final before = PendingAsk(
        toolCallId: 'call_9',
        asks: 2,
        request: const AskRequest(
          question: '你想改哪一篇？',
          type: AskType.singleChoice,
          limit: 5,
          source: AskSource(kind: 'search', query: '会议'),
        ),
        messages: [
          AgentMessage.system('SYS'),
          AgentMessage.user('帮我改会议记录'),
          AgentMessage.assistant('我先找找', toolCalls: const []),
        ],
      );

      final after = PendingAsk.tryParse(before.encode())!;

      expect(after.toolCallId, 'call_9');
      expect(after.asks, 2);
      expect(after.request.question, '你想改哪一篇？');
      expect(after.request.type, AskType.singleChoice);
      expect(after.request.limit, 5);
      expect(after.request.source!.kind, 'search');
      expect(after.request.source!.query, '会议');
      expect(after.messages, hasLength(3));
      expect(after.messages[1].content, '帮我改会议记录');
      expect(after.messages[1].role, 'user');
    });

    test('模型直接给的选项也存得下', () {
      final before = PendingAsk(
        toolCallId: 'c',
        request: const AskRequest(
          question: '选一个',
          type: AskType.multipleChoice,
          options: [
            AskOption(id: 'a', label: '甲', description: '第一个'),
            AskOption(id: 'b', label: '乙'),
          ],
        ),
      );
      final after = PendingAsk.tryParse(before.encode())!;
      expect(after.request.options, hasLength(2));
      expect(after.request.options.first.description, '第一个');
    });

    test('坏数据 → null（当成"没有挂起"），不是抛错', () {
      // 一条损坏的记录不该让整个会话打不开
      expect(PendingAsk.tryParse(null), isNull);
      expect(PendingAsk.tryParse(''), isNull);
      expect(PendingAsk.tryParse('不是 json'), isNull);
      expect(PendingAsk.tryParse('{"kind":"别的"}'), isNull);
      expect(PendingAsk.tryParse('{"kind":"askUser"}'), isNull, reason: '缺 toolCallId');
      expect(PendingAsk.tryParse('{"kind":"askUser","toolCallId":"c"}'), isNull,
          reason: '缺 request');
      expect(
        PendingAsk.tryParse(
            '{"kind":"askUser","toolCallId":"c","request":{"question":"q"}}'),
        isNull,
        reason: '缺 type',
      );
    });

    test('allowCancel 恒为 true（就算模型想禁掉取消）', () {
      const r = AskRequest(question: 'q', type: AskType.confirm);
      expect(r.allowCancel, isTrue, reason: '"拒绝"本身就是合法回答');

      // 一圈编解码之后仍然是 true
      final p = PendingAsk(toolCallId: 'c', request: r);
      expect(PendingAsk.tryParse(p.encode())!.request.allowCancel, isTrue);
    });
  });

  group('挂起状态在数据库里（杀掉 App 重开还能继续）', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('写进去之后，新建一个连接也读得到', () async {
      final conv = await _newConversation(db);
      final msgId = 'm1';
      await db.insertAiMessage(AiMessagesCompanion.insert(
        id: msgId,
        conversationId: conv.id,
        role: 'assistant',
        createdAt: DateTime.now().toUtc(),
        content: const Value('（等你回答）'),
      ));
      await db.setPendingAction(
        msgId,
        PendingAsk(
          toolCallId: 'c1',
          request: const AskRequest(question: '选哪篇？', type: AskType.text),
        ).encode(),
      );

      // 模拟"重启"：只从库里读，不看任何内存状态
      final row = await db.pendingAskMessage(conv.id);
      expect(row, isNotNull);
      final pending = PendingAsk.tryParse(row!.pendingAction);
      expect(pending, isNotNull);
      expect(pending!.request.question, '选哪篇？');
      expect(pending.toolCallId, 'c1');
    });

    test('没有挂起时返回 null', () async {
      final conv = await _newConversation(db);
      expect(await db.pendingAskMessage(conv.id), isNull);
    });

    test('清掉之后就读不到了（回答过 / 取消对话）', () async {
      final conv = await _newConversation(db);
      await db.insertAiMessage(AiMessagesCompanion.insert(
        id: 'm1',
        conversationId: conv.id,
        role: 'assistant',
        createdAt: DateTime.now().toUtc(),
      ));
      await db.setPendingAction('m1', '{"kind":"askUser"}');
      expect(await db.pendingAskMessage(conv.id), isNotNull);

      await db.setPendingAction('m1', null);

      expect(await db.pendingAskMessage(conv.id), isNull);
    });

    test('只在**本会话**里找挂起', () async {
      final a = await _newConversation(db);
      final b = await _newConversation(db);
      await db.insertAiMessage(AiMessagesCompanion.insert(
        id: 'ma',
        conversationId: a.id,
        role: 'assistant',
        createdAt: DateTime.now().toUtc(),
      ));
      await db.setPendingAction('ma', '{"kind":"askUser"}');

      expect(await db.pendingAskMessage(a.id), isNotNull);
      expect(await db.pendingAskMessage(b.id), isNull);
    });
  });

  group('AskResolver：选项来自 App 的查询', () {
    late AppDatabase db;
    late NoteRepository notes;
    late AskResolver resolver;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      notes = NoteRepository(db);
      resolver = AskResolver(db);
    });
    tearDown(() => db.close());

    test('★ source=search：选项是**现查**的，不是模型编的', () async {
      final hit = await notes.createInbox(title: '产品会议记录', content: '讨论了排期。');
      await notes.createInbox(title: '无关笔记', content: '别的。');

      final options = await resolver.resolve(const AskRequest(
        question: '改哪一篇？',
        type: AskType.singleChoice,
        source: AskSource(kind: 'search', query: '会议'),
      ));

      expect(options, hasLength(1));
      expect(options.single.id, hit.id, reason: 'id 必须是**库里真实存在**的');
      expect(options.single.label, '产品会议记录');
    });

    test('★ 用户删掉笔记后，选项里不会再有它', () async {
      final note = await notes.createInbox(title: '会议记录', content: 'x');
      var options = await resolver.resolve(const AskRequest(
        question: 'q',
        type: AskType.singleChoice,
        source: AskSource(kind: 'search', query: '会议'),
      ));
      expect(options, hasLength(1));

      await notes.softDelete(note.id);

      options = await resolver.resolve(const AskRequest(
        question: 'q',
        type: AskType.singleChoice,
        source: AskSource(kind: 'search', query: '会议'),
      ));
      expect(options, isEmpty, reason: '这就是"选项由 App 现查"要解决的问题');
    });

    test('同一篇笔记命中多片只留一条（用户选的是"哪一篇"）', () async {
      final note = await notes.createInbox(
        title: 'N',
        content: '# 甲章\n\n${'甲。' * 300}\n\n关键词在这。\n\n'
            '# 乙章\n\n${'乙。' * 300}\n\n关键词也在这。',
      );

      final options = await resolver.resolve(AskRequest(
        question: 'q',
        type: AskType.singleChoice,
        source: const AskSource(kind: 'search', query: '关键词'),
      ));

      expect(options, hasLength(1), reason: '命中多片仍是同一篇');
      expect(options.single.id, note.id);
    });

    test('source=notebooks：列笔记库', () async {
      final nb = await NotebookRepository(db).create(name: '工作');
      final options = await resolver.resolve(const AskRequest(
        question: '放哪个库？',
        type: AskType.singleChoice,
        source: AskSource(kind: 'notebooks'),
      ));
      expect(options.single.id, nb.id);
      expect(options.single.label, '工作');
    });

    test('source=recentNotes：列最近的笔记', () async {
      await notes.createInbox(title: '最近的', content: 'x');
      final options = await resolver.resolve(const AskRequest(
        question: 'q',
        type: AskType.singleChoice,
        source: AskSource(kind: 'recentNotes'),
      ));
      expect(options.single.label, '最近的');
    });

    test('无标题的笔记给"无标题"，不是空标签', () async {
      await notes.createInbox(title: '', content: 'x');
      final options = await resolver.resolve(const AskRequest(
        question: 'q',
        type: AskType.singleChoice,
        source: AskSource(kind: 'recentNotes'),
      ));
      expect(options.single.label, '无标题');
    });

    test('limit 生效（不会把 200 条笔记全塞进选项）', () async {
      for (var i = 0; i < 20; i++) {
        await notes.createInbox(title: '笔记$i', content: 'x');
      }
      final options = await resolver.resolve(const AskRequest(
        question: 'q',
        type: AskType.singleChoice,
        source: AskSource(kind: 'recentNotes'),
        limit: 4,
      ));
      expect(options, hasLength(4));
    });

    test('未知 kind 也尽量给出选项（退回搜索），而不是空手失败', () async {
      await notes.createInbox(title: '会议', content: 'x');
      final options = await resolver.resolve(const AskRequest(
        question: 'q',
        type: AskType.singleChoice,
        source: AskSource(kind: '模型编的kind', query: '会议'),
      ));
      expect(options, isNotEmpty);
    });

    test('不用 source 时用模型给的清单，但**丢掉没有 id 的项**', () async {
      final options = await resolver.resolve(const AskRequest(
        question: 'q',
        type: AskType.singleChoice,
        options: [
          AskOption(id: 'a', label: '甲'),
          AskOption(id: '', label: '没 id 的'),
          AskOption(id: 'b', label: '乙'),
        ],
      ));
      expect(options.map((o) => o.id), ['a', 'b'],
          reason: '没有 id 的选项用户选了也没法回灌给模型');
    });

    test('模型给的选项超过 10 条会被截断', () async {
      final options = await resolver.resolve(AskRequest(
        question: 'q',
        type: AskType.multipleChoice,
        options: [for (var i = 0; i < 30; i++) AskOption(id: '$i', label: '$i')],
        limit: 10,
      ));
      expect(options, hasLength(10));
    });
  });

  group('AgentLoop：问不过 3 次', () {
    late AppDatabase db;
    late ToolExecutor executor;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      executor = ToolExecutor(db);
    });
    tearDown(() => db.close());

    test('★ 第 4 次 askUser 会被挡下，让模型收尾', () async {
      var round = 0;
      final seen = <String>[];

      Stream<AiEvent> fake({
        required String systemPrompt,
        required List<AgentMessage> messages,
        required List<ToolSpec> tools,
      }) {
        round++;
        seen.addAll(messages.where((m) => m.role == 'tool').map((m) => m.content));
        if (round <= 4) {
          return Stream.value(AiDone(
            toolCalls: [
              ToolCall(
                id: 'c$round',
                name: 'askUser',
                arguments:
                    '{"question":"问第$round 次","type":"text"}',
              ),
            ],
          ));
        }
        return Stream.value(const AiDone(fullText: '好，我直接说。'));
      }

      // 模拟"用户每次都回答"：循环被挂起后由调用方重新跑，asksSoFar 带回来。
      // 这一条正是上限能生效的关键 —— 不累计的话每次恢复都从 0 数起。
      var asksSoFar = 0;
      var asked = 0;
      for (var i = 0; i < 10; i++) {
        var suspended = false;
        await for (final e in AgentLoop(round: fake, executor: executor).run(
          systemPrompt: 'SYS',
          history: [AgentMessage.user('x')],
          asksSoFar: asksSoFar,
        )) {
          if (e is AgentAwaitingUser) {
            asksSoFar = e.asks;
            asked++;
            suspended = true;
          }
        }
        if (!suspended) break; // 模型不再问 → 收尾
      }

      expect(asked, AgentLoop.maxAsksPerTurn,
          reason: '问到第 ${AgentLoop.maxAsksPerTurn} 次就该封顶');
      // 第 4 次（被拒的那次）会得到一条"不要再问"的工具结果
      expect(
        seen.any((c) => c.contains('不要再问')),
        isTrue,
        reason: '要明确告诉模型"别再问了"，而不是静默忽略',
      );
    });

    test('asksSoFar 直接生效：已问满 3 次时，再问就被拒', () async {
      final toolResults = <String>[];

      Stream<AiEvent> asking({
        required String systemPrompt,
        required List<AgentMessage> messages,
        required List<ToolSpec> tools,
      }) {
        // 把回灌进来的工具结果收下来，断言里要看它
        toolResults
          ..clear()
          ..addAll(messages.where((m) => m.role == 'tool').map((m) => m.content));
        return Stream.value(AiDone(toolCalls: [
          const ToolCall(
            id: 'c1',
            name: 'askUser',
            arguments: '{"question":"还想问","type":"text"}',
          ),
        ]));
      }

      final events = await AgentLoop(round: asking, executor: executor).run(
        systemPrompt: 'SYS',
        history: [AgentMessage.user('x')],
        asksSoFar: AgentLoop.maxAsksPerTurn,
      ).toList();

      // 已经问满 → 不该再挂起
      expect(events.whereType<AgentAwaitingUser>(), isEmpty);
      // 而且要**明确告诉模型别再问了**（不是静默忽略）
      expect(toolResults.any((c) => c.contains('不要再问')), isTrue);
      // 它还会再试一次，所以最终仍可能耗尽轮数；关键是它拿到了"别再问"的反馈
      expect(events.whereType<AgentFinished>(), isEmpty);
    });
    test('没到上限时正常挂起，并带上"问到第几次"', () async {
      final events = await AgentLoop(
        round: ({
          required String systemPrompt,
          required List<AgentMessage> messages,
          required List<ToolSpec> tools,
        }) =>
            Stream.value(AiDone(toolCalls: [
          const ToolCall(
            id: 'c1',
            name: 'askUser',
            arguments: '{"question":"哪一篇？","type":"text"}',
          ),
        ])),
        executor: executor,
      ).run(
        systemPrompt: 'SYS',
        history: [AgentMessage.user('x')],
        asksSoFar: 1,
      ).toList();

      final waiting = events.whereType<AgentAwaitingUser>().single;
      expect(waiting.asks, 2, reason: '要把累计次数带给调用方存下来');
    });
  });
}
/// 建一个会话（用真实仓储，避免手写 companion 漏字段）
Future<AiConversation> _newConversation(AppDatabase db) => AiChatRepository(
      db: db,
      ai: AiRepository(db: db, client: DeepSeekClient()),
    ).createConversation();
