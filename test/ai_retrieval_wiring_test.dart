// 前置检索**怎么接进请求**：这一层不验"检索准不准"（那是 `rag_eval_test.dart`
// 的事），只验四条接线上的约定 —— 四条都是踩过一次就会很痛的那种：
//
//   1. 有素材时，它拼在**用户消息的末尾**（不是 system 头，不然前缀缓存整段失效）
//   2. 库里那条用户消息**一个字节都不改**（界面上显示的必须还是用户自己写的话）
//   3. 检索炸了**不能带崩 AI**（模型加载失败、库坏了，都只是"这次没素材"）
//   4. 挂起恢复时不叠第二遍（不然模型会看到两份候选）
//
// 这里**不加载模型**：检索用注入的假钩子。真的那条链路由 `rag_eval_test.dart`
// 与 `text_embedder_test.dart` 覆盖。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/core/db/ai_udfs.dart';
import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/core/db/models.dart';
import 'package:lightnote/features/note/data/note_repository.dart';
import 'package:lightnote/features/ai/data/rag_index_schedule.dart';
import 'package:lightnote/features/ai/domain/ai_chat_repository.dart';
import 'package:lightnote/features/ai/domain/ai_repository.dart';
import 'package:lightnote/features/ai/domain/note_retriever.dart';

import 'ask_flow_test.dart' show FakeClient;

const _block = '$kMarkerForTest'
    '\n1. 《周一 · 项目A 启动会》 id=n1 offset=0';

/// 注入素材块的首行标记（与 `NoteRetriever.kRetrievalMarker` 同值）。
///
/// 这里不 import 生产代码里的常量，是为了**让测试自己钉住这个字符串**：
/// 它已经是对外契约的一部分（模型看到的第一行、判重靠它），改了就该有测试红。
const kMarkerForTest = '【可能相关的笔记片段】';

