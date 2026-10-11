// 阶段 8：删除与批量。
//
// 这一层的验收点不在"能不能删掉"，而在**删不掉的那些路径**：
//   · 模型忘了请求确认 → 执行器照样拦住
//   · 用户重复点「允许」→ 只执行一次
//   · 措辞是否写明"找不回来"
//   · AI 根本够不到敏感操作（设置 / Key / SQL / 文件系统）
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

  ({ToolExecutor executor, List<ToolConfirmRequest> seen}) agreeing() {
    final seen = <ToolConfirmRequest>[];
    return (
      executor: ToolExecutor(db, onConfirm: (r) async {
        seen.add(r);
        return true;
      }),
      seen: seen,
    );
  }

  Map<String, Object?> okData(ToolResult r) {
    expect(r.ok, isTrue, reason: '本该成功：${r.error}');
    return (jsonDecode(r.encode())['data'] as Map).cast<String, Object?>();
  }

  group('★ 模型忘了请求确认，也删不掉', () {
    test('没有确认通道 → deleteNote 被拒，笔记还在', () async {
      final note = await notes.createInbox(title: 'N', content: '正文。');
      final ex = ToolExecutor(db); // 没接 onConfirm

      final r = await ex.execute('deleteNote', {'noteId': note.id});

      expect(r.ok, isFalse);
      expect(r.error, contains('确认通道'));
      expect((await notes.byId(note.id))!.deletedAt, isNull,
          reason: '风险拦截必须在 App 执行器里，不能靠模型自觉调 askUser');
    });

    test('用户拒绝 → 不删，并明确告诉模型"用户拒绝了"', () async {
      final note = await notes.createInbox(title: 'N', content: '正文。');
      final ex = ToolExecutor(db, onConfirm: (_) async => false);

      final r = await ex.execute('deleteNote', {'noteId': note.id});

      expect(r.ok, isFalse);
      expect(r.error, contains('拒绝'));
      expect((await notes.byId(note.id))!.deletedAt, isNull);
    });

    test('三个删除工具都标了 delete 风险（= 需要二次确认）', () {
      for (final name in ['deleteNote', 'deleteNotebook', 'batchDeleteNotes']) {
        final t = toolByName(name)!;
        expect(t.risk, ToolRisk.delete, reason: name);
        expect(t.needsStrongConfirm, isTrue, reason: name);
      }
    });
  });

  group('deleteNote', () {
    test('★ 确认措辞写明"找不回来"（用户要知道这是不可逆的）', () async {
      final note = await notes.createInbox(title: '会议记录', content: '正文。');
      final (executor: ex, seen: seen) = agreeing();

      await ex.execute('deleteNote', {'noteId': note.id});

      expect(seen.single.strong, isTrue);
      expect(seen.single.summary, contains('找不回来'));
      expect(seen.single.summary, contains('会议记录'));
      expect(seen.single.summary, contains('没有回收站'));
    });

    test('确认后真的删了，并且**切片一起清掉**', () async {
      final note = await notes.createInbox(
        title: 'N',
        content: '# 章\n\n${'内容。' * 200}',
      );
      // 先让切片落库
      await ex0(db).execute('listChunks', {'noteId': note.id});
      expect(await db.chunkCount(note.id), greaterThan(0));

      final (executor: ex, seen: _) = agreeing();
      okData(await ex.execute('deleteNote', {'noteId': note.id}));

      expect((await notes.byId(note.id))!.deletedAt, isNotNull);
      expect(await db.chunkCount(note.id), 0,
          reason: '软删不会触发外键级联，留着片会让搜索算到已删笔记头上');
    });

    test('★ 重复调用只删一次，且**不报错**（防重复点「允许」）', () async {
      final note = await notes.createInbox(title: 'N', content: '正文。');
      final (executor: ex, seen: seen) = agreeing();

      final first = okData(await ex.execute('deleteNote', {'noteId': note.id}));
      final second = await ex.execute('deleteNote', {'noteId': note.id});

      expect(first['alreadyDeleted'], isNull);
      expect(second.ok, isTrue, reason: '第二次不该报错 —— 用户会以为自己点坏了');
      expect(okData(second)['alreadyDeleted'], isTrue);
      expect(seen, hasLength(1), reason: '第二次连确认都不该再弹');
    });

    test('删不存在的笔记 → 当成已删，不报错', () async {
      final (executor: ex, seen: seen) = agreeing();
      final r = await ex.execute('deleteNote', {'noteId': '编的'});
      expect(r.ok, isTrue);
      expect(okData(r)['alreadyDeleted'], isTrue);
      expect(seen, isEmpty);
    });

    test('缺 noteId → 失败', () async {
      final (executor: ex, seen: _) = agreeing();
      final r = await ex.execute('deleteNote', const {});
      expect(r.ok, isFalse);
      expect(r.error, contains('noteId'));
    });
  });

  group('deleteNotebook：笔记退回「我的轻笔记」', () {
    test('确认措辞要说清"里面的笔记不会删"', () async {
      final nb = await NotebookRepository(db).create(name: '工作');
      await notes.createInNotebook(nb.id, title: 'A', content: 'x');
      final (executor: ex, seen: seen) = agreeing();

      await ex.execute('deleteNotebook', {'notebookId': nb.id});

      expect(seen.single.summary, contains('工作'));
      expect(seen.single.summary, contains('不会删'),
          reason: '不说的话用户以为笔记也没了，不敢点');
      expect(seen.single.summary, contains('1 条'));
    });

    test('删库之后笔记回到轻笔记（不是被删）', () async {
      final nb = await NotebookRepository(db).create(name: '工作');
      final a = await notes.createInNotebook(nb.id, title: 'A', content: 'x');
      final b = await notes.createInNotebook(nb.id, title: 'B', content: 'y');
      final (executor: ex, seen: _) = agreeing();

      final data = okData(await ex.execute('deleteNotebook', {'notebookId': nb.id}));

      expect(data['notesKept'], 2);
      // ⚠️ `getNotebook` **不筛软删**：行还在，靠 `deletedAt` 判断
      expect((await db.getNotebook(nb.id))!.deletedAt, isNotNull);
      for (final id in [a.id, b.id]) {
        final n = await notes.byId(id);
        expect(n!.deletedAt, isNull, reason: '笔记不该被删');
        expect(n.notebookId, isNull);
        expect(n.isInbox, isTrue, reason: '退回「我的轻笔记」');
      }
    });

    test('重复删同一个库 → 当成已删', () async {
      final nb = await NotebookRepository(db).create(name: '工作');
      final (executor: ex, seen: _) = agreeing();

      await ex.execute('deleteNotebook', {'notebookId': nb.id});
      final again = await ex.execute('deleteNotebook', {'notebookId': nb.id});

      expect(again.ok, isTrue);
      expect(okData(again)['alreadyDeleted'], isTrue);
    });
  });

  group('batchDeleteNotes', () {
    test('≤10 条正常删除', () async {
      final made = [
        for (var i = 0; i < 3; i++)
          await notes.createInbox(title: '笔记$i', content: '正文'),
      ];
      final (executor: ex, seen: _) = agreeing();

      final data = okData(await ex.execute(
        'batchDeleteNotes',
        {'noteIds': [for (final n in made) n.id]},
      ));

      expect(data['deleted'], 3);
      for (final n in made) {
        expect((await notes.byId(n.id))!.deletedAt, isNotNull);
      }
    });

    test('★ 超过 10 条 → 拒绝（协议上限），一条都不删', () async {
      final made = [
        for (var i = 0; i < 11; i++)
          await notes.createInbox(title: '笔记$i', content: '正文'),
      ];
      final (executor: ex, seen: seen) = agreeing();

      final r = await ex.execute(
        'batchDeleteNotes',
        {'noteIds': [for (final n in made) n.id]},
      );

      expect(r.ok, isFalse);
      expect(r.error, contains('10'));
      expect(seen, isEmpty, reason: '参数就不合法，不该弹确认');
      expect((await notes.byId(made.first.id))!.deletedAt, isNull);
    });

    test('列表里混了已删 / 不存在的 id → 只删还活着的', () async {
      final a = await notes.createInbox(title: 'A', content: 'x');
      final b = await notes.createInbox(title: 'B', content: 'y');
      await notes.softDelete(b.id);
      final (executor: ex, seen: _) = agreeing();

      final data = okData(await ex.execute(
        'batchDeleteNotes',
        {'noteIds': [a.id, b.id, '编的']},
      ));

      expect(data['deleted'], 1);
    });

    test('全都已删 → 直接成功，不再弹确认', () async {
      final a = await notes.createInbox(title: 'A', content: 'x');
      await notes.softDelete(a.id);
      final (executor: ex, seen: seen) = agreeing();

      final r = await ex.execute('batchDeleteNotes', {'noteIds': [a.id]});

      expect(r.ok, isTrue);
      expect(okData(r)['alreadyDeleted'], isTrue);
      expect(seen, isEmpty);
    });

    test('空数组 / 缺参数 → 失败', () async {
      final (executor: ex, seen: _) = agreeing();
      expect((await ex.execute('batchDeleteNotes', const {})).ok, isFalse);
      expect(
        (await ex.execute('batchDeleteNotes', {'noteIds': []})).ok,
        isFalse,
      );
    });
  });

  group('★ AI 够不到敏感操作', () {
    test('全部工具里没有一个是"改设置 / 改 Key / 执行 SQL / 文件 / 清库"', () {
      // 这条是**结构性**保证：不提供这类工具，模型就没有入口。
      // 一旦有人加了一个，这条会红。
      const sensitive = [
        'setting', 'config', 'pref', 'apikey', 'api_key', 'key',
        'sql', 'query_db', 'exec', 'shell', 'file', 'fs',
        'wipe', 'clear', 'reset', 'drop', 'delete_all', 'truncate',
        'backup', 'restore', 'conversation',
      ];
      for (final t in kAgentTools) {
        final lower = t.name.toLowerCase();
        for (final bad in sensitive) {
          expect(lower.contains(bad), isFalse,
              reason: '工具 `${t.name}` 碰到了敏感面（$bad）');
        }
      }
    });

    test('凭空编一个工具名 → 被拒', () async {
      final (executor: ex, seen: _) = agreeing();
      for (final name in [
        'runSql',
        'writeSetting',
        'setApiKey',
        'deleteDatabase',
        'wipeAllNotes',
        'readFile',
      ]) {
        final r = await ex.execute(name, const {});
        expect(r.ok, isFalse, reason: name);
        expect(r.error, contains('requestTools'), reason: name);
      }
    });

    test('工具清单仍是 22 个（加敏感工具会让上一条红，这条兜住数量）', () {
      expect(kAgentTools, hasLength(22));
    });
  });
}

/// 只读执行器（不需要确认通道）：给"先把切片建出来"这种准备工作用
ToolExecutor ex0(AppDatabase db) => ToolExecutor(db);
