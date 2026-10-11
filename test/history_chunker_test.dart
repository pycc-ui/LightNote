// 会话切片（`HistoryChunker`）。
//
// ## 盯的三件事
//
//   1. **一片 = 一轮** —— 角色清晰、索引只往后追加、工具调用链不会被切断
//   2. **同一套上下限**（700/300），且合并**不越上限**
//   3. `catalog` / `slice` 的截断：目录默认 20 片、取片 ≤3 且 ≤1500 字
//
// 另外一条容易忽略的：`tool` 消息**不进片正文**（机器中间产物，烧 token），
// 但它的存在不影响轮次边界 —— 这正是"工具链不被切断"的实现方式。
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/features/note/domain/history_chunker.dart';

var _seq = 0;

/// 轮次序号：保证**整轮**的时间是递增的（见 [round] 的说明）。
var _round = 0;

AiMessage msg(String role, String content, {DateTime? at}) => AiMessage(
      id: 'm${_seq++}',
      conversationId: 'c1',
      role: role,
      content: content,
      pendingAction: null,
      // 不给时间时按**分钟**自增（不是按秒）：见 [round] 的说明，
      // 秒级递增会让相邻两轮交错。
      createdAt:
          at ?? DateTime.utc(2026, 1, 1).add(Duration(minutes: _round++)),
    );

/// 造一轮：用户问 + 助手答。
///
/// ## ⚠️ 时间必须**整轮递增**，不能按消息条数递增
///
/// 一轮内部 user 与 assistant 只差几秒，而**下一轮必须排在上一轮的
/// assistant 之后**。早先这里用同一个"消息序号"当秒数，于是第 2 轮的 user
/// 落在 `00:00:02`、而第 1 轮的 assistant 落在 `00:00:05` —— 按时间排序后
/// 两轮**交错**在一起，`HistoryChunker` 的分组自然全乱。
///
/// **那是测试数据不真实（真实对话的时间天然递增），不是实现的问题。**
/// 所以这里改成每轮占一分钟，轮内 assistant 只比 user 晚 5 秒。
List<AiMessage> round(String q, String a, {DateTime? at}) {
  final t = at ?? DateTime.utc(2026, 1, 1).add(Duration(minutes: _round++));
  return [
    msg('user', q, at: t),
    msg('assistant', a, at: t.add(const Duration(seconds: 5))),
  ];
}

