// 更早历史的压缩摘要（§8.6）。
//
// 两条要害：
//   · 摘要必须**只生成一次** —— 每轮都重压的话，省下的历史 token 又被压缩调用
//     吃回去，白忙一场
//   · 窗口与"更早"必须**严格互补** —— 错位就会漏掉整轮对话（而且不报错）
import 'package:dio/dio.dart' show CancelToken;
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/core/db/models.dart';
import 'package:lightnote/features/ai/data/deepseek_client.dart';
import 'package:lightnote/features/ai/domain/ai_chat_repository.dart';
import 'package:lightnote/features/ai/domain/ai_repository.dart';
import 'package:lightnote/features/ai/domain/tool_types.dart';

/// 假客户端：`streamChat` 返回固定摘要并**计数**（验"只生成一次"），
/// `streamAgent` 直接给一句回答（让 send 能跑完）。
class FakeClient extends DeepSeekClient {
  int chatCalls = 0;
  String summary = '用户想要整理会议记录，已经确定按项目分。';

  @override
  bool get hasApiKey => true;

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
  }) {
    chatCalls++;
    return Stream.fromIterable([
      AiChunk(summary),
      const AiDone(fullText: ''),
    ]);
  }

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
    seenSystem.add(systemPrompt);
    return Stream.value(const AiDone(fullText: '好'));
  }

  final List<String> seenSystem = [];
}

