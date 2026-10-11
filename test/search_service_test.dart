// 统一搜索（`SearchService`）。
//
// 这一层的要害是"**不存正文也能定位到片**"：结果必须带得出片号与标题路径，
// 搜索页才谈得上"点进去定位到那一段"，AI 才谈得上"接着只读那一小片"。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_notes/core/db/app_database.dart';
import 'package:smart_notes/features/note/data/notebook_repository.dart';
import 'package:smart_notes/features/note/data/note_repository.dart';
import 'package:smart_notes/features/note/data/search_service.dart';
import 'package:smart_notes/features/note/domain/note_chunk.dart';
import 'package:smart_notes/features/note/domain/note_chunker.dart';

void main() {
  group('纯函数：找命中位置', () {
    test('找出全部命中，且不重叠', () {
      expect(SearchService.findHits('abcabc', 'abc'), [0, 3]);
      // 不重叠：`aaaa` 里找 `aa` 只有 0 和 2，不是 0/1/2
      expect(SearchService.findHits('aaaa', 'aa'), [0, 2]);
    });

    test('中文 2 字词能命中（这是 LIKE 相对 FTS5 的关键优势）', () {
      // 间(0)隔(1)重(2)复(3)是(4)记(5)忆(6)的(7)好(8)朋(9)友(10)
      const text = '间隔重复是记忆的好朋友';
      expect(SearchService.findHits(text, '记忆'), [5]);
      expect(SearchService.findHits(text, '间隔'), [0]);
      expect(SearchService.findHits(text, '朋友'), [9]);
    });

    test('ASCII 大小写不敏感 —— 与 SQLite 的 LIKE 行为一致', () {
      // 数据库说命中了、这里却找不到位置的话，摘要就永远算不出来
      expect(SearchService.findHits('用 Provider 管理状态', 'provider'), [2]);
      expect(SearchService.findHits('用 provider 管理状态', 'PROVIDER'), [2]);
    });

    test('找不到 / 空输入 → 空列表', () {
      expect(SearchService.findHits('abc', 'zzz'), isEmpty);
      expect(SearchService.findHits('', 'a'), isEmpty);
      expect(SearchService.findHits('abc', ''), isEmpty);
      expect(SearchService.findHits('ab', 'abc'), isEmpty);
    });

    test('特殊字符按字面处理（不是正则）', () {
      expect(SearchService.findHits('100% 完成', '100%'), [0]);
      expect(SearchService.findHits('a.b.c', '.'), [1, 3]);
      expect(SearchService.findHits('a(b', '('), [1]);
    });
  });

  group('纯函数：命中位置映射到片', () {
    const chunks = [
      NoteChunk(index: 0, heading: 'A', level: 1, start: 0, end: 100, contentHash: 0),
      NoteChunk(index: 1, heading: 'B', level: 1, start: 102, end: 200, contentHash: 0),
    ];

    test('落在片内 → 那一片', () {
      expect(SearchService.chunkIndexAt(chunks, 0), 0);
      expect(SearchService.chunkIndexAt(chunks, 99), 0);
      expect(SearchService.chunkIndexAt(chunks, 102), 1);
      expect(SearchService.chunkIndexAt(chunks, 199), 1);
    });

    test('落在两片之间的空白里 → **前一片**', () {
      // 用户点进来是想看命中那段的上下文，给前一片比装作"标题命中"更贴近意图
      expect(SearchService.chunkIndexAt(chunks, 100), 0);
      expect(SearchService.chunkIndexAt(chunks, 101), 0);
    });

    test('在首片之前 / 完全越界 → 收敛到 0', () {
      expect(SearchService.chunkIndexAt(chunks, 250), 1, reason: '越界给最后一片');
      expect(SearchService.chunkIndexAt(chunks, -5), 0);
    });
  });

  group('纯函数：摘要', () {
    test('前后各留 40 字，两端截断处加省略号', () {
      final text = '${'前' * 60}关键词${'后' * 60}';
      final s = SearchService.snippetOf(text, 60, 3);
      expect(s.startsWith('…'), isTrue);
      expect(s.endsWith('…'), isTrue);
      expect(s, contains('关键词'));
      // 40 + 3 + 40 的字，加上两个省略号
      expect(s.length, 40 + 3 + 40 + 2);
    });

    test('命中在开头 → 不加前省略号', () {
      final text = '关键词${'后' * 100}';
      final s = SearchService.snippetOf(text, 0, 3);
      expect(s.startsWith('…'), isFalse);
      expect(s.startsWith('关键词'), isTrue);
      expect(s.endsWith('…'), isTrue);
    });

    test('短正文不加省略号', () {
      expect(SearchService.snippetOf('就这一句关键词。', 5, 3), '就这一句关键词。');
    });

    test('换行压成空格（摘要只占一行，否则列表高度会跳）', () {
      final s = SearchService.snippetOf('第一行\n\n第二行关键词\n第三行', 10, 3);
      expect(s.contains('\n'), isFalse);
      expect(s, contains('关键词'));
    });
  });

  group('集成：两类结果', () {
    late AppDatabase db;
    late NoteRepository notes;
    late SearchService search;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      notes = NoteRepository(db);
      search = SearchService(db);
    });
    tearDown(() => db.close());

    /// 两章，每章够长能成一片，各自埋一个独特词
    String twoChapters() => '# 甲章\n\n${'甲的内容。' * 90}\n\n'
        '这里提到间隔重复。\n\n'
        '# 乙章\n\n${'乙的内容。' * 90}\n\n'
        '这里提到番茄工作法。';

    test('标题命中 → chunkIndex 为空、得分 3', () async {
      await notes.createInbox(title: '间隔重复笔记', content: '与标题无关的正文。');

      final r = await search.search('间隔');
      final hit = r.single;
      expect(hit.isTitleHit, isTrue);
      expect(hit.chunkIndex, isNull);
      expect(hit.score, SearchService.titleScore);
      expect(hit.title, '间隔重复笔记');
    });

    test('正文命中 → 带片号与标题路径、得分 2', () async {
      await notes.createInbox(title: '我的笔记', content: twoChapters());

      final r = await search.search('间隔重复');
      final hit = r.single;
      expect(hit.isTitleHit, isFalse);
      expect(hit.chunkIndex, 0);
      expect(hit.heading, '甲章', reason: '要能告诉用户命中在哪一节');
      expect(hit.score, SearchService.chunkScore);
      expect(hit.snippet, contains('间隔重复'));
    });

    test('命中的片号**真的对得上正文**（拿片正文验证，不信下标）', () async {
      final note = await notes.createInbox(title: '我的笔记', content: twoChapters());
      final r = await search.search('番茄工作法');
      final hit = r.single;

      final chunks = NoteChunker.chunk(note.content);
      final text = chunks[hit.chunkIndex!].textOf(note.content);
      expect(text, contains('番茄工作法'));
      expect(hit.heading, '乙章');
    });

    test('同一片里命中多次 → 合成一条、得分累加', () async {
      final body = '# 章\n\n${'间隔重复。' * 30}\n\n间隔重复。';
      await notes.createInbox(title: 'N', content: body);

      final r = await search.search('间隔重复');
      final hit = r.single;
      expect(hit.score, greaterThan(SearchService.chunkScore));
    });

    test('不同片命中 → 分成多条', () async {
      final body = '# 甲章\n\n${'甲。' * 300}\n\n关键词在这。\n\n'
          '# 乙章\n\n${'乙。' * 300}\n\n关键词也在这。';
      await notes.createInbox(title: 'N', content: body);

      final r = await search.search('关键词');
      expect(r.length, greaterThanOrEqualTo(2));
      final idxs = r.map((x) => x.chunkIndex).toSet();
      expect(idxs.length, greaterThanOrEqualTo(2), reason: '两条要在不同的片');
    });

    test('一篇笔记同时命中标题和正文 → 两类各一条', () async {
      await notes.createInbox(title: '间隔重复', content: twoChapters());

      final r = await search.search('间隔重复');
      expect(r.where((x) => x.isTitleHit), hasLength(1));
      expect(r.where((x) => !x.isTitleHit), hasLength(1));
    });

    test('排序：标题命中（3）排在片命中（2）前面', () async {
      await notes.createInbox(title: '别的标题', content: twoChapters());
      await notes.createInbox(title: '间隔重复', content: '无关正文。');

      final r = await search.search('间隔重复');
      expect(r.first.isTitleHit, isTrue);
    });

    test('2 字中文能命中（FTS5 unicode61/trigram 做不到的那个长度）', () async {
      await notes.createInbox(title: 'N', content: twoChapters());
      expect(await search.search('记忆'), isEmpty, reason: '这篇里没有"记忆"');
      final r = await search.search('间隔');
      expect(r, isNotEmpty);
      // `间隔` 同时出现在 "间隔重复" 里
      expect(r.first.snippet, contains('间隔'));
    });

    test('搜不到 → 空列表，不报错', () async {
      await notes.createInbox(title: 'N', content: '平平无奇的正文。');
      expect(await search.search('绝不存在的词'), isEmpty);
    });

    test('空查询 / 纯空白 → 空列表', () async {
      await notes.createInbox(title: 'N', content: '正文。');
      expect(await search.search(''), isEmpty);
      expect(await search.search('   '), isEmpty);
    });

    test('软删的笔记搜不到', () async {
      final n = await notes.createInbox(title: '间隔重复', content: twoChapters());
      await notes.softDelete(n.id);
      expect(await search.search('间隔重复'), isEmpty);
    });

    test('限定笔记库：库外的不返回', () async {
      final nb = await NotebookRepository(db).create(name: '工作');
      await notes.createInNotebook(nb.id, title: '库内', content: twoChapters());
      await notes.createInbox(title: '库外', content: twoChapters());

      final inside = await search.search('间隔重复', notebookIds: [nb.id], includeUnfiled: false);
      expect(inside, isNotEmpty);
      for (final r in inside) {
        expect(r.title, '库内');
      }
    });

    test('limit 生效，且默认 20', () async {
      for (var i = 0; i < 30; i++) {
        await notes.createInbox(title: '关键词$i', content: '正文。');
      }
      expect((await search.search('关键词')).length, SearchService.defaultLimit);
      expect((await search.search('关键词', limit: 5)).length, 5);
    });

    test('`%` 和 `_` 按字面搜（LIKE 通配符要转义）', () async {
      await notes.createInbox(title: '进度', content: '目前 100% 完成。');
      await notes.createInbox(title: '干扰', content: '完全无关的内容。');

      final r = await search.search('100%');
      expect(r, isNotEmpty);
      expect(r.every((x) => x.title == '进度'), isTrue);

      // 单独搜 `%`：**应该**只命中正文里真有 `%` 的那篇。
      // 不转义的话 `%` 会变成"匹配任意串"，两篇都会命中 —— 那才是 bug。
      final pct = await search.search('%');
      expect(pct, isNotEmpty, reason: '正文里确实有 `%`，应当命中');
      expect(pct.every((x) => x.title == '进度'), isTrue,
          reason: '`%` 不转义就会把「干扰」也匹上');
    });

    test('结果可复现：同样的查询两次得到同样的顺序', () async {
      for (var i = 0; i < 5; i++) {
        await notes.createInbox(title: '同名', content: '关键词。');
      }
      final a = await search.search('关键词');
      final b = await search.search('关键词');
      expect(a.map((x) => x.noteId).toList(), b.map((x) => x.noteId).toList());
    });
  });
}
