// **同 App 内换页不该被当成中断。**
//
// ## 报的是什么问题
//
// 用户在 AI 页发了消息，然后切到本应用的其他地方（AI 页是 push 上来的路由，
// 退出去就销毁），再回来 —— 界面弹出「上次生成中断（App 被系统中断）要不要继续」。
// **可那一轮根本没中断，还在正常跑。**
//
// ## 为什么以前会这样
//
// 判据是 `interrupt_reason != null && !busy`，而 `busy` 是**页面局部**的 `_sending`：
//
//   · `send()` 的 Future **不绑在 widget 上** —— 退出页面它照样跑；
//   · 退出时 State 被销毁、`_sending` 归 false；
//   · 再进页面是个**新 State**，`_sending` 还是 false；
//   · 而 `in_flight` 戳是**每轮开始就写上**的 → 于是一轮正常跑的生成，
//     看起来就是"有戳 + 没在生成" = 中断。
//
// 而且这时点「继续」会在同一条消息上**再起一轮**，两轮并发写同一条回答
//（防这道的那道闸在 AiChatRepository.send 里）。
//
// ## 修法
//
// "在不在跑"改由**仓库**回答（Provider 里的单例，生命周期 = 进程）：
// 内存里在跑 = 正在生成；内存里不在、库里却是 `in_flight` = 上次进程没了（真中断）。
//
// 这个文件就锁这两件事，两个方向都要测：**假中断不能再报**、**真中断还得报**。
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

/// 一个**永远不结束**的模型客户端：用来制造"这一轮还在跑"的状态。
///
/// 不用定时器、不用延时：`streamAgent` 返回一个受控的 Stream，测试想让它结束
/// 就 [finish]，不想就让它一直挂着 —— 这正是"用户切走了、任务还在跑"。
class HangingClient extends DeepSeekClient {
  final _controller = StreamController<AiEvent>();

  int calls = 0;

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
    calls++;
    return _controller.stream;
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
      const Stream.empty();

  /// 让这一轮正常收尾（不给工具调用 = 模型直接给答复）。
  Future<void> finish() async {
    _controller.add(const AiChunk('好'));
    await _controller.close();
  }
}

