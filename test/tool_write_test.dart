// 阶段 7：修改类工具。
//
// 这一层最要命的两种错法：
//   · 锚点失效了还照改 → **改错地方**，而且改得毫无声息
//   · 没有确认通道时"默认放行" → 任何一条漏接的回调都变成"AI 能随便改数据"
// 所以下面两条各有一组重头用例。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/features/ai/domain/tool_executor.dart';
import 'package:lightnote/features/ai/domain/tool_specs.dart';
import 'package:lightnote/features/ai/domain/tool_types.dart';
import 'package:lightnote/features/note/data/notebook_repository.dart';
import 'package:lightnote/features/note/data/note_repository.dart';

void main() {
  late AppDatabase db;
  late NoteRepository notes;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    notes = NoteRepository(db);
  });
  tearDown(() => db.close());

  /// 一个"总是同意"的确认器，顺便把收到的请求记下来供断言
  ({ToolExecutor executor, List<ToolConfirmRequest> seen}) agreeing() {
    final seen = <ToolConfirmRequest>[];
    final ex = ToolExecutor(db, onConfirm: (r) async {
      seen.add(r);
      return true;
    });
    return (executor: ex, seen: seen);
  }

  ToolExecutor refusing() => ToolExecutor(db, onConfirm: (_) async => false);

  Map<String, Object?> okData(ToolResult r) {
    expect(r.ok, isTrue, reason: '本该成功：${r.error}');
    return (jsonDecode(r.encode())['data'] as Map).cast<String, Object?>();
  }

  group('★ 没有确认通道 = 写操作一律拒绝（fail closed）', () {
    test('没接 onConfirm 时，所有写工具都失败且**什么都不改**', () async {
      final note = await notes.createInbox(title: '原名', content: '原始内容。');
      final nb = await NotebookRepository(db).create(name: '旧库名');
      final ex = ToolExecutor(db); // 没有确认通道

      // 显式标注类型：条目里既有字符串参数也有数组参数，
      // 不标注的话 Dart 推不出 `Map<String, Object?>`
      final calls = <(String, Map<String, Object?>)>[
        ('createNote', {'content': '新内容'}),
        ('createNotebook', {'name': '新库'}),
        ('updateNote', {'noteId': note.id, 'expectedText': '原始内容。', 'newContent': '改了'}),
        ('replaceInNote', {'noteId': note.id, 'find': '原始', 'replace': 'X'}),
        ('moveNote', {'noteId': note.id}),
        ('renameNotebook', {'notebookId': nb.id, 'name': 'y'}),
        ('batchMoveNotes', {'noteIds': [note.id]}),
      ];
      for (final call in calls) {
        final r = await ex.execute(call.$1, call.$2);
        expect(r.ok, isFalse, reason: '${call.$1} 不该在没有确认通道时成功');
        expect(r.error, contains('确认通道'), reason: call.$1);
      }

      // 笔记一个字都没动
      expect((await notes.byId(note.id))!.content, '原始内容。');
      expect((await notes.byId(note.id))!.title, '原名');
      // 笔记库也只有一个（就是测试自己建的那个），没有被新建或改名
      final all = await db.allNotebooks();
      expect(all, hasLength(1));
      expect(all.single.name, '旧库名');
    });

    test('反过来：接了确认通道，同样的调用就能成功', () async {
      final note = await notes.createInbox(title: 'N', content: '原始内容。');
      final (executor: ex, seen: _) = agreeing();

      final data = okData(await ex.execute('updateNote', {
        'noteId': note.id,
        'expectedText': '原始内容。',
        'newContent': '改过了。',
      }));

      expect(data['noteId'], note.id);
      expect((await notes.byId(note.id))!.content, '改过了。');
    });
  });

  group('★ 锚点校验：expectedText 不在就**一个字都不改**', () {
    test('锚点失效 → 失败，正文原样', () async {
      final note = await notes.createInbox(title: 'N', content: '现在的正文是这样。');
      final (executor: ex, seen: seen) = agreeing();

      final r = await ex.execute('updateNote', {
        'noteId': note.id,
        'expectedText': '早就不在了的那段', // AI 拿的是旧内容
        'newContent': '新内容',
      });

      expect(r.ok, isFalse);
      expect(r.error, contains('锚点失效'));
      expect((await notes.byId(note.id))!.content, '现在的正文是这样。',
          reason: '锚点不中时**绝对不能**照写 —— 那会改到别的地方');
      expect(seen, isEmpty, reason: '连确认都不该弹（没什么可确认的）');
    });

    test('改正文却不给 expectedText → 失败', () async {
      final note = await notes.createInbox(title: 'N', content: '正文。');
      final (executor: ex, seen: _) = agreeing();

      final r = await ex.execute('updateNote', {
        'noteId': note.id,
        'newContent': '整篇换掉',
      });

      expect(r.ok, isFalse);
      expect(r.error, contains('expectedText'));
      expect((await notes.byId(note.id))!.content, '正文。');
    });

    test('锚点命中 → 替换的是**那一处**', () async {
      final note = await notes.createInbox(
        title: 'N',
        content: '第一句客户反馈很好。第二句客户反馈很好。',
      );
      final (executor: ex, seen: _) = agreeing();

      await ex.execute('updateNote', {
        'noteId': note.id,
        'expectedText': '第一句客户反馈很好。',
        'newContent': '第一句用户反馈很好。',
      });

      // 只换第一处（`indexOf` + replaceRange），第二处不动
      expect((await notes.byId(note.id))!.content,
          '第一句用户反馈很好。第二句客户反馈很好。');
    });

    test('只改标题不需要锚点', () async {
      final note = await notes.createInbox(title: '旧标题', content: '正文。');
      final (executor: ex, seen: _) = agreeing();

      await ex.execute('updateNote', {'noteId': note.id, 'title': '新标题'});

      final after = (await notes.byId(note.id))!;
      expect(after.title, '新标题');
      expect(after.content, '正文。');
    });

    test('笔记不存在 → 可读的失败，并提示重新找', () async {
      final (executor: ex, seen: _) = agreeing();
      final r = await ex.execute('updateNote', {
        'noteId': '编的',
        'expectedText': 'x',
        'newContent': 'y',
      });
      expect(r.ok, isFalse);
      expect(r.error, contains('searchNotes'));
    });
  });

  group('快照粗筛 + 改前改后', () {
    test('确认请求里带着**改前**与**改后**（弹层要显示 diff）', () async {
      final note = await notes.createInbox(title: 'N', content: '旧的正文。');
      final (executor: ex, seen: seen) = agreeing();

      await ex.execute('updateNote', {
        'noteId': note.id,
        'expectedText': '旧的正文。',
        'newContent': '新的正文。',
      });

      expect(seen, hasLength(1));
      expect(seen.single.before, '旧的正文。');
      expect(seen.single.after, '新的正文。');
      expect(seen.single.risk, ToolRisk.modify);
      expect(seen.single.strong, isFalse);
      expect(seen.single.title, '修改笔记');
    });

    test('★ 读到之后被手改过 → 确认层带上提醒', () async {
      final note = await notes.createInbox(title: 'N', content: '第一版内容。');
      final (executor: ex, seen: seen) = agreeing();

      // AI 先读一次（记下快照）
      await ex.execute('readChunk', {'noteId': note.id, 'index': 0});

      // 用户在这期间手改了（模拟：走另一条路写库）
      await notes.saveContent(note.id, content: '用户手改过的第二版内容。');

      // AI 再按旧内容改
      final r = await ex.execute('updateNote', {
        'noteId': note.id,
        'expectedText': '第二版',
        'newContent': '第三版',
      });

      expect(r.ok, isTrue);
      expect(seen.single.warning, isNotNull, reason: '要提醒用户"这条被改过"');
      expect(seen.single.warning, contains('改过'));
    });

    test('没读过就直接改 → 没有快照，也就没有提醒（不能凭空造提醒）', () async {
      final note = await notes.createInbox(title: 'N', content: '正文。');
      final (executor: ex, seen: seen) = agreeing();

      await ex.execute('updateNote', {
        'noteId': note.id,
        'expectedText': '正文。',
        'newContent': '改了。',
      });

      expect(seen.single.warning, isNull);
    });

    test('用户拒绝 → 失败信息明确说"用户拒绝了"，且不改', () async {
      final note = await notes.createInbox(title: 'N', content: '正文。');

      final r = await refusing().execute('updateNote', {
        'noteId': note.id,
        'expectedText': '正文。',
        'newContent': '改了。',
      });

      expect(r.ok, isFalse);
      expect(r.error, contains('拒绝'));
      expect(r.error, contains('不要重试'), reason: '要拦住它反复重试同一个操作');
      expect((await notes.byId(note.id))!.content, '正文。');
    });
  });

  group('replaceInNote', () {
    test('全部替换，返回替换了几处', () async {
      final note = await notes.createInbox(title: 'N', content: '客户说，客户又问。');
      final (executor: ex, seen: _) = agreeing();

      final data = okData(await ex.execute('replaceInNote', {
        'noteId': note.id,
        'find': '客户',
        'replace': '用户',
      }));

      expect(data['replaced'], 2);
      expect((await notes.byId(note.id))!.content, '用户说，用户又问。');
    });

    test('找不到 → 失败，并提示先 readChunk 确认原文', () async {
      final note = await notes.createInbox(title: 'N', content: '正文。');
      final (executor: ex, seen: seen) = agreeing();

      final r = await ex.execute('replaceInNote', {
        'noteId': note.id,
        'find': '不存在的词',
        'replace': 'x',
      });

      expect(r.ok, isFalse);
      expect(r.error, contains('readChunk'));
      expect(seen, isEmpty);
    });

    test('find == replace → 直接失败（没有意义）', () async {
      final note = await notes.createInbox(title: 'N', content: '正文。');
      final (executor: ex, seen: _) = agreeing();
      final r = await ex.execute('replaceInNote', {
        'noteId': note.id,
        'find': '正文',
        'replace': '正文',
      });
      expect(r.ok, isFalse);
    });

    test('也走确认（不是 App 绕过 AI 直接改）', () async {
      final note = await notes.createInbox(title: 'N', content: '客户说。');
      final (executor: ex, seen: seen) = agreeing();

      await ex.execute('replaceInNote', {
        'noteId': note.id,
        'find': '客户',
        'replace': '用户',
      });

      expect(seen.single.toolName, 'replaceInNote');
    });
  });

  group('撤销', () {
    test('改完之后可以撤销，正文与切片都回到改前', () async {
      final note = await notes.createInbox(title: 'N', content: '原始内容，比较长${'补' * 400}');
      final (executor: ex, seen: _) = agreeing();

      await ex.execute('replaceInNote', {
        'noteId': note.id,
        'find': '原始',
        'replace': '改过',
      });
      expect((await notes.byId(note.id))!.content, contains('改过'));
      expect(ex.undoable, isNotNull);

      final restored = await ex.undoLast();

      expect(restored, note.id);
      expect((await notes.byId(note.id))!.content, contains('原始'));
      expect(ex.undoable, isNull, reason: '撤销一次就没了（不是版本历史）');
    });

    test('撤销会**重切切片**（否则搜索会指向错位置）', () async {
      final note = await notes.createInbox(
        title: 'N',
        content: '# 甲章\n\n${'甲的内容。' * 85}\n\n# 乙章\n\n${'乙的内容。' * 85}',
      );
      final (executor: ex, seen: _) = agreeing();

      await ex.execute('updateNote', {
        'noteId': note.id,
        'expectedText': '甲的内容。',
        'newContent': '换掉的内容。',
      });
      await ex.undoLast();

      // 撤销后的片必须与恢复出来的正文一致
      final body = (await notes.byId(note.id))!.content;
      final rows = await db.chunksOf(note.id);
      expect(rows, isNotEmpty);
      for (final r in rows) {
        expect(
          body.substring(r.startOffset, r.endOffset).hashCode,
          r.contentHash,
          reason: '撤销之后切片没重切，偏移就失效了',
        );
      }
    });

    test('没有可撤销的 → undoLast 返回 null', () async {
      final ex = ToolExecutor(db);
      expect(ex.undoable, isNull);
      expect(await ex.undoLast(), isNull);
    });
  });

  group('创建与移动', () {
    test('createNote 落到「我的轻笔记」', () async {
      final (executor: ex, seen: seen) = agreeing();
      final data = okData(await ex.execute(
        'createNote',
        {'title': '新笔记', 'content': '正文内容'},
      ));

      final created = await notes.byId(data['noteId'] as String);
      expect(created!.title, '新笔记');
      expect(created.content, '正文内容');
      expect(created.isInbox, isTrue);
      expect(seen.single.risk, ToolRisk.create);
    });

    test('createNote 指定不存在的笔记库 → 失败并提示 listNotebooks', () async {
      final (executor: ex, seen: _) = agreeing();
      final r = await ex.execute(
        'createNote',
        {'content': 'x', 'notebookId': '编的'},
      );
      expect(r.ok, isFalse);
      expect(r.error, contains('listNotebooks'));
    });

    test('createNotebook', () async {
      final (executor: ex, seen: _) = agreeing();
      final data = okData(await ex.execute('createNotebook', {'name': '工作'}));
      expect((await db.getNotebook(data['notebookId'] as String))!.name, '工作');
    });

    test('createNotebook 缺 name → 失败', () async {
      final (executor: ex, seen: _) = agreeing();
      final r = await ex.execute('createNotebook', const {});
      expect(r.ok, isFalse);
      expect(r.error, contains('name'));
    });

    test('moveNote 到笔记库、以及移回轻笔记', () async {
      final nb = await NotebookRepository(db).create(name: '工作');
      final note = await notes.createInbox(title: 'N', content: 'x');
      final (executor: ex, seen: _) = agreeing();

      await ex.execute('moveNote', {'noteId': note.id, 'notebookId': nb.id});
      expect((await notes.byId(note.id))!.notebookId, nb.id);

      await ex.execute('moveNote', {'noteId': note.id});
      expect((await notes.byId(note.id))!.notebookId, isNull);
    });

    test('renameNotebook', () async {
      final nb = await NotebookRepository(db).create(name: '旧名');
      final (executor: ex, seen: _) = agreeing();
      await ex.execute('renameNotebook', {'notebookId': nb.id, 'name': '新名'});
      expect((await db.getNotebook(nb.id))!.name, '新名');
    });

    test('batchMoveNotes 正常移动', () async {
      final nb = await NotebookRepository(db).create(name: '工作');
      final a = await notes.createInbox(title: 'A', content: 'x');
      final b = await notes.createInbox(title: 'B', content: 'y');
      final (executor: ex, seen: _) = agreeing();

      final data = okData(await ex.execute(
        'batchMoveNotes',
        {'noteIds': [a.id, b.id], 'notebookId': nb.id},
      ));

      expect(data['moved'], 2);
      expect((await notes.byId(a.id))!.notebookId, nb.id);
      expect((await notes.byId(b.id))!.notebookId, nb.id);
    });

    test('★ batchMoveNotes 超过 10 条 → 失败（协议上限）', () async {
      final (executor: ex, seen: seen) = agreeing();
      final r = await ex.execute('batchMoveNotes', {
        'noteIds': [for (var i = 0; i < 11; i++) 'n$i'],
      });
      expect(r.ok, isFalse);
      expect(r.error, contains('10'));
      expect(seen, isEmpty, reason: '参数都不合法就不该弹确认');
    });
  });

  group('★ AI 写笔记受**与编辑页同一套**上限约束', () {
    // 编辑页在 100 KB 处拒绝保存、标题超 200 字截断；AI 走的是另一条写入路径，
    // 早先完全不受约束（同一张表两条路，一条有上限一条没有）。

    test('createNote：正文到硬上限 → 失败、**不落盘、也不弹确认**', () async {
      final (executor: ex, seen: seen) = agreeing();
      // 100 KB 硬上限：中文一字 3 字节，写 40 万字肯定超
      final huge = '很长的正文。' * 20000;

      final r = await ex.execute('createNote', {
        'title': '太大',
        'content': huge,
      });

      expect(r.ok, isFalse);
      expect(r.error, contains('硬上限'));
      expect(seen, isEmpty, reason: '注定写不进去的事不该让用户点确认');
      expect(await db.allActiveNotes(), isEmpty, reason: '一条都不该写进去');
    });

    test('createNote：标题超 200 字被**截断**（与编辑页一样，不是拒绝）', () async {
      final (executor: ex, seen: _) = agreeing();
      final longTitle = '标' * 260;

      final data = okData(await ex.execute('createNote', {
        'title': longTitle,
        'content': '正文。',
      }));

      // `safeTruncate` 截到 200 字并**补一个省略号**（那是给用户看的"被截了"标记）
      expect(data['title'], '${'标' * 200}…');
    });

    test('updateNote：改完超上限 → 失败，正文一个字都不改', () async {
      final note = await notes.createInbox(title: 'N', content: '原文。');
      final (executor: ex, seen: _) = agreeing();

      final r = await ex.execute('updateNote', {
        'noteId': note.id,
        'expectedText': '原文。',
        'newContent': '很长的正文。' * 20000,
      });

      expect(r.ok, isFalse);
      expect(r.error, contains('硬上限'));
      expect((await notes.byId(note.id))!.content, '原文。');
    });

    test('appendToNote：追加后超上限 → 失败（不然"只加一点"能绕过去）', () async {
      final note = await notes.createInbox(title: 'N', content: '很长的正文。' * 20000);
      final (executor: ex, seen: _) = agreeing();

      final r = await ex.execute('appendToNote', {
        'noteId': note.id,
        'text': '再来一句。',
      });

      expect(r.ok, isFalse);
      expect(r.error, contains('硬上限'));
      expect((await notes.byId(note.id))!.content, '很长的正文。' * 20000);
    });
  });

  group('★ 派生字段的口径与编辑页完全一致', () {
    // `notes.excerpt` / `notes.wordCount` 一列多写：编辑页与 AI 两条路。
    // 早先 AI 那条用的是"自己那套"（预览 80 字、字数 content.length），
    // 于是同一篇笔记，AI 写过和人改过在列表里显示的数字不一样。

    test('AI 写过的笔记，excerpt / wordCount 与 NoteRepository 写出来的一致', () async {
      final (executor: ex, seen: _) = agreeing();
      const md = '# 标题\n\n**粗体**与 `代码`，还有 [链接](http://x) 与 English words.';

      final data = okData(await ex.execute('createNote', {'content': md}));
      final byAi = (await notes.byId('${data['noteId']}'))!;

      // 同样内容由 `NoteRepository` 直接写一份作对照
      final byRepo = await notes.createInbox(title: '', content: md);

      expect(byAi.excerpt, byRepo.excerpt);
      expect(byAi.wordCount, byRepo.wordCount);
      // 顺手钉一下口径本身：Markdown 噪声（`#`、`**`、链接 URL）不该被算进去
      expect(byAi.excerpt, isNot(contains('**')));
      expect(byAi.excerpt, isNot(contains('http')));
    });
  });

  group('笔记库名的上限只有一处收口', () {
    test('超长名字被截断（界面与 AI 的 createNotebook 走同一个方法）', () async {
      final repo = NotebookRepository(db);
      // 截到 200 字 + 省略号（与标题同一套 `safeTruncate`）
      final nb = await repo.create(name: '库' * 260);
      expect(nb.name, '${'库' * 200}…');

      final (executor: ex, seen: _) = agreeing();
      final data = okData(await ex.execute('createNotebook', {'name': '库' * 300}));
      expect(data['name'], '${'库' * 200}…');
    });
  });

  group('写完之后切片跟着走', () {
    test('改完正文，切片与新的正文一致（搜索才不会指错）', () async {
      final note = await notes.createInbox(
        title: 'N',
        content: '# 甲章\n\n${'甲的内容。' * 85}\n\n# 乙章\n\n${'乙的内容。' * 85}',
      );
      final (executor: ex, seen: _) = agreeing();

      await ex.execute('updateNote', {
        'noteId': note.id,
        'expectedText': '甲的内容。',
        'newContent': '完全换掉的一段话。',
      });

      final body = (await notes.byId(note.id))!.content;
      final rows = await db.chunksOf(note.id);
      expect(rows, isNotEmpty);
      for (final r in rows) {
        expect(body.substring(r.startOffset, r.endOffset).hashCode, r.contentHash);
      }
    });
  });
}
