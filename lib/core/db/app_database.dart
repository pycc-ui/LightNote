import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'ai_functions.dart';
import 'ai_udfs.dart';
import 'database_location.dart';
import 'models.dart';
import 'tables.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [
    Notebooks,
    Notes,
    AiCalls,
    AiConversations,
    AiMessages,
    AppKv,
    FeedReserve,
    NoteChunks,
    AiFunctions,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  /// 测试用构造：传入内存库
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => kCurrentSchemaVersion;

  /// 当前数据库文件的绝对路径。
  ///
  /// 由 [_openConnection] 在打开时记下，因此设置页展示的路径
  /// 与实际写入的路径永远是同一个值（不会两处各解析一次而互相矛盾）。
  String get databasePath => _activeDbFile?.path ?? '(尚未打开)';

  /// 导出/切换工作目录时用的**一致性快照**。
  ///
  /// 为什么不用 `File.copy`：SQLite 的默认 journal 模式下，
  /// 最近一次事务的内容可能还在 `-journal` 文件里，
  /// 直接拷主文件可能得到一个**少了最后一次提交**的库，
  /// 更糟的是拷到一半 App 又写了一次，会得到撕裂的文件。
  ///
  /// `VACUUM INTO` 是 SQLite 官方提供的在线备份方式：
  /// 由数据库自己保证一致性，且输出是一个已整理过的完整库。
  /// 目标文件必须不存在，否则 SQLite 会直接报错（这也是我们希望的行为，
  /// 避免静默覆盖用户已有的备份）。
  Future<void> snapshotTo(String targetPath) async {
    final escaped = targetPath.replaceAll("'", "''");
    await customStatement("VACUUM INTO '$escaped'");
  }

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createIndexes();
        },
        onUpgrade: (m, from, to) async {
          // 迁移规则：只追加，永不修改已发布的版本分支。
          // 每次改表后请执行：
          //   dart run drift_dev schema dump lib/core/db/app_database.dart drift_schemas/
          // 并补一条迁移测试。

          // ---- 1 -> 2：笔记消费流 ----
          if (from < 2) {
            // `note_feed_state` 原先在这里用 `m.createTable(noteFeedState)` 建出。
            // 那张表**已在 v8 删除**（连 Dart 表定义一起移除了，见下面的 7 -> 8），
            // 所以这一支不再建它：建了也会在同一次迁移里被删掉，最终状态完全一样
            // （drift 的 onUpgrade 永远一次升到最新版，不存在"停在 v2"的库）。

            // 存量数据修正（必须做，否则这部分笔记会"消失"）：
            //
            // 「轻笔记」区块筛的是 is_inbox = true。而 v1 期间
            // NoteRepository.createLibrary() 写的是
            // `isInbox = false, notebookId = null`——一条"已归档但没笔记库"的笔记。
            // 改成按 is_inbox 筛选后，这类笔记既不在任何笔记库下、
            // 也不满足 is_inbox = true，**两个入口都看不到，等于丢失**。
            //
            // 同一类问题还出现在 softDeleteNotebook 把笔记移出笔记库时。
            // 这条 UPDATE 一并修正：
            await customStatement(
              'UPDATE notes SET is_inbox = 1 '
              'WHERE is_inbox = 0 AND folder_id IS NULL AND deleted_at IS NULL',
            );
          }

          // ---- 2 -> 3：笔记库化 + 去掉层级 ----
          if (from < 3) {
            // ⚠️ 这一段踩了两个坑，都记下来免得再犯。
            //
            // 坑 1（列名）：最初以为在 tables.dart 给字段加
            //   `@JsonKey('folder_id')` 就能让 SQL 列名保持不变。
            //   **不能**——`@JsonKey` 只作用于 Drift 的 JSON 序列化
            //   （toJson/fromJson），不参与建表；真正控制列名的是
            //   `named('...')`。于是 drift 按字段名生成了 `notebook_id`，
            //   而老库还是 `folder_id`，查询报 `no such column: notebook_id`。
            //
            // 坑 2（探测）：想用 `PRAGMA table_info(notebooks)` 或查
            //   `sqlite_master` 来判断"是不是老库"，**在 onUpgrade 里
            //   都拿不到结果**（drift 的 customSelect 在这个阶段返回空）。
            //   据此判断会漏掉改名步骤。
            //
            // 所以这里**不做探测**：直接执行改名，若目标已经不存在就忽略错误。
            // 对全新库（onCreate 已建好新结构）来说，下面每条都会以
            // "no such table / no such column" 失败——那正是预期，吃掉即可。
            Future<void> trySql(String sql) async {
              try {
                await customStatement(sql);
              } catch (_) {
                // 目标不存在 = 已经是最新结构，无需迁移
              }
            }

            // 1) 表改名（老库叫 folders）
            await trySql('ALTER TABLE folders RENAME TO notebooks');

            // 2) 列改名（老库用 folder_id / workspace_folder_id）
            await trySql(
              'ALTER TABLE notes RENAME COLUMN folder_id TO notebook_id',
            );
            await trySql(
              'ALTER TABLE ai_conversations '
              'RENAME COLUMN workspace_folder_id TO workspace_notebook_id',
            );

            // 3) 去掉层级。
            //
            //    SQLite 3.35+ 支持 DROP COLUMN。老版本会失败，
            //    退一步把值清空——宁可留一个恒为 NULL 的列
            //    （drift 不会再读它，留着无害），也不要让迁移整个失败。
            try {
              await customStatement(
                'ALTER TABLE notebooks DROP COLUMN parent_id',
              );
            } catch (_) {
              await trySql('UPDATE notebooks SET parent_id = NULL');
            }

            // 4) parent_id 的索引已随层级一起没意义
            await trySql('DROP INDEX IF EXISTS idx_folders_parent');

            // 5) 建新的笔记库排序索引（两条路径都需要）
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_notebooks_order '
              'ON notebooks(sort_order, name)',
            );
          }

          // ---- 3 -> 4：原本在这里建「每篇笔记的 AI 摘要」表 ----
          if (from < 4) {
            // `ai_note_summaries`（旧名 `note_ai_summaries`）**已整体删除**：
            // 卡片流的素材现在只有一小段原文，不再需要摘要。Dart 表定义没了，
            // 所以这里不再建它；存量老库由 v12 迁移 DROP 掉。
            // 同一批建过的 `note_ai_tags` 已在 v8 删除。
          }

          // ---- 4 -> 5：轻笔记跨启动预留 ----
          if (from < 5) {
            // 纯新增表，不动现有数据。
            // 索引同样交给下面的 `_createIndexes()`（原因见上）。
            await m.createTable(feedReserve);
          }

          // ---- 5 -> 6：删除记忆卡片相关表 ----
          if (from < 6) {
            // 轻笔记（卡片流）替代了记忆卡片复习，这三张表不再有任何读写方。
            //
            // **这是不可逆的**：老库升级后其中的卡片与复习记录会消失。
            // 但那正是产品决策——功能去掉了，数据留着也没人能看。
            //
            // 顺序：先删 reviews（它外键指向 cards）再删 cards，最后 decks。
            // 用 raw SQL 而不是 drift 的 delete()：delete 需要表还在
            // schema 里注册，而我们已经把它们从 `@DriftDatabase` 移除了。
            //
            // `IF EXISTS` 让"本来就没这张表"也不报错，所以不需要额外 try/catch。
            for (final t in const ['reviews', 'cards', 'card_decks']) {
              await customStatement('DROP TABLE IF EXISTS $t');
            }
          }

          // ---- 6 -> 7：删除「AI 整理要点」的落库表 ----
          if (from < 7) {
            // 编辑页那个 ✨ 菜单已移除。它会把整理结果写进 `note_summaries`，
            // 但**从来没有任何界面读它**（读侧 `watchLatestSummary` 一直没人调），
            // 也就是说这张表只写不读——功能去掉后就是纯死表。
            //
            // 同样不可逆；内容只是 AI 摘要，需要时还能重新生成。
            await customStatement('DROP TABLE IF EXISTS note_summaries');
          }

          // ---- 7 -> 8：清理两张无用表 ----
          if (from < 8) {
            // 两张表都已没有任何读写方，留着只是死重量：
            //
            //   · `note_feed_state`：卡片流"复习已有笔记"时代的调度状态
            //     （到期时间 / 间隔天数 / 难度因子 / 收藏）。卡片改成
            //     **AI 新生成**之后不复用同一条笔记，这套状态就没意义了，
            //     repository 里的读写方法早已删干净。
            //   · `note_ai_tags`：每篇笔记的 AI 标签。它**只写不读**——
            //     读侧链路（`NoteAiAssetRepository.get` → `FeedRepository.tagsOf`）
            //     零调用方，v8 已把那条链路连同 `NoteAiAsset.tags` 字段一起删掉；
            //     卡片上显示的那个标签来自卡片自己的 tags
            //     （`FeedDraft.tag` → `displayTag`），与这张表无关。
            //
            // 用 raw SQL 而不是 drift 的 delete()：两张表已经从
            // `@DriftDatabase` 移除，schema 里不再有它们。
            // `IF EXISTS` 让"本来就没这张表"也不报错，所以不需要 try/catch。
            for (final t in const ['note_feed_state', 'note_ai_tags']) {
              await customStatement('DROP TABLE IF EXISTS $t');
            }
          }

          // ---- 8 -> 9：删手动标签表 + 两个表改名 ----
          if (from < 9) {
            // 1) 删「用户手动标签」整条链路。
            //
            //    它是个闭环：写入只有编辑页那个标签弹窗，读取只有那个弹窗
            //    自己 + Markdown 导出里一行 `> 标签：`。产品确认不要了，
            //    `usageCount` 那个反范式计数器也只服务 `watchTags` 的
            //    ORDER BY，而 `watchTags` 零调用方。
            //
            //    顺序：先删连接表 `note_tags`（它外键指向 `tags`），再删主表。
            //    `IF EXISTS` 让"本来就没这两张表"（全新库）也不报错。
            //
            //    注意这与卡片上的标签**无关**：卡片标签来自卡片自己的
            //    `FeedDraft.tag`，存在 `feed_reserve.tags` 列里，一行不动。
            for (final t in const ['note_tags', 'tags']) {
              await customStatement('DROP TABLE IF EXISTS $t');
            }

            // 2) 两个表改名。做法与 v2→v3 的 `folders` → `notebooks` 完全一致：
            //    改类名会让 drift 认为"旧表不存在"，必须显式 RENAME，
            //    否则老库升级会丢掉这两张表的全部数据。
            //
            //    onUpgrade 里读不到探测结果（drift 的 customSelect 在迁移阶段
            //    返回空），所以不做探测：直接执行，失败就吃掉。
            //    全新库（onCreate 已按新名建好）必然会失败——那正是预期。
            Future<void> trySql(String sql) async {
              try {
                await customStatement(sql);
              } catch (_) {
                // 目标不存在 = 已经是最新结构，无需迁移
              }
            }

            await trySql(
              'ALTER TABLE note_ai_summaries RENAME TO ai_note_summaries',
            );
            await trySql('ALTER TABLE settings RENAME TO app_kv');
          }

          // ---- 9 -> 10：笔记切片表 ----
          //
          // 只建表，**不在迁移里回填**。
          //
          // 为什么不在迁移里回填：drift 的 `customSelect` 在迁移回调里拿不到数据
          // （与上面 8→9 那段注释是同一个坑），而回填需要读全部笔记正文。
          // 硬凑出来的话，几万条笔记会在升级那一刻卡住启动，而且**中断了就只
          // 回填了一半**，很难判断哪些补过哪些没补。
          //
          // 改成**懒回填**：`NoteChunkRepository` 在真正要用某篇笔记的切片时
          // 发现"一片都没有"就当场切一遍写回（毫秒级）。老库升级后
          // 第一次搜到某篇笔记时才为它建切片，用户完全无感，也不会卡启动。
          if (from < 10) {
            await m.createTable(noteChunks);
          }

          // ---- 10 -> 11：工作区从"一个笔记库 id"变成"范围" ----
          //
          // 用 `ALTER TABLE ADD COLUMN`（纯新增、不动数据、不重建表）：
          // 这是最不容易出错的一种迁移，而这次改的只是一个会话级设置。
          //
          // 顺手把老值搬过去：原来存的是**单个**笔记库 id，
          // 对应新形状的 `pick` + 一个目录 + 不含轻笔记。
          // （老的空值 = 未选择 → 留空串，读取时按 `none` 处理。）
          //
          // ⚠️ 这条 UPDATE 只在 `from < 11` 时跑，也就是**老库**才有
          // `workspace_notebook_id` 这一列；全新库的表里已经没有它了，
          // 所以这里不会因为列不存在而报错。
          if (from < 11) {
            await customStatement(
              'ALTER TABLE ai_conversations '
              "ADD COLUMN workspace_scope TEXT NOT NULL DEFAULT ''",
            );
            await customStatement(
              "UPDATE ai_conversations SET workspace_scope = "
              "'{\"mode\":\"pick\",\"notebookIds\":[\"' || workspace_notebook_id "
              "|| '\"],\"includeUnfiled\":false}' "
              'WHERE workspace_notebook_id IS NOT NULL',
            );
          }

          // ---- 11 -> 12：删除「每篇笔记的 AI 摘要」表 ----
          if (from < 12) {
            // 卡片流的素材现在只有一小段原文，不再需要摘要。
            // 老库里的这张表（含 v9 改名前的 `note_ai_summaries`）一并清掉。
            await customStatement(
              'DROP TABLE IF EXISTS ai_note_summaries',
            );
          }

          // ---- 12 -> 13：ai_capabilities 换成 ai_functions ----
          if (from < 13) {
            // 老表是 v1 的遗留，从建表起就没有任何读写方，**必然是空的**，
            // 所以不 ALTER RENAME 迁数据，直接删掉重建：
            // 顺带把列换成设计里的那五列（去掉了 one_line / sort_order）。
            await customStatement('DROP TABLE IF EXISTS ai_capabilities');
            await m.createTable(aiFunctions);
          }

          // 升级路径的索引统一在这里补。
          //
          // 放在**整个 onUpgrade 的末尾**是关键：迁移回调里 `m.createTable`
          // 建的表这时才真正存在。全部是 `CREATE INDEX IF NOT EXISTS`，
          // 重复执行安全。
          await _createIndexes();

          // v1 内部（未发布）那批调整的历史记录，保留作参考：
          //   notes: archived        -> is_inbox
          //   notes: content_format  -> source（默认值 markdown -> local）
          //   notes: 新增 folder_id
          //   新增: notebooks / ai_conversations / ai_messages / settings
        },
        beforeOpen: (details) async {
          // 外键约束在 SQLite 中默认关闭，必须显式打开，否则 CASCADE/SET NULL 不生效。
          await customStatement('PRAGMA foreign_keys = ON');

          // AI 操作层的两件启动活（见 core/db/ai_udfs.dart 与 ai_functions.dart）：
          //   · 触发器 —— 正文一变就清切片
          //   · 函数清单 —— 25 条种子数据，按版本号对齐
          //
          // 放在 beforeOpen 而不是 onCreate/onUpgrade：这两件事都是**每次打开
          // 对齐一次**的幂等动作，「新库建了、老库漏了」这种分叉在这里不会发生。
          // 也不能放进下面那个 setup 回调：那是开库时执行的，那时表还没建出来。
          await installAiTriggers(this);
          await _ensureAiFunctions();
        },
      );

  /// app_kv 里记「函数清单已经对齐到第几版」的 key。
  ///
  /// 不是设置项，是**派生数据的水位线**：清单内容在 Dart（core/db/ai_functions.dart），
  /// 库里只放副本，这个 key 用来判断副本过期没有。
  static const _aiFunctionsVersionKey = 'ai_functions_version';

  /// AI 的函数清单（`ai_functions` 表）——**种子数据，每次打开对齐一次**。
  ///
  /// 为什么不做成迁移里的一次性 INSERT：清单是「给 AI 看的说明书」，
  /// 会随函数增删、措辞调整而变，而迁移只跑一次（跑完就再也不回头）。
  /// 对齐的成本是一次 SELECT + 最多 25 次 UPSERT，而且有版本号挡着
  ///（app_kv 里的 ai_functions_version），绝大多数启动连写都不会写。
  ///
  /// 放在数据库层而不是 AI 层：它是**库的一部分**（表由迁移建、内容由这里灌），
  /// 和「示例笔记」那种产品数据不是一回事 —— 放这儿，任何打开库的入口
  ///（App、测试、工具脚本）都自动拿到同一份清单。
  Future<void> _ensureAiFunctions() async {
    final row = await (select(appKv)
          ..where((t) => t.key.equals(_aiFunctionsVersionKey)))
        .getSingleOrNull();
    if (row?.value == '$kAiFunctionsVersion') return;

    await transaction(() async {
      for (final f in kAiFunctions) {
        await into(aiFunctions).insertOnConflictUpdate(
          AiFunctionsCompanion.insert(
            name: f.name,
            category: f.category,
            signature: f.signature,
            description: f.description,
            example: Value(f.example),
          ),
        );
      }
      // 清单里已经删掉的函数要跟着清：留着它，AI 会照着表写出
      // 一个不存在的函数，然后拿到 no such function。
      await (delete(aiFunctions)
            ..where((t) =>
                t.name.isNotIn([for (final f in kAiFunctions) f.name])))
          .go();
      await into(appKv).insertOnConflictUpdate(AppKvCompanion.insert(
        key: _aiFunctionsVersionKey,
        value: '$kAiFunctionsVersion',
      ));
    });
  }

  Future<void> _createIndexes() async {
    // 列表页默认排序
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_notes_updated ON notes(updated_at DESC)',
    );
    // 轻笔记页（收件箱）的主力索引
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_notes_inbox ON notes(is_inbox, updated_at DESC)',
    );
    // 笔记库详情页
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_notes_notebook ON notes(notebook_id, updated_at DESC)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_notes_deleted ON notes(deleted_at)',
    );
    // 笔记库：平铺列表按排序 + 名字（原先的 idx_notebooks_order 已随层级一起删除）
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_notebooks_order ON notebooks(sort_order, name)',
    );
    // 笔记切片：卡片流取"最近没用过的片"时按它排序
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_chunks_used ON note_chunks(last_used_at)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_ai_messages_conv ON ai_messages(conversation_id, created_at)',
    );
  }

  // ==========================================================================
  // notebooks 笔记库
  //
  // **平铺，没有层级。** 原先叫 folders（目录）且支持父子嵌套，
  // 改成「笔记库」语义时一并去掉了 parent_id —— 用数据库而非文件系统
  // 本来就是为了不模仿目录树。
  // ==========================================================================

  /// 全部未删除笔记库，按 (排序, 名称)。
  Stream<List<Notebook>> watchNotebooks() {
    return (select(notebooks)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([
            (t) => OrderingTerm(expression: t.sortOrder),
            (t) => OrderingTerm(expression: t.name),
          ]))
        .watch();
  }

  Future<List<Notebook>> allNotebooks() {
    return (select(notebooks)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([
            (t) => OrderingTerm(expression: t.sortOrder),
            (t) => OrderingTerm(expression: t.name),
          ]))
        .get();
  }

  Future<Notebook?> getNotebook(String id) {
    return (select(notebooks)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  Future<int> notebookNoteCount(String notebookId) async {
    final expr = notes.id.count();
    final q = selectOnly(notes)
      ..addColumns([expr])
      ..where(
          notes.notebookId.equals(notebookId) & notes.deletedAt.isNull());
    final row = await q.getSingle();
    return row.read(expr) ?? 0;
  }

  Future<void> upsertNotebook(NotebooksCompanion entry) {
    return into(notebooks).insertOnConflictUpdate(entry);
  }

  /// 笔记库重命名
  Future<void> renameNotebook(String id, String name) {
    return (update(notebooks)..where((t) => t.id.equals(id))).write(
      NotebooksCompanion(
        name: Value(name.trim()),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  /// 删除笔记库（逻辑删除）。
  ///
  /// 关键行为：**笔记库里的笔记不删**，而是回到「我的轻笔记」，
  /// 由用户决定去处。直接连笔记一起删掉是数据丢失事故。
  /// 外键的 SET NULL 会把 folder_id 置空，这里再补上 is_inbox = true。
  ///
  /// 不再有"子目录上浮"这一步——笔记库是平的，不存在子库。
  Future<void> softDeleteNotebook(String id) {
    return transaction(() async {
      await (update(notes)
            ..where((t) =>
                t.notebookId.equals(id) & t.deletedAt.isNull()))
          .write(
        NotesCompanion(notebookId: const Value(null),
          isInbox: const Value(true),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
      await (update(notebooks)..where((t) => t.id.equals(id))).write(
        NotebooksCompanion(
          deletedAt: Value(DateTime.now().toUtc()),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
    });
  }

  // ==========================================================================
  // notes
  // ==========================================================================

  /// 轻笔记页：收件箱里的速记，最新在前。
  Stream<List<Note>> watchInboxNotes() {
    return (select(notes)
          ..where((t) =>
              t.deletedAt.isNull() &
              t.isInbox.equals(true) &
              t.notebookId.isNull())
          ..orderBy([
            (t) => OrderingTerm(expression: t.pinned, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  /// 笔记库「最近笔记」：已归档的全部笔记
  Stream<List<Note>> watchLibraryNotes() {
    return (select(notes)
          ..where((t) => t.deletedAt.isNull() & t.isInbox.equals(false))
          ..orderBy([
            (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  /// 笔记库页的「轻笔记」区块：未归档笔记（原收件箱内容），最新在前。
  ///
  /// 与 [watchInboxNotes] 的区别：这里**不额外要求 `notebookId IS NULL`**。
  /// 数据一致性上未归档笔记就不该有笔记库，但迁移修正过的历史数据
  /// 万一有残留，也不该让它从两个入口都看不见。
  Stream<List<Note>> watchUnfiledNotes() {
    return (select(notes)
          ..where((t) => t.deletedAt.isNull() & t.isInbox.equals(true))
          ..orderBy([
            (t) => OrderingTerm(expression: t.pinned, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  /// 笔记库详情页：该笔记库内的笔记
  Stream<List<Note>> watchNotesInNotebook(String notebookId) {
    return (select(notes)
          ..where((t) => t.deletedAt.isNull() & t.notebookId.equals(notebookId))
          ..orderBy([
            (t) => OrderingTerm(expression: t.pinned, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  /// 兼容：全部未删除笔记（不含轻笔记与已归档的区分）
  Stream<List<Note>> watchNotes() {
    return (select(notes)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([
            (t) => OrderingTerm(expression: t.pinned, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  Future<List<Note>> allActiveNotes() {
    return (select(notes)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([
            (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
          ]))
        .get();
  }

  Stream<Note?> watchNote(String id) {
    return (select(notes)..where((t) => t.id.equals(id))).watchSingleOrNull();
  }

  Future<Note?> getNote(String id) {
    return (select(notes)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// 搜索：标题或正文命中。
  ///
  /// 首版用 LIKE。中文全文检索需要 FTS5 + trigram/jieba 分词，列入 v1.1。
  ///
  /// 转义说明：`%` 与 `_` 在 LIKE 里是通配符，用户输入含这两个字符时若不转义，
  /// 搜 "100%" 会变成匹配任意串。SQLite 的 ESCAPE 子句要求显式给出转义符，
  /// 这里用反斜杠。
  ///
  /// 反斜杠用 [String.fromCharCode] 构造，而不是写成「r 前缀 + 单引号 + 反斜杠」：
  /// Dart 的 raw 字符串不能以反斜杠结尾（反斜杠会转义收尾引号），
  /// 那种写法是语法错误。这里是构建期求值，运行期零开销。
  static final _backslash = String.fromCharCode(0x5C);

  Stream<List<Note>> searchNotes(String keyword) {
    final k = _likePattern(keyword);
    return (select(notes)
          ..where((t) =>
              t.deletedAt.isNull() &
              (t.title.like(k, escapeChar: _backslash) |
                  t.content.like(k, escapeChar: _backslash)))
          ..orderBy([
            (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  /// **限定在某个笔记库内**搜索。
  ///
  /// 与 [searchNotes]（全局）分开：笔记库详情页的搜索图标应当只在这个库内找，
  /// 否则用户在一个库里搜却看到别的库的结果，会以为搜索坏了。
  Stream<List<Note>> searchNotesInNotebook(String notebookId, String keyword) {
    final k = _likePattern(keyword);
    return (select(notes)
          ..where((t) =>
              t.deletedAt.isNull() &
              t.notebookId.equals(notebookId) &
              (t.title.like(k, escapeChar: _backslash) |
                  t.content.like(k, escapeChar: _backslash)))
          ..orderBy([
            (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  /// 构造 LIKE 模式串，并转义 `%` 与 `_`。
  ///
  /// 不转义的话搜 "100%" 会变成"匹配任意串"，搜 "_" 会匹配任意单字符。
  String _likePattern(String keyword) {
    final escaped = keyword
        .trim()
        .replaceAll(_backslash, '$_backslash$_backslash')
        .replaceAll('%', '$_backslash%')
        .replaceAll('_', '${_backslash}_');
    return '%$escaped%';
  }

  /// 只按**标题**匹配的笔记（搜索页的「笔记」类）。
  ///
  /// 与 [searchNotes] 分开是因为搜索页要把结果**分两类展示**：
  /// 「笔记」= 标题命中（整篇相关），「笔记内容」= 正文命中（要定位到某一片）。
  /// 合并成一个查询再在内存里分类，等于要读全部正文来判断命中的是哪一类。
  Future<List<Note>> notesWithTitleLike(
    String keyword, {
    List<String>? notebookIds,
    bool includeUnfiled = true,
    int limit = 50,
  }) =>
      _notesLike(
        titleOnly: true,
        keyword: keyword,
        notebookIds: notebookIds,
        includeUnfiled: includeUnfiled,
        limit: limit,
      );

  /// 只按**正文**匹配的笔记（搜索页的「笔记内容」类）。
  ///
  /// [limit] 是**真实的上限**：调用方（`SearchService`）还要为每篇笔记算出
  /// "命中哪一片"，那需要先有切片。命中几千篇时不能每篇都切一遍，所以这里
  /// 先按更新时间取最近的若干篇。
  Future<List<Note>> notesWithContentLike(
    String keyword, {
    List<String>? notebookIds,
    bool includeUnfiled = true,
    int limit = 50,
  }) =>
      _notesLike(
        titleOnly: false,
        keyword: keyword,
        notebookIds: notebookIds,
        includeUnfiled: includeUnfiled,
        limit: limit,
      );

  /// "在哪些笔记库里"的过滤条件。
  ///
  /// [notebookIds] 为 **null = 不限目录**；空列表 = 一个目录都不含
  /// （此时只可能靠 [includeUnfiled] 命中轻笔记）。
  ///
  /// 「轻笔记」= `notebook_id IS NULL`（没有归入任何库）。
  Expression<bool> _scopeOf(List<String>? notebookIds, bool includeUnfiled) {
    if (notebookIds == null) {
      // 不限目录：要么全要，要么只要已归档的（不含轻笔记）
      return includeUnfiled
          ? const Constant(true)
          : notes.notebookId.isNotNull();
    }
    var e = notes.notebookId.isIn(notebookIds);
    if (includeUnfiled) e = e | notes.notebookId.isNull();
    return e;
  }

  /// 只要 **id / 标题 / 所属库 / 修改时间** 的笔记列表（`askUser` 现查选项时用它）。
  ///
  /// 用 `selectOnly` 而不是 `select`：给 AI 当选项时只要几个短字段，
  /// 读整行会把每篇笔记的正文都取出来 —— **那就得真的省**。
  /// 读整行会把每篇笔记的正文都取出来，几百篇就是几百 KB，
  /// 只为了拿几个短字段。
  ///
  /// 排序是 `updatedAt DESC`（最近改过的在前）：AI 说"我最近写的那篇"时，
  /// 它只看得见顺序，看不见时间戳之外的线索 —— 顺序本身就是信息。
  /// `updatedAt` 也一并返回，好让它能说清"那篇是几天前的"。
  Future<
      List<
          ({
            String id,
            String title,
            String? notebookId,
            DateTime updatedAt,
          })>> noteBriefs({
    List<String>? notebookIds,
    bool includeUnfiled = true,
    int limit = 50,
  }) async {
    final q = selectOnly(notes)
      ..addColumns([notes.id, notes.title, notes.notebookId, notes.updatedAt])
      ..where(notes.deletedAt.isNull() &
          _scopeOf(notebookIds, includeUnfiled))
      ..orderBy([
        OrderingTerm(expression: notes.updatedAt, mode: OrderingMode.desc),
      ])
      ..limit(limit);
    final rows = await q.get();
    return [
      for (final r in rows)
        (
          id: r.read(notes.id) ?? '',
          title: r.read(notes.title) ?? '',
          notebookId: r.read(notes.notebookId),
          // updatedAt 是非空列，读出来不可能是 null；兜底只是为了不写 `!`
          updatedAt: r.read(notes.updatedAt) ?? DateTime.fromMillisecondsSinceEpoch(0),
        ),
    ];
  }



  Future<List<Note>> _notesLike({
    required bool titleOnly,
    required String keyword,
    required List<String>? notebookIds,
    required bool includeUnfiled,
    required int limit,
  }) {
    final k = _likePattern(keyword);
    final q = select(notes)
      ..where((t) {
        final hit = titleOnly
            ? t.title.like(k, escapeChar: _backslash)
            : t.content.like(k, escapeChar: _backslash);
        return t.deletedAt.isNull() &
            hit &
            _scopeOf(notebookIds, includeUnfiled);
      })
      ..orderBy([
        (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
      ])
      ..limit(limit);
    return q.get();
  }

  Future<void> upsertNote(NotesCompanion entry) {
    return into(notes).insertOnConflictUpdate(entry);
  }

  // ==========================================================================
  // 卡片流（轻笔记）的素材查询
  //
  // 卡片流的内容是 AI 从素材里**新生成**的，不是已有笔记的视图。
  // 所以这里只需要"取素材"，不再需要原来那套笔记消费状态
  // （到期时间 / 间隔天数 / 难度因子 / 收藏）——那是为"复习已有笔记"
  // 设计的，卡片换成 AI 新内容之后就不适用了。
  //
  // 已删除的旧方法（连同 note_feed_state 表的使用）：
  //   getFeedState / feedStatesFor / upsertFeedState / deleteFeedState
  //   newFeedCandidates / dueFeedCandidates
  //   recordFeedShown / recordFeedOpened / markFeedNotInterested
  //   setFeedStarred / countFeedStates / latestSummaryOneLiners
  //
  // 那张 `note_feed_state` 表本身也已在 **v8 删除**（连同 idx_feed_due /
  // idx_feed_starred 两条索引），这一段只留作历史说明。
  // ==========================================================================

  /// 随机取卡片流的素材笔记。
  ///
  /// [notebookIds] 为用户勾选的笔记库；[includeUnfiled] 为是否带上
  /// 未归档的「我的轻笔记」。只取正文非空的——空笔记当素材没意义。
  ///
  /// **为什么随机**：每次都用同样几条素材拼 prompt，生成的卡片会高度雷同。
  ///
  /// **为什么走 `customSelect`**：drift 的类型化 `orderBy` 只接受列表达式，
  /// 而随机排序要 `ORDER BY RANDOM()`（一个函数）。`LIMIT` 很小（默认 8），
  /// 全表扫描的代价可以接受。
  Future<List<Note>> notesForFeed({
    required List<String> notebookIds,
    required bool includeUnfiled,
    int limit = 8,
  }) async {
    final hasNotebooks = notebookIds.isNotEmpty;
    if (!hasNotebooks && !includeUnfiled) return const [];

    final clauses = <String>['deleted_at IS NULL', "content != ''"];
    final vars = <Variable<Object>>[];

    if (includeUnfiled && hasNotebooks) {
      final ph = List.filled(notebookIds.length, '?').join(',');
      clauses.add('(notebook_id IN ($ph) OR is_inbox = 1)');
      vars.addAll(notebookIds.map(Variable<String>.new));
    } else if (includeUnfiled) {
      clauses.add('is_inbox = 1');
    } else {
      final ph = List.filled(notebookIds.length, '?').join(',');
      clauses.add('notebook_id IN ($ph)');
      vars.addAll(notebookIds.map(Variable<String>.new));
    }

    final sql = 'SELECT * FROM notes WHERE ${clauses.join(' AND ')} '
        'ORDER BY RANDOM() LIMIT $limit';
    final rows = await customSelect(sql, variables: vars, readsFrom: {notes}).get();
    return rows.map((r) => notes.map(r.data)).toList(growable: false);
  }


  /// 逻辑删除：保留数据，可做回收站与增量同步
  Future<void> softDeleteNote(String id) {
    return (update(notes)..where((t) => t.id.equals(id))).write(
      NotesCompanion(
        deletedAt: Value(DateTime.now().toUtc()),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  /// 撤销逻辑删除。
  ///
  /// 左滑删除走的是"乐观删除 + 撤销"（见 [SwipeToDelete] 的说明），
  /// 所以必须有恢复入口。逻辑删除的好处正在这里：`deletedAt` 清空即可，
  /// 笔记内容与关联（卡片流摘要）都还在。
  Future<void> restoreNote(String id) {
    return (update(notes)..where((t) => t.id.equals(id))).write(
      NotesCompanion(
        deletedAt: const Value(null),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  Future<void> setPinned(String id, bool pinned) {
    return (update(notes)..where((t) => t.id.equals(id))).write(
      NotesCompanion(
        pinned: Value(pinned),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  /// 轻笔记 → 笔记库：指定笔记库即完成归档。
  /// 传 null 表示「移出笔记库，回到我的轻笔记」。
  Future<void> moveNoteToNotebook(String noteId, String? notebookId) {
    return (update(notes)..where((t) => t.id.equals(noteId))).write(
      NotesCompanion(notebookId: Value(notebookId),
        isInbox: Value(notebookId == null),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  // ==========================================================================
  // AI 结果与审计
  // ==========================================================================

  Future<void> markNoteAiDone(String noteId) {
    return (update(notes)..where((t) => t.id.equals(noteId))).write(
      NotesCompanion(lastAiAt: Value(DateTime.now().toUtc())),
    );
  }

  Future<void> insertAiCall(AiCallsCompanion entry) {
    return into(aiCalls).insert(entry);
  }

  /// 设置页展示累计成本（分）
  Stream<double> watchTotalCostCents() {
    final total = aiCalls.costCents.sum();
    return (selectOnly(aiCalls)..addColumns([total]))
        .watchSingle()
        .map((row) => row.read(total) ?? 0.0);
  }

  /// 清空 AI 调用审计。
  ///
  /// 只清 `ai_calls`。「AI 整理要点」的 `note_summaries` 已随功能一起删除，
  /// 没有别的表要动。
  Future<void> clearAiHistory() => delete(aiCalls).go();

  // ==========================================================================
  // AI 会话（见《数据库设计》的「ai_conversations / ai_messages」一节）
  // ==========================================================================

  /// 会话列表：按最近活动倒序，**且只列有消息的**。
  ///
  /// 一条消息都没有的会话，用户点进去也看不到任何东西，却因为时间戳最新而排在
  /// 列表最前面、还会被"打开上次的会话"选中 —— 一进来看到的是空白。它们是
  /// "点一下新建就在库里落一行"留下的空壳（现在新建不再落库，见
  /// `AiPage._newConversation` 的说明）。
  ///
  /// 这里**只是不显示，不删行**：删除是破坏性动作（本项目的规矩是先问再做），
  /// 而这个列表本来就是"给用户挑会话"的视图，空会话不构成一个可挑的东西。
  ///
  /// 用 `EXISTS` 子查询而不是"先查会话、再逐个查消息"：
  /// 后者是 N+1 次查询，会话一多就明显。
  Stream<List<AiConversation>> watchConversations() {
    final hasMessages = existsQuery(
      select(aiMessages)
        ..where((m) => m.conversationId.equalsExp(aiConversations.id)),
    );
    return (select(aiConversations)
          ..where((t) => hasMessages)
          ..orderBy([
            (t) => OrderingTerm(
                expression: t.updatedAt, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  Future<AiConversation?> getConversation(String id) {
    return (select(aiConversations)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  Stream<List<AiMessage>> watchMessages(String conversationId) {
    return (select(aiMessages)
          ..where((t) => t.conversationId.equals(conversationId))
          ..orderBy([(t) => OrderingTerm(expression: t.createdAt)]))
        .watch();
  }

  Future<void> upsertConversation(AiConversationsCompanion entry) {
    return into(aiConversations).insertOnConflictUpdate(entry);
  }

  Future<void> touchConversation(String id, {String? title}) {
    return (update(aiConversations)..where((t) => t.id.equals(id))).write(
      AiConversationsCompanion(
        updatedAt: Value(DateTime.now().toUtc()),
        title: title == null ? const Value.absent() : Value(title),
      ),
    );
  }

  Future<void> deleteConversation(String id) {
    return (delete(aiConversations)..where((t) => t.id.equals(id))).go();
  }

  /// 一次删多条会话（会话记录页的「多选 → 删除」）。
  ///
  /// 一条 `WHERE id IN (...)` 而不是循环调用 [deleteConversation]：
  /// 循环是 N 次独立语句，中途失败就只删了一半，而调用方以为全删了。
  /// 消息由外键 `ON DELETE CASCADE` 跟着走（`beforeOpen` 里开了 `foreign_keys`）。
  Future<void> deleteConversations(List<String> ids) {
    if (ids.isEmpty) return Future.value();
    return (delete(aiConversations)..where((t) => t.id.isIn(ids))).go();
  }

  Future<void> insertAiMessage(AiMessagesCompanion entry) {
    return into(aiMessages).insert(entry);
  }

  Future<void> updateAiMessage(String id, String content) {
    return (update(aiMessages)..where((t) => t.id.equals(id))).write(
      AiMessagesCompanion(content: Value(content)),
    );
  }

  /// 写入/清除某条消息的**挂起动作**（`ai_messages.pendingAction`）。
  ///
  /// 这一列项目里早就有、至今零引用。`askUser` 的"持久化挂起"正需要它：
  /// 把"等你回答"写进**数据库**而不是内存，于是用户三小时后回答、
  /// 甚至重启 App 之后回答，都能从这条记录接着跑。
  ///
  /// [json] 传 null 表示清掉挂起（用户已答 / 主动取消整个对话）。
  Future<void> setPendingAction(String messageId, String? json) {
    return (update(aiMessages)..where((t) => t.id.equals(messageId)))
        .write(AiMessagesCompanion(pendingAction: Value(json)));
  }

  /// 按 id 取一条 AI 消息（回答挂起后要继续写同一条，得先读它现在的内容）。
  Future<AiMessage?> aiMessageById(String id) {
    return (select(aiMessages)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// 找出某个会话里**正在等回答**的那条消息（没有就返回 null）。
  /// 从数据库找而不是从内存找，正是"杀掉 App 重开还能继续回答"的实现方式：
  /// 挂起状态本来就是持久化的，冷启动后照样能恢复。
  Future<AiMessage?> pendingAskMessage(String conversationId) {
    return (select(aiMessages)
          ..where((t) =>
              t.conversationId.equals(conversationId) &
              t.pendingAction.isNotNull())
          ..orderBy([(t) => OrderingTerm(expression: t.createdAt)])..limit(1))
        .getSingleOrNull();
  }

  // ==========================================================================
  // app_kv（key-value）
  // ==========================================================================

  Future<String?> readSetting(String key) async {
    final row = await (select(appKv)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Stream<String?> watchSetting(String key) {
    return (select(appKv)..where((t) => t.key.equals(key)))
        .watchSingleOrNull()
        .map((row) => row?.value);
  }

  Future<void> writeSetting(String key, String value) {
    return into(appKv).insertOnConflictUpdate(
      AppKvCompanion.insert(key: key, value: value),
    );
  }

  Future<void> deleteSetting(String key) {
    return (delete(appKv)..where((t) => t.key.equals(key))).go();
  }

  // ==========================================================================
  // 笔记切片（note_chunks）
  //
  // 只存"原文的哪一段"（偏移），**不存正文**：读片时从 `notes.content` 现取，
  // 于是永远和正文一致。代价是正文改了偏移会失效 —— 由 `contentHash` 检出、
  // 由 `NoteChunkRepository` 当场重切（自愈）。
  //
  // 这一层**只碰数据库**：切片器（`NoteChunker`）与领域类型（`NoteChunk`）
  // 都在 `features/note/` 下，`core/` 不能反向依赖它们，所以这里收的是
  // 现成的 `NoteChunksCompanion`。
  // ==========================================================================

  /// 换掉某篇笔记的全部切片：**先删后插，同一个事务**。
  ///
  /// 事务是必须的：分两步做的话，中间那一瞬读到的会是"旧片已删、新片没插"的
  /// 空表，搜索/卡片流刚好撞上就会以为这篇笔记没内容。
  Future<void> replaceNoteChunks(
    String noteId,
    List<NoteChunksCompanion> rows,
  ) {
    return transaction(() async {
      await (delete(noteChunks)..where((t) => t.noteId.equals(noteId))).go();
      if (rows.isEmpty) return;
      await batch((b) => b.insertAll(noteChunks, rows));
    });
  }

  /// 某篇笔记的切片，按 [NoteChunks.idx] 升序。
  Future<List<NoteChunkRow>> chunksOf(String noteId) {
    return (select(noteChunks)
          ..where((t) => t.noteId.equals(noteId))
          ..orderBy([(t) => OrderingTerm(expression: t.idx)]))
        .get();
  }

  /// 某篇笔记有几片。
  ///
  /// **懒回填的判据**：0 片 = 还没切过（老库升级上来的笔记就是这样），
  /// 调到 0 就当场切一遍写回。
  Future<int> chunkCount(String noteId) async {
    final c = countAll();
    final q = selectOnly(noteChunks)
      ..addColumns([c])
      ..where(noteChunks.noteId.equals(noteId));
    final row = await q.getSingle();
    return row.read(c) ?? 0;
  }

  /// 取某一片。没有返回 null（调用方据此触发重切）。
  Future<NoteChunkRow?> chunkAt(String noteId, int idx) {
    return (select(noteChunks)
          ..where((t) => t.noteId.equals(noteId) & t.idx.equals(idx)))
        .getSingleOrNull();
  }

  /// 记一次「这片被卡片流用掉了」，并把窗口轮换位推进到 [nextWindowStart]。
  Future<void> markChunkUsed(
    String noteId,
    int idx, {
    required DateTime at,
    required int nextWindowStart,
  }) {
    return (update(noteChunks)
          ..where((t) => t.noteId.equals(noteId) & t.idx.equals(idx)))
        .write(NoteChunksCompanion(
      lastUsedAt: Value(at),
      nextWindowStart: Value(nextWindowStart),
    ));
  }

  /// 还没切过片的笔记 id（删掉的笔记不算）。
  ///
  /// 给"后台慢慢补切片"用：不做成全量回填是因为**几万条笔记会在升级那一刻
  /// 卡住启动**，而且中断了只补一半、很难判断谁补过谁没补。
  Future<List<String>> noteIdsWithoutChunks({int limit = 50}) {
    return customSelect(
      'SELECT n.id AS id FROM notes n '
      'LEFT JOIN note_chunks c ON c.note_id = n.id '
      'WHERE n.deleted_at IS NULL AND c.note_id IS NULL '
      'LIMIT ?',
      variables: [Variable<int>(limit)],
      readsFrom: {notes, noteChunks},
    ).map((r) => r.read<String>('id')).get();
  }

  // ==========================================================================
  // 轻笔记的跨启动预留（feed_reserve）
  //
  // 语义：几张"已经生成好、留给下次打开先看"的卡片。
  // 取出即清（消费掉），写入即替换（只保留最近一批）。
  //
  // **注意它只决定"进来时先拿哪 6 张"**，不参与列表的增删——
  // 列表行为在 UI 层（`InboxPage._loadBatch`：首次替换、下拉前向追加）。
  // ==========================================================================

  /// 取出全部预留（按 position 顺序）并**立刻清空表**。
  ///
  /// 取与清在**同一个事务**里：否则两个并发取用可能都拿到同一批
  /// （读到之后、删除之前），导致同一张卡片被展示两次。
  Future<List<FeedDraft>> takeFeedReserve() async {
    return transaction(() async {
      final rows = await (select(feedReserve)
            ..orderBy([(t) => OrderingTerm.asc(t.position)]))
          .get();

      if (rows.isNotEmpty) {
        await delete(feedReserve).go();
      }

      final out = <FeedDraft>[];
      for (final r in rows) {
        final d = FeedDraft(
          title: r.title,
          body: r.body,
          tag: _decodeTag(r.tags),
        );
        if (d.isValid) out.add(d);
      }
      return out;
    });
  }

  /// 用 [drafts] **替换**整张预留表。
  ///
  /// 替换而不是追加：语义是"最近一批留给下次的"，累积起来会让下次打开
  /// 看到一堆旧内容。
  Future<void> replaceFeedReserve(List<FeedDraft> drafts) async {
    await transaction(() async {
      await delete(feedReserve).go();
      if (drafts.isEmpty) return;

      final now = DateTime.now().toUtc();
      const uuid = Uuid();
      for (var i = 0; i < drafts.length; i++) {
        final d = drafts[i];
        await into(feedReserve).insert(
          FeedReserveCompanion.insert(
            id: uuid.v4(),
            title: d.title,
            body: d.body,
            // 列名仍叫 `tags`、存的也仍是 JSON 数组，但里面**只有那一个**标签
            // —— 列名是历史遗留，不代表一次能生成多个（见 `_decodeTag`）。
            tags: Value(jsonEncode([d.tag])),
            position: i,
            createdAt: now,
          ),
        );
      }
    });
  }

  /// 预留里有几张（测试与诊断用）。
  Future<int> feedReserveCount() async {
    final c = countAll();
    final row = await (selectOnly(feedReserve)..addColumns([c])).getSingle();
    return row.read(c) ?? 0;
  }

  /// 标签解析：列里存的是 JSON 数组（历史格式），但**取第一个**就是那唯一的标签。
  /// 损坏就当空串，不让它把页面搞崩。
  static String _decodeTag(String raw) {
    if (raw.isEmpty) return '';
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final e in decoded) {
          final s = e.toString().trim();
          if (s.isNotEmpty) return s;
        }
      }
    } catch (_) {
      // 忽略：标签只是锦上添花
    }
    return '';
  }

}

/// 当前数据库文件。
///
/// 顶层变量而不是 `AppDatabase` 的静态字段：写它的是 [_openConnection]
/// （一个顶层函数），读它的是 `AppDatabase.databasePath`。
/// 放在顶层，两边引用的是同一个东西。
File? _activeDbFile;

/// 打开数据库连接。
///
/// 关键点：用 `NativeDatabase`（基于 dart:ffi）而不是 `SqfliteQueryExecutor`，
/// 这样 **同一份代码同时跑 Android 和 Windows 桌面调试**，无需条件分支。
/// 自 drift 2.32 / sqlite3 3.x 起，SQLite 原生库由 build hooks 自动打包，
/// 不再需要依赖 `sqlite3_flutter_libs`。
///
/// 目录解析交给 [DatabaseLocation]：
/// **默认放 App 私有目录**，用户可以在设置里改成自己的工作目录。
/// 这里只负责拿目录、记录实际路径、开连接。
LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await DatabaseLocation.resolveDirectory();

    // Android 上系统临时目录对 SQLite 不可用，复杂查询会 OOM。
    // 官方文档明确要求：打开数据库前告知临时目录位置。
    if (Platform.isAndroid) {
      try {
        final tmp = Directory.systemTemp;
        if (tmp.existsSync()) sqlite3.tempDirectory = tmp.path;
      } catch (_) {
        // 拿不到临时目录不致命：SQLite 会退回系统默认值，
        // 极端复杂查询才可能受影响，不值得让 App 起不来。
      }
    }

    final file = File(DatabaseLocation.dbPathIn(dir));
    _activeDbFile = file;

    final note = DatabaseLocation.lastFallbackNote;
    if (note != null) {
      // 发生降级必须留下痕迹：用户以为数据在新位置、实际还在私有目录，
      // 这是最容易导致"我的笔记不见了"的一类问题。
      // ignore: avoid_print
      print('[LightNote] 数据库位置降级：$note\n  实际使用：${file.path}');
    }

    // 不在这里设 PRAGMA journal_mode=WAL：WAL 是持久化设置，
    // 而切换 journal mode 需要独占锁，放在每次连接都会跑的 setup 回调里
    // 可能与并发连接冲突。默认的 rollback journal 对本 App 的读写量足够。
    // 连接交给背景 isolate（drift 的默认实现），但要把 **UDF 装上去**：
    // AI 的全部写操作都是「调用一个函数」，函数体是 Dart（见 core/db/ai_udfs.dart），
    // 所以必须在开库时把它注册到这条连接上，之后 SQLite 按名字查表调用。
    //
    // ⚠️ setup 回调在**背景 isolate** 里执行，所以 installAiUdfs 只能是顶层函数，
    // 不能闭包捕获主 isolate 的对象（Dart 不允许那样跨 isolate 传）。
    // 若本地 drift 的 createInBackground 没有 setup 参数（编译报错），
    // 换成 NativeDatabase(file, setup: installAiUdfs) 即可 —— UDF 注册代码不用动，
    // 代价只是所有查询回到主 isolate 跑。
    return NativeDatabase.createInBackground(file, setup: installAiUdfs);
  });
}
