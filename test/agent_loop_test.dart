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

  void fail(String message) {
    scripts.add(() => Stream.fromIterable([AiError(message, code: 'x')]));
  }
}

void main() {
  late AppDatabase db;
  late ToolExecutor executor;
  late FakeModel model;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
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
