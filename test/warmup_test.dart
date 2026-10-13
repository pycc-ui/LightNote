// 轻笔记**跨启动预留**的行为。
//
// ## 产品要求的流程
//
// ```
// 取出表里的预留（消费即清）
// 申请 6 张
// 池子 = 预留 + 6 张
// 末尾 3 张写入 feed_reserve 并从内存删除   ← 给下次启动
// 剩下 3 张留在池子                          ← 这次当屏
// ```
//
// 于是**每次进入都只展示 3 张**，另外 3 张在表里等下次。
//
// ## 与"卡片自己往后追加"无关
//
// 这张表只决定"进来时先拿哪 3 张"。列表在 UI 层**永远只替换、不追加**，
// 所以这里存多少张都不会让屏幕上的卡片自己增长。
// 那条 bug 是误加的"上拉加载"造成的，已经移除。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/core/db/models.dart';
import 'package:lightnote/features/ai/data/deepseek_client.dart';
import 'package:lightnote/features/ai/domain/ai_repository.dart';
import 'package:lightnote/features/note/data/feed_repository.dart';
import 'package:lightnote/features/note/data/note_repository.dart';

FeedDraft draft(String n) => FeedDraft(
      title: '标题$n',
      body: '正文$n',
      tag: '标签$n',
    );

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  /// 造一段长正文：每段约 370 字、段间空行 → **一段就是一片**。
  ///
  /// ⚠️ 段落必须够大。切片器是"**填到上限 700 为止**"地合并相邻片：
  /// 段落只有 60 字时 11 段会并成一片，`longBody(100)` 只剩约 9 片 ——
  /// 那时"一批取 9 份素材"就把池子抽干了，去重也没得去。
  /// 370 × 2 = 740 > 700，两段装不进一片，于是**段数 = 片数**。
  ///
  /// 定义在这里（`main` 顶层）而不是某个 `group` 里面：早先有两份同名副本，
  /// 一份改大了段落、另一份没改 → 没改的那个组就红了。**只留一份。**
  String longBody(int paragraphs) =>
      List.generate(paragraphs, (i) => '第$i段。${'内容' * 180}').join('\n\n');

  group('预留表：写入与消费', () {
    test('初始为空', () async {
      expect(await db.feedReserveCount(), 0);
      expect(await db.takeFeedReserve(), isEmpty);
    });

    test('写入后能按顺序读回，标题正文标签都在', () async {
      await db.replaceFeedReserve([draft('A'), draft('B'), draft('C')]);
      expect(await db.feedReserveCount(), 3);

      final got = await db.takeFeedReserve();
      expect(got.map((d) => d.title), ['标题A', '标题B', '标题C'],
          reason: '顺序必须稳定（下次打开按这个顺序展示）');
      expect(got.first.body, '正文A');
      expect(got.first.tag, '标签A');
    });

    test('取出即清（消费即清）', () async {
      await db.replaceFeedReserve([draft('A'), draft('B')]);
      await db.takeFeedReserve();

      expect(await db.feedReserveCount(), 0, reason: '取过就该清掉');
      expect(await db.takeFeedReserve(), isEmpty,
          reason: '第二次取应当是空的，不能重复展示同一批');
    });

    test('再次写入是替换而不是追加', () async {
      await db.replaceFeedReserve([draft('旧1'), draft('旧2'), draft('旧3')]);
      await db.replaceFeedReserve([draft('新1')]);

      expect(await db.feedReserveCount(), 1);
      expect((await db.takeFeedReserve()).single.title, '标题新1',
          reason: '累积起来会让下次打开看到一堆旧内容');
    });

    test('写入空列表就是清空', () async {
      await db.replaceFeedReserve([draft('A')]);
      await db.replaceFeedReserve([]);
      expect(await db.feedReserveCount(), 0);
    });

    test('空标题或空正文的卡片不出现在读取结果里', () async {
      await db.replaceFeedReserve([
        const FeedDraft(title: '', body: '只有正文', tag: ''),
        const FeedDraft(title: '只有标题', body: '', tag: ''),
        draft('好卡片'),
      ]);
      final got = await db.takeFeedReserve();
      expect(got, hasLength(1));
      expect(got.single.title, '标题好卡片');
    });

    test('标签 JSON 损坏时不抛，退回空标签', () async {
      await db.customStatement(
        'INSERT INTO feed_reserve (id, title, body, tags, position, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        [
          'x',
          '标题',
          '正文',
          '{不是json',
          0,
          DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
        ],
      );
      final got = await db.takeFeedReserve();
      expect(got, hasLength(1));
      // 列名是 feed_reserve.tags（历史遗留的 JSON 数组），但现在只放一个标签
      expect(got.single.tag, '');
    });
  });

  group('warmUpIfNeeded 不联网时的行为', () {
    late FeedRepository feed;
    late NoteRepository notes;

    setUp(() {
      notes = NoteRepository(db);
      feed = FeedRepository(
        db,
        AiRepository(db: db, client: DeepSeekClient()), // 没配 Key
      );
    });

    test('来源为空时什么都不做', () async {
      expect(await feed.warmUpIfNeeded(FeedSource.empty), isFalse);
      expect(feed.poolSize, 0);
    });

    test('库里没笔记（没素材）时，预留照旧给页面用，不浪费', () async {
      await db.replaceFeedReserve([draft('A'), draft('B'), draft('C')]);

      final ran = await feed.warmUpIfNeeded(
        const FeedSource(notebookIds: [], includeUnfiled: true),
      );

      expect(ran, isTrue);
      expect(feed.poolSize, 3, reason: '预留要进池子，用户至少能看到这 3 张');
    });

    // ---- 有预留：不让用户等生成（"秒出"） ----
    //
    // 这条以前断言 `ran == false`，那是**旧语义**：旧实现无论有没有预留
    // 都要 await 生成，失败就返回 false。
    // 现在的设计是「预留优先」：有预留就直接当这一屏，**后台**再去生成。
    // 所以即使没有 Key、后台生成必然失败，这一屏也是成功的。
    test('有预留但没 Key：预留照样当一屏（秒出），返回 true', () async {
      await notes.createInbox(title: '素材', content: '一段正文');
      await db.replaceFeedReserve([draft('A'), draft('B'), draft('C')]);

      final ran = await feed.warmUpIfNeeded(
        const FeedSource(notebookIds: [], includeUnfiled: true),
      );

      expect(ran, isTrue,
          reason: '有预留 = 这一屏立刻能显示。后台生成失败是后台的事，'
              '不该让用户看到的这一屏变成"生成失败"');
      expect(feed.poolSize, 3, reason: '取出来又丢掉等于用户白等还看不到东西');
    });

    test('既没预留、生成又失败：返回 false，且不抛', () async {
      // 故意不写预留：这样才走"必须当场生成"那条路径
      await notes.createInbox(title: '素材', content: '一段正文');

      final ran = await feed.warmUpIfNeeded(
        const FeedSource(notebookIds: [], includeUnfiled: true),
      );

      expect(ran, isFalse, reason: '生成不了就返回 false，且不抛');
      expect(feed.poolSize, 0);
    });
  });

  // ==========================================================================
  // 素材数**不能**被笔记数卡死（回归测试）
  //
  // 实测被用户抓到的 bug：把"一份素材 = 一张卡片"写成"一篇笔记 = 一份素材"，
  // 于是库里只有 3 条笔记时就只能生成 3 张卡。内存池（目标 12 张）永远补不满，
  // 用户等一次只拿到几张，然后又得等。
  //
  // 修法是**从同一篇笔记取不同的切片**当多份素材——切片设计本来就有这个好处，
  // 而且每块说的是不同的事，卡片不会重复。
  // ==========================================================================
  group('素材数不被笔记数卡死', () {
    late NoteRepository notes;
    late FeedRepository feed;

    setUp(() {
      notes = NoteRepository(db);
      feed = FeedRepository(
        db,
        AiRepository(db: db, client: DeepSeekClient()), // 没配 Key
      );
    });

    const source = FeedSource(notebookIds: [], includeUnfiled: true);

    test('只有 1 条长笔记，也凑够 9 份素材', () async {
      await notes.createInbox(title: '长笔记', content: longBody(100));

      final materials = await feed.gatherSources(source, limit: 9);

      expect(materials, hasLength(9),
          reason: '被笔记数卡死的话只会拿到 1 份 → 用户等一次只得到 1 张卡');
    });

    test('同一篇笔记取出的切片**各不相同**', () async {
      await notes.createInbox(title: '长笔记', content: longBody(100));

      final chunks =
          (await feed.gatherSources(source, limit: 9)).map((m) => m.chunk);
      expect(chunks.toSet(), hasLength(chunks.length),
          reason: '取到重复的块 = 9 张卡都在讲同一件事');
    });

    test('笔记的标题跟着它自己的切片走', () async {
      await notes.createInbox(title: '唯一标题', content: longBody(100));

      final materials = await feed.gatherSources(source, limit: 9);
      // 9 份素材来自同一篇笔记，所以标题应当一致
      expect(materials.every((m) => m.title == '唯一标题'), isTrue);
    });

    test('极端情况：多条短笔记（各只有 1 块）就只凑到笔记条数', () async {
      // 短笔记整篇一块，切不出第二块——素材数到这里确实是上限。
      // 张数由提示词兜底（"同一份素材可以写多张，抓不同的具体内容"），
      // 见 AiPrompts.feedUser 的 count < materials.length 分支。
      for (var i = 0; i < 3; i++) {
        await notes.createInbox(title: '短$i', content: '很短的一段正文$i。');
      }

      final materials = await feed.gatherSources(source, limit: 9);
      expect(materials, hasLength(3),
          reason: '3 条短笔记各 1 块，凑不出更多——这是素材的物理上限');
      expect(materials.every((m) => m.chunk.isNotEmpty), isTrue);
    });

    test('长笔记 + 短笔记混合：优先凑满', () async {
      await notes.createInbox(title: '长', content: longBody(60));
      await notes.createInbox(title: '短', content: '很短的一段。');

      final materials = await feed.gatherSources(source, limit: 9);
      expect(materials, hasLength(9),
          reason: '长笔记能提供足够的块，短笔记不该拖住总数');
      expect(materials.any((m) => m.title == '长'), isTrue);
    });
  });

  // ==========================================================================
  // 去重（回归）：笔记少的时候，同一批切片会被反复取到，卡片就重复了
  //
  // 三道防线：取块时跳过用过的 → prompt 里列出已有标题 → 生成后丢掉撞车的。
  // 这里测第 1 和第 3 道（第 2 道是提示词，只能真调 AI 才能验，没有自动化覆盖）。
  // ==========================================================================
  group('去重', () {
    late NoteRepository notes;
    late FeedRepository feed;

    setUp(() {
      notes = NoteRepository(db);
      feed = FeedRepository(
        db,
        AiRepository(db: db, client: DeepSeekClient()), // 没配 Key
      );
    });

    const source = FeedSource(notebookIds: [], includeUnfiled: true);

    // `longBody` 提到 `main()` 顶部**只定义一份**。这里原本还有一份副本，
    // 两份各自演化（一份改大了段落、另一份没改）→ 这个组仍然用 61 字的段落，
    // 在新切片器下 11 段并成一片，"去重"用例就红了。

    test('同一篇笔记连续两次取素材，块**不是同一批**', () async {
      await notes.createInbox(title: '长', content: longBody(100));

      final a = (await feed.gatherSources(source, limit: 9))
          .map((m) => m.chunk)
          .toSet();
      final b = (await feed.gatherSources(source, limit: 9))
          .map((m) => m.chunk)
          .toSet();

      // 修之前：cursor 每次从 0 开始按索引取块 → 两次拿到的**完全一样**
      expect(a, isNot(equals(b)),
          reason: '块的选择必须随机；不随机的话每批素材一模一样，卡片必然重复');
    });

    test('第二次会优先用没取过的块（重叠明显变小）', () async {
      await notes.createInbox(title: '长', content: longBody(100));

      final a = (await feed.gatherSources(source, limit: 9))
          .map((m) => m.chunk)
          .toList();
      final b = (await feed.gatherSources(source, limit: 9))
          .map((m) => m.chunk)
          .toList();

      final overlap = b.where(a.contains).length;
      expect(overlap, lessThanOrEqualTo(5),
          reason: '一共 14+ 块、一批取 9 块：完全不管的话重叠就是 9（全撞），'
              '优先跳过用过的之后应当明显更低（实测 3~5）');
    });

    test('标题指纹去重：标点 / 空格 / 大小写不同也算同一张', () {
      final drafts = [
        FeedDraft(title: '抄书是最没用的努力', body: 'a', tag: ''),
        FeedDraft(title: '抄书是最没用的努力！', body: 'b', tag: ''),
        FeedDraft(title: ' 抄书是最没用的努力 ', body: 'c', tag: ''),
        FeedDraft(title: '抄书，是最没用的努力', body: 'd', tag: ''),
        FeedDraft(title: '完全另一个题目', body: 'e', tag: ''),
      ];

      final out = FeedRepository.dropSimilarDrafts(
        drafts,
        against: const ['抄书是最没用的努力'],
      );

      expect(out.map((d) => d.body), ['e'],
          reason: '前四条对用户来说就是同一张卡，都该丢掉');
    });

    test('同一批里自己撞车的也只留一张', () {
      final drafts = [
        FeedDraft(title: '同一句话', body: 'a', tag: ''),
        FeedDraft(title: '同一句话', body: 'b', tag: ''),
      ];

      // 注意 against 为空时也要去重——这里曾经写成"空就提前返回"，漏掉了批内重复
      expect(FeedRepository.dropSimilarDrafts(drafts, against: const []),
          hasLength(1));
    });

    test('英文标题不区分大小写', () {
      final drafts = [
        FeedDraft(title: 'Spaced Repetition', body: 'a', tag: ''),
        FeedDraft(title: 'spaced repetition', body: 'b', tag: ''),
      ];
      expect(FeedRepository.dropSimilarDrafts(drafts, against: const []),
          hasLength(1));
    });

    test('标题里没有实义字符时不误杀', () {
      final drafts = [
        FeedDraft(title: '？？？', body: 'a', tag: ''),
        FeedDraft(title: '！！！', body: 'b', tag: ''),
      ];
      expect(FeedRepository.dropSimilarDrafts(drafts, against: const []),
          hasLength(2));
    });
  });
}