// 阶段 5：只读工具的执行器。
//
// 这一层是 §9.4「安全靠 App 而不是靠模型」的落点，也是 token 经济的关键：
// `listChunks` 只给目录、`readChunk` 有轮次预算。
//
// 全部用真实（内存）数据库测 —— 工具的活儿就是查库与切片的组合，
// mock 掉数据库等于什么都没测。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/features/ai/domain/tool_executor.dart';
import 'package:lightnote/features/ai/domain/tool_types.dart';
import 'package:lightnote/features/note/data/notebook_repository.dart';
import 'package:lightnote/features/note/data/note_repository.dart';
import 'package:lightnote/features/note/domain/history_chunker.dart';

void main() {
  late AppDatabase db;
  late NoteRepository notes;
  late ToolExecutor executor;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    notes = NoteRepository(db);
    executor = ToolExecutor(db);
  });
  tearDown(() => db.close());

  /// 每段约 370 字 → 一段一片（370×2 = 740 > 700）
  String manyChunks(int n, {String tag = '段'}) =>
      List.generate(n, (i) => '第$i$tag。${'内容' * 180}').join('\n\n');

  /// 解出成功结果里的 data
  Map<String, Object?> okData(ToolResult r) {
    expect(r.ok, isTrue, reason: '本该成功：${r.error}');
    final decoded = jsonDecode(r.encode()) as Map<String, Object?>;
    return (decoded['data'] as Map).cast<String, Object?>();
  }

  group('searchNotes', () {
    test('返回 noteId / chunkIndex / heading / 摘要 —— AI 才能接着读那一小片', () async {
      final note = await notes.createInbox(
        title: '我的笔记',
        content: '# 甲章\n\n${'甲的内容。' * 85}\n\n这里提到间隔重复。',
      );

      final data = okData(await executor.execute(
        'searchNotes',
        {'query': '间隔重复'},
      ));

      expect(data['count'], 1);
      final first = ((data['results'] as List).first as Map).cast<String, Object?>();
      expect(first['noteId'], note.id);
      expect(first['hit'], 'chunk');
      expect(first['chunkIndex'], isA<int>());
      expect(first['heading'], '甲章');
      expect(first['snippet'], contains('间隔重复'));
    });

    test('标题命中没有 chunkIndex（表示"整篇相关"）', () async {
      await notes.createInbox(title: '间隔重复心得', content: '无关正文。');
      final data = okData(await executor.execute(
        'searchNotes',
        {'query': '间隔重复'},
      ));
      final first = ((data['results'] as List).first as Map).cast<String, Object?>();
      expect(first['hit'], 'title');
      expect(first.containsKey('chunkIndex'), isFalse);
    });

    test('搜不到 → count 0 + 给模型下一步的提示（不是报错）', () async {
      await notes.createInbox(title: 'N', content: '平平无奇。');
      final r = await executor.execute('searchNotes', {'query': '绝无此词'});
      final data = okData(r);
      expect(data['count'], 0);
      expect(data['hint'], isA<String>());
    });

    test('缺 query → 明确的失败原因', () async {
      final r = await executor.execute('searchNotes', const {});
      expect(r.ok, isFalse);
      expect(r.error, contains('query'));
    });

    test('limit 会被收敛到合法范围（模型可能给 9999）', () async {
      for (var i = 0; i < 30; i++) {
        await notes.createInbox(title: '关键词$i', content: '正文。');
      }
      final data = okData(await executor.execute(
        'searchNotes',
        {'query': '关键词', 'limit': 9999},
      ));
      expect((data['results'] as List).length, lessThanOrEqualTo(50));
    });
  });

  group('listChunks：**只给元数据，绝不含正文**', () {
    test('目录项有 index / heading / level / charCount', () async {
      final note = await notes.createInbox(
        title: 'N',
        content: '# 甲章\n\n${'甲的内容。' * 85}\n\n# 乙章\n\n${'乙的内容。' * 85}',
      );

      final data = okData(await executor.execute('listChunks', {'noteId': note.id}));

      expect(data['chunkCount'], 2);
      final chunks = (data['chunks'] as List).cast<Map>();
      expect(chunks.first['index'], 0);
      expect(chunks.first['heading'], '甲章');
      expect(chunks.first['charCount'], isA<int>());
      expect(chunks.first['level'], isA<int>());
    });

    test('★ 目录里**一个字正文都不能有**（否则省 token 就是空话）', () async {
      const secret = '这是绝不该出现在目录里的正文';
      final note = await notes.createInbox(
        title: 'N',
        content: '# 甲章\n\n$secret${'补充内容。' * 90}',
      );

      final r = await executor.execute('listChunks', {'noteId': note.id});
      expect(r.ok, isTrue);

      final encoded = r.encode();
      expect(encoded.contains(secret), isFalse,
          reason: '目录里出现了正文 —— 一篇 5000 字的笔记会把 prompt 撑爆');
      expect(encoded.contains('补充内容'), isFalse);
    });

    test('找不到笔记 → 失败并提示换个办法', () async {
      final r = await executor.execute('listChunks', {'noteId': '不存在'});
      expect(r.ok, isFalse);
      expect(r.error, contains('searchNotes'));
    });

    test('空正文的笔记 → 0 片，不是报错', () async {
      final note = await notes.createInbox(title: '空', content: '   ');
      final data = okData(await executor.execute('listChunks', {'noteId': note.id}));
      expect(data['chunkCount'], 0);
    });

    test('缺 noteId → 明确失败', () async {
      final r = await executor.execute('listChunks', const {});
      expect(r.ok, isFalse);
      expect(r.error, contains('noteId'));
    });
  });

  group('readChunk', () {
    test('读到的就是那一片的正文，与切片器一致', () async {
      final note = await notes.createInbox(title: 'N', content: manyChunks(5));

      final data = okData(await executor.execute(
        'readChunk',
        {'noteId': note.id, 'index': 1},
      ));

      expect(data['index'], 1);
      expect(data['noteId'], note.id);
      expect(data['charCount'], (data['text'] as String).length);
      // 片正文确实是原文的一段
      expect(note.content.contains(data['text'] as String), isTrue);
    });

    test('越界 → 失败，并告诉它总共有几片、该先看目录', () async {
      final note = await notes.createInbox(title: 'N', content: manyChunks(5));
      final r = await executor.execute(
        'readChunk',
        {'noteId': note.id, 'index': 99},
      );
      expect(r.ok, isFalse);
      expect(r.error, contains('listChunks'));
    });

    test('缺 index → 明确失败', () async {
      final note = await notes.createInbox(title: 'N', content: manyChunks(3));
      final r = await executor.execute('readChunk', {'noteId': note.id});
      expect(r.ok, isFalse);
      expect(r.error, contains('index'));
    });

    test('★ 一轮最多读 3 片（第 4 次被挡下）', () async {
      final note = await notes.createInbox(title: 'N', content: manyChunks(6));
      executor.beginTurn();

      for (var i = 0; i < ToolExecutor.maxChunksPerTurn; i++) {
        final r = await executor.execute(
          'readChunk',
          {'noteId': note.id, 'index': i},
        );
        expect(r.ok, isTrue, reason: '第 ${i + 1} 片本该允许：${r.error}');
      }

      final r4 = await executor.execute(
        'readChunk',
        {'noteId': note.id, 'index': 3},
      );
      expect(r4.ok, isFalse, reason: '模型很容易连着调五次把整篇灌进来');
      expect(r4.error, contains('这一轮'));
    });

    test('beginTurn 之后预算重置（新一轮可以再读）', () async {
      final note = await notes.createInbox(title: 'N', content: manyChunks(6));
      executor.beginTurn();
      for (var i = 0; i < ToolExecutor.maxChunksPerTurn; i++) {
        await executor.execute('readChunk', {'noteId': note.id, 'index': i});
      }
      expect(
        (await executor.execute('readChunk', {'noteId': note.id, 'index': 3})).ok,
        isFalse,
      );

      executor.beginTurn();

      expect(
        (await executor.execute('readChunk', {'noteId': note.id, 'index': 3})).ok,
        isTrue,
        reason: '新一轮应当重新给出 3 片预算',
      );
    });

    test('★ 一轮读的正文不超过 1500 字', () async {
      // 3 段 × 约 600 字 → 3 片，每片 600 字；两片 1200 还行，第三片会超
      final body = List.generate(3, (i) => '第$i段。${'长内容' * 200}').join('\n\n');
      expect(body.length, greaterThan(1500), reason: '这份数据要足够长');
      final note = await notes.createInbox(title: 'N', content: body);

      // ⚠️ 不能直接读 `db.chunksOf`：笔记是 `createInbox` 直插的，
      // **懒回填还没触发**，表里是空的（这正说明懒回填在工作）。
      // 先问一次目录，顺带把片建出来并拿到片数。
      final listed = okData(await executor.execute('listChunks', {'noteId': note.id}));
      final total = listed['chunkCount'] as int;
      expect(total, greaterThanOrEqualTo(3));

      executor.beginTurn();
      var used = 0;
      ToolResult? blocked;
      for (var i = 0; i < total; i++) {
        final r = await executor.execute(
          'readChunk',
          {'noteId': note.id, 'index': i},
        );
        if (!r.ok && (r.error ?? '').contains('上限')) {
          blocked = r;
          break;
        }
        used += (jsonDecode(r.encode())['data'] as Map)['charCount'] as int;
      }

      expect(blocked, isNotNull, reason: '总字数早就超过 1500 了，必须有拦截');
      expect(used, lessThanOrEqualTo(ToolExecutor.maxChunkCharsPerTurn));
    });
  });

  group('listNotebooks / listNotes', () {
    test('列笔记库，带笔记数', () async {
      final nb = await NotebookRepository(db).create(name: '工作');
      await notes.createInNotebook(nb.id, title: 'A', content: '正文。');
      await notes.createInbox(title: 'B', content: '正文。');

      final data = okData(await executor.execute('listNotebooks', const {}));

      expect(data['count'], 1);
      final first = ((data['notebooks'] as List).first as Map);
      expect(first['name'], '工作');
      expect(first['id'], nb.id);
      expect(first['noteCount'], 1);
    });

    test('一个笔记库都没有 → 0 + 提示（不是报错）', () async {
      final data = okData(await executor.execute('listNotebooks', const {}));
      expect(data['count'], 0);
      expect(data['hint'], isA<String>());
    });

    test('列笔记只给 id 与标题（不给正文）', () async {
      await notes.createInbox(title: '第一篇', content: '这是不该出现的正文内容。');

      final r = await executor.execute('listNotes', const {});
      final data = okData(r);

      expect(data['count'], 1);
      final first = ((data['notes'] as List).first as Map);
      expect(first['title'], '第一篇');
      expect(first.length, 2, reason: '只有 id 与 title 两个字段');
      // 工具描述里写着"只要 id 和标题时用它，比 searchNotes 省钱"——
      // 那就得真的不把正文取出来
      expect(r.encode().contains('不该出现'), isFalse);
    });

    test('按笔记库过滤', () async {
      final nb = await NotebookRepository(db).create(name: '工作');
      await notes.createInNotebook(nb.id, title: '库内', content: '正文。');
      await notes.createInbox(title: '库外', content: '正文。');

      final data = okData(await executor.execute(
        'listNotes',
        {'notebookId': nb.id},
      ));

      expect(data['count'], 1);
      expect(((data['notes'] as List).first as Map)['title'], '库内');
    });
  });

  group('会话历史（listHistory / readHistory）', () {
    /// ⚠️ 每轮的长度要落在 **[300, 700]** 这个区间里，才会"一轮一片"：
    ///   · 太短（< 300）→ 被合并成一片（那是切片器该做的，避免碎片）
    ///   · 太长（> 700）→ 一轮被拆成两片
    /// 实测两版数据都栽在这里（先是 1 片、后是 6 片）。所以断言里
    /// **不硬写片数**，而是拿切片器的结果当基准。
    List<AiMessage> history() => [
          for (var r = 0; r < 3; r++) ...[
            AiMessage(
              id: 'u$r',
              conversationId: 'c',
              role: 'user',
              content: '第$r轮的问题：${'问的内容。' * 38}',
              pendingAction: null,
              createdAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: r)),
            ),
            AiMessage(
              id: 'a$r',
              conversationId: 'c',
              role: 'assistant',
              content: '第$r轮的回答：${'答的内容。' * 38}',
              pendingAction: null,
              createdAt: DateTime.utc(2026, 1, 1)
                  .add(Duration(minutes: r, seconds: 5)),
            ),
          ],
        ];

    test('listHistory 只给元数据（不含正文）', () async {
      final msgs = history();
      final expected = HistoryChunker.chunk(msgs).length;
      expect(expected, greaterThanOrEqualTo(3), reason: '这份数据要切出多片才测得到目录');

      final r = await executor.execute('listHistory', const {}, history: msgs);
      final data = okData(r);
      expect(data['count'], expected);
      final first = ((data['chunks'] as List).first as Map);
      expect(first['index'], isA<int>());
      expect(first['charCount'], isA<int>());
      expect(first['userSnippet'], contains('问题'));
      expect(r.encode().contains('回答'), isFalse, reason: '目录不该有正文');
    });

    test('readHistory 取正文，最多 3 片', () async {
      final data = okData(await executor.execute(
        'readHistory',
        {'indexes': [0, 1, 2, 3, 4]},
        history: history(),
      ));
      expect((data['chunks'] as List).length, lessThanOrEqualTo(3));
      final first = ((data['chunks'] as List).first as Map);
      expect(first['text'], contains('问题'));
    });

    test('indexes 缺失 / 全无效 → 明确失败', () async {
      final a = await executor.execute('readHistory', const {}, history: history());
      expect(a.ok, isFalse);
      expect(a.error, contains('indexes'));

      final b = await executor.execute(
        'readHistory',
        {'indexes': ['x', 'y']},
        history: history(),
      );
      expect(b.ok, isFalse);
    });

    test('没有历史 → 0，不是报错', () async {
      final data = okData(await executor.execute('listHistory', const {}));
      expect(data['count'], 0);
    });
  });

  group('安全与边界', () {
    test('不认识的名字 → 失败，并提示用 requestTools', () async {
      final r = await executor.execute('dropDatabase', const {});
      expect(r.ok, isFalse);
      expect(r.error, contains('requestTools'));
    });

    test('创建/修改类工具在**没有确认通道**时一律被拒（fail closed）', () async {
      // 这条断言在阶段 7 之前是"还没开放"；工具实现之后行为变成
      // "有确认才执行"，而这里没接确认通道 → 拒。
      // ⚠️ 关键仍然是"**不是静默成功**"：静默成功会让模型以为改完了。
      //
      // 参数必须是**合法的**：执行器先校验参数再问确认（不该拿一个注定失败的
      // 操作去打扰用户），所以参数不合法时根本走不到确认门。
      final n = await notes.createInbox(title: 'N', content: '原始正文。');
      final calls = <(String, Map<String, Object?>)>[
        ('createNote', {'content': '正文'}),
        ('createNotebook', {'name': '库'}),
        ('updateNote', {'noteId': n.id, 'expectedText': '原始正文。', 'newContent': 'b'}),
        ('replaceInNote', {'noteId': n.id, 'find': '原始', 'replace': 'X'}),
        ('moveNote', {'noteId': n.id}),
      ];
      for (final call in calls) {
        final r = await executor.execute(call.$1, call.$2);
        expect(r.ok, isFalse, reason: '${call.$1} 不该成功');
        expect(r.error, contains('确认通道'), reason: call.$1);
      }
      // 一个字都没改
      expect((await notes.byId(n.id))!.content, '原始正文。');
    });

    test('删除类同样 fail closed：没有确认通道就删不掉', () async {
      // 阶段 8 实现之后，这条断言从"还没开放"变成"必须走确认"。
      // **关键仍然是"不是静默成功"** —— 静默成功等于模型能随便删数据。
      //
      // ⚠️ 必须用**真实存在**的对象：删一个不存在的 id 会走幂等路径
      // 直接返回成功（防重复点击），根本走不到确认门。
      final n = await notes.createInbox(title: 'N', content: '正文。');
      final nb = await NotebookRepository(db).create(name: '库');

      final calls = <(String, Map<String, Object?>)>[
        ('deleteNote', {'noteId': n.id}),
        ('deleteNotebook', {'notebookId': nb.id}),
        ('batchDeleteNotes', {'noteIds': [n.id]}),
      ];
      for (final call in calls) {
        final r = await executor.execute(call.$1, call.$2);
        expect(r.ok, isFalse, reason: call.$1);
        expect(r.error, contains('确认通道'), reason: call.$1);
      }
      // 都还在
      expect((await notes.byId(n.id))!.deletedAt, isNull);
      expect((await db.getNotebook(nb.id))!.deletedAt, isNull);
    });

    test('静态方法名与工具清单一致：只读工具都真的实现了', () async {
      // 这一组是"清单说它是只读、执行器就得能做"的对账
      for (final name in [
        'searchNotes',
        'listChunks',
        'readChunk',
        'listNotebooks',
        'listNotes',
        'listHistory',
        'readHistory',
      ]) {
        final r = await executor.execute(name, const {'noteId': 'x', 'query': 'x'});
        expect((r.error ?? '').contains('还没开放'), isFalse,
            reason: '$name 是只读工具，应当已实现');
      }
    });
  });

  group('parseArgs：模型给的 JSON 不一定规矩', () {
    test('正常对象', () {
      expect(ToolExecutor.parseArgs('{"query":"甲"}'), {'query': '甲'});
    });

    test('空串 → 空 map', () {
      expect(ToolExecutor.parseArgs(''), isEmpty);
    });

    test('坏 JSON → 空 map（后续参数校验会给出**具体**的抱怨）', () {
      expect(ToolExecutor.parseArgs('{不是 json'), isEmpty);
      expect(ToolExecutor.parseArgs('null'), isEmpty);
      expect(ToolExecutor.parseArgs('[1,2]'), isEmpty);
    });
  });
}