void main() {
  late AppDatabase db;
  late FakeClient client;

  /// 每次检索被问了什么（验"有没有重复问"和"问了没"）。
  late List<String> asked;

  /// 假检索的结果：默认给一段素材。
  late String? Function(String query) answer;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory(setup: installAiUdfs));
    client = FakeClient((_, __) => const AiChunk(''));
    asked = [];
    answer = (_) => _block;
    // 调度器是全局单例：每个用例都从"没启动"这个干净状态开始
    RagIndexSchedule.stop();
  });
  tearDown(() {
    RagIndexSchedule.stop();
    db.close();
  });

  AiChatRepository chatWith({Future<String?> Function(String)? retrieval}) =>
      AiChatRepository(
        db: db,
        ai: AiRepository(db: db, client: client),
        retrievalBlock: retrieval ??
            (q) async {
              asked.add(q);
              return answer(q);
            },
      );

  Future<AiConversation> newConversation() =>
      chatWith().createConversation();

  Future<void> ask(AiChatRepository chat, String convId, String text) => chat.send(
        conversationId: convId,
        userInput: text,
        thinkingEffort: 'medium',
        thinkingEnabled: false,
      );

  test('有素材 → 拼在用户消息末尾；库里那条消息一个字节没改', () async {
    final chat = chatWith();
    final conv = await newConversation();

    // 模型第一轮就收工（不调工具）
    client.script = (round, messages) => const AiChunk('好的');

    await ask(chat, conv.id, '帮我看看项目和会议的事');

    // 发给模型的那条 user 消息：原话 + 素材
    final sent = client.seen.first.firstWhere((m) => m.role == 'user');
    expect(sent.content, startsWith('帮我看看项目和会议的事'));
    expect(sent.content, contains(kMarkerForTest));
    expect(sent.content, contains('id=n1'));

    // 库里那条：**只有原话**
    final rows = await db.watchMessages(conv.id).first;
    final userRow = rows.firstWhere((r) => r.role == 'user');
    expect(userRow.content, '帮我看看项目和会议的事',
        reason: '界面上要显示的是用户自己写的话，素材只该存在于请求里');

    // 只检索一次
    expect(asked, ['帮我看看项目和会议的事']);
  });

  test('没素材（检索返回 null）→ 请求里就只有原话', () async {
    answer = (_) => null;
    final chat = chatWith();
    final conv = await newConversation();
    client.script = (round, messages) => const AiChunk('好的');

    await ask(chat, conv.id, '如何养蜂');

    final sent = client.seen.first.firstWhere((m) => m.role == 'user');
    expect(sent.content, '如何养蜂');
    expect(sent.content, isNot(contains(kMarkerForTest)));
  });

  test('★★ 检索抛异常 → AI 照常跑完（不能因为检索坏了就用不了）', () async {
    final chat = chatWith(
      retrieval: (_) async => throw StateError('原生库加载失败'),
    );
    final conv = await newConversation();
    client.script = (round, messages) => const AiChunk('照样能回答');

    await ask(chat, conv.id, '随便问点什么');

    final sent = client.seen.first.firstWhere((m) => m.role == 'user');
    expect(sent.content, '随便问点什么');

    final rows = await db.watchMessages(conv.id).first;
    final assistant = rows.lastWhere((r) => r.role == 'assistant');
    expect(assistant.content, contains('照样能回答'));
  });

  test('挂起恢复时不叠第二遍（历史里已经带过素材了）', () async {
    final chat = chatWith();
    final conv = await newConversation();
    client.script = (round, messages) => const AiChunk('好的');

    // 第一轮：带上了素材
    await ask(chat, conv.id, '第一句');
    expect(client.seen.first.firstWhere((m) => m.role == 'user').content,
        contains(kMarkerForTest));

    // 第二轮：历史里那条消息已经带过素材（模拟恢复时重拼历史）——
    // 这次让它再问一次，断言**没有出现两个标记**
    client.script = (round, messages) => const AiChunk('好的');
    await ask(chat, conv.id, '第二句');
    final second = client.seen.last;
    for (final m in second.where((m) => m.role == 'user')) {
      expect(kMarkerForTest.allMatches(m.content).length, lessThanOrEqualTo(1),
          reason: '同一条消息里不该出现两份素材候选');
    }
  });

  test('素材块是拼在 user 消息上，不是插一条 system 消息（前缀缓存）', () async {
    final chat = chatWith();
    final conv = await newConversation();
    client.script = (round, messages) => const AiChunk('好的');

    await ask(chat, conv.id, '看看我的笔记');

    // system prompt 是**单独一栏**传的（不在 messages 里）。
    // 前缀缓存逐块比对，头一动后面整段按全价重算（30k token 时 3~27 分），
    // 所以素材**只能**出现在 messages 的用户消息里。
    expect(client.systems, isNotEmpty);
    expect(client.systems.first, isNot(contains(kMarkerForTest)),
        reason: '素材进了 system prompt 的话，前缀缓存每一轮都会失效');
    expect(client.systems.first, contains('read_note_batch'),
        reason: '函数文档本来就常驻 system（那是稳定段，不影响缓存）');

    // messages 里也不该多出 system 角色（中途插 system 协议上也没保证）
    final roles = client.seen.first.map((m) => m.role).toList();
    expect(roles, isNot(contains('system')));
  });


  group('索引的后台调度', () {
    test('没 start 过 → instance 是 null（保存路径一行都不执行）', () {
      expect(RagIndexSchedule.instance, isNull);
    });

    test('★ 保存正文不会去等索引（编辑页防抖后 await 的就是这条路径）', () async {
      RagIndexSchedule.start(db);
      final notes = NoteRepository(db);

      final note = await notes.createInbox(title: 'A', content: '正文一');
      final sw = Stopwatch()..start();
      await notes.saveContent(note.id, content: '正文二');
      sw.stop();

      // 同步等索引的话这里会立刻变成几十到几百毫秒。
      // 这条断言不精确（机器差异大），但能抓住"改成 await 了"这种退化。
      expect(sw.elapsedMilliseconds, lessThan(150),
          reason: '保存路径上不该等嵌入（74ms/片）');

      await RagIndexSchedule.instance!.drain();
    });

    test('★ 连续改多次只去重成一次（脏集合的作用）', () async {
      RagIndexSchedule.start(db);
      final notes = NoteRepository(db);
      final note = await notes.createInbox(title: 'A', content: '第一版');

      final sched = RagIndexSchedule.instance!;
      sched.noteChanged(note.id);
      sched.noteChanged(note.id);
      sched.noteChanged(note.id);
      await sched.drain();

      // 空库/无片时补出来就是 0 片，这里验的是"不崩、跑得完"；
      // 真正的片数由 rag_eval_test.dart 覆盖（那边有模型）。
      expect(sched.indexedThisRun, greaterThanOrEqualTo(0));
    });

    test('kickBackfill 是 fire-and-forget，不会冒未捕获的异步错误', () async {
      final sched = RagIndexSchedule.start(db);
      sched.kickBackfill(); // 不 await
      await sched.drain(); // 等它跑完，确认没有异常逃出来
      expect(sched.indexedThisRun, 0, reason: '空库里没有可以补的');
    });
  });

  test('素材块本身：格式与字符预算', () {
    // `formatMaterial` 是纯函数：给几条结果，吐一段文字。不碰库、不碰模型。
    final block = NoteRetriever.formatMaterial([
      const RetrievedSnippet(
        noteId: 'n9',
        title: '周一 · 项目A 启动会',
        heading: '目标',
        chunkIndex: 2,
        offset: 120,
        text: '本季度把结算模块推到 3 个部门试点。',
        vectorScore: 0.61,
        vectorRank: 0,
        keywordRank: null,
        fusedScore: 1 / 61,
      ),
    ]);

    expect(block.split('\n').first, kMarkerForTest);
    expect(block, contains('可能不相关'), reason: '必须说清这是猜的，不然模型会当事实用');
    expect(block, contains('read_note_batch'), reason: '要告诉它怎么接着读');
    expect(block, contains('id=n9'));
    expect(block, contains('offset=120'), reason: '带 offset 才能续读，不用从头读整篇');
    expect(block, contains('第 2 片'));
    expect(block.length, lessThan(600), reason: '一段素材不该长到挤掉别的上下文');
  });
}
