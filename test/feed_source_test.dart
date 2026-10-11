// 卡片流的「素材来源」解析规则。
//
// ## 产品要求的三条
//
//   1. **默认是全选所有的笔记库和我的轻笔记**
//   2. **用户改过之后，以用户的为准**
//   3. **新增的笔记库默认是勾选的**
//
// ## 为什么存「排除集」而不是「包含集」
//
// 第 ③ 条是最苛刻的，它决定了数据怎么存：
//
//   · 存**包含集**时，"一个 id 不在集合里"**有歧义** —— 是"从没见过"
//     还是"用户取消的"？于是不得不额外记一个"用户改过没有"的标记，
//     再靠一段"把缺失的库补回来"的对账来实现 ③。
//     而那段对账以前只在页面 `initState` 跑一次，三个 tab 又是 `IndexedStack`
//     保活的（切标签不重建页面）→ **新建的库进不了来源，要重启 App 才对**。
//
//   · 存**排除集**时，"不在集合里"**无歧义地等于"包含"**（不管是新库还是没动过的库），
//     所以 ② 和 ③ 天然共存，既不需要那个标记，也不需要任何对账。
//
// 这个文件盯的就是"② 和 ③ 同时成立"这一条，以及"没改过就什么都不写"。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/features/ai/data/deepseek_client.dart';
import 'package:lightnote/features/ai/domain/ai_repository.dart';
import 'package:lightnote/features/note/data/feed_repository.dart';
import 'package:lightnote/features/note/data/notebook_repository.dart';

/// 这两个 key 的名字**不能**变回 `feed_source_notebooks`：
/// 老数据里那个 key 存的是"包含集"，当"排除集"读会把来源整个清空。
const _kExcluded = 'feed_source_excluded';
const _kIncludeUnfiled = 'feed_include_unfiled';
const _kLegacyNotebooks = 'feed_source_notebooks';

