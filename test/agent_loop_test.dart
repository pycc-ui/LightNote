// Agent 主循环：多轮工具调用。
//
// 用**假模型**驱动整条循环，所以不花一分钱 API 额度就能测透最容易写错的地方：
// 工具结果怎么回灌、循环靠什么终止。
//
// 终止条件那几条尤其重要 —— 少一条就是**无限烧钱**，而且只在真机上才暴露。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/core/util/app_params.dart';
import 'package:lightnote/core/db/ai_udfs.dart';
import 'package:lightnote/core/db/models.dart';
import 'package:lightnote/features/ai/domain/agent_loop.dart';
import 'package:lightnote/features/ai/domain/tool_executor.dart';
import 'package:lightnote/features/ai/domain/tool_types.dart';
import 'package:lightnote/features/note/data/note_repository.dart';

/// 记录每次请求、按脚本回答的假模型。
class FakeModel {
  final List<({String system, List<AgentMessage> messages, List<ToolSpec> tools})>
      calls = [];

  /// 每一轮的脚本：给一个"这一轮吐什么"的函数
  final List<Stream<AiEvent> Function()> scripts = [];

  int _at = 0;

  Stream<AiEvent> round({
    required String systemPrompt,
    required List<AgentMessage> messages,
    required List<ToolSpec> tools,
  }) {
    calls.add((
      system: systemPrompt,
      messages: List<AgentMessage>.from(messages),
      tools: List<ToolSpec>.from(tools),
    ));
    if (_at >= scripts.length) {
      // 脚本用完还继续被调 → 说明循环没停，给一个空回答让它收场
      return Stream.value(const AiDone(fullText: '（脚本用完）'));
    }
    return scripts[_at++]();
  }

  /// 便捷构造：一轮回答一段话
  void say(String text) {
    scripts.add(() => Stream.fromIterable([
          AiChunk(text),
          AiDone(fullText: text),
        ]));
  }

  /// 便捷构造：一轮提工具（可带一句垫话）
  void callTool(String name, Map<String, Object?> args,
      {String id = 'call_1', String text = ''}) {
    scripts.add(() => Stream.fromIterable([
          if (text.isNotEmpty) AiChunk(text),
          AiDone(
            fullText: text,
            toolCalls: [
              ToolCall(id: id, name: name, arguments: jsonEncode(args)),
            ],
          ),
        ]));
  }

  /// 一轮里提**多个**调用（`finish` 后面跟一个写操作，验证它不会被继续执行）
  void callMany(List<ToolCall> calls, {String text = ''}) {
    scripts.add(() => Stream.fromIterable([
          if (text.isNotEmpty) AiChunk(text),
          AiDone(fullText: text, toolCalls: calls),
        ]));
  }

  void fail(String message) {
    scripts.add(() => Stream.fromIterable([AiError(message, code: 'x')]));
  }
}