void main() {
  late AppDatabase db;
  late HangingClient client;
  late AiChatRepository chat;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    client = HangingClient();
    chat = AiChatRepository(db: db, ai: AiRepository(db: db, client: client));
  });
  tearDown(() => db.close());

  Widget host() => MultiProvider(
        providers: [
          Provider<AppDatabase>.value(value: db),
          Provider<AiChatRepository>.value(value: chat),
        ],
        child: const MaterialApp(home: AiPage()),
      );

  /// 把异步的 `_bootstrap`（读库）跑完。不能用 `pumpAndSettle`：它等的是动画与
  /// 定时器，而这里等的是一个 Future（drift 查询），settle 会在它落地前返回。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// 交替推**两个时钟**，直到这一轮收尾。
  ///
  /// ⚠️ 只推一个会卡住：`runAsync` 推的是真异步（drift、受控的 Stream），
  /// `pump` 推的是假时钟（widget 与帧）。而 `send()` 这条链**跨在两个 zone 上**
  ///（起点在 `runAsync` 里，续体要假时钟才动）—— 实测踩过：只推真异步的话
  /// `finish()` 之后 `isRunning` 一直是 true，看着像"登记漏摘了"，其实是没推它。
  Future<void> driveUntilIdle(WidgetTester tester, String convId) async {
    for (var i = 0; i < 100 && chat.isRunning(convId); i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)));
      await tester.pump(const Duration(milliseconds: 2));
    }
  }

  /// 发送按钮（用 tooltip 找：**忙碌时图标会换成转圈**，
  /// 按 `Icons.arrow_upward` 找会在"正忙"时找不到 —— 那正是要断言的场景）。
  IconButton sendButton(WidgetTester tester) => tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip('发送'),
          matching: find.byType(IconButton),
        ),
      );

  /// 页面拆掉，让 drift 排的那个零延时清理 timer 落地（否则框架会报
  /// "A Timer is still pending"，那是 drift 的内部动作）。
  Future<void> teardownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  /// 发一条消息并让它**卡在生成中**（返回会话 id 与那次 send 的 Future）。
  ///
  /// ⚠️ 必须用 `tester.runAsync`：`testWidgets` 默认跑在**假时钟**里，而
  /// `send()` 里面是一条真实的异步链（落库 → 读会话 → 读历史 → 起流），
  /// 光靠 `pump()` 推不动它 —— 表现是"等半天 isRunning 还是 false"。
  Future<(String, Future<String>)> sendAndHang(WidgetTester tester) async {
    final conv = await chat.createConversation();
    // 真机上这一步是界面做的：用户在 AI 页选中/新建一条会话时，
    // 页面会把它记到仓库上（`_activate` / `_ensureConversation`）。
    // 它存在**仓库**里而不是页面里，所以退出页面再回来还在 —— 这正是能认出
    // "刚才那条会话还在跑"的关键。这里手工补上这一步。
    chat.currentConversationId = conv.id;
    late Future<String> pending;

    await tester.runAsync(() async {
      pending = chat.send(
        conversationId: conv.id,
        userInput: '帮我整理一下上周的会议记录',
        thinkingEffort: 'medium',
        thinkingEnabled: false,
      );
      // 别让它变成未捕获的异步错误（成功了这条会被忽略）
      unawaited(pending.then((_) {}, onError: (Object e) {
        // ignore: avoid_print
        print('▸ send 抛了：$e');
      }));

      for (var i = 0; i < 200 && !chat.isRunning(conv.id); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });

    expect(chat.isRunning(conv.id), isTrue, reason: '这一轮应当已经在跑');
    return (conv.id, pending);
  }

  testWidgets('★★ 正在跑的时候重建页面 → 不能报"被中断"', (tester) async {
    final (convId, _) = await sendAndHang(tester);

    // 模拟用户"切走再回来"：全新 State，页面级的 _sending 一律是 false
    await tester.pumpWidget(host());
    await settle(tester);

    expect(find.textContaining('上次生成中断'), findsNothing,
        reason: '这一轮在正常跑，不该说它被打断了（这就是报的那个 bug）');
    expect(find.text('继续'), findsNothing);
    expect(find.textContaining('App 被系统中断'), findsNothing);

    // 而且这一轮确实在跑（不是"恰好跑完了所以没提示"）
    expect(chat.isRunning(convId), isTrue);

    // 界面该知道"还在生成"：发送按钮禁用（后台在跑时不该再发一条）
    expect(sendButton(tester).onPressed, isNull,
        reason: '后台还有一轮在跑，发送应当禁用');

    await client.finish();
    await driveUntilIdle(tester, convId);
    await settle(tester);
    expect(chat.isRunning(convId), isFalse, reason: '跑完之后要摘掉登记');
    await teardownTree(tester);
  });

  testWidgets('★ 真被系统杀掉（库里残留 in_flight、内存里没在跑）→ 仍然要提示', (tester) async {
    // 造一条"上次没写完"的回答：库里是 in_flight，但没有任何一轮在跑
    final conv = await chat.createConversation();
    await db.insertAiMessage(AiMessagesCompanion.insert(
      id: 'assistant-1',
      conversationId: conv.id,
      role: 'assistant',
      content: const Value('写到一半的内容'),
      createdAt: DateTime.now().toUtc(),
    ));
    await db.setMessageInterrupt('assistant-1', AiChatRepository.inFlightReason);
    await db.touchConversation(conv.id, title: '上次那条');

    chat.currentConversationId = conv.id;
    await tester.pumpWidget(host());
    await settle(tester);

    expect(find.textContaining('上次生成中断'), findsOneWidget,
        reason: '进程真的没了的话，提示必须还在 —— 修假中断不能把真中断也修掉');
    expect(find.textContaining('App 被系统中断'), findsOneWidget);

    await teardownTree(tester);
  });

  testWidgets('跑完之后不再显示"正在生成"（不会因为漏摘登记而永远转圈）',
      (tester) async {
    final (convId, _) = await sendAndHang(tester);
    await tester.pumpWidget(host());
    await settle(tester);

    await client.finish();
    await driveUntilIdle(tester, convId);
    await settle(tester);

    expect(chat.isRunning(convId), isFalse);
    // 跑完了 → 发送按钮恢复可用
    expect(sendButton(tester).onPressed, isNotNull,
        reason: '跑完之后应当能再发消息');
    await teardownTree(tester);
  });

  group('仓库那道闸', () {
    test('同一会话同时只能有一轮', () async {
      final conv = await chat.createConversation();

      unawaited(chat.send(
        conversationId: conv.id,
        userInput: '第一条',
        thinkingEffort: 'medium',
        thinkingEnabled: false,
      ));
      // 等到这一轮真的登记上
      for (var i = 0; i < 50 && !chat.isRunning(conv.id); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(chat.isRunning(conv.id), isTrue);

      await expectLater(
        chat.send(
          conversationId: conv.id,
          userInput: '第二条',
          thinkingEffort: 'medium',
          thinkingEnabled: false,
        ),
        throwsA(isA<StateError>()),
      );

      // 被拒的那次**不该在库里留下半条记录**
      final rows = await db.watchMessages(conv.id).first;
      expect(rows.where((r) => r.content == '第二条'), isEmpty);

      await client.finish();
      // 等这一轮收尾
      for (var i = 0; i < 100 && chat.isRunning(conv.id); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(chat.isRunning(conv.id), isFalse, reason: '摘登记要可靠，否则会话就废了');
    });

    test('不同会话互不影响（登记是按会话分的）', () async {
      final a = await chat.createConversation();
      final b = await chat.createConversation();

      unawaited(chat.send(
        conversationId: a.id,
        userInput: '甲',
        thinkingEffort: 'medium',
        thinkingEnabled: false,
      ));
      for (var i = 0; i < 50 && !chat.isRunning(a.id); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(chat.isRunning(a.id), isTrue);
      expect(chat.isRunning(b.id), isFalse,
          reason: '甲会话在跑，不该把乙会话也判成"正在生成"');

      await client.finish();
      for (var i = 0; i < 100 && chat.isRunning(a.id); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
  });
}
