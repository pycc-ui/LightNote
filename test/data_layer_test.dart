import 'dart:convert';

// drift 导出的 isNull / isNotNull 与 flutter_test 的 matcher 同名，会报
// ambiguous_import。这里从 drift 侧隐藏它们，测试里统一用 matcher 的语义。
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/core/db/models.dart';
import 'package:lightnote/core/util/ai_limits.dart';
import 'package:lightnote/core/util/text_utils.dart';
import 'package:lightnote/features/ai/domain/prompts.dart';
import 'package:lightnote/features/note/data/notebook_repository.dart';
import 'package:lightnote/features/note/data/note_repository.dart';
import 'package:lightnote/core/prefs/preferences_service.dart';

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

  group('AiPrompts.parseFeedCards 的长度兜底', () {
    // 提示词要求"标题 ≤30 字、正文 400–800 字"，但**模型的自我约束不算约束**：
    // 实测会返回几千字的正文，而卡片正文会被收进笔记、也会进 prompt。
    // （卡片字段上限的完整清单见《软件理念设计》第 3 节。）

    test('标题/正文超长各自截断，标签照常规整', () {
      final raw = jsonEncode({
        'cards': [
          {'title': '标' * 200, 'body': '正' * 5000, 'tag': '#记忆'},
        ],
      });

      final card = AiPrompts.parseFeedCard(raw);

      // `safeTruncate` 截到上限并补省略号（"被截了"的可见标记）
      expect(card!.title, '${'标' * AiLimits.feedCardTitleMax}…');
      expect(card.body, '${'正' * AiLimits.feedCardBodyMax}…');
      expect(card.tag, '记忆', reason: '标签仍然剥掉 # 号');
    });

    test('没超长的原样通过（别把正常卡片也改了）', () {
      final raw = jsonEncode({
        'cards': [
          {'title': '抄书是最没用的努力', 'body': '正文内容。', 'tag': '笔记法'},
        ],
      });

      final card = AiPrompts.parseFeedCard(raw);
      expect(card!.title, '抄书是最没用的努力');
      expect(card.body, '正文内容。');
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
  // ==========================================================================
  // 数据层集成测试（内存 SQLite，不依赖设备）
  // ==========================================================================

  group('数据层', () {
    late AppDatabase db;
    late NoteRepository notes;
    late NotebookRepository notebooks;
    late PreferencesService prefs;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      notes = NoteRepository(db);
      notebooks = NotebookRepository(db);
      prefs = PreferencesService(db);
    });

    tearDown(() async => db.close());

    // ---- 轻笔记 / 笔记库 ----

    test('新建轻笔记进收件箱，新建目录笔记进笔记库', () async {
      final quick = await notes.createInbox(title: '速记', content: '随手记');
      expect(quick.isInbox, isTrue);
      expect(quick.notebookId, isNull);

      final folder = await notebooks.create(name: '工作笔记');
      final formal =
          await notes.createInNotebook(folder.id, title: '正式', content: '内容');
      expect(formal.isInbox, isFalse);
      expect(formal.notebookId, folder.id);

      expect((await notes.watchInbox().first).map((n) => n.id), [quick.id]);
      expect((await notes.watchLibrary().first).map((n) => n.id), [formal.id]);
    });

    test('加入笔记库：isInbox 变 false 且归属目录', () async {
      final note = await notes.createInbox(content: '待归档');
      final folder = await notebooks.create(name: '灵感收集');

      await notes.moveToNotebook(note.id, folder.id);

      final updated = (await notes.byId(note.id))!;
      expect(updated.isInbox, isFalse);
      expect(updated.notebookId, folder.id);
      expect((await notes.watchInbox().first), isEmpty);
      expect((await notes.watchNotesInNotebook(folder.id).first).length, 1);
    });

    test('移回轻笔记：notebookId 清空且 isInbox 恢复', () async {
      final folder = await notebooks.create(name: 'X');
      final note = await notes.createInNotebook(folder.id, content: 'c');

      await notes.moveToInbox(note.id);

      final updated = (await notes.byId(note.id))!;
      expect(updated.isInbox, isTrue);
      expect(updated.notebookId, isNull);
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
      final folder = await notebooks.create(name: '临时目录');
      final a = await notes.createInNotebook(folder.id, content: 'A');
      final b = await notes.createInNotebook(folder.id, content: 'B');

      await notebooks.softDelete(folder.id);

      // 目录消失
      expect((await notebooks.all()).any((f) => f.id == folder.id), isFalse);
      // 笔记还在，且回到收件箱
      final a2 = (await notes.byId(a.id))!;
      final b2 = (await notes.byId(b.id))!;
      expect(a2.deletedAt, isNull);
      expect(b2.deletedAt, isNull);
      expect(a2.isInbox, isTrue);
      expect(a2.notebookId, isNull);
      expect((await notes.watchInbox().first).length, 2);
    });

    // 笔记库是**平铺**的：去掉了 parent_id，不能有子笔记库。
    // 原先这里有三条测试（子目录上浮、buildTree 组层级）——它们测的是
    // 已被移除的能力。删掉，换成验证"确实没有层级"。
    test('删除一个笔记库不影响其他笔记库', () async {
      final a = await notebooks.create(name: 'A');
      final b = await notebooks.create(name: 'B');

      await notebooks.softDelete(a.id);

      final rest = await notebooks.all();
      expect(rest.map((n) => n.id), [b.id]);
      expect((await notebooks.byId(a.id))!.deletedAt, isNotNull);
    });

    test('笔记库列表是平的：没有嵌套结构可用', () async {
      await notebooks.create(name: '甲');
      await notebooks.create(name: '乙');
      await notebooks.create(name: '丙');

      final all = await notebooks.all();
      expect(all.length, 3);
      // 每个都是独立一行，没有 children 之类的层级字段
      expect(all.map((n) => n.name).toSet(), {'甲', '乙', '丙'});
    });

    test('重命名笔记库会 trim 空白', () async {
      final f = await notebooks.create(name: '原名');
      await notebooks.rename(f.id, '  新名  ');
      expect((await notebooks.byId(f.id))!.name, '新名');
    });

    // ---- 搜索 ----

    test('搜索命中标题与正文', () async {
      await notes.createInbox(title: 'Flutter 学习', content: '无关内容');
      await notes.createInbox(title: '无关', content: '正文里有 Flutter');
      await notes.createInbox(title: '无关', content: '什么都搜不到');

      final hit = await notes.search('Flutter').first;
      expect(hit.length, 2);
    });

    test('搜索关键词里的 % 与 _ 被当字面量而非通配符', () async {
      await notes.createInbox(title: '完成度 100%', content: 'a');
      await notes.createInbox(title: '完全无关', content: 'b');

      // 若不转义，"100%" 会因为 % 通配而匹配到别的记录
      final hit = await notes.search('100%').first;
      expect(hit.length, 1);
      expect(hit.first.title.contains('100%'), isTrue);

      final underscore = await notes.search('a_b').first;
      expect(underscore, isEmpty);
    });

    test('搜索已删除笔记不会返回', () async {
      final n = await notes.createInbox(title: '唯一关键词', content: 'x');
      await notes.softDelete(n.id);
      expect(await notes.search('唯一关键词').first, isEmpty);
    });

    // ---- 标签 ----
    //
    // 「用户手动标签」整条链路（`tags` / `note_tags` 两张表、`ensureTag` /
    // `attachTag` / `detachTag` / `watchTags` / `tagsOf`）已在 schema v9 删除，
    // 原有的两条标签用例（复用归一化、usageCount 不重复累加）随之移除。
    // 卡片级标签还活着，见 `ai_asset_test.dart` 的「标签规整」。

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

    test('会话列表只列**有消息**的会话（空会话不显示，但行还在）', () async {
      final now = DateTime.now().toUtc();
      await db.upsertConversation(AiConversationsCompanion.insert(
        id: 'with-msg',
        createdAt: now,
        updatedAt: now,
      ));
      // 时间戳差一分钟：排序断言要**确定**，不能靠"两次调用碰巧不同毫秒"
      await db.upsertConversation(AiConversationsCompanion.insert(
        id: 'empty',
        createdAt: now,
        updatedAt: now.add(const Duration(minutes: 1)),
      ));
      await db.insertAiMessage(AiMessagesCompanion.insert(
        id: 'm1',
        conversationId: 'with-msg',
        role: 'user',
        content: const Value('你好'),
        createdAt: now,
      ));

      // 早先"点一下新建就落一行"留下的空壳不该出现在列表里：
      // 它们时间戳最新，会排在最前面、还会被"打开上次的会话"选中
      final list = await db.watchConversations().first;
      expect(list.map((c) => c.id), ['with-msg']);
      // 只是**不显示**，不删行（删除是破坏性动作，不在这里做）
      expect((await db.getConversation('empty'))?.id, 'empty');

      // 一旦有了消息就该出现（列表是 watch 的，发消息要能刷出来）
      await db.insertAiMessage(AiMessagesCompanion.insert(
        id: 'm2',
        conversationId: 'empty',
        role: 'user',
        content: const Value('在吗'),
        createdAt: now,
      ));

      final after = await db.watchConversations().first;
      expect(after.map((c) => c.id).toSet(), {'with-msg', 'empty'});
      expect(after.first.id, 'empty', reason: '最近活动的排在最前');
    });

    test('批量删会话：一条语句删完，消息跟着级联走，空列表是安全 no-op', () async {
      final now = DateTime.now().toUtc();
      for (final id in ['c1', 'c2', 'c3']) {
        await db.upsertConversation(AiConversationsCompanion.insert(
          id: id,
          createdAt: now,
          updatedAt: now,
        ));
        await db.insertAiMessage(AiMessagesCompanion.insert(
          id: 'm-$id',
          conversationId: id,
          role: 'user',
          content: const Value('你好'),
          createdAt: now,
        ));
      }

      // 空列表：什么都不做，而不是报错
      await db.deleteConversations(const []);
      expect((await db.watchConversations().first).length, 3);

      await db.deleteConversations(['c1', 'c2']);

      expect(
        (await db.watchConversations().first).map((c) => c.id),
        ['c3'],
        reason: '只删传进去的那些',
      );
      // 外键 ON DELETE CASCADE 生效：消息跟着走，不留孤儿行
      expect(await db.watchMessages('c1').first, isEmpty);
      expect(await db.watchMessages('c2').first, isEmpty);
      expect((await db.watchMessages('c3').first).length, 1);

      // 传了不存在的 id 也不影响还在的行
      await db.deleteConversations(['并不存在']);
      expect((await db.watchConversations().first).map((c) => c.id), ['c3']);
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

    test('清空 AI 历史不影响笔记与笔记库', () async {
      final f = await notebooks.create(name: '笔记库');
      await notes.createInNotebook(f.id, content: 'c');
      await db.insertAiCall(AiCallsCompanion.insert(
        id: 'a1',
        task: 'summarize',
        model: 'deepseek-flash',
        promptTokens: const Value(10),
        completionTokens: const Value(20),
        costCents: const Value(0.1),
        createdAt: DateTime.now().toUtc(),
      ));

      await db.clearAiHistory();

      // 只清调用审计，笔记与笔记库一条不少
      expect(await db.select(db.aiCalls).get(), isEmpty);
      expect((await db.select(db.notes).get()).length, 1);
      expect((await db.select(db.notebooks).get()).length, 1);
    });
  });


  group('复制全文', () {
    test('有标题：标题 + 空行 + 正文', () {
      expect(
        TextUtils.noteCopyText(title: '我的标题', content: '正文'),
        '我的标题\n\n正文',
      );
    });

    test('无标题：只返回正文（不留下多余空行）', () {
      expect(TextUtils.noteCopyText(title: '', content: '正文'), '正文');
      expect(TextUtils.noteCopyText(title: '   ', content: '正文'), '正文');
    });
  });
}
