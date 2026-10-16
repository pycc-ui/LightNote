// 会话记忆：从 AI 入口进页面时，**回到上次看的那条会话**。
//
// 四行期望（见《界面设计》的 AI 页一节）：
//   冷启动（新进程）        → 空状态
//   页面重建（切 tab / 返回）→ 上次查看的那条
//   用户切换会话            → 记住新的那条
//   点「新建会话」          → 切空状态（不落库、不建行）
//   会话被删                → 校验时发现并忘掉它
//
// 为什么必须是 widget 测试：记住的是**页面级**状态，判断逻辑在 `_bootstrap` /
// `_activate` 里（什么时候读、什么时候写、什么时候清）。纯数据层测不到
// "挂载之后界面到底停在哪"。
import 'dart:async';

import 'package:dio/dio.dart' show CancelToken;
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/core/db/models.dart';
import 'package:lightnote/features/ai/data/deepseek_client.dart';
import 'package:lightnote/features/ai/domain/ai_chat_repository.dart';
import 'package:lightnote/features/ai/domain/ai_repository.dart';
import 'package:lightnote/features/ai/domain/tool_types.dart';
import 'package:lightnote/features/ai/ui/ai_page.dart';

/// 不会真的联网的客户端（这些用例从不发送消息）。
class SilentClient extends DeepSeekClient {
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
  }) =>
      const Stream.empty();

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
      const Stream.empty();
}

void main() {
  late AppDatabase db;
  late AiChatRepository chat;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    chat = AiChatRepository(
      db: db,
      ai: AiRepository(db: db, client: SilentClient()),
    );
  });
  tearDown(() => db.close());

  Widget host() => MultiProvider(
        providers: [
          Provider<AppDatabase>.value(value: db),
          Provider<AiChatRepository>.value(value: chat),
        ],
        child: const MaterialApp(home: AiPage()),
      );

  /// 让它把异步的 `_bootstrap`（读库）跑完。
  ///
  /// 不能用 `pumpAndSettle`：它等的是动画与定时器，而这里等的是一个 Future
  /// （drift 查询），settle 会在它落地之前就返回。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// 测试收尾：先把页面拆掉，让 drift 的 stream 查询取消时排的那个零延时
  /// timer 落地。不这么做的话，框架在拆树时会报「A Timer is still pending」——
  /// 那是 drift 清理订阅的内部动作，不是被测代码的问题。
  Future<void> teardownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  /// 造一条**有消息**的会话（会话列表只列有消息的）。
  Future<String> convWith(String title, String content) async {
    final c = await chat.createConversation();
    await db.insertAiMessage(AiMessagesCompanion.insert(
      id: 'm-${c.id}',
      conversationId: c.id,
      role: 'user',
      content: Value(content),
      createdAt: DateTime.now().toUtc(),
    ));
    await db.touchConversation(c.id, title: title);
    return c.id;
  }

  group('★ 会话记忆', () {
    testWidgets('冷启动（新进程）→ 停在空状态，不跳到"最近聊过的"', (tester) async {
      await convWith('甲会话', '甲的内容');

      await tester.pumpWidget(host());
      await settle(tester);

      expect(find.text('LightNote AI'), findsOneWidget, reason: '应当是空状态');
      expect(find.text('甲的内容'), findsNothing,
          reason: '冷启动没有记忆：进页面不该自作主张打开最近那条');
      await teardownTree(tester);
    });

    testWidgets('页面重建（切 tab / 返回再进）→ 回到上次查看的那条', (tester) async {
      final a = await convWith('甲会话', '甲的内容');
      chat.currentConversationId = a; // 上次看的是甲

      // 先挂一个别的页面（模拟"离开"），再挂回来（模拟"返回再进"）
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpWidget(host());
      await settle(tester);

      expect(find.text('甲的内容'), findsOneWidget);
      expect(chat.currentConversationId, a);
      await teardownTree(tester);
    });

    testWidgets('切换会话 → 记住新的那条', (tester) async {
      await convWith('甲会话', '甲的内容');
      final b = await convWith('乙会话', '乙的内容');

      await tester.pumpWidget(host());
      await settle(tester);

      // 打开「会话记录」→ 点乙
      await tester.tap(find.byTooltip('会话记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('乙会话'));
      await settle(tester);

      expect(find.text('乙的内容'), findsOneWidget);
      expect(chat.currentConversationId, b, reason: '切过的那条要被记住');
      await teardownTree(tester);
    });

    testWidgets('点「新建会话」→ 切空状态，并且忘掉原来那条', (tester) async {
      final a = await convWith('甲会话', '甲的内容');
      chat.currentConversationId = a;

      await tester.pumpWidget(host());
      await settle(tester);
      expect(find.text('甲的内容'), findsOneWidget);

      await tester.tap(find.byTooltip('新建会话'));
      await settle(tester);

      expect(find.text('LightNote AI'), findsOneWidget);
      expect(chat.currentConversationId, isNull, reason: '新建 = 清空记忆');
      expect(find.text('甲的内容'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('★ 新建**不落库**：点 3 次也不多出空会话', (tester) async {
      await tester.pumpWidget(host());
      await settle(tester);

      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byTooltip('新建会话'));
        await settle(tester);
      }

      final n = await db
          .customSelect('SELECT COUNT(*) AS n FROM ai_conversations')
          .getSingle();
      expect(n.read<int>('n'), 0,
          reason: '空会话根本不该存在：行由第一次发送时创建');
      await teardownTree(tester);
    });

    testWidgets('会话被删 → 下次进来发现它没了，忘掉并停在空状态', (tester) async {
      final a = await convWith('甲会话', '甲的内容');
      chat.currentConversationId = a;
      await db.deleteConversation(a);

      await tester.pumpWidget(host());
      await settle(tester);

      expect(find.text('LightNote AI'), findsOneWidget);
      expect(chat.currentConversationId, isNull,
          reason: '不清掉的话下次进来还会拿一个不存在的 id 去查');
      await teardownTree(tester);
    });
  });
}
