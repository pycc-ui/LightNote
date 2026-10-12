// 笔记切片的**存取与自愈**（`NoteChunkRepository`）。
//
// 这一层要盯的是三条路径（见仓储的类注释）：
//   · 保存后：**大多数时候什么都不做**，只有"没切过"或"长度变化够大"才重切
//   · 读取时：hash 对不上就当场重切（**自愈**），这是"小改动不重切"能成立的前提
//   · 软删除：切片一起清（外键的 ON DELETE CASCADE 在软删下**不会触发**）
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/features/note/data/note_chunk_repository.dart';
import 'package:lightnote/features/note/data/note_repository.dart';
import 'package:lightnote/features/note/domain/note_chunk.dart';
import 'package:lightnote/features/note/domain/note_chunker.dart';

void main() {
  late AppDatabase db;
  late NoteChunkRepository chunks;
  late NoteRepository notes;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    chunks = NoteChunkRepository(db);
    notes = NoteRepository(db);
  });
  tearDown(() => db.close());

  /// 够长、能切出多片的正文（每段约 150 字，段间空行）
  String body(int paragraphs) =>
      List.generate(paragraphs, (i) => '第$i段。${'内容' * 70}').join('\n\n');

  group('懒回填：老库升级上来的笔记第一次被用到时才切', () {
    test('一片都没有时，chunksFor 会现切一遍并写回', () async {
      final note = await notes.createInbox(title: '长', content: body(20));
      expect(await db.chunkCount(note.id), 0, reason: '新建时还没切片');

      final got = await chunks.chunksFor(note.id, note.content);

      expect(got, isNotEmpty);
      expect(await db.chunkCount(note.id), got.length, reason: '要写回库里');
    });

    test('写回的片与正文逐字对应', () async {
      final note = await notes.createInbox(title: '长', content: body(20));
      final got = await chunks.chunksFor(note.id, note.content);

      for (final c in got) {
        expect(c.textOf(note.content), note.content.substring(c.start, c.end));
        expect(c.contentHash, NoteChunk.hashOf(note.content, c.start, c.end));
      }
    });

    test('空正文不产出片，也不写库', () async {
      final note = await notes.createInbox(title: '空', content: '   ');
      expect(await chunks.chunksFor(note.id, note.content), isEmpty);
      expect(await db.chunkCount(note.id), 0);
    });

    test('backfillMissing 只补"没切过"的，返回补了几篇', () async {
      await notes.createInbox(title: 'A', content: body(20));
      final b = await notes.createInbox(title: 'B', content: body(20));
      await chunks.rebuild(b.id, b.content); // B 已经有片

      final done = await chunks.backfillMissing();

      expect(done, 1, reason: '只有 A 需要补');
      expect(await db.chunkCount(b.id), greaterThan(0));
    });

    test('noteIdsWithoutChunks 不把软删的笔记算进去', () async {
      final a = await notes.createInbox(title: 'A', content: body(20));
      final b = await notes.createInbox(title: 'B', content: body(20));
      await notes.softDelete(b.id);

      final ids = await db.noteIdsWithoutChunks();
      expect(ids, contains(a.id));
      expect(ids, isNot(contains(b.id)));
    });
  });

  group('自愈：正文改了、偏移失效时当场重切', () {
    test('**人为把偏移改坏 → 读片时重切**，用户拿到的是正确正文', () async {
      final note = await notes.createInbox(title: '长', content: body(20));
      final before = await chunks.chunksFor(note.id, note.content);
      expect(before, isNotEmpty);

      // 直接把某一片的 hash 改坏，模拟"正文变了但没重切"
      final row = (await db.chunksOf(note.id)).first;
      await (db.update(db.noteChunks)
            ..where((t) => t.noteId.equals(note.id) & t.idx.equals(row.idx)))
          .write(NoteChunksCompanion(
        contentHash: Value(row.contentHash ^ 0x7fffffff),
      ));

      final after = await chunks.chunksFor(note.id, note.content);

      expect(after, isNotEmpty);
      for (final c in after) {
        expect(c.textOf(note.content),
            note.content.substring(c.start, c.end),
            reason: '重切之后偏移必须是有效的');
      }
    });

    test('偏移越界（正文被截短）也会触发重切', () async {
      final note = await notes.createInbox(title: '长', content: body(20));
      await chunks.chunksFor(note.id, note.content);

      final shortened = body(3);
      final got = await chunks.chunksFor(note.id, shortened);

      expect(got, isNotEmpty);
      for (final c in got) {
        expect(c.end, lessThanOrEqualTo(shortened.length));
      }
      expect(await db.chunkCount(note.id), got.length);
    });

    test('一致时**零写入**：不改库里的任何一行', () async {
      final note = await notes.createInbox(title: '长', content: body(20));
      await chunks.chunksFor(note.id, note.content);
      final snapshot = (await db.chunksOf(note.id))
          .map((r) => '${r.idx}:${r.contentHash}')
          .toList();

      await chunks.chunksFor(note.id, note.content);

      final again = (await db.chunksOf(note.id))
          .map((r) => '${r.idx}:${r.contentHash}')
          .toList();
      expect(again, snapshot);
    });
  });

  group('保存后：按长度差决定要不要重切', () {
    test('还没切过 → 切', () async {
      final note = await notes.createInbox(title: '长', content: body(20));
      expect(await chunks.onNoteSaved(note.id, note.content), isTrue);
      expect(await db.chunkCount(note.id), greaterThan(0));
    });

    test('**内容一字未变 → 不重切**（重复保存不该白干一次切片）', () async {
      final note = await notes.createInbox(title: '长', content: body(20));
      await chunks.rebuild(note.id, note.content);
      final before = (await db.chunksOf(note.id)).map((r) => r.contentHash).toList();

      // 同一个正文再保存一次：长度差为 0
      final did = await chunks.onNoteSaved(note.id, note.content);

      expect(did, isFalse, reason: '没变就不该重切');
      expect((await db.chunksOf(note.id)).map((r) => r.contentHash).toList(),
          before,
          reason: '片应当原样不动');
    });

    test('**改一个错别字也重切**（`staleRatio = 0`：宁可多切一次）', () async {
      // 这一条盯的是一个**产品决定**（见 `NoteChunkRepository.staleRatio`）：
      // 早先阈值是 20%，小改动留给读片时的 hash 自愈；后来改成 0 ——
      // 因为"改得少"不等于"改得不重要"（纠正一个错别字正是最该立刻生效的改动），
      // 而自愈只在**有人真的读到那一片**时才发生。
      //
      // 代价如实写在这里：每次保存都会重切一次（纯函数 + 一次事务内的删/插），
      // 换来的是"片永远指向当前正文"。
      final note = await notes.createInbox(title: '长', content: body(20));
      await chunks.rebuild(note.id, note.content);
      final before = (await db.chunksOf(note.id)).map((r) => r.contentHash).toList();

      final edited = '${note.content}嗯';
      final did = await chunks.onNoteSaved(note.id, edited);

      expect(did, isTrue, reason: '哪怕只多一个字，也要重切');
      expect((await db.chunksOf(note.id)).map((r) => r.contentHash).toList(),
          isNot(before),
          reason: '重切过就不该还是旧 hash（否则等于没切）');
    });

    test('长度变化很大 → 同样重切', () async {
      final note = await notes.createInbox(title: '长', content: body(20));
      await chunks.rebuild(note.id, note.content);

      final did = await chunks.onNoteSaved(note.id, body(60));
      expect(did, isTrue);
    });

    test('正文被清空 → 片也清掉（不留指向空文本的偏移）', () async {
      final note = await notes.createInbox(title: '长', content: body(20));
      await chunks.rebuild(note.id, note.content);
      expect(await db.chunkCount(note.id), greaterThan(0));

      await chunks.onNoteSaved(note.id, '   ');
      expect(await db.chunkCount(note.id), 0);
    });

    test('走 saveContent 这条路也会切（真实调用链）', () async {
      final note = await notes.createInbox(title: '长', content: body(20));
      await notes.saveContent(note.id, content: body(30));
      expect(await db.chunkCount(note.id), greaterThan(0));
    });

    test('内容没变时不碰切片', () async {
      final note = await notes.createInbox(title: '长', content: body(20));
      await chunks.rebuild(note.id, note.content);
      final before = (await db.chunksOf(note.id)).length;

      await notes.saveContent(note.id, title: '只改标题');

      expect((await db.chunksOf(note.id)).length, before);
    });
  });

  group('删除与恢复', () {
    test('软删除时清掉切片（外键级联在软删下不触发）', () async {
      final note = await notes.createInbox(title: '长', content: body(20));
      await chunks.rebuild(note.id, note.content);
      expect(await db.chunkCount(note.id), greaterThan(0));

      await notes.softDelete(note.id);

      expect(await db.chunkCount(note.id), 0,
          reason: '软删的笔记留着片，搜索结果会把"命中哪一片"算到它头上');
    });

    test('批量软删同样清干净', () async {
      final a = await notes.createInbox(title: 'A', content: body(20));
      final b = await notes.createInbox(title: 'B', content: body(20));
      await chunks.rebuild(a.id, a.content);
      await chunks.rebuild(b.id, b.content);

      await notes.softDeleteMany([a.id, b.id]);

      expect(await db.chunkCount(a.id), 0);
      expect(await db.chunkCount(b.id), 0);
    });

    test('恢复之后切片能按需重建', () async {
      final note = await notes.createInbox(title: '长', content: body(20));
      await chunks.rebuild(note.id, note.content);
      await notes.softDelete(note.id);
      await notes.restore(note.id);

      final got = await chunks.chunksFor(note.id, note.content);
      expect(got, isNotEmpty);
    });
  });

  group('读片', () {
    test('readChunk 取到的就是那一片的正文，与切片器一致', () async {
      final note = await notes.createInbox(title: '长', content: body(20));
      final expected = NoteChunker.chunk(note.content);

      for (final c in expected) {
        final text = await chunks.readChunk(note.id, note.content, c.index);
        expect(text, note.content.substring(c.start, c.end));
      }
    });

    test('越界返回 null（与"取到空串"要能区分）', () async {
      final note = await notes.createInbox(title: '长', content: body(5));
      final n = (await chunks.chunksFor(note.id, note.content)).length;

      expect(await chunks.readChunk(note.id, note.content, -1), isNull);
      expect(await chunks.readChunk(note.id, note.content, n), isNull);
      expect(await chunks.readChunk(note.id, note.content, n + 99), isNull);
    });

    test('cachedChunks 不触发重切', () async {
      final note = await notes.createInbox(title: '长', content: body(20));
      expect(await chunks.cachedChunks(note.id), isEmpty);
      expect(await db.chunkCount(note.id), 0, reason: 'cached 版不该写库');
    });
  });

  group('重切是原子的', () {
    test('replaceNoteChunks 先删后插，不会留下"一半"的状态', () async {
      final note = await notes.createInbox(title: '长', content: body(20));
      final first = await chunks.rebuild(note.id, note.content);
      expect(await db.chunkCount(note.id), first.length);

      final second = await chunks.rebuild(note.id, body(10));

      expect(await db.chunkCount(note.id), second.length);
      final idxs = (await db.chunksOf(note.id)).map((r) => r.idx).toList();
      expect(idxs, List.generate(second.length, (i) => i),
          reason: 'idx 必须是从 0 起连续的，不能有旧片残留');
    });
  });
}