void main() {
  late AppDatabase db;
  late FeedRepository feed;
  late NotebookRepository notebooks;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    feed = FeedRepository(
      db,
      AiRepository(db: db, client: DeepSeekClient()), // 不联网
    );
    notebooks = NotebookRepository(db);
  });
  tearDown(() => db.close());

  // 把来源压成"库名字的集合"，断言更好读
  Future<Set<String>> resolvedNames() async {
    final src = await feed.resolveSource();
    final all = await db.allNotebooks();
    final byId = {for (final n in all) n.id: n.name};
    return src.notebookIds.map((id) => byId[id] ?? id).toSet();
  }

  group('需求①：默认全选所有笔记库 + 我的轻笔记', () {
    test('全新安装（没有任何 key）→ 全部库都在，且包含我的轻笔记', () async {
      await notebooks.create(name: '工作');
      await notebooks.create(name: '学习');

      final src = await feed.resolveSource();

      expect(src.notebookIds.length, 2);
      expect(src.includeUnfiled, isTrue);
      expect(src.isEmpty, isFalse);
    });

    test('**解析来源不写任何 key** —— 默认态是算出来的，不是存出来的', () async {
      await notebooks.create(name: '工作');

      await feed.resolveSource();
      await feed.resolveSource(); // 多算几次也不该落盘

      expect(await db.readSetting(_kExcluded), isNull,
          reason: '没排除任何库时不该写这个 key');
      expect(await db.readSetting(_kIncludeUnfiled), isNull,
          reason: '缺省就是包含我的轻笔记，不需要写');
    });

    test('一个笔记库都没有时：来源仍是"含我的轻笔记"，不算空', () async {
      final src = await feed.resolveSource();
      expect(src.notebookIds, isEmpty);
      expect(src.includeUnfiled, isTrue);
      expect(src.isEmpty, isFalse, reason: '还有「我的轻笔记」可用，不该显示引导');
    });
  });

  group('需求②：用户改过之后以用户的为准', () {
    test('取消勾选某个库 → 它不再参与', () async {
      final work = await notebooks.create(name: '工作');
      await notebooks.create(name: '学习');

      await feed.writeSource(
        FeedSource(
          notebookIds: [(await notebooks.all())
              .firstWhere((n) => n.id != work.id)
              .id],
          includeUnfiled: true,
        ),
      );

      expect(await resolvedNames(), {'学习'});
    });

    test('取消勾选后**重新解析多次**仍然不含它（不是靠内存记着）', () async {
      final work = await notebooks.create(name: '工作');
      await notebooks.create(name: '学习');

      final all = await notebooks.all();
      await feed.writeSource(FeedSource(
        notebookIds: [all.firstWhere((n) => n.id != work.id).id],
        includeUnfiled: true,
      ));

      expect(await resolvedNames(), {'学习'});
      expect(await resolvedNames(), {'学习'}, reason: '第二次解析结果必须一样');
    });

    test('关掉「包含我的轻笔记」会被尊重', () async {
      await notebooks.create(name: '工作');

      await feed.writeSource(
        FeedSource(notebookIds: (await notebooks.all()).map((n) => n.id).toList(), includeUnfiled: false),
      );

      expect((await feed.resolveSource()).includeUnfiled, isFalse);
    });

    test('全部取消（库 + 我的轻笔记）→ 来源为空，页面显示引导', () async {
      await notebooks.create(name: '工作');

      await feed.writeSource(
        const FeedSource(notebookIds: [], includeUnfiled: false),
      );

      expect((await feed.resolveSource()).isEmpty, isTrue);
    });
  });

  group('需求③：新增的笔记库默认勾选（**② ③ 必须同时成立**）', () {
    test('取消掉「工作」之后再新建「项目」→ 项目自动进来，工作仍不含', () async {
      final work = await notebooks.create(name: '工作');
      await notebooks.create(name: '学习');

      // 用户取消「工作」
      final all = await notebooks.all();
      await feed.writeSource(FeedSource(
        notebookIds: [
          for (final n in all)
            if (n.id != work.id) n.id,
        ],
        includeUnfiled: true,
      ));
      expect(await resolvedNames(), {'学习'});

      // 之后新建的库
      await notebooks.create(name: '项目');

      expect(await resolvedNames(), {'学习', '项目'},
          reason: '新库不在排除集里，必须自动勾选；同时用户排除掉的「工作」不能被带回来');
    });

    test('连着新建多个库都会自动进来', () async {
      final work = await notebooks.create(name: '工作');
      await notebooks.create(name: '学习');
      final all = await notebooks.all();
      await feed.writeSource(FeedSource(
        notebookIds: [
          for (final n in all)
            if (n.id != work.id) n.id,
        ],
        includeUnfiled: true,
      ));

      await notebooks.create(name: '项目A');
      await notebooks.create(name: '项目B');

      expect(await resolvedNames(), {'学习', '项目A', '项目B'});
    });

    test('**不重启**也能看到新库 —— 每次调用都现算，没有快照可过期', () async {
      await notebooks.create(name: '工作');
      final before = await feed.resolveSource();

      await notebooks.create(name: '学习');
      final after = await feed.resolveSource();

      expect(before.notebookIds.length, 1);
      expect(after.notebookIds.length, 2,
          reason: '同一个进程里再解析就该看到新库（这正是"要重启才生效"那个 bug 的反面）');
    });
  });

  group('恢复默认', () {
    test('清掉排除集 → 回到"全部库 + 我的轻笔记"', () async {
      await notebooks.create(name: '工作');
      await notebooks.create(name: '学习');
      await feed.writeSource(
        const FeedSource(notebookIds: [], includeUnfiled: false),
      );
      expect((await feed.resolveSource()).isEmpty, isTrue);

      await feed.resetSource();

      final src = await feed.resolveSource();
      expect(src.notebookIds.length, 2);
      expect(src.includeUnfiled, isTrue);
      expect(await db.readSetting(_kExcluded), isNull);
      expect(await db.readSetting(_kIncludeUnfiled), isNull);
    });

    test('恢复默认之后，新建的库照样自动进来', () async {
      await notebooks.create(name: '工作');
      await feed.writeSource(
        FeedSource(
          notebookIds: (await notebooks.all()).map((n) => n.id).toList(),
          includeUnfiled: false,
        ),
      );
      await feed.resetSource();

      await notebooks.create(name: '新库');

      expect((await feed.resolveSource()).notebookIds.length, 2);
      expect((await feed.resolveSource()).includeUnfiled, isTrue);
    });
  });

  group('边界', () {
    test('删掉一个笔记库 → 保存后排除集里不残留它的 id', () async {
      final work = await notebooks.create(name: '工作');
      await notebooks.create(name: '学习');

      // 用户保留「工作」、排除「学习」
      await feed.writeSource(FeedSource(
        notebookIds: [work.id],
        includeUnfiled: true,
      ));

      // 删掉「学习」之后再保存一次（用户又动了设置）
      final study = (await notebooks.all()).firstWhere((n) => n.id != work.id);
      await notebooks.softDelete(study.id);
      await feed.writeSource(FeedSource(
        notebookIds: [work.id],
        includeUnfiled: true,
      ));

      expect(await resolvedNames(), {'工作'});
      final raw = await db.readSetting(_kExcluded);
      expect(raw, isNot(contains(study.id)),
          reason: '已删除的库 id 不该留在排除集里（每次保存按当前全部库重算）');
    });

    test('老 key `feed_source_notebooks`（包含集）**不被读取**', () async {
      await notebooks.create(name: '工作');
      await notebooks.create(name: '学习');

      // 模拟旧版本留下的数据：一个只含 1 个库的"包含集"
      await db.writeSetting(_kLegacyNotebooks, '["some-old-id"]');

      final src = await feed.resolveSource();
      expect(src.notebookIds.length, 2,
          reason: '老 key 的语义是"包含集"，一旦被当"排除集"读，来源会整个空掉');
    });

    test('排除集 JSON 损坏 → 当成"没排除任何"（全选），而不是全排除', () async {
      await notebooks.create(name: '工作');
      await notebooks.create(name: '学习');

      await db.writeSetting(_kExcluded, '{坏掉的 json');

      final src = await feed.resolveSource();
      expect(src.notebookIds.length, 2,
          reason: '损坏时当成全选比当成全排除安全：后者会让卡片流突然全空且无从解释');
    });

    test('writeSource 存的是"没勾上的"（排除集），不是"勾上的"', () async {
      final work = await notebooks.create(name: '工作');
      await notebooks.create(name: '学习');

      await feed.writeSource(FeedSource(
        notebookIds: [work.id],
        includeUnfiled: true,
      ));

      final raw = await db.readSetting(_kExcluded);
      expect(raw, isNotNull);
      expect(raw, isNot(contains(work.id)), reason: '勾上的库不该出现在排除集');
      final all = await notebooks.all();
      for (final n in all.where((n) => n.id != work.id)) {
        expect(raw, contains(n.id), reason: '没勾上的库必须在排除集里');
      }
    });
  });
}