void main() {
  late AppDatabase db;
  late FakeClient client;
  late AiChatRepository chat;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    client = FakeClient();
    chat = AiChatRepository(db: db, ai: AiRepository(db: db, client: client));
  });
  tearDown(() => db.close());

  var seq = 0;
  AiMessage row(String role, String content) => AiMessage(
        id: 'm${seq++}',
        conversationId: 'c',
        role: role,
        content: content,
        pendingAction: null,
        createdAt: DateTime.utc(2026, 1, 1).add(Duration(seconds: seq)),
      );

  List<AiMessage> rounds(int n) => [
        for (var i = 0; i < n; i++) ...[
          row('user', '第$i问'),
          row('assistant', '第$i答'),
        ],
      ];

  group('★ 窗口与"更早"严格互补', () {
    test('两者合起来正好是全部消息，一条不多一条不少', () {
      for (final n in [1, 3, 5, 6, 10, 50]) {
        final all = rounds(n);
        final window = AiChatRepository.historyWindowOf(all);
        final older = AiChatRepository.olderHistoryOf(all);
        expect(window.length + older.length, all.length, reason: '$n 轮时对不上');
        expect(older.map((m) => m.content).toSet()
            .intersection(window.map((m) => m.content).toSet()), isEmpty,
            reason: '$n 轮时有重叠 —— 同一条会被算两遍');
      }
    });

    test('顺序也对：更早的在前，窗口在后', () {
      final all = rounds(8);
      final older = AiChatRepository.olderHistoryOf(all);
      final window = AiChatRepository.historyWindowOf(all);

      // 更早部分的最后一条，应当紧挨着窗口的第一条
      
      final joined = [for (final m in older) m.content, for (final m in window) m.content];
      expect(joined, [for (final m in all) m.content], reason: '拼起来顺序必须还原原文');
    });

    test('不多于 5 轮时"更早"为空', () {
      expect(AiChatRepository.olderHistoryOf(rounds(5)), isEmpty);
      expect(AiChatRepository.olderHistoryOf(rounds(6)), hasLength(2),
          reason: '第 6 轮把第 0 轮挤了出去');
    });

    test('空会话 / 全空白 → 两边都是空', () {
      expect(AiChatRepository.olderHistoryOf(const []), isEmpty);
      expect(AiChatRepository.historyWindowOf(const []), isEmpty);
    });
  });

  group('拼进 system prompt', () {
    test('有摘要时拼在**末尾**（前缀一致才命中缓存）', () {
      const base = '你是 LightNote 的助手…';
      final out = AiChatRepository.withSummary(base, '用户想要整理会议记录。');

      expect(out.startsWith(base), isTrue, reason: '前缀必须一字不变');
      expect(out, endsWith('用户想要整理会议记录。'));
    });

    test('摘要是空的 → 原样返回（不留多余空行）', () {
      const base = 'SYS';
      expect(AiChatRepository.withSummary(base, ''), base);
      expect(AiChatRepository.withSummary(base, '   '), base);
    });
  });

  group('★ 只生成一次', () {
    test('第一次 send 生成并落库；第二次 send **不再调用**', () async {
      final conv = await chat.createConversation();
      // 堆 8 轮历史 → 有 3 轮落在窗口外
      for (var i = 0; i < 8; i++) {
        await db.insertAiMessage(AiMessagesCompanion.insert(
          id: 'h${i}u',
          conversationId: conv.id,
          role: 'user',
          content: Value('历史第$i问'),
          createdAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: i * 2)),
        ));
        await db.insertAiMessage(AiMessagesCompanion.insert(
          id: 'h${i}a',
          conversationId: conv.id,
          role: 'assistant',
          content: Value('历史第$i答'),
          createdAt:
              DateTime.utc(2026, 1, 1).add(Duration(minutes: i * 2 + 1)),
        ));
      }

      Future<void> sendOnce() => chat.send(
            conversationId: conv.id,
            userInput: '接着说',
            contextNoteIds: const [],
            thinkingEffort: 'low',
            thinkingEnabled: false,
          );

      await sendOnce();
      expect(client.chatCalls, 1, reason: '第一次该生成摘要');
      expect(
        await db.readSetting('${AiChatRepository.summaryKeyPrefix}${conv.id}'),
        isNotNull,
        reason: '要落库，否则下次还得重算',
      );
      // 摘要进了 system prompt
      expect(client.seenSystem.last, contains('整理会议记录'));

      await sendOnce();
      expect(client.chatCalls, 1, reason: '第二次**不该**再压一遍（白花钱）');
    });

    test('历史不够 5 轮时根本不调压缩（没有"更早的"）', () async {
      final conv = await chat.createConversation();
      await db.insertAiMessage(AiMessagesCompanion.insert(
        id: 'u1',
        conversationId: conv.id,
        role: 'user',
        content: const Value('就一句话'),
        createdAt: DateTime.utc(2026, 1, 1),
      ));

      await chat.send(
        conversationId: conv.id,
        userInput: '再说一句',
        contextNoteIds: const [],
        thinkingEffort: 'low',
        thinkingEnabled: false,
      );

      expect(client.chatCalls, 0, reason: '没有更早的历史，压缩纯属浪费');
      expect(client.seenSystem.last, isNot(contains('整理会议记录')));
    });

    test('压缩失败**不拖垮整轮对话**', () async {
      final conv = await chat.createConversation();
      for (var i = 0; i < 8; i++) {
        await db.insertAiMessage(AiMessagesCompanion.insert(
          id: 'x${i}u',
          conversationId: conv.id,
          role: 'user',
          content: Value('历史第$i问'),
          createdAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: i * 2)),
        ));
        await db.insertAiMessage(AiMessagesCompanion.insert(
          id: 'x${i}a',
          conversationId: conv.id,
          role: 'assistant',
          content: Value('历史第$i答'),
          createdAt:
              DateTime.utc(2026, 1, 1).add(Duration(minutes: i * 2 + 1)),
        ));
      }
      // 让压缩那条路报错
      client.summary = '';

      await chat.send(
        conversationId: conv.id,
        userInput: '接着说',
        contextNoteIds: const [],
        thinkingEffort: 'low',
        thinkingEnabled: false,
      );

      // 对话照常完成（没有摘要顶多多花点 token）
      final rows = await db.watchMessages(conv.id).first;
      expect(rows.any((m) => m.content == '好'), isTrue, reason: 'AI 的回答要落下来');
    });

    test('删会话时顺手清掉摘要（app_kv 不跟外键走）', () async {
      final conv = await chat.createConversation();
      await db.writeSetting(
        '${AiChatRepository.summaryKeyPrefix}${conv.id}',
        '旧摘要',
      );

      await chat.deleteConversation(conv.id);

      expect(
        await db.readSetting('${AiChatRepository.summaryKeyPrefix}${conv.id}'),
        isNull,
        reason: '不清就是一条永远读不到的垃圾',
      );
    });

    test('批量删会话时，**每一条**的摘要都要清掉（不是只清第一条）', () async {
      // 会话记录页的「多选 → 删除」走的就是这条路径：单条删除是它的特例
      //（`deleteConversation` 就是 `deleteConversations([id])`），
      // 所以这里盯的是"循环清 key"那一步别写成只清一个。
      final a = await chat.createConversation();
      final b = await chat.createConversation();
      await db.writeSetting('${AiChatRepository.summaryKeyPrefix}${a.id}', 'A 的摘要');
      await db.writeSetting('${AiChatRepository.summaryKeyPrefix}${b.id}', 'B 的摘要');

      final n = await chat.deleteConversations([a.id, b.id]);

      expect(n, 2);
      for (final id in [a.id, b.id]) {
        expect(
          await db.readSetting('${AiChatRepository.summaryKeyPrefix}$id'),
          isNull,
          reason: '会话 $id 的摘要没清掉',
        );
      }
    });

    test('批量删会话：空列表是安全 no-op（返回 0，不动任何数据）', () async {
      final conv = await chat.createConversation();
      await db.writeSetting('${AiChatRepository.summaryKeyPrefix}${conv.id}', '留着');

      expect(await chat.deleteConversations(const []), 0);
      expect(await db.getConversation(conv.id), isNotNull);
      expect(
        await db.readSetting('${AiChatRepository.summaryKeyPrefix}${conv.id}'),
        '留着',
      );
    });
  });
}
