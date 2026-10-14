// 动态函数标记（mark_functions）的**三层关系**：会话 > 问题 > 轮。
//
//   会话（Session）：打开 AI 页 → 关掉 / 新建会话
//   问题（用户发一次消息）：按发送 → AI 不再返回 tool_call
//   轮（一次 API 往返）：请求发出 → 响应回来（可能带 tool_call）
//
// 这里最容易理解错的是**生效时机**：
//   ❌ "下次会话生效"   —— 那要关掉 AI 页再开
//   ❌ "下次问题生效"   —— 那要用户再发一句
//   ✅ **当前问题的下一轮生效** —— 同一个问题内，标记完下一轮就用上
//
// 为什么不可能"本轮生效"：一次 API 请求只发一次。AI 在第 N 轮**响应里**
// 才说要标记，而第 N 轮的 system prompt 早就发出去了，改不了。
//
// ## 这个文件为什么必须装 UDF
//
// 要验的是「UDF 写 app_kv → 下一轮重拼读回来」这条**跨模块的线**，
// 所以数据库得和真机一样装着 UDF：`NativeDatabase.memory(setup: installAiUdfs)`。
// （其余测试里的 `NativeDatabase.memory()` 没装 UDF，那样 mark_functions
// 只会拿到 no such function —— 测不到这条线。）
import 'dart:convert';

import 'package:dio/dio.dart' show CancelToken;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/core/db/ai_functions.dart';
import 'package:lightnote/core/db/ai_udfs.dart';
import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/core/db/models.dart';
import 'package:lightnote/features/ai/data/deepseek_client.dart';
import 'package:lightnote/features/ai/domain/ai_chat_repository.dart';
import 'package:lightnote/features/ai/domain/ai_repository.dart';
import 'package:lightnote/features/ai/domain/prompts.dart';
import 'package:lightnote/features/ai/domain/tool_executor.dart';
import 'package:lightnote/features/ai/domain/tool_types.dart';

/// 按脚本回答的假客户端：记录每次请求的 system prompt，按轮吐 tool_call。
class ScriptedClient extends DeepSeekClient {
  /// 每次 `streamAgent` 收到的 system prompt（按时间顺序）。
  final List<String> seenSystem = [];

  /// 逐轮脚本：第 i 项是第 i 轮要提的工具调用；脚本用完就收尾（不提工具）。
  final List<List<ToolCall>> scripts = [];

  int _at = 0;

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
    seenSystem.add(systemPrompt);
    final calls = _at < scripts.length ? scripts[_at++] : const <ToolCall>[];
    return Stream.value(AiDone(fullText: calls.isEmpty ? '好了' : '', toolCalls: calls));
  }

  /// 更早历史压缩用的（本文件里会话都很短，走不到）。
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

  /// 让第 [round] 轮提出「调 mark_functions 标记 [names]」。
  void mark(List<String> names) {
    scripts.add([
      ToolCall(
        id: 'c${scripts.length}',
        name: 'sql',
        arguments: jsonEncode({
          'query': "SELECT mark_functions('${jsonEncode(names)}')",
        }),
      ),
    ]);
  }
}