void main() {
  late AppDatabase db;
  late ToolExecutor executor;
  late FakeModel model;

  setUp(() {
    // 装 UDF：这一层要测的是**真链路**（AI 提的 SQL 真的被执行、finish 真的被认出来）。
    // 不装的话 `SELECT finish(...)` 只会拿到 no such function，测的就成了"报错路径"。
    db = AppDatabase.forTesting(NativeDatabase.memory(setup: installAiUdfs));
    executor = ToolExecutor(db);
    model = FakeModel();
  });
  tearDown(() => db.close());

  AgentLoop loop() => AgentLoop(round: model.round, executor: executor);

  Future<List<AgentEvent>> collect(Stream<AgentEvent> s) => s.toList();

  String finishedText(List<AgentEvent> events) {
    final f = events.whereType<AgentFinished>().toList();
    expect(f, hasLength(1), reason: '应当正好有一个 AgentFinished');
    return f.single.text;
  }

  group('没有工具调用：一轮就结束', () {
    test('直接回答，只发一次请求', () async {
      model.say('你好，有什么可以帮你的？');

      final events = await collect(loop().run(
        systemPrompt: 'SYS',
        history: [AgentMessage.user('在吗')],
      ));

      expect(finishedText(events), '你好，有什么可以帮你的？');
      expect(model.calls, hasLength(1));
    });

    test('文字是**流式**转发的（不是等整段拿到才给）', () async {
      model.say('前半后半');

      final events = await collect(loop().run(
        systemPrompt: 'SYS',
        history: [AgentMessage.user('x')],
      ));

      // 至少有一个增量事件，且拼起来等于全文
      final deltas = events.whereType<AgentText>().map((e) => e.delta).join();
      expect(deltas, contains('前半后半'));
    });

  });

  group('一轮工具：执行 → 回灌 → 再问', () {

    test('连着两轮工具也能跑（多轮拼接）', () async {
      await NoteRepository(db)
          .createInbox(title: '间隔重复心得', content: '间隔重复是记忆的好朋友。');
      model.callTool('sql', {'query': "SELECT search_notes('间隔重复')"}, id: 'c1');
      model.callTool('sql', {'query': 'SELECT recent_notes(3)'}, id: 'c2');
      model.say('你写过：间隔重复是记忆的好朋友。');

      final events = await collect(loop().run(
        systemPrompt: 'SYS',
        history: [AgentMessage.user('我关于间隔重复写了什么？')],
      ));

      expect(model.calls, hasLength(3));
      expect(finishedText(events), contains('间隔重复是记忆的好朋友'));
      // 第三轮应当同时看得到两次工具的结果
      final roles = model.calls[2].messages.map((m) => m.role).toList();
      expect(roles.where((r) => r == 'tool').length, 2);
    });

    test('工具轮里的垫话留在回答里，但和结论隔开', () async {
      model.callTool('sql', {'query': 'SELECT list_notebooks()'}, text: '我先查一下。');
      model.say('查到了。');

      final events = await collect(loop().run(
        systemPrompt: 'SYS',
        history: [AgentMessage.user('x')],
      ));

      expect(finishedText(events), '我先查一下。\n\n查到了。');
    });
  });


  group('askUser：停下来等用户', () {
    test('发出待答事件后**循环停止**，不伪造结果也不继续烧钱', () async {
      model.callTool('askUser', {
        'question': '你想改哪一篇？',
        'type': 'singleChoice',
        'source': {'kind': 'search', 'query': '会议'},
      }, id: 'ask1');

      final events = await collect(loop().run(
        systemPrompt: 'SYS',
        history: [AgentMessage.user('帮我改一下会议记录')],
      ));

      final waiting = events.whereType<AgentAwaitingUser>().toList();
      expect(waiting, hasLength(1));
      expect(waiting.single.request.question, '你想改哪一篇？');
      expect(waiting.single.request.type.name, 'singleChoice');
      expect(waiting.single.request.source?.kind, 'search');
      expect(waiting.single.toolCallId, 'ask1', reason: '恢复时要靠它对上');

      expect(model.calls, hasLength(1), reason: '不该再发一轮');
      expect(events.whereType<AgentFinished>(), isEmpty);
      // 绝不能凭空造一个用户没给过的回答
      expect(events.whereType<AgentToolDone>(), isEmpty);
    });

    test('参数不全 → 回灌一条失败原因，循环继续（模型能自己改）', () async {
      model.callTool('askUser', {'type': 'text'}); // 缺 question
      model.say('那我直接说结论吧。');

      final events = await collect(loop().run(
        systemPrompt: 'SYS',
        history: [AgentMessage.user('x')],
      ));

      expect(events.whereType<AgentAwaitingUser>(), isEmpty);
      final receipt = model.calls[1].messages.lastWhere((m) => m.role == 'tool');
      expect(receipt.content, contains('question'));
      expect(finishedText(events), '那我直接说结论吧。');
    });

    test('cancel 永远是允许的（不接受 false）', () async {
      model.callTool('askUser', {
        'question': '确认吗？',
        'type': 'confirm',
        'allowCancel': false, // 模型想禁掉取消
      });

      final events = await collect(loop().run(
        systemPrompt: 'SYS',
        history: [AgentMessage.user('x')],
      ));

      expect(events.whereType<AgentAwaitingUser>().single.request.allowCancel,
          isTrue);
    });
  });

  group('每轮重拼 system prompt（动态函数标记靠它生效）', () {
    test('★ 第二轮用的是**重拼后**的 prompt', () async {
      model.callTool('sql', {'query': 'SELECT 1'}, id: 'c1');
      model.say('好了。');

      var n = 0;
      await collect(loop().run(
        systemPrompt: 'SYS-初始',
        // 伪装成"读 app_kv 现拼"：每调一次内容就变
        rebuildPrompt: () async => 'SYS-第${n++}次',
        history: [AgentMessage.user('x')],
      ));

      expect(model.calls, hasLength(2));
      expect(model.calls[0].system, 'SYS-第0次');
      expect(model.calls[1].system, 'SYS-第1次',
          reason: '标记是这一轮做的，下一轮必须重拼才看得到刚加载的函数详情');
    });

    test('不传 rebuildPrompt → 一直用给定的固定段（老路径不变）', () async {
      model.callTool('sql', {'query': 'SELECT 1'}, id: 'c1');
      model.say('好了。');

      await collect(loop().run(
        systemPrompt: 'SYS',
        history: [AgentMessage.user('x')],
      ));

      expect(model.calls.map((c) => c.system), everyElement('SYS'));
    });

    test('重拼抛异常 → 退回固定段，**不打断整轮对话**', () async {
      model.say('照样回答。');

      final events = await collect(loop().run(
        systemPrompt: 'SYS',
        rebuildPrompt: () async => throw StateError('读库失败'),
        history: [AgentMessage.user('x')],
      ));

      expect(model.calls.single.system, 'SYS');
      expect(finishedText(events), '照样回答。');
    });
  });

  group('finish：声明完成就当场收尾', () {
    test('★ 收到 finish 立刻结束：不再发下一轮、也不回灌工具结果', () async {
      model.callTool('sql', {'query': "SELECT finish('改好了')"},
          id: 'c1', text: '已经把风险段落改完了。');

      final events = await collect(loop().run(
        systemPrompt: 'SYS',
        history: [AgentMessage.user('把风险段落改一下')],
      ));

      // 普通工具要「回灌 → 再问一轮」（至少 2 次请求）；finish 只花 1 次
      expect(model.calls, hasLength(1), reason: 'finish 之后不该再发请求');
      expect(finishedText(events), '已经把风险段落改完了。',
          reason: '答案就是这一轮已经流出来的文字');
    });

    test('只调 finish、一个字没写 → 用 description 兜底，不给用户空白', () async {
      model.callTool('sql', {'query': "SELECT finish('删掉了 3 篇草稿')"}, id: 'c1');

      final events = await collect(loop().run(
        systemPrompt: 'SYS',
        history: [AgentMessage.user('删掉草稿')],
      ));

      expect(finishedText(events), '删掉了 3 篇草稿',
          reason: '违反 prompt（只调 finish 不说话）也别让用户看到空白');
      expect(model.calls, hasLength(1));
    });

    test('★ finish 之后的调用不再执行（同一轮里的写操作会被跳过）', () async {
      model.callMany([
        ToolCall(
          id: 'c1',
          name: 'sql',
          arguments: jsonEncode({'query': "SELECT finish('够了')"}),
        ),
        ToolCall(
          id: 'c2',
          name: 'sql',
          arguments: jsonEncode({
            'query':
                "SELECT create_notes_batch('[{\"title\":\"不该被建出来\"}]')",
          }),
        ),
      ], text: '做完了。');

      await collect(loop().run(
        systemPrompt: 'SYS',
        history: [AgentMessage.user('x')],
      ));

      final cnt = await db
          .customSelect(
              "SELECT COUNT(*) AS n FROM notes WHERE title = '不该被建出来'")
          .getSingle();
      expect(cnt.read<int>('n'), 0,
          reason: 'finish 是收尾信号：它后面排队的调用一条都不该执行');
    });

    test('finish 走的是工具结果那条路（description 能被上层拿到）', () async {
      model.callTool('sql', {'query': "SELECT finish('标记一下')"}, id: 'c1');

      final events = await collect(loop().run(
        systemPrompt: 'SYS',
        history: [AgentMessage.user('x')],
      ));

      final done = events.whereType<AgentToolDone>().toList();
      expect(done, hasLength(1));
      expect(done.single.ok, isTrue);
      expect(done.single.description, '标记一下');
      expect(done.single.mutated, isFalse,
          reason: 'finish 不改任何数据，不该被算进「本轮改过哪些笔记」');
    });
  });

  group('轮数预算：软上限提醒 + 用尽 + 硬上限', () {
    /// 让模型连着提 [n] 轮工具（循环照样数轮数）。
    void toolRounds(int n) {
      for (var i = 0; i < n; i++) {
        model.callTool('sql', {'query': 'SELECT 1'}, id: 'c$i');
      }
    }

    /// 某一轮发出去的**最后一条消息**（轮数提醒挂在那里，不碰 system 头部）。
    String tailOf(int round) {
      final msgs = model.calls[round].messages;
      return msgs.isEmpty ? '' : msgs.last.content;
    }

    test('还剩 >2 轮不提醒；剩 ≤2 轮时提醒挂在**消息末尾**', () async {
      toolRounds(4);
      model.say('收尾');

      await collect(loop().run(
        systemPrompt: 'SYS',
        roundsUsed: 0,
        roundBudget: 6, // 各轮开始时剩：6 / 5 / 4 / 3 / 2 轮
        history: [AgentMessage.user('x')],
      ));

      final systems = [for (final c in model.calls) c.system];
      expect(systems, hasLength(5));
      // ⚠️ 提醒**不能动 system prompt**：前缀缓存逐块比对，改头部会让整段上下文
      // 按全价重算一次（30k token 时约 3–27 分）。所以它挂在消息列表末尾。
      expect(systems.every((s) => s == 'SYS'), isTrue,
          reason: 'system prompt 必须一字不变（缓存前提）');
      expect(tailOf(0), isNot(contains('轮数提醒')), reason: '还剩 6 轮');
      expect(tailOf(3), isNot(contains('轮数提醒')), reason: '还剩 3 轮');
      expect(tailOf(4), contains('轮数提醒'), reason: '还剩 2 轮，该提醒了');
      expect(tailOf(4), startsWith('## 轮数提醒'));
    });

    test('提醒要教会模型两条出路，并说明继续会再花钱', () async {
      toolRounds(2);

      await collect(loop().run(
        systemPrompt: 'SYS',
        roundsUsed: 0,
        roundBudget: 2,
        history: [AgentMessage.user('x')],
      ));

      final notice = tailOf(model.calls.length - 1);
      expect(notice, contains('askUser'), reason: '没做完：让模型自己问用户');
      expect(notice, contains('finish'), reason: '做完了：让模型收尾');
      expect(notice, contains('调用费用'), reason: '必须说清"继续"是再花一次钱');
      expect(notice, contains('${AgentLimits.maxRoundsHard}'),
          reason: '要写明硬上限，模型才知道继续也有限度');
    });

    test('提醒每轮**替换**，不在消息里累积', () async {
      toolRounds(3);

      await collect(loop().run(
        systemPrompt: 'SYS',
        roundsUsed: 0,
        roundBudget: 3,
        history: [AgentMessage.user('x')],
      ));

      for (var i = 0; i < model.calls.length; i++) {
        final n = model.calls[i]
            .messages
            .where((m) => m.content.startsWith('## 轮数提醒'))
            .length;
        expect(n, lessThanOrEqualTo(1), reason: '第 $i 轮挂了 $n 条提醒，会越滚越多');
      }
    });

    test('★ 预算用尽 → 强制收尾，且带机器可读的 code', () async {
      toolRounds(3); // 永远提工具，绝不收尾

      final events = await collect(loop().run(
        systemPrompt: 'SYS',
        roundBudget: 3,
        history: [AgentMessage.user('x')],
      ));

      expect(model.calls, hasLength(3), reason: '预算 3 轮就只发 3 次');
      final failed = events.whereType<AgentFailed>().single;
      expect(failed.code, 'rounds',
          reason: '界面靠 code 落 interrupt_reason，拿中文 message 去认不可靠');
      expect(failed.message, contains('继续'),
          reason: '要告诉用户怎么办（再发一句"继续"）');
      expect(events.whereType<AgentFinished>(), isEmpty);
    });

    test('★ 预算被夹到硬上限（调用方传多大都不行）', () async {
      toolRounds(60);

      await collect(loop().run(
        systemPrompt: 'SYS',
        roundsUsed: 0,
        roundBudget: 999, // 调用方瞎传
        history: [AgentMessage.user('x')],
      ));

      expect(model.calls, hasLength(AgentLimits.maxRoundsHard),
          reason: '硬上限是最后一道闸，不能靠调用方自觉');
    });

    test('★ roundsUsed 跨挂起累计：预算不会被重新给满', () async {
      toolRounds(30);

      await collect(loop().run(
        systemPrompt: 'SYS',
        // 挂起前已经用了 13 轮，总预算 30 → 这次只剩 17 轮
        roundsUsed: 13,
        roundBudget: 30,
        history: [AgentMessage.user('x')],
      ));

      expect(model.calls, hasLength(17),
          reason: '不把已用轮数带回来，每问一次就等于重新给满预算（软上限形同虚设）');
    });

    test('挂起事件要把 rounds / budget 一起带出去', () async {
      model.callTool('askUser', {
        'question': '还要继续吗？',
        'type': 'confirm',
      }, id: 'ask1');

      final events = await collect(loop().run(
        systemPrompt: 'SYS',
        roundsUsed: 5,
        roundBudget: 20,
        history: [AgentMessage.user('x')],
      ));

      final awaiting = events.whereType<AgentAwaitingUser>().single;
      expect(awaiting.rounds, 6,
          reason: '含这一轮（已用 5 + 本轮 1）；少了它恢复时预算就重置了');
      expect(awaiting.budget, 20, reason: '预算也要原样带回去');
    });
  });

  group('终止条件（少一条就是无限烧钱）', () {
    test('★ 模型每轮都提工具 → 到上限就停，且只发了上限次', () async {
      // 一个永远在提工具、永远拿不到结果的模型
      for (var i = 0; i < 20; i++) {
        model.callTool('readChunk', {'noteId': '编的', 'index': 0},
            id: 'c$i');
      }

      final events = await collect(loop().run(
        systemPrompt: 'SYS',
        history: [AgentMessage.user('x')],
      ));

      expect(model.calls, hasLength(AgentLoop.maxRounds),
          reason: '轮数上限必须真的生效');
      expect(events.whereType<AgentFailed>(), hasLength(1));
    });

    test('出错就停，但**已经收到的文字不丢**', () async {
      model.scripts.add(() => Stream.fromIterable([
            const AiChunk('我已经查到了这些：'),
            const AiError('网络断了', code: 'network'),
          ]));

      final events = await collect(loop().run(
        systemPrompt: 'SYS',
        history: [AgentMessage.user('x')],
      ));

      expect(events.whereType<AgentFailed>().single.message, contains('网络断了'));
      final deltas = events.whereType<AgentText>().map((e) => e.delta).join();
      expect(deltas, contains('我已经查到了这些'), reason: '半截内容也要给用户看到');
    });
  });
}
