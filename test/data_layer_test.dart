import 'dart:convert';

// drift 导出的 isNull / isNotNull 与 flutter_test 的 matcher 同名，会报
// ambiguous_import。这里从 drift 侧隐藏它们，测试里统一用 matcher 的语义。
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_notes/core/db/app_database.dart';
import 'package:smart_notes/core/db/models.dart';
import 'package:smart_notes/core/util/text_utils.dart';
import 'package:smart_notes/features/ai/domain/prompts.dart';
import 'package:smart_notes/features/cards/domain/card_repository.dart';
import 'package:smart_notes/features/cards/domain/review_scheduler.dart';
import 'package:smart_notes/features/folders/data/folder_repository.dart';
import 'package:smart_notes/features/notes/data/note_repository.dart';
import 'package:smart_notes/services/markdown_export_service.dart';
import 'package:smart_notes/services/preferences_service.dart';

void main() {
  group('TextUtils', () {
    test('中英混排字数：中文按字、英文按词', () {
      expect(TextUtils.wordCount('你好世界'), 4);
      expect(TextUtils.wordCount('hello world'), 2);
      expect(TextUtils.wordCount('你好 hello'), 3);
    });

    test('excerpt 剥掉 Markdown 噪声', () {
      final e = TextUtils.excerpt('# 标题\n\n这是**正文**内容。');
      expect(e.contains('#'), isFalse);
      expect(e.contains('*'), isFalse);
      expect(e.contains('正文'), isTrue);
    });
  });

  group('JSON 数组往返（存库 → 阅读页解析）', () {
    test('含引号、反斜杠、换行的要点能正确往返', () {
      final items = [
        '他说"这样不行"',
        r'路径 C:\Users\test',
        '第一行\n第二行',
      ];
      expect(parseJsonStringList(jsonEncode(items)), items);
    });

    test('落库内容被截断成非法 JSON 时降级按分隔符切分', () {
      expect(parseJsonStringList('["正常项", "被截断'), ['正常项', '被截断']);
    });

    test('null / 空串返回空列表', () {
      expect(parseJsonStringList(null), isEmpty);
      expect(parseJsonStringList('   '), isEmpty);
    });
  });

  group('AiPrompts.extractJson 三级降级', () {
    test('直接合法 JSON', () {
      expect(AiPrompts.extractJson('{"one_line":"测试"}')?['one_line'], '测试');
    });

    test('被代码块围栏包裹', () {
      expect(
        AiPrompts.extractJson('```json\n{"one_line":"测试"}\n```')?['one_line'],
        '测试',
      );
    });

    test('前后有解释性文字', () {
      final r = AiPrompts.extractJson('好的：\n{"one_line":"测试"}\n完毕。');
      expect(r?['one_line'], '测试');
    });

    test('字符串值含花括号时不截断错位', () {
      expect(
        AiPrompts.extractJson('{"one_line":"含 } 的文本"}')?['one_line'],
        '含 } 的文本',
      );
    });

    test('完全无法解析返回 null', () {
      expect(AiPrompts.extractJson('不是 JSON'), isNull);
    });
  });

  group('AiPrompts.agentUser 隐私行为', () {
    test('未选择任何笔记时不拼接笔记正文', () {
      final prompt = AiPrompts.agentUser('帮我写个标题', const []);
      expect(prompt.contains('帮我写个标题'), isTrue);
      expect(prompt.contains('未选择任何笔记文件'), isTrue);
    });

    test('选中笔记时才拼接内容', () {
      final prompt = AiPrompts.agentUser('总结一下', ['《笔记A》\n正文内容']);
      expect(prompt.contains('正文内容'), isTrue);
      expect(prompt.contains('共 1 条'), isTrue);
    });
  });

  group('HighlightUtils', () {
    test('大小写不敏感地切分并标记命中片段', () {
      final parts = HighlightUtils.split('Hello Flutter World', 'flutter');
      expect(parts.length, 3);
      expect(parts[0], ('Hello ', false));
      expect(parts[1], ('Flutter', true));
      expect(parts[2], (' World', false));
    });

    test('无命中时返回整段', () {
      final parts = HighlightUtils.split('abc', 'xyz');
      expect(parts, [('abc', false)]);
    });

    test('无关键词时返回整段', () {
      expect(HighlightUtils.split('abc', '  '), [('abc', false)]);
    });

    test('snippet 截取关键词附近上下文', () {
      final content = '${'前' * 100}关键词${'后' * 100}';
      final s = HighlightUtils.snippet(content, '关键词', radius: 10);
      expect(s.contains('关键词'), isTrue);
      expect(s.startsWith('…'), isTrue);
      expect(s.endsWith('…'), isTrue);
    });
  });

  group('ReviewScheduler（SM-2）', () {
    const scheduler = ReviewScheduler();
    final base = DateTime.utc(2026, 3, 1, 10);

    test('第一次答对：间隔 1 天，EF 不变', () {
      final r = scheduler.schedule(
        grade: ReviewGrade.good,
        ease: 2.5,
        intervalDays: 0,
        repetitions: 0,
        lapses: 0,
        now: base,
      );
      expect(r.intervalDays, 1);
      expect(r.repetitions, 1);
      expect(r.ease, closeTo(2.5, 0.0001));
    });

    test('第二次答对固定 6 天', () {
      final r = scheduler.schedule(
        grade: ReviewGrade.good,
        ease: 2.5,
        intervalDays: 1,
        repetitions: 1,
        lapses: 0,
        now: base,
      );
      expect(r.intervalDays, 6);
    });

    test('第三次起按 EF 增长：6 × 2.5 = 15', () {
      final r = scheduler.schedule(
        grade: ReviewGrade.good,
        ease: 2.5,
        intervalDays: 6,
        repetitions: 2,
        lapses: 0,
        now: base,
      );
      expect(r.intervalDays, 15);
    });

    test('忘记了：重置为 1 天、reps 归零、lapses +1、EF 下调', () {
      final r = scheduler.schedule(
        grade: ReviewGrade.forgot,
        ease: 2.5,
        intervalDays: 30,
        repetitions: 5,
        lapses: 2,
        now: base,
      );
      expect(r.intervalDays, 1);
      expect(r.repetitions, 0);
      expect(r.lapses, 3);
      expect(r.ease, closeTo(1.96, 0.0001));
    });

    test('EF 被钳制在 [1.3, 2.8]', () {
      var low = 1.35;
      var high = 2.75;
      for (var i = 0; i < 10; i++) {
        low = scheduler
            .schedule(
              grade: ReviewGrade.forgot,
              ease: low,
              intervalDays: 1,
              repetitions: 0,
              lapses: 0,
              now: base,
            )
            .ease;
        high = scheduler
            .schedule(
              grade: ReviewGrade.easy,
              ease: high,
              intervalDays: 1,
              repetitions: 1,
              lapses: 0,
              now: base,
            )
            .ease;
      }
      expect(low, closeTo(ReviewGrade.minEase, 0.0001));
      expect(high, closeTo(ReviewGrade.maxEase, 0.0001));
    });

    test('到期时间是「当前时刻 + 间隔」而非当天零点', () {
      final now = DateTime.utc(2026, 3, 1, 23, 30);
      final r = scheduler.schedule(
        grade: ReviewGrade.good,
        ease: 2.5,
        intervalDays: 6,
        repetitions: 2,
        lapses: 0,
        now: now,
      );
      expect(r.dueAt.hour, 23);
      expect(r.dueAt.difference(now).inDays, r.intervalDays);
    });
  });

  // ==========================================================================
  // 数据层集成测试（内存 SQLite，不依赖设备）
  // ==========================================================================

  group('数据层', () {
    late AppDatabase db;
    late NoteRepository notes;
    late FolderRepository folders;
    late CardRepository cards;
    late PreferencesService prefs;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      notes = NoteRepository(db);
      folders = FolderRepository(db);
      cards = CardRepository(db);
      prefs = PreferencesService(db);
    });

    tearDown(() async => db.close());

    // ---- 轻笔记 / 笔记库 ----

    test('新建轻笔记进收件箱，新建目录笔记进笔记库', () async {
      final quick = await notes.createInbox(title: '速记', content: '随手记');
      expect(quick.isInbox, isTrue);
      expect(quick.folderId, isNull);

      final folder = await folders.create(name: '工作笔记');
      final formal =
          await notes.createInFolder(folder.id, title: '正式', content: '内容');
      expect(formal.isInbox, isFalse);
      expect(formal.folderId, folder.id);

      expect((await notes.watchInbox().first).map((n) => n.id), [quick.id]);
      expect((await notes.watchLibrary().first).map((n) => n.id), [formal.id]);
    });

    test('加入笔记库：isInbox 变 false 且归属目录', () async {
      final note = await notes.createInbox(content: '待归档');
      final folder = await folders.create(name: '灵感收集');

      await notes.moveToFolder(note.id, folder.id);

      final updated = (await notes.byId(note.id))!;
      expect(updated.isInbox, isFalse);
      expect(updated.folderId, folder.id);
      expect((await notes.watchInbox().first), isEmpty);
      expect((await notes.watchInFolder(folder.id).first).length, 1);
    });

    test('移回轻笔记：folderId 清空且 isInbox 恢复', () async {
      final folder = await folders.create(name: 'X');
      final note = await notes.createInFolder(folder.id, content: 'c');

      await notes.moveToInbox(note.id);

      final updated = (await notes.byId(note.id))!;
      expect(updated.isInbox, isTrue);
      expect(updated.folderId, isNull);
    });

    test('保存正文同步更新 excerpt 与 wordCount', () async {
      final note = await notes.createInbox(content: '旧');
      await notes.saveContent(note.id, content: '# 新标题\n\n新内容更长一些');

      final updated = (await notes.byId(note.id))!;
      expect(updated.excerpt.contains('#'), isFalse);
      expect(updated.excerpt.contains('新内容'), isTrue);
      expect(updated.wordCount, greaterThan(0));
    });

    test('逻辑删除后不出现在任何列表，但数据仍在', () async {
      final note = await notes.createInbox(content: '待删除');
      await notes.softDelete(note.id);

      expect(await notes.watchInbox().first, isEmpty);
      expect(await notes.watchLibrary().first, isEmpty);
      final raw = await notes.byId(note.id);
      expect(raw, isNotNull);
      expect(raw!.deletedAt, isNotNull);
    });

    // ---- 目录 ----

    test('删除目录不删笔记，笔记回到轻笔记', () async {
      final folder = await folders.create(name: '临时目录');
      final a = await notes.createInFolder(folder.id, content: 'A');
      final b = await notes.createInFolder(folder.id, content: 'B');

      await folders.softDelete(folder.id);

      // 目录消失
      expect((await folders.all()).any((f) => f.id == folder.id), isFalse);
      // 笔记还在，且回到收件箱
      final a2 = (await notes.byId(a.id))!;
      final b2 = (await notes.byId(b.id))!;
      expect(a2.deletedAt, isNull);
      expect(b2.deletedAt, isNull);
      expect(a2.isInbox, isTrue);
      expect(a2.folderId, isNull);
      expect((await notes.watchInbox().first).length, 2);
    });

    test('删除父目录时子目录上浮为顶层', () async {
      final parent = await folders.create(name: '父');
      final child = await folders.create(name: '子', parentId: parent.id);

      await folders.softDelete(parent.id);

      final childAfter = (await folders.byId(child.id))!;
      expect(childAfter.parentId, isNull);
      expect(childAfter.deletedAt, isNull);
    });

    test('重命名目录会 trim 空白', () async {
      final f = await folders.create(name: '原名');
      await folders.rename(f.id, '  新名  ');
      expect((await folders.byId(f.id))!.name, '新名');
    });

    test('buildTree 正确组层级并计算深度', () async {
      final root = await folders.create(name: '根');
      final child = await folders.create(name: '子', parentId: root.id);
      await folders.create(name: '孙', parentId: child.id);

      final all = await folders.all();
      final tree = FolderRepository.buildTree(all, const {});
      expect(tree.length, 1);
      expect(tree.first.depth, 0);
      expect(tree.first.children.length, 1);
      expect(tree.first.children.first.depth, 1);
      expect(tree.first.children.first.children.first.depth, 2);
    });

    // ---- 搜索 ----

    test('搜索命中标题与正文', () async {
      await notes.createLibrary(title: 'Flutter 学习', content: '无关内容');
      await notes.createLibrary(title: '无关', content: '正文里有 Flutter');
      await notes.createLibrary(title: '无关', content: '什么都搜不到');

      final hit = await notes.search('Flutter').first;
      expect(hit.length, 2);
    });

    test('搜索关键词里的 % 与 _ 被当字面量而非通配符', () async {
      await notes.createLibrary(title: '完成度 100%', content: 'a');
      await notes.createLibrary(title: '完全无关', content: 'b');

      // 若不转义，"100%" 会因为 % 通配而匹配到别的记录
      final hit = await notes.search('100%').first;
      expect(hit.length, 1);
      expect(hit.first.title.contains('100%'), isTrue);

      final underscore = await notes.search('a_b').first;
      expect(underscore, isEmpty);
    });

    test('搜索已删除笔记不会返回', () async {
      final n = await notes.createLibrary(title: '唯一关键词', content: 'x');
      await notes.softDelete(n.id);
      expect(await notes.search('唯一关键词').first, isEmpty);
    });

    // ---- 标签 ----

    test('标签复用：大小写与空格归一化后不重复创建', () async {
      final id1 = await db.ensureTag('t1', 'Flutter');
      final id2 = await db.ensureTag('t2', '  flutter  ');
      expect(id1, id2);
      expect((await db.watchTags().first).length, 1);
    });

    test('重复关联同一标签不重复增加 usageCount', () async {
      final note = await notes.createLibrary(content: 'c');
      await notes.addTag(note.id, '测试');
      await notes.addTag(note.id, '测试');

      final tags = await db.watchTags().first;
      expect(tags.length, 1);
      expect(tags.first.usageCount, 1);
    });

    // ---- 卡片 ----

    test('复习一次同时写入卡片状态与流水', () async {
      final note = await notes.createLibrary(content: 'c');
      await cards.createCard(question: 'Q', answer: 'A', noteId: note.id);
      final card = (await cards.cardsOfNote(note.id)).first;

      await cards.review(
        card: card,
        grade: ReviewGrade.good,
        elapsedMs: 1500,
      );

      final after = (await cards.cardsOfNote(note.id)).first;
      expect(after.repetitions, 1);
      expect(after.reviewCount, 1);
      expect(after.intervalDays, 1);

      final reviews = await db.select(db.reviews).get();
      expect(reviews.length, 1);
      expect(reviews.first.quality, ReviewGrade.good.quality);
      expect(reviews.first.easeBefore, 2.5);
    });

    test('今日待复习：新卡受上限约束，未到期的不进队列', () async {
      final note = await notes.createLibrary(content: 'c');
      for (var i = 0; i < 20; i++) {
        await cards.createCard(question: 'Q$i', answer: 'A$i', noteId: note.id);
      }
      final due = await db.watchDueCards(newCardLimit: 5).first;
      expect(due.length, 5);
      expect(due.map((c) => c.question).toList(),
          ['Q0', 'Q1', 'Q2', 'Q3', 'Q4']);
    });

    test('暂停的卡片不进复习队列', () async {
      final note = await notes.createLibrary(content: 'c');
      final id =
          await cards.createCard(question: 'Q', answer: 'A', noteId: note.id);
      await cards.setSuspended(id, true);
      expect(await db.watchDueCards().first, isEmpty);
    });

    // ---- 会话与设置 ----

    test('AI 会话与消息：删除会话级联删除消息', () async {
      final now = DateTime.now().toUtc();
      await db.upsertConversation(AiConversationsCompanion.insert(
        id: 'conv-1',
        title: const Value('会话'),
        createdAt: now,
        updatedAt: now,
      ));
      await db.insertAiMessage(AiMessagesCompanion.insert(
        id: 'msg-1',
        conversationId: 'conv-1',
        role: 'user',
        content: const Value('你好'),
        createdAt: now,
      ));

      expect((await db.watchMessages('conv-1').first).length, 1);
      await db.deleteConversation('conv-1');
      // 外键 ON DELETE CASCADE 生效需要 PRAGMA foreign_keys=ON，
      // beforeOpen 里已开启
      expect(await db.watchMessages('conv-1').first, isEmpty);
    });

    test('settings 表读写与覆盖', () async {
      expect(await db.readSetting('k'), isNull);
      await db.writeSetting('k', 'v1');
      expect(await db.readSetting('k'), 'v1');
      await db.writeSetting('k', 'v2');
      expect(await db.readSetting('k'), 'v2');
      await db.deleteSetting('k');
      expect(await db.readSetting('k'), isNull);
    });

    test('搜索历史：去重置顶、超上限截断', () async {
      await prefs.pushSearchHistory('flutter');
      await prefs.pushSearchHistory('笔记');
      await prefs.pushSearchHistory('flutter'); // 重复应置顶且不重复

      final h = await prefs.readSearchHistory();
      expect(h, ['flutter', '笔记']);

      for (var i = 0; i < PreferencesService.maxSearchHistory + 5; i++) {
        await prefs.pushSearchHistory('k$i');
      }
      expect(
        (await prefs.readSearchHistory()).length,
        PreferencesService.maxSearchHistory,
      );
    });

    test('搜索历史为空时不抛异常', () async {
      expect(await prefs.readSearchHistory(), isEmpty);
      await prefs.clearSearchHistory();
      expect(await prefs.readSearchHistory(), isEmpty);
    });

    test('一次性任务幂等标记', () async {
      expect(await prefs.isSeeded('x'), isFalse);
      await prefs.markSeeded('x');
      expect(await prefs.isSeeded('x'), isTrue);
    });

    test('清空 AI 历史不影响笔记/目录/卡片', () async {
      final f = await folders.create(name: '目录');
      final n = await notes.createInFolder(f.id, content: 'c');
      await cards.createCard(question: 'Q', answer: 'A', noteId: n.id);
      await db.insertSummary(NoteSummariesCompanion.insert(
        id: 's1',
        noteId: n.id,
        model: 'deepseek-flash',
        oneLine: const Value('摘要'),
        createdAt: DateTime.now().toUtc(),
      ));

      await db.clearAiHistory();

      expect(await db.select(db.noteSummaries).get(), isEmpty);
      expect((await db.select(db.notes).get()).length, 1);
      expect((await db.select(db.folders).get()).length, 1);
      expect((await db.select(db.cards).get()).length, 1);
    });
  });

  group('MarkdownExportService', () {
    test('renderSingle 含标题、元信息与正文', () {
      final note = Note(
        id: 'n1',
        title: '我的标题',
        content: '正文 **加粗**',
        excerpt: '',
        source: 'local',
        isInbox: true,
        pinned: false,
        readingProgress: 0,
        readingSeconds: 0,
        wordCount: 10,
        lastAiAt: null,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 2),
        deletedAt: null,
        folderId: null,
      );

      final md = MarkdownExportService.renderSingle(note, tags: ['Flutter']);
      expect(md.contains('# 我的标题'), isTrue);
      expect(md.contains('正文 **加粗**'), isTrue);
      expect(md.contains('#Flutter'), isTrue);
    });

    test('buildCopyText：无标题时只返回正文', () {
      // 用函数声明而不是闭包赋值：Dart 会警告
      // prefer_function_declarations_over_variables。
      Note mk(String t) => Note(
            id: 'n',
            title: t,
            content: '正文',
            excerpt: '',
            source: 'local',
            isInbox: true,
            pinned: false,
            readingProgress: 0,
            readingSeconds: 0,
            wordCount: 2,
            lastAiAt: null,
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
            deletedAt: null,
            folderId: null,
          );
      expect(MarkdownExportService.buildCopyText(mk('')), '正文');
      expect(MarkdownExportService.buildCopyText(mk('T')), 'T\n\n正文');
    });
  });
}
