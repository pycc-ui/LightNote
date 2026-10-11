// AI 摘要的持久化、失效判断与硬性上限。
//
// 这些是本次改造里最容易做错的部分：
//   · 失效判断的**防抖**：改一个错别字就重生成 = 每次编辑都白烧 token
//   · **截断**：模型不守字数，兜底必须在写入口；且不能切断代理对
//   · **标签规整**：5 汉字 / 12 字母、去重、数量上限
//     （每篇笔记的 AI 标签表 `note_ai_tags` 已在 schema v8 删除，
//      但规整函数还服务卡片自己的标签，见 `AiPrompts.parseFeedCards`）
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/core/util/ai_limits.dart';
import 'package:lightnote/features/note/data/note_ai_asset_repository.dart';
import 'package:lightnote/features/note/data/note_repository.dart';
import 'package:drift/native.dart';

void main() {
  group('UTF-8 字节计数', () {
    test('中文按 3 字节、ASCII 按 1 字节', () {
      expect(utf8ByteLength('abc'), 3);
      expect(utf8ByteLength('中文'), 6);
      expect(utf8ByteLength('a中'), 4);
    });

    test('emoji 按 4 字节', () {
      expect(utf8ByteLength('😀'), 4);
    });

    test('空串为 0', () {
      expect(utf8ByteLength(''), 0);
    });
  });

  group('安全截断', () {
    test('不超长时原样返回，不加省略号', () {
      expect(safeTruncate('短', 10), '短');
      expect(safeTruncate('恰好十个字啊啊啊啊啊', 10), '恰好十个字啊啊啊啊啊');
    });

    test('超长时截断并加省略号', () {
      final out = safeTruncate('字' * 100, 10);
      expect(out.length, 11); // 10 字 + 省略号
      expect(out.endsWith('…'), isTrue);
    });

    test('不切断 emoji（代理对）', () {
      // 4 个 emoji，每个 2 个 UTF-16 码元。按 5 个码元截断会切开第 3 个
      final out = safeTruncate('😀😀😀😀', 5);
      // 结果里不该出现孤立的代理码元
      for (var i = 0; i < out.length; i++) {
        final c = out.codeUnitAt(i);
        final isHigh = c >= 0xD800 && c <= 0xDBFF;
        final isLow = c >= 0xDC00 && c <= 0xDFFF;
        if (isHigh) {
          // 高代理后面必须跟低代理
          expect(i + 1 < out.length, isTrue);
          final n = out.codeUnitAt(i + 1);
          expect(n >= 0xDC00 && n <= 0xDFFF, isTrue, reason: '孤立的代理码元');
          i++;
        } else {
          expect(isLow, isFalse, reason: '孤立的低代理码元');
        }
      }
    });

    test('补全被切开的 Markdown 行内标记', () {
      // 截断点落在 `**粗体` 中间 → 应当补上 ** 而不是留半个
      final out = safeTruncate('前面**粗体内容**后面', 5);
      final boldCount = '**'.allMatches(out).length;
      expect(out.endsWith('…'), isTrue);
      // 不能留下奇数个 **
      final stars = out.split('**').length - 1;
      expect(stars.isEven, isTrue, reason: '遗留未闭合的 ** 会让整段样式失效');
      expect(boldCount, greaterThan(0));
    });

    test('maxChars 为 0 或负数返回空串', () {
      expect(safeTruncate('abc', 0), '');
      expect(safeTruncate('abc', -5), '');
    });
  });

  group('标签规整', () {
    test('去掉 # 与引号等包装', () {
      expect(normalizeTag('#间隔重复'), '间隔重复');
      expect(normalizeTag('「记忆」'), '记忆');
      expect(normalizeTag('  spaced  '), 'spaced');
    });

    test('汉字超过 5 个截断', () {
      expect(normalizeTag('一二三四五六七八'), '一二三四五');
    });

    test('英文字母超过 12 个截断', () {
      expect(normalizeTag('abcdefghijklmnop'), 'abcdefghijkl');
    });

    test('中英混合各自计数', () {
      // 3 汉字 + 12 字母都还没到上限，第 13 个字母开始截
      final out = normalizeTag('中文字abcdefghijklmn');
      expect(out, '中文字abcdefghijkl');
    });

    test('sanitizeTags 去重、去空、限量 6 个', () {
      final out = sanitizeTags([
        '记忆', '记忆', '  ', '#间隔重复', '复习',
        '标签五', '标签六', '标签七', '标签八',
      ]);
      expect(out.length, lessThanOrEqualTo(AiLimits.tagCountMax));
      expect(out.toSet().length, out.length, reason: '不该有重复');
      expect(out.contains(''), isFalse);
      expect(out.first, '记忆');
    });

    test('sanitizeTags 保留少量标签（不为凑数硬塞）', () {
      final out = sanitizeTags(['只有这一个']);
      expect(out, ['只有这一个']);
    });
  });

  group('摘要的持久化与失效判断', () {
    late AppDatabase db;
    late NoteRepository notes;
    late NoteAiAssetRepository assets;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      notes = NoteRepository(db);
      assets = NoteAiAssetRepository(db);
    });

    tearDown(() => db.close());

    test('写入后能读回摘要', () async {
      final n = await notes.createInbox(title: 'T', content: '一些内容');
      await assets.putSummary(n.id, '这是摘要');

      expect(await assets.getFreshSummary(n.id), '这是摘要');
    });

    test('写入时按硬上限截断（模型不守字数）', () async {
      final n = await notes.createInbox(title: 'T', content: '内容');
      final tooLong = '字' * 800;
      await assets.putSummary(n.id, tooLong);

      final summary = (await assets.getFreshSummary(n.id))!;
      expect(summary.length, AiLimits.summaryHardMax + 1); // +1 是省略号
      expect(summary.endsWith('…'), isTrue);
    });

    test('第二次读同一篇：摘要仍在，不需要重生成', () async {
      final n = await notes.createInbox(title: 'T', content: '内容');
      await assets.putSummary(n.id, '摘要');

      // 模拟"同一篇笔记被抽中两次"
      final first = await assets.getFreshSummary(n.id);
      final second = await assets.getFreshSummary(n.id);
      expect(first, '摘要');
      expect(second, '摘要', reason: '第二次应当走已有的，不再调 AI');
    });

    test('内容小幅修改（<20%）不算过期——防抖', () async {
      final n = await notes.createInbox(title: 'T', content: '字' * 1000);
      await assets.putSummary(n.id, '摘要');

      // 改 10 个字 = 1%，远低于 20%
      await notes.saveContent(n.id, title: 'T', content: '字' * 1010);

      expect(await assets.getFreshSummary(n.id), '摘要',
          reason: '改错别字不该让摘要作废，否则每次编辑都白烧 token');
    });

    test('内容大幅修改（>20%）算过期', () async {
      final n = await notes.createInbox(title: 'T', content: '字' * 1000);
      await assets.putSummary(n.id, '摘要');

      // 改 300 个字 = 30%
      await notes.saveContent(n.id, title: 'T', content: '字' * 1300);

      expect(await assets.getFreshSummary(n.id), isNull,
          reason: '内容变了三成，摘要该重新生成');
    });

    test('恰好 20% 不算过期（边界是"超过"）', () async {
      final n = await notes.createInbox(title: 'T', content: '字' * 1000);
      await assets.putSummary(n.id, '摘要');
      await notes.saveContent(n.id, title: 'T', content: '字' * 1200);

      expect(await assets.getFreshSummary(n.id), '摘要');
    });

    test('笔记被删除后摘要失效', () async {
      final n = await notes.createInbox(title: 'T', content: '内容');
      await assets.putSummary(n.id, '摘要');
      await notes.softDelete(n.id);

      // 逻辑删除只是标记，笔记行还在，所以摘要仍读得到——
      // 这是有意的：撤销删除后摘要还能用。
      expect(await assets.getFreshSummary(n.id), '摘要');
    });

    test('批量读只返回新鲜的', () async {
      final fresh = await notes.createInbox(title: 'A', content: '字' * 500);
      final stale = await notes.createInbox(title: 'B', content: '字' * 500);
      final none = await notes.createInbox(title: 'C', content: '字' * 500);

      await assets.putSummary(fresh.id, '新鲜');
      await assets.putSummary(stale.id, '会过期');
      // none 不写摘要

      await notes.saveContent(stale.id, title: 'B', content: '字' * 900);

      final map = await assets.freshSummaries([fresh.id, stale.id, none.id]);
      expect(map[fresh.id], '新鲜');
      expect(map.containsKey(stale.id), isFalse, reason: '过期的不该出现');
      expect(map.containsKey(none.id), isFalse, reason: '没有的不该出现');
    });

    test('覆盖写入：新摘要替换旧的', () async {
      final n = await notes.createInbox(title: 'T', content: '内容');
      await assets.putSummary(n.id, '第一版');
      await assets.putSummary(n.id, '第二版');

      expect(await assets.getFreshSummary(n.id), '第二版');
      // 确认只有一行（主键是 noteId）
      final rows = await db.select(db.aiNoteSummaries).get();
      expect(rows.length, 1);
    });

    test('笔记删除时摘要跟着 CASCADE', () async {
      final n = await notes.createInbox(title: 'T', content: '内容');
      await assets.putSummary(n.id, '摘要');

      // 物理删除才触发 CASCADE（逻辑删除不触发）
      await db.customStatement('DELETE FROM notes WHERE id = ?', [n.id]);

      expect(await assets.getFreshSummary(n.id), isNull);
      expect(await db.select(db.aiNoteSummaries).get(), isEmpty);
    });
  });
}