void main() {
  group('一片 = 一轮', () {
    test('空历史 → 空列表', () {
      expect(HistoryChunker.chunk(const []), isEmpty);
    });

    test('两轮短对话 → 合成一片（都低于下限）', () {
      final chunks = HistoryChunker.chunk([
        ...round('你好', '你好，有什么可以帮你？'),
        ...round('谢谢', '不客气'),
      ]);

      expect(chunks.length, 1);
      expect(chunks.single.roles, ['user', 'assistant']);
      expect(chunks.single.text, contains(HistoryChunker.userLabel));
      expect(chunks.single.text, contains(HistoryChunker.assistantLabel));
    });

    test('索引从 0 起、连续', () {
      // 每轮都够长，逼它们分开
      final long = '内容' * 200; // 400 字
      final chunks = HistoryChunker.chunk([
        ...round(long, long),
        ...round(long, long),
        ...round(long, long),
      ]);

      expect(chunks.length, greaterThan(1));
      for (var i = 0; i < chunks.length; i++) {
        expect(chunks[i].index, i);
      }
    });

    test('**新的一轮只追加，旧片索引不变**（会话是只增的）', () {
      final long = '内容' * 200;
      final first = [
        ...round(long, long),
        ...round(long, long),
      ];
      final before = HistoryChunker.chunk(first);

      final after = HistoryChunker.chunk([
        ...first,
        ...round('新的一轮问题', '新的一轮回答'),
      ]);

      // 前 N 片必须原样保留
      for (var i = 0; i < before.length; i++) {
        expect(after[i].index, before[i].index);
        expect(after[i].text, before[i].text,
            reason: '追加一轮不该改变已有片的内容与索引');
      }
      expect(after.length, greaterThanOrEqualTo(before.length));
    });
  });

  group('角色标注与 tool 消息', () {
    test('tool 消息的正文不进片（机器中间产物，烧 token）', () {
      final chunks = HistoryChunker.chunk([
        msg('user', '列出我的笔记库'),
        msg('assistant', '', at: DateTime.utc(2026, 1, 1, 0, 0, 1)),
        msg('tool', '{"ok":true,"data":{"notebooks":[1,2,3]}}'),
        msg('assistant', '你有 3 个笔记库。', at: DateTime.utc(2026, 1, 1, 0, 0, 2)),
      ]);

      expect(chunks.length, 1);
      expect(chunks.single.text, isNot(contains('notebooks')));
      expect(chunks.single.text, contains('你有 3 个笔记库'));
      expect(chunks.single.text, isNot(contains('{"ok":true')),
          reason: 'tool 结果不该出现在可读的历史片里');
    });

    test('只提工具、还没回答的空 assistant 不会留下光秃秃的【我】', () {
      final chunks = HistoryChunker.chunk([
        msg('user', '查一下'),
        msg('assistant', ''),
        msg('tool', '{}'),
      ]);

      expect(chunks.length, 1);
      expect(chunks.single.text, isNot(contains(HistoryChunker.assistantLabel)));
      expect(chunks.single.roles, ['user']);
    });

    test('**一整轮包含它的 tool 消息**（所以切不出半个工具调用链）', () {
      // 一轮里 user → assistant(带调用) → tool(结果) → assistant(回答)
      // 无论怎么切，这四个消息必须在同一片里
      final chunks = HistoryChunker.chunk([
        msg('user', '用户问题'),
        msg('assistant', ''),
        msg('tool', '{}'),
        msg('assistant', '最终回答'),
      ]);

      expect(chunks.length, 1, reason: '一轮内的消息不可被切开');
      expect(chunks.single.text, contains('用户问题'));
      expect(chunks.single.text, contains('最终回答'));
    });
  });

  group('上下限与合并', () {
    test('所有片都不超过上限（纯文本情形）', () {
      final chunks = HistoryChunker.chunk([
        ...round('问题' * 300, '回答' * 300),
        ...round('问题' * 300, '回答' * 300),
        ...round('短', '短'),
      ]);

      for (final c in chunks) {
        expect(c.charCount, lessThanOrEqualTo(HistoryChunker.cap),
            reason: '${c.index} 超上限了：${c.charCount}');
      }
    });

    test('合并**不越上限**：宁可留短片，也不超', () {
      final chunks = HistoryChunker.chunk([
        ...round('问题' * 200, '回答' * 200),
        ...round('问题' * 200, '回答' * 200),
      ]);

      var total = 0;
      for (final c in chunks) {
        total += c.charCount;
        expect(c.charCount, lessThanOrEqualTo(HistoryChunker.cap));
      }
      expect(total, greaterThan(0));
    });

    test('超长的一轮会被拆成多片，且不丢内容', () {
      final q = '问' * 400;
      final a = '答' * 900;
      final chunks = HistoryChunker.chunk(round(q, a));

      expect(chunks.length, greaterThan(1));
      final all = chunks.map((c) => c.text).join();
      expect(all, contains('问' * 100));
      expect(all, contains('答' * 100));
      for (final c in chunks) {
        expect(c.charCount, lessThanOrEqualTo(HistoryChunker.cap));
      }
    });
  });

  group('目录（catalog）只给元数据', () {
    test('**不含正文**，只有 index / 时间 / 角色 / 用户摘要 / 字数', () {
      final chunks = HistoryChunker.catalog([
        ...round('我该学什么', '先学基础'),
      ]);

      expect(chunks.length, 1);
      final row = chunks.single;
      expect(row.keys.toSet(),
          {'index', 'at', 'roles', 'userSnippet', 'charCount'});
      expect(row.containsKey('text'), isFalse, reason: '目录带正文就等于把全文灌进上下文');
    });

    test('userSnippet 截到 40 字并加省略号', () {
      final long = '问' * 100;
      final row = HistoryChunker.catalog(round(long, '答')).single;

      final s = row['userSnippet'] as String;
      expect(s.length, HistoryChunker.userSnippetChars + 1); // 40 + '…'
      expect(s.endsWith('…'), isTrue);
    });

    test('目录默认只给**最近** 20 片，且带真实 index', () {
      // 造 25 轮、每轮都够长逼成独立片
      final many = <AiMessage>[];
      for (var i = 0; i < 25; i++) {
        many.addAll(round('问' * 200, '答' * 200,
            at: DateTime.utc(2026, 1, 1, 0, i, 0)));
      }
      final all = HistoryChunker.chunk(many);
      final cat = HistoryChunker.catalog(many);

      expect(all.length, greaterThan(20));
      expect(cat.length, 20);
      // 最后一片的 index 就是全量的最后一片
      expect(cat.last['index'], all.last.index);
      // 而且是"最近"的 20 片，不是最前面的
      expect(cat.first['index'], all.last.index - 19);
    });

    test('limit 有上限 50', () {
      final many = <AiMessage>[];
      for (var i = 0; i < 60; i++) {
        many.addAll(round('问' * 200, '答' * 200,
            at: DateTime.utc(2026, 1, 1, 0, i, 0)));
      }
      expect(HistoryChunker.catalog(many, limit: 999).length, lessThanOrEqualTo(50));
    });
  });

  group('取片（slice）', () {
    test('最多 3 片、总量不超过 1500 字', () {
      final many = <AiMessage>[];
      for (var i = 0; i < 10; i++) {
        many.addAll(round('问' * 200, '答' * 200,
            at: DateTime.utc(2026, 1, 1, 0, i, 0)));
      }
      final got = HistoryChunker.slice(many, indexes: [0, 1, 2, 3, 4]);

      expect(got.length, lessThanOrEqualTo(3));
      final total = got.fold<int>(0, (s, c) => s + c.charCount);
      expect(total, lessThanOrEqualTo(1500));
    });

    test('越界的 index 被跳过而不是抛错', () {
      final many = round('问题', '回答');
      expect(HistoryChunker.slice(many, indexes: [-1, 99]).length, 0);
      expect(HistoryChunker.slice(many, indexes: [0]).length, 1);
    });
  });

  group('稳健性', () {
    test('同一输入切两次结果完全一致', () {
      final many = [
        ...round('问题' * 100, '回答' * 100),
        ...round('另一个问题', '另一个回答'),
      ];
      final a = HistoryChunker.chunk(many);
      final b = HistoryChunker.chunk(many);
      expect(a.map((c) => c.text).toList(), b.map((c) => c.text).toList());
    });

    test('乱序传入也按时间正序切（不依赖调用方排序）', () {
      final t1 = DateTime.utc(2026, 1, 1, 0, 0, 1);
      final t2 = DateTime.utc(2026, 1, 1, 0, 0, 2);
      final ordered = [msg('user', '第一句', at: t1), msg('user', '第二句', at: t2)];
      final shuffled = [ordered[1], ordered[0]];

      final a = HistoryChunker.chunk(ordered).single.text;
      final b = HistoryChunker.chunk(shuffled).single.text;
      expect(a, b);
      expect(a.indexOf('第一句'), lessThan(a.indexOf('第二句')));
    });

    test('全是空消息时不产生片', () {
      expect(
        HistoryChunker.chunk([msg('assistant', '   '), msg('tool', '')]),
        isEmpty,
      );
    });
  });
}
