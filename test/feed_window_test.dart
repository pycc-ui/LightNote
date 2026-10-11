// 阶段 3：卡片流的素材改成「片内的 400 字窗口」。
//
// 要盯住的三件事：
//   · 窗口候选起点的算法（含"最后一个窗口尾部对齐"）
//   · **轮换**：一片的每个窗口都会轮到，不会出现"后半段永远不出卡片"
//   · **last_used_at 落库**：重启之后不重复（内存方案重启就回到高重复）
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/features/ai/data/deepseek_client.dart';
import 'package:lightnote/features/ai/domain/ai_repository.dart';
import 'package:lightnote/features/note/data/feed_repository.dart';
import 'package:lightnote/features/note/data/note_repository.dart';
import 'package:lightnote/features/note/domain/feed_window.dart';
import 'package:lightnote/features/note/domain/note_chunk.dart';

void main() {
  group('纯函数：候选窗口起点', () {
    test('片 ≤400 → 只有起点 0（用整片，不开窗）', () {
      expect(FeedWindow.starts(0), [0]);
      expect(FeedWindow.starts(350), [0]);
      expect(FeedWindow.starts(400), [0]);
    });

    test('刚好超一个字符 → 两个起点', () {
      expect(FeedWindow.starts(401), [0, 1]);
    });

    test('文档里那三行', () {
      expect(FeedWindow.starts(350), [0]);
      expect(FeedWindow.starts(700), [0, 300]);
      expect(FeedWindow.starts(1500), [0, 400, 800, 1100]);
    });

    test('**最后一个窗口尾部对齐**：不会只剩几十个字', () {
      for (final len in [401, 700, 801, 1000, 1500, 2001]) {
        final s = FeedWindow.starts(len);
        expect(s.last, len - FeedWindow.chars,
            reason: 'len=$len 的最后一个起点必须让窗口贴到片尾');
        for (final x in s) {
          expect(x, greaterThanOrEqualTo(0));
          expect(x + FeedWindow.chars, lessThanOrEqualTo(len),
              reason: 'len=$len 起点 $x 的窗口越出片尾');
        }
      }
    });

    test('起点严格递增、不重复', () {
      final s = FeedWindow.starts(1500);
      for (var i = 1; i < s.length; i++) {
        expect(s[i], greaterThan(s[i - 1]));
      }
      expect(s.toSet().length, s.length);
    });
  });

  group('纯函数：轮换', () {
    test('环形推进，到末尾回到第一个', () {
      final s = FeedWindow.starts(1500); // [0, 400, 800, 1100]
      expect(FeedWindow.nextStart(s, 0), 400);
      expect(FeedWindow.nextStart(s, 400), 800);
      expect(FeedWindow.nextStart(s, 800), 1100);
      expect(FeedWindow.nextStart(s, 1100), 0, reason: '环形回到开头');
    });

    test('单起点时原地打转', () {
      expect(FeedWindow.nextStart([0], 0), 0);
    });

    test('当前值不在候选里（正文改过）→ 回到第一个', () {
      // 猜一个下标可能越界，只有第一个是安全的
      expect(FeedWindow.nextStart([0, 400, 800], 250), 0);
      expect(FeedWindow.nextStart([0, 400, 800], 99999), 0);
    });

    test('空候选不炸', () {
      expect(FeedWindow.nextStart(const [], 5), 0);
    });
  });

  group('纯函数：取窗口正文', () {
    const content = 'abcdefghij';
    // 片 = [2, 10) → "cdefghij"
    const chunk = NoteChunk(
      index: 0, heading: '', level: 0, start: 2, end: 10, contentHash: 0);

    test('片比窗口短 → 整片', () {
      expect(FeedWindow.textOf(content, chunk, 0), 'cdefghij');
    });

    test('从起点取 400 字，且**不越出片**', () {
      // 片只有 8 个字，起点 3 → 只剩 5 个字，不能越到片外
      expect(FeedWindow.textOf(content, chunk, 3), 'fghij');
    });

    test('起点越界 → 收敛（返回空或最短），不抛错', () {
      expect(FeedWindow.textOf(content, chunk, 99), '');
      expect(FeedWindow.textOf(content, chunk, -5), 'cdefghij');
    });

    test('偏移失效（片越界）→ 空串而不是抛错', () {
      const broken = NoteChunk(
        index: 0, heading: '', level: 0, start: 5, end: 999, contentHash: 0);
      expect(FeedWindow.textOf(content, broken, 0), '');
    });

    test('正好 400 字的片 → 整片就是窗口', () {
      final c = 'x' * 400;
      const ch = NoteChunk(
        index: 0, heading: '', level: 0, start: 0, end: 400, contentHash: 0);
      expect(FeedWindow.textOf(c, ch, 0).length, 400);
    });
  });

  group('集成：素材是 400 字窗口', () {
    late AppDatabase db;
    late NoteRepository notes;
    late FeedRepository feed;

    const source = FeedSource(notebookIds: [], includeUnfiled: true);

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      notes = NoteRepository(db);
      feed = FeedRepository(
        db,
        AiRepository(db: db, client: DeepSeekClient()), // 没配 Key
      );
    });
    tearDown(() => db.close());

    /// 30 段 × 约 370 字 → **一段就是一片**（370×2 = 740 > 700，两段装不进一片）
    String manyChunks(int n) =>
        List.generate(n, (i) => '第$i段。${'内容' * 180}').join('\n\n');

    test('每份素材都 ≤400 字，一批总量 ≤4000 字', () async {
      await notes.createInbox(title: '长', content: manyChunks(30));

      final materials = await feed.gatherSources(source, limit: 9);

      expect(materials, hasLength(9));
      var total = 0;
      for (final m in materials) {
        expect(m.chunk.length, lessThanOrEqualTo(FeedWindow.chars),
            reason: '素材超过 400 字会打破卡片流的成本估算');
        total += m.chunk.length;
      }
      expect(total, lessThanOrEqualTo(FeedWindow.batchBudget),
          reason: '单批输入预算 4000 字（9 × 400 = 3600 本来就有余量）');
    });

    test('片数不再被"笔记数"卡死：1 篇长笔记也能凑够 9 份', () async {
      await notes.createInbox(title: '长', content: manyChunks(30));
      expect(await feed.gatherSources(source, limit: 9), hasLength(9));
    });

    test('同一批里的 9 份素材来自**不同的片**', () async {
      await notes.createInbox(title: '长', content: manyChunks(30));

      final keys = (await feed.gatherSources(source, limit: 9))
          .map((m) => m.chunkKey)
          .toList();

      expect(keys.toSet().length, keys.length, reason: '同一批不该重复取同一片');
      expect(keys.every((k) => k.contains(':')), isTrue, reason: '键是 noteId:idx');
    });

    test('用过的片**落库**了（last_used_at）', () async {
      final note = await notes.createInbox(title: '长', content: manyChunks(30));

      await feed.gatherSources(source, limit: 9);

      final rows = await db.chunksOf(note.id);
      final used = rows.where((r) => r.lastUsedAt != null).toList();
      expect(used, hasLength(9), reason: '取过的 9 片都要记上时间');

      // 每片的轮换位必须是**合法候选起点**。
      //
      // ⚠️ 这里不能断言"一定大于 0"：这些片只有约 370 字（< 400），
      // 只有 `[0]` 一个候选，轮换位本来就该是 0。要验"推进"得用更长的片，
      // 见下面「窗口轮换」那组。
      for (final r in used) {
        final starts = FeedWindow.starts(r.endOffset - r.startOffset);
        expect(starts, contains(r.nextWindowStart),
            reason: '轮换位 ${r.nextWindowStart} 不是合法候选起点 $starts');
      }
    });

    test('**重启后不重复**：新开一个 FeedRepository 取到的是没碰过的片', () async {
      await notes.createInbox(title: '长', content: manyChunks(30));

      final first = (await feed.gatherSources(source, limit: 9))
          .map((m) => m.chunkKey)
          .toSet();

      // 换一个实例 = 丢掉全部内存状态，只剩库里的 last_used_at
      final restarted = FeedRepository(
        db,
        AiRepository(db: db, client: DeepSeekClient()),
      );
      final second = (await restarted.gatherSources(source, limit: 9))
          .map((m) => m.chunkKey)
          .toSet();

      expect(first.intersection(second), isEmpty,
          reason: '30 片里取过 9 片，重启后应当优先剩下的 21 片 —— '
              '内存方案在这里会重新抽到同一批');
    });
  });

  group('集成：窗口轮换', () {
    late AppDatabase db;
    late NoteRepository notes;
    late FeedRepository feed;

    const source = FeedSource(notebookIds: [], includeUnfiled: true);

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      notes = NoteRepository(db);
      feed = FeedRepository(
        db,
        AiRepository(db: db, client: DeepSeekClient()),
      );
    });
    tearDown(() => db.close());

    /// 一段**逐字不同**的正文（[len] 字）。
    ///
    /// ⚠️ 造这种"位置可辨认"的数据时，**周期性是最容易踩的坑**，而且踩两次：
    ///   · `'内容句子。' * 140`：周期 5，而 300 是 5 的倍数 →
    ///     `body[0..400]` 与 `body[300..700]` **字面上完全相同**
    ///   · `String.fromCharCode(0x4E00 + (i % 400))`：周期 400 < 700 →
    ///     `body[650..700]` 那 50 个字**照样能在 `body[0..400]` 里找到**
    /// 两次都让"轮换看起来没生效"，而实现其实是对的。
    ///
    /// 所以这里让**每个下标对应一个独一无二的字**（不取模）。
    String varying(int len) =>
        List.generate(len, (i) => String.fromCharCode(0x4E00 + i)).join();

    test('同一片的每个窗口都会轮到（跑 N 次覆盖全部起点）', () async {
      // 700 字的片 → 候选起点 [0, 300]，整篇就这一片
      final body = varying(700);
      expect(FeedWindow.starts(body.length), [0, 300]);
      final note = await notes.createInbox(title: '单', content: body);

      final seen = <String>[];
      for (var i = 0; i < 2; i++) {
        final m = (await feed.gatherSources(source, limit: 1)).single;
        seen.add(m.chunk);
      }

      expect(seen[0], body.substring(0, 400), reason: '第一次从 0 开始');
      expect(seen[1], body.substring(300, 700), reason: '第二次轮到尾部对齐那个窗口');
      expect(seen[0], isNot(seen[1]), reason: '两个窗口的内容必须真的不同');

      // 走完一轮之后轮换位应当回到第一个起点
      expect((await db.chunksOf(note.id)).single.nextWindowStart, 0);

      // 第三次确实绕回第一个窗口
      final third = (await feed.gatherSources(source, limit: 1)).single;
      expect(third.chunk, body.substring(0, 400), reason: '环形回到开头');

      // 第三次用完之后，轮换位又推进到第二个起点
      final row = (await db.chunksOf(note.id)).single;
      expect(row.lastUsedAt, isNotNull);
      expect(row.nextWindowStart, 300);
    });

    test('★ 后半段也能出卡片（这正是轮换要解决的问题）', () async {
      final body = varying(700);
      await notes.createInbox(title: '单', content: body);

      final first = (await feed.gatherSources(source, limit: 1)).single.chunk;
      final second = (await feed.gatherSources(source, limit: 1)).single.chunk;

      // 不轮换的话永远是 [0..400)，后 300 个字**一次都不会成为素材**
      expect(first.contains(body.substring(650)), isFalse);
      expect(second.contains(body.substring(650)), isTrue,
          reason: '片尾必须能被轮到，否则那部分内容永远不会变成卡片');
    });
  });
}
