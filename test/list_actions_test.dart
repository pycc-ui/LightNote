// 列表交互的**数据层**部分：左滑删除的撤销、多选的批量移动/删除。
//
// 手势本身（Dismissible、多选顶栏）属于 UI，跟手写用例价值低、易脆；
// 真正容易做错的是数据语义，所以重点测这些：
//   · 撤销删除要真的把笔记恢复（而不只是把它从界面移走）
//   · 批量操作要在一个事务里（中途失败不能删一半）
//   · 批量移动能移到别的库，也能移回「我的轻笔记」
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_notes/core/db/app_database.dart';
import 'package:smart_notes/features/note/data/notebook_repository.dart';
import 'package:smart_notes/features/note/data/note_repository.dart';

void main() {
  late AppDatabase db;
  late NoteRepository notes;
  late NotebookRepository notebooks;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    notes = NoteRepository(db);
    notebooks = NotebookRepository(db);
  });

  tearDown(() => db.close());

  group('左滑删除 + 撤销', () {
    test('删除后从列表消失，撤销后回来', () async {
      final n = await notes.createInbox(title: '要删的', content: '正文');
      expect((await notes.watchUnfiled().first).length, 1);

      // 左滑删除
      await notes.softDelete(n.id);
      expect(await notes.watchUnfiled().first, isEmpty, reason: '删了就该从列表消失');

      // 点撤销
      await notes.restore(n.id);
      final back = await notes.watchUnfiled().first;
      expect(back.length, 1, reason: '撤销后要真的回来');
      expect(back.first.title, '要删的');
    });

    test('撤销保留内容与归属，不只是把行加回来', () async {
      final nb = await notebooks.create(name: '工作');
      final n = await notes.createInNotebook(nb.id, title: 'T', content: 'C');

      await notes.softDelete(n.id);
      await notes.restore(n.id);

      final after = await notes.byId(n.id);
      expect(after!.title, 'T');
      expect(after.content, 'C');
      expect(after.notebookId, nb.id, reason: '归属不该被撤销动作冲掉');
      expect(after.isInbox, isFalse);
      expect(await notes.watchNotesInNotebook(nb.id).first, hasLength(1));
    });

    test('撤销一条本来就不存在的笔记不会炸', () async {
      await notes.restore('不存在的-id'); // 不抛即可
    });
  });

  group('批量删除', () {
    test('一次删多条', () async {
      final a = await notes.createInbox(title: 'A', content: 'x');
      final b = await notes.createInbox(title: 'B', content: 'x');
      final c = await notes.createInbox(title: 'C', content: 'x');

      await notes.softDeleteMany([a.id, b.id, c.id]);

      expect(await notes.watchUnfiled().first, isEmpty);
      expect(await db.allActiveNotes(), isEmpty);
    });

    test('只删传进去的那些', () async {
      final keep = await notes.createInbox(title: '留', content: 'x');
      final del = await notes.createInbox(title: '删', content: 'x');

      await notes.softDeleteMany([del.id]);

      final rest = await notes.watchUnfiled().first;
      expect(rest.map((n) => n.id), [keep.id]);
    });

    test('空列表是安全的 no-op', () async {
      final n = await notes.createInbox(title: '在', content: 'x');
      await notes.softDeleteMany(const []);
      expect((await notes.watchUnfiled().first).map((x) => x.id), [n.id]);
    });

    test('批量撤销（对已删的一批调 restore）', () async {
      final ids = <String>[];
      for (var i = 0; i < 3; i++) {
        ids.add((await notes.createInbox(title: 'N$i', content: 'x')).id);
      }
      await notes.softDeleteMany(ids);
      expect(await notes.watchUnfiled().first, isEmpty);

      for (final id in ids) {
        await notes.restore(id);
      }
      expect(await notes.watchUnfiled().first, hasLength(3));
    });
  });

  group('批量移动', () {
    test('移到指定笔记库，返回条数', () async {
      final nb = await notebooks.create(name: '工作');
      final ids = <String>[];
      for (var i = 0; i < 3; i++) {
        ids.add((await notes.createInbox(title: 'N$i', content: 'x')).id);
      }

      final moved = await notes.moveManyToNotebook(ids, nb.id);

      expect(moved, 3);
      expect(await notes.watchUnfiled().first, isEmpty, reason: '不该还在我的轻笔记');
      expect(await notes.watchNotesInNotebook(nb.id).first, hasLength(3));
    });

    test('移到「我的轻笔记」（传 null 表示移出笔记库）', () async {
      final nb = await notebooks.create(name: '工作');
      final a = await notes.createInNotebook(nb.id, title: 'A', content: 'x');
      final b = await notes.createInNotebook(nb.id, title: 'B', content: 'x');

      await notes.moveManyToNotebook([a.id, b.id], null);

      expect(await notes.watchNotesInNotebook(nb.id).first, isEmpty);
      final inbox = await notes.watchUnfiled().first;
      expect(inbox.map((n) => n.id).toSet(), {a.id, b.id});
      // 移出笔记库后应当变成未归档
      expect(inbox.every((n) => n.isInbox), isTrue);
    });

    test('跨库批量移动', () async {
      final from = await notebooks.create(name: '来自');
      final to = await notebooks.create(name: '去往');
      final a = await notes.createInNotebook(from.id, title: 'A', content: 'x');
      final b = await notes.createInNotebook(from.id, title: 'B', content: 'x');

      await notes.moveManyToNotebook([a.id, b.id], to.id);

      expect(await notes.watchNotesInNotebook(from.id).first, isEmpty);
      expect(await notes.watchNotesInNotebook(to.id).first, hasLength(2));
    });

    test('空列表返回 0', () async {
      final nb = await notebooks.create(name: '工作');
      expect(await notes.moveManyToNotebook(const [], nb.id), 0);
    });

    test('批量操作在事务里：一次调用要么全成要么全不成', () async {
      // 用一个不存在的 notebookId 制造外键冲突（PRAGMA foreign_keys 已开）。
      // 要求：第一条也不会被改掉，不留下"改了一半"的状态。
      final nb = await notebooks.create(name: '工作');
      final a = await notes.createInNotebook(nb.id, title: 'A', content: 'x');

      await expectLater(
        notes.moveManyToNotebook([a.id], '不存在的库-id'),
        throwsA(anything),
      );

      // 原归属不变
      final after = await notes.byId(a.id);
      expect(after!.notebookId, nb.id, reason: '失败后不该留下半完成状态');
    });
  });
}