void main() {
  late AppDatabase db;
  late ScriptedClient client;
  late AiChatRepository chat;

  const detailHeading = '## 已加载函数详情';

  setUp(() {
    // 装 UDF：这一层要验的就是 UDF 与 App 的接力
    db = AppDatabase.forTesting(NativeDatabase.memory(setup: installAiUdfs));
    client = ScriptedClient();
    chat = AiChatRepository(db: db, ai: AiRepository(db: db, client: client));
  });
  tearDown(() => db.close());

  Future<String> ask(String conversationId, String text) => chat.send(
        conversationId: conversationId,
        userInput: text,
        thinkingEffort: 'medium',
        thinkingEnabled: false,
      );

  Future<List<String>> pinnedInDb() async =>
      parsePinnedFunctions(await db.readSetting(kAiPinnedFunctionsKey));

  group('★ 标记在**当前问题的下一轮**生效', () {
    test('轮 1 标记 → 轮 2 的 system prompt 末尾就带上详情', () async {
      final conv = await chat.createConversation();
      client.mark(['search_notes']); // 轮 1：标记

      await ask(conv.id, '把项目A的笔记找出来');

      expect(client.seenSystem, hasLength(2), reason: '这个问题是 2 轮');
      final round1 = client.seenSystem[0];
      final round2 = client.seenSystem[1];

      expect(round1, isNot(contains(detailHeading)),
          reason: '轮 1 时一个函数都没标记，不该有详情段');
      expect(round2, contains(detailHeading), reason: '标记后下一轮必须带上详情');
      expect(round2, contains('search_notes(keyword, limit)'));
      expect(round2, contains('例：SELECT search_notes('),
          reason: '详情里要有能照抄的 example');
    });

    test('★ 前缀一字不变（只有新增的那一段不命中缓存）', () async {
      final conv = await chat.createConversation();
      client.mark(['search_notes']);
      client.mark(['read_preview']); // 轮 2 再标一个 → 轮 3 该看到两个

      await ask(conv.id, '整理一下');

      expect(client.seenSystem, hasLength(3));
      final [r1, r2, r3] = client.seenSystem;
      expect(r2.startsWith(r1), isTrue, reason: '追加式：前缀不能重写');
      expect(r3.startsWith(r2), isTrue, reason: '追加式：前缀不能重写');
      expect(r3, contains('read_preview(note_id'));
      expect(r3, contains('search_notes(keyword, limit)'));
    });

    test('标记真的写进了 app_kv（会话结束也不丢）', () async {
      final conv = await chat.createConversation();
      client.mark(['search_notes']);

      await ask(conv.id, '随便');

      expect(await pinnedInDb(), ['search_notes']);
    });
  });

  group('★ 会话 / 问题的边界', () {
    test('下一次问题沿用同一份详情段（详情段会话内只增不改）', () async {
      final conv = await chat.createConversation();
      client.mark(['search_notes']);
      await ask(conv.id, '第一问');
      final endOfQ1 = client.seenSystem.last;

      await ask(conv.id, '第二问'); // 问题 2：1 轮就收尾
      final startOfQ2 = client.seenSystem.last;

      expect(startOfQ2, endOfQ1,
          reason: '同样从 app_kv 拼出来：固定段与详情段逐字一致 → '
              '第二次问题的第一轮照样命中缓存');
    });

    test('换个会话（相当于关掉 AI 页重开）标记还在', () async {
      final first = await chat.createConversation();
      client.mark(['search_notes']);
      await ask(first.id, '第一问');

      final second = await chat.createConversation();
      await ask(second.id, '新会话第一句');

      expect(client.seenSystem.last, contains('search_notes(keyword, limit)'),
          reason: '标记存在 app_kv，不随会话结束消失');
    });

    test('没标记过的会话开头：固定段 + 空详情段', () async {
      final conv = await chat.createConversation();
      await ask(conv.id, '你好');

      expect(client.seenSystem.single, AiPrompts.agentSystem,
          reason: '没有摘要、没有标记时，system prompt 就该等于固定段本身');
    });
  });

  group('prompt 与库的契约', () {
    test('★ prompt 里那条目录查询真的能跑（列名对得上）', () async {
      final r = await ToolExecutor(db)
          .execute('sql', {'query': AiPrompts.catalogQuery});

      expect(r.ok, isTrue, reason: r.error ?? '目录查询失败');
      final rows = (r.data as Map)['rows'] as List;
      expect(rows, hasLength(kAiFunctions.length),
          reason: '目录要列出全部 ${kAiFunctions.length} 个函数');
      expect((rows.first as Map).keys, containsAll(['name', 'signature']));
    });

    test('标记清单里的每个名字都能在目录里查到（否则详情段渲染不出来）', () async {
      final r = await ToolExecutor(db)
          .execute('sql', {'query': AiPrompts.catalogQuery});
      final names = {
        for (final row in (r.data as Map)['rows'] as List)
          (row as Map)['name'] as String,
      };

      expect(names, {for (final f in kAiFunctions) f.name});
    });
  });
}
