// schemaVersion 1 → 2 迁移测试。
//
// 这一条测试价值最高，因为 v2 的迁移里**带了数据修正**（一条 UPDATE），
// 写错就是丢数据：
//
//   v1 期间 NoteRepository.createLibrary() 写的是
//   `isInbox = false, notebookId = null`——一条"已归档但没目录"的笔记。
//   v2 把「轻笔记」区块改成按 is_inbox 筛选后，这类笔记既不在任何目录下、
//   也不满足 is_inbox = true，**两个入口都看不到**。
//   迁移必须把它们改成 is_inbox = 1。
//
// 做法：手工造一个 v1 形态的库（真实文件，不是内存库——迁移只在打开
// 已存在的文件时触发），塞进各类笔记，再用当前的 AppDatabase 打开它，
// 验证升级结果。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'package:lightnote/core/db/ai_functions.dart';
import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/core/db/database_location.dart';

/// v1 的 notes 表结构（字段名与顺序照抄 v1 生成的 DDL）
const _v1NotesDdl = '''
CREATE TABLE "notes" (
  "id" TEXT NOT NULL,
  "folder_id" TEXT NULL REFERENCES folders (id) ON DELETE SET NULL,
  "title" TEXT NOT NULL DEFAULT '',
  "content" TEXT NOT NULL DEFAULT '',
  "excerpt" TEXT NOT NULL DEFAULT '',
  "source" TEXT NOT NULL DEFAULT 'local',
  "is_inbox" INTEGER NOT NULL DEFAULT 0 CHECK ("is_inbox" IN (0, 1)),
  "pinned" INTEGER NOT NULL DEFAULT 0 CHECK ("pinned" IN (0, 1)),
  "word_count" INTEGER NOT NULL DEFAULT 0,
  "last_ai_at" INTEGER NULL,
  "created_at" INTEGER NOT NULL,
  "updated_at" INTEGER NOT NULL,
  "deleted_at" INTEGER NULL,
  PRIMARY KEY ("id")
)
''';

/// v1 的 folders 表结构。
///
/// 注意这里**必须叫 folders、必须有 parent_id**：迁移测试要模拟真实老库，
/// 表名与列名都不能提前变成新名字，否则测的就不是迁移了。
/// （曾经被批量重命名脚本误改成 notebooks，导致迁移测试建出错误的库。）
const _v1FoldersDdl = '''
CREATE TABLE "folders" (
  "id" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "parent_id" TEXT NULL REFERENCES folders (id) ON DELETE SET NULL,
  "sort_order" INTEGER NOT NULL DEFAULT 0,
  "created_at" INTEGER NOT NULL,
  "updated_at" INTEGER NOT NULL,
  "deleted_at" INTEGER NULL,
  PRIMARY KEY ("id")
)
''';

/// v2 迁移建出来的 `note_feed_state`（笔记消费流状态，v8 已删除）。
///
/// **它不是 v1 的原生表**，写在这里是为了让 v8 的 `DROP TABLE` 真的作用到
/// 东西——否则那两条删表语句在测试里是空转，"v8 删掉了这两张表"的断言
/// 也就没有意义（表本来就存在与否都能过）。
const _v2FeedStateDdl = '''
CREATE TABLE "note_feed_state" (
  "note_id" TEXT NOT NULL REFERENCES notes (id) ON DELETE CASCADE,
  "due_at" INTEGER NOT NULL,
  "interval_days" INTEGER NOT NULL DEFAULT 0,
  "ease" REAL NOT NULL DEFAULT 2.5,
  "repetitions" INTEGER NOT NULL DEFAULT 0,
  "lapses" INTEGER NOT NULL DEFAULT 0,
  "shown_count" INTEGER NOT NULL DEFAULT 0,
  "opened_count" INTEGER NOT NULL DEFAULT 0,
  "last_shown_at" INTEGER NULL,
  "last_opened_at" INTEGER NULL,
  "starred" INTEGER NOT NULL DEFAULT 0,
  "created_at" INTEGER NOT NULL,
  "updated_at" INTEGER NOT NULL,
  PRIMARY KEY ("note_id")
)
''';

/// v4 迁移建出来的 `note_ai_tags`（每篇笔记的 AI 标签，v8 已删除）。
///
/// 同上：写进 v1 脚本是为了让 v8 的删表可测。
const _v4AiTagsDdl = '''
CREATE TABLE "note_ai_tags" (
  "note_id" TEXT NOT NULL REFERENCES notes (id) ON DELETE CASCADE,
  "tags" TEXT NOT NULL DEFAULT '[]',
  "model" TEXT NOT NULL DEFAULT '',
  "source_bytes" INTEGER NOT NULL DEFAULT 0,
  "created_at" INTEGER NOT NULL,
  "updated_at" INTEGER NOT NULL,
  PRIMARY KEY ("note_id")
)
''';

const _v1SettingsDdl = '''
CREATE TABLE "settings" (
  "key" TEXT NOT NULL,
  "value" TEXT NOT NULL,
  PRIMARY KEY ("key")
)
''';

/// v1 的 `tags` / `note_tags`（用户手动标签，**v9 已删除**）。
///
/// 和 `note_feed_state` / `note_ai_tags` 一样：**必须在这里建出来**，
/// 否则 v9 的 `DROP TABLE` 是空转，"删掉了"的断言也就没有意义。
const _v1ManualTagsDdl = [
  '''
  CREATE TABLE "tags" (
    "id" TEXT NOT NULL, "name" TEXT NOT NULL,
    "normalized_name" TEXT NOT NULL UNIQUE, "color_value" INTEGER NULL,
    "usage_count" INTEGER NOT NULL DEFAULT 0, "created_at" INTEGER NOT NULL,
    PRIMARY KEY ("id")
  )
  ''',
  '''
  CREATE TABLE "note_tags" (
    "note_id" TEXT NOT NULL REFERENCES notes (id) ON DELETE CASCADE,
    "tag_id" TEXT NOT NULL REFERENCES tags (id) ON DELETE CASCADE,
    "created_at" INTEGER NOT NULL,
    PRIMARY KEY ("note_id", "tag_id")
  )
  ''',
];

/// v1 里存在、但迁移测试的种子数据里不直接写入的那些表。
///
/// **必须建出来**：drift 的 `Migrator.createAll()` 只创建"尚不存在"的表，
/// 已有的会跳过。而迁移末尾会调用 `_createIndexes()`，那条语句要给
/// `ai_messages` 建索引——表不存在就会整个迁移失败。
///
/// 这块原先漏了，表现为"全新库（无 v1 文件）走 onCreate"和
/// "迁移不动正常数据"两条测试失败。
const _v1OtherTablesDdl = [
  '''
  CREATE TABLE "card_decks" (
    "id" TEXT NOT NULL, "name" TEXT NOT NULL, "description" TEXT NULL,
    "created_at" INTEGER NOT NULL, "updated_at" INTEGER NOT NULL,
    PRIMARY KEY ("id")
  )
  ''',
  '''
  CREATE TABLE "cards" (
    "id" TEXT NOT NULL,
    "note_id" TEXT NULL REFERENCES notes (id) ON DELETE CASCADE,
    "deck_id" TEXT NULL REFERENCES card_decks (id) ON DELETE SET NULL,
    "question" TEXT NOT NULL, "answer" TEXT NOT NULL,
    "source" TEXT NOT NULL DEFAULT 'manual', "ai_model" TEXT NULL,
    "tags" TEXT NULL, "due_at" INTEGER NOT NULL,
    "interval_days" INTEGER NOT NULL DEFAULT 0,
    "ease" REAL NOT NULL DEFAULT 2.5,
    "repetitions" INTEGER NOT NULL DEFAULT 0,
    "lapses" INTEGER NOT NULL DEFAULT 0, "last_reviewed_at" INTEGER NULL,
    "review_count" INTEGER NOT NULL DEFAULT 0,
    "suspended" INTEGER NOT NULL DEFAULT 0,
    "stability" REAL NOT NULL DEFAULT 0, "difficulty" REAL NOT NULL DEFAULT 0,
    "created_at" INTEGER NOT NULL, "updated_at" INTEGER NOT NULL,
    "deleted_at" INTEGER NULL, PRIMARY KEY ("id")
  )
  ''',
  '''
  CREATE TABLE "reviews" (
    "id" TEXT NOT NULL,
    "card_id" TEXT NOT NULL REFERENCES cards (id) ON DELETE CASCADE,
    "quality" INTEGER NOT NULL, "ease_before" REAL NOT NULL,
    "ease_after" REAL NOT NULL, "interval_before" INTEGER NOT NULL,
    "interval_after" INTEGER NOT NULL,
    "elapsed_ms" INTEGER NOT NULL DEFAULT 0, "reviewed_at" INTEGER NOT NULL,
    PRIMARY KEY ("id")
  )
  ''',
  '''
  CREATE TABLE "note_summaries" (
    "id" TEXT NOT NULL,
    "note_id" TEXT NOT NULL REFERENCES notes (id) ON DELETE CASCADE,
    "model" TEXT NOT NULL, "one_line" TEXT NOT NULL DEFAULT '',
    "bullets" TEXT NOT NULL DEFAULT '[]',
    "suggested_tags" TEXT NOT NULL DEFAULT '[]',
    "action_items" TEXT NOT NULL DEFAULT '[]',
    "raw_response" TEXT NULL,
    "prompt_tokens" INTEGER NOT NULL DEFAULT 0,
    "completion_tokens" INTEGER NOT NULL DEFAULT 0,
    "cost_cents" REAL NOT NULL DEFAULT 0, "created_at" INTEGER NOT NULL,
    PRIMARY KEY ("id")
  )
  ''',
  '''
  CREATE TABLE "ai_calls" (
    "id" TEXT NOT NULL, "note_id" TEXT NULL, "task" TEXT NOT NULL,
    "model" TEXT NOT NULL, "thinking_enabled" INTEGER NOT NULL DEFAULT 0,
    "prompt_tokens" INTEGER NOT NULL DEFAULT 0,
    "completion_tokens" INTEGER NOT NULL DEFAULT 0,
    "cost_cents" REAL NOT NULL DEFAULT 0,
    "latency_ms" INTEGER NOT NULL DEFAULT 0,
    "success" INTEGER NOT NULL DEFAULT 1, "error_code" TEXT NULL,
    "created_at" INTEGER NOT NULL, PRIMARY KEY ("id")
  )
  ''',
  '''
  CREATE TABLE "ai_conversations" (
    "id" TEXT NOT NULL,
    "workspace_folder_id" TEXT NULL REFERENCES folders (id) ON DELETE SET NULL,
    "thinking_effort" TEXT NOT NULL DEFAULT 'medium',
    "title" TEXT NOT NULL DEFAULT '',
    "created_at" INTEGER NOT NULL, "updated_at" INTEGER NOT NULL,
    PRIMARY KEY ("id")
  )
  ''',
  '''
  CREATE TABLE "ai_messages" (
    "id" TEXT NOT NULL,
    "conversation_id" TEXT NOT NULL
      REFERENCES ai_conversations (id) ON DELETE CASCADE,
    "role" TEXT NOT NULL, "content" TEXT NOT NULL DEFAULT '',
    "pending_action" TEXT NULL, "created_at" INTEGER NOT NULL,
    PRIMARY KEY ("id")
  )
  ''',
  // v1 时代的死表（AI 能力清单）。**必须在这里建出来**：v13 要 DROP 它，
  // 建不出来那一步就是空转，「换掉了」的断言也就没有意义。
  //（真实的老库里它一直存在 —— 它是 createAll 建的，只是从没被写过一行。）
  '''
  CREATE TABLE "ai_capabilities" (
    "name" TEXT NOT NULL, "category" TEXT NOT NULL, "one_line" TEXT NOT NULL,
    "signature" TEXT NULL, "description" TEXT NULL, "example_sql" TEXT NULL,
    "sort_order" INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY ("name")
  )
  ''',
];

void main() {
  late Directory tmp;
  late String dbPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('lightnote_mig_');
    dbPath = p.join(tmp.path, kDatabaseFileName);
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 造一个 v1 形态的库，并写入 [rows]（每项是 notes 的一行）。
  void seedV1(List<Map<String, Object?>> rows) {
    final raw = sqlite.sqlite3.open(dbPath);
    try {
      raw.execute('PRAGMA foreign_keys = ON');
      raw.execute(_v1FoldersDdl);
      raw.execute(_v1NotesDdl);
      raw.execute(_v1SettingsDdl);
      for (final ddl in _v1OtherTablesDdl) {
        raw.execute(ddl);
      }
      // 两张"后来才建、又被后来删掉"的表：显式建出来，让 v8 的 DROP 有东西可删
      raw.execute(_v2FeedStateDdl);
      raw.execute(_v4AiTagsDdl);
      // 用户手动标签的两张表：v9 要删它们，同样得先建出来
      for (final ddl in _v1ManualTagsDdl) {
        raw.execute(ddl);
      }
      // 只建迁移会用到的那张之外的必要索引；drift 的 onUpgrade 会补其余

      for (final r in rows) {
        raw.execute(
          'INSERT INTO notes '
          '(id, folder_id, title, content, excerpt, source, is_inbox, pinned, '
          ' word_count, created_at, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?)',
          [
            r['id'],
            r['folder_id'],
            r['title'] ?? '',
            r['content'] ?? '',
            '',
            'local',
            r['is_inbox'],
            r['ts'],
            r['ts'],
          ],
        );
      }
      // v1 的版本号
      raw.execute('PRAGMA user_version = 1');
    } finally {
      raw.close();
    }
  }

  AppDatabase openCurrent() => AppDatabase.forTesting(NativeDatabase(File(dbPath)));

  test('v1 库能被升级到当前版本，且笔记一条不少', () async {
    final t = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    seedV1([
      {'id': 'inboxed', 'folder_id': null, 'is_inbox': 1, 'ts': t, 'title': 'A'},
      {'id': 'filed', 'folder_id': null, 'is_inbox': 0, 'ts': t, 'title': 'B'},
      {'id': 'orphan', 'folder_id': null, 'is_inbox': 0, 'ts': t, 'title': 'C'},
    ]);

    final db = openCurrent();
    addTearDown(db.close);

    final all = await db.allActiveNotes();
    expect(all.length, 3, reason: '升级不能弄丢任何笔记');
    expect(await db.getNote('inboxed'), isNotNull);
    expect(await db.getNote('filed'), isNotNull);
    expect(await db.getNote('orphan'), isNotNull);
  });

  test('迁移把 isInbox=false 且无目录的笔记修正为未归档（关键）', () async {
    final t = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    seedV1([
      // v1 的 createLibrary() 产物：已归档但没目录
      {'id': 'orphan', 'folder_id': null, 'is_inbox': 0, 'ts': t, 'title': '孤儿'},
    ]);

    final db = openCurrent();
    addTearDown(db.close);

    final note = await db.getNote('orphan');
    expect(note, isNotNull);
    expect(
      note!.isInbox,
      isTrue,
      reason: '不修正的话，这条笔记在两个入口都看不到，等于丢失',
    );

    // 修正后应当出现在「轻笔记」区块
    final unfiled = await db.watchUnfiledNotes().first;
    expect(unfiled.map((n) => n.id), contains('orphan'));
  });

  test('迁移不动正常数据', () async {
    final t = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final raw = sqlite.sqlite3.open(dbPath);
    // notebooks 表要先有行，folder_id 外键才成立
    raw.execute(_v1FoldersDdl);
    raw.execute(_v1NotesDdl);
    raw.execute(_v1SettingsDdl);
    for (final ddl in _v1OtherTablesDdl) {
      raw.execute(ddl);
    }
    raw.execute(
      'INSERT INTO folders (id, name, sort_order, created_at, updated_at) '
      'VALUES (?, ?, 0, ?, ?)',
      ['f1', '工作', t, t],
    );
    raw.execute(
      'INSERT INTO notes (id, folder_id, title, content, excerpt, source, '
      'is_inbox, pinned, word_count, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?)',
      ['filed', 'f1', '已归档', '正文', '', 'local', 0, t, t],
    );
    raw.execute(
      'INSERT INTO notes (id, folder_id, title, content, excerpt, source, '
      'is_inbox, pinned, word_count, created_at, updated_at) '
      'VALUES (?, NULL, ?, ?, ?, ?, ?, 0, 0, ?, ?)',
      ['inboxed', '未归档', '正文', '', 'local', 1, t, t],
    );
    raw.execute('PRAGMA user_version = 1');
    raw.close();

    final db = openCurrent();
    addTearDown(db.close);

    // 已归档到目录的：不该被改成未归档
    final filed = await db.getNote('filed');
    expect(filed!.isInbox, isFalse);
    expect(filed.notebookId, 'f1');

    // 本来就未归档的：保持
    final inboxed = await db.getNote('inboxed');
    expect(inboxed!.isInbox, isTrue);
  });

  test('v1 老库升到 v8 后，note_feed_state / note_ai_tags 被删掉', () async {
    // 这两张表原先都在 schema 里：
    //   · note_feed_state 是"笔记消费状态"（到期时间/间隔/难度因子），
    //     供卡片流复习已有笔记用。卡片流改成 **AI 生成新内容**之后不再复用
    //     同一条笔记，那套状态就没用了，repository 里的方法早已全部删掉。
    //   · note_ai_tags 是每篇笔记的 AI 标签，**只写不读**：读侧链路
    //     （get → FeedRepository.tagsOf）零调用方，卡片上那个标签其实来自
    //     卡片自己的 `FeedDraft.tag`。
    //
    // 表本身原先"留着无害"，v8 把它们清掉了——这里验证真的清了，
    // 且没有牵连其它表与数据。
    final t = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    seedV1([
      {'id': 'n1', 'folder_id': null, 'is_inbox': 1, 'ts': t, 'title': 'A'},
    ]);

    final db = openCurrent();
    addTearDown(db.close);
    await db.allActiveNotes(); // 触发迁移

    final tables = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
        .get();
    final names = tables.map((r) => r.read<String>('name')).toSet();

    // 这两张表在 seedV1 的脚本里是建出来的（见文件顶部），v8 必须清掉
    expect(names.contains('note_feed_state'), isFalse,
        reason: 'v8 应当删掉 note_feed_state');
    expect(names.contains('note_ai_tags'), isFalse,
        reason: 'v8 应当删掉 note_ai_tags');

    // 同一批里仍在用的表不能被误删
    expect(names.contains('feed_reserve'), isTrue);
    // `ai_note_summaries`（v4 建、v9 改名）已在 v12 删除
    expect(names.contains('ai_note_summaries'), isFalse);

    // 删表不该牵连数据
    expect(await db.allActiveNotes(), hasLength(1));
  });

  test('v9：删掉手动标签两张表，并把两个表名改掉', () async {
    // v9 做三件事，这里逐条验证：
    //   1. DROP note_tags / tags —— 用户手动标签整条链路（写入只有编辑页那个
    //      弹窗，读取只有它自己 + Markdown 导出里一行 `> 标签：`）
    //   2. note_ai_summaries → ai_note_summaries（跟 ai_calls 对齐命名），
    //      并在 v12 整表删除（卡片流不再用摘要）
    //   3. settings → app_kv（它 10 个 key 里有 6 个不是"设置"）
    //
    // 3 是**改名**，漏掉 RENAME 就会直接丢数据，所以既要断言新名在，
    // 也要断言老名不在，还要断言**里面的数据还在**。
    final t = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final raw = sqlite.sqlite3.open(dbPath);
    raw.execute(_v1FoldersDdl);
    raw.execute(_v1NotesDdl);
    raw.execute(_v1SettingsDdl);
    for (final ddl in _v1OtherTablesDdl) {
      raw.execute(ddl);
    }
    for (final ddl in _v1ManualTagsDdl) {
      raw.execute(ddl);
    }
    raw.execute(
      'INSERT INTO notes (id, folder_id, title, content, excerpt, source, '
      'is_inbox, pinned, word_count, created_at, updated_at) '
      'VALUES (?, NULL, ?, ?, ?, ?, ?, 0, 0, ?, ?)',
      ['n1', 'A', '正文', '', 'local', 1, t, t],
    );
    raw.execute(
      "INSERT INTO tags (id, name, normalized_name, created_at) "
      "VALUES ('tg1', 'Flutter', 'flutter', ?)",
      [t],
    );
    raw.execute(
      'INSERT INTO note_tags (note_id, tag_id, created_at) VALUES (?, ?, ?)',
      ['n1', 'tg1', t],
    );
    raw.execute(
      "INSERT INTO settings (key, value) VALUES ('theme_mode', 'dark')",
    );
    raw.execute('PRAGMA user_version = 2');
    raw.close();

    final db = openCurrent();
    addTearDown(db.close);
    await db.allActiveNotes(); // 触发迁移

    final tables = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
        .get();
    final names = tables.map((r) => r.read<String>('name')).toSet();

    // 1) 手动标签两张表清掉了（先删连接表再删主表，顺序在迁移里注释了）
    expect(names.contains('note_tags'), isFalse,
        reason: 'v9 应当删掉 note_tags');
    expect(names.contains('tags'), isFalse, reason: 'v9 应当删掉 tags');

    // 2) note_ai_summaries 改名后又在 v12 整表删除：最终不该在
    expect(names.contains('ai_note_summaries'), isFalse);
    expect(names.contains('note_ai_summaries'), isFalse);
    // 3) settings → app_kv 改名：新名在、老名不在
    expect(names.contains('app_kv'), isTrue,
        reason: 'v9 应当把 settings 改名为 app_kv');
    expect(names.contains('settings'), isFalse);

    // 改名不能丢数据：那条设置还在，且能通过新的读写入口读到
    expect(await db.readSetting('theme_mode'), 'dark');

    // 笔记一条不少
    expect(await db.allActiveNotes(), hasLength(1));
  });

  test('升级后的库版本号等于 kCurrentSchemaVersion', () async {
    final t = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    seedV1([
      {'id': 'n1', 'folder_id': null, 'is_inbox': 1, 'ts': t, 'title': 'A'},
    ]);

    final db = openCurrent();
    addTearDown(db.close);
    // 触发一次真实查询，确保连接已建立、迁移已执行
    await db.allActiveNotes();

    final raw = sqlite.sqlite3.open(dbPath);
    final rs = raw.select('PRAGMA user_version');
    final version = rs.first.values.first as int;
    raw.close();

    expect(version, kCurrentSchemaVersion);
    // ⚠️ 这一句是**故意的硬编码**：加迁移时它必须跟着改。
    // 上面那句是"等于常量"（永远成立、抓不到忘改版本号）；
    // 这句才有用 —— 它逼你在改 `kCurrentSchemaVersion` 时确认这里。
    expect(kCurrentSchemaVersion, 15);
  });

  test('v13：ai_capabilities 换成 ai_functions，并灌入函数清单', () async {
    final t = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    seedV1([
      {'id': 'n1', 'folder_id': null, 'is_inbox': 1, 'ts': t, 'title': 'A'},
    ]);

    final db = openCurrent();
    addTearDown(db.close);
    await db.allActiveNotes(); // 触发迁移 + beforeOpen

    final tables = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
        .get();
    final names = tables.map((r) => r.read<String>('name')).toSet();
    expect(names.contains('ai_capabilities'), isFalse,
        reason: 'v13 应当把这张死表删掉');
    expect(names.contains('ai_functions'), isTrue,
        reason: 'v13 应当建出 ai_functions');

    // 清单是种子数据：beforeOpen 每次打开都对齐一遍，所以这里应当已经满了
    final count = await db
        .customSelect('SELECT COUNT(*) AS n FROM ai_functions')
        .getSingle();
    expect(count.read<int>('n'), kAiFunctions.length);
    expect(kAiFunctions.length, 25,
        reason: '25 个函数是 v6 设计里定死的数'
            '（11 读 + 3 建 + 8 改 + 2 删 + 1 系统 + 1 信号）；'
            '改这张表要同步改文档与测试');

    // 触发器也在 beforeOpen 里建（清切片那条，见 core/db/ai_udfs.dart）
    final triggers = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type='trigger'")
        .get();
    expect(
      triggers.map((r) => r.read<String>('name')),
      contains('ai_notes_content_changed'),
      reason: '正文一变就要清切片，触发器没建出来的话偏移会静默失效',
    );
  });

  test('v14：ai_messages 多出 interrupt_reason（断线续传靠它）', () async {
    final t = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    seedV1([
      {'id': 'n1', 'folder_id': null, 'is_inbox': 1, 'ts': t, 'title': 'A'},
    ]);

    final db = openCurrent();
    addTearDown(db.close);
    await db.allActiveNotes(); // 触发迁移

    final cols = await db.customSelect('PRAGMA table_info(ai_messages)').get();
    final names = cols.map((r) => r.read<String>('name')).toSet();
    expect(names.contains('interrupt_reason'), isTrue,
        reason: 'v14 要给 ai_messages 加这一列；没有它，界面上就分不出「写完了」和「被打断了」');
  });
  test('v15：note_vectors 表被建出来（语义检索的向量存这儿）', () async {
    final t = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    seedV1([
      {'id': 'n1', 'folder_id': null, 'is_inbox': 1, 'ts': t, 'title': 'A'},
    ]);

    final db = openCurrent();
    addTearDown(db.close);
    await db.allActiveNotes(); // 触发迁移

    final cols = await db.customSelect('PRAGMA table_info(note_vectors)').get();
    final names = cols.map((r) => r.read<String>('name')).toSet();
    expect(
      names,
      containsAll(<String>[
        'note_id', 'idx', 'content_hash', 'model', 'dim', 'vec', 'created_at',
      ]),
    );

    // 迁移只建空表、不做任何回填：全量回填会在升级那一刻卡住启动
    final rows =
        await db.customSelect('SELECT COUNT(*) AS c FROM note_vectors').get();
    expect(rows.first.read<int>('c'), 0,
        reason: 'v15 只建表；向量由 RagIndexer 后台慢慢补');
  });


  test('v1 老库升到 v10 后，note_chunks 表被建出来且可用', () async {
    final t = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    seedV1([
      {'id': 'n1', 'folder_id': null, 'is_inbox': 1, 'ts': t, 'title': 'A'},
    ]);

    final db = openCurrent();
    addTearDown(db.close);
    // 触发一次真实查询，确保连接已建立、迁移已执行
    await db.allActiveNotes();

    // 表存在
    final raw = sqlite.sqlite3.open(dbPath);
    final rs = raw.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='note_chunks'",
    );
    expect(rs, isNotEmpty, reason: 'note_chunks 没建出来');
    final idx = raw.select(
      "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_chunks_used'",
    );
    expect(idx, isNotEmpty, reason: '索引没建出来（_createIndexes 要在 onUpgrade 末尾跑）');
    raw.close();

    // 而且真的能写能读（不只是建了张空壳表）
    final note = (await db.allActiveNotes()).single;
    await db.replaceNoteChunks(note.id, [
      NoteChunksCompanion.insert(
        noteId: note.id,
        idx: 0,
        startOffset: 0,
        endOffset: 1,
        charCount: 1,
        contentHash: 1,
        createdAt: DateTime.now().toUtc(),
      ),
    ]);
    expect(await db.chunkCount(note.id), 1);
    expect((await db.chunksOf(note.id)).single.idx, 0);

    // **不在迁移里回填**：老笔记升上来时是 0 片，等被用到时由仓储懒回填
    // （迁移回调里读不到数据，硬回填会卡住启动、中断了还只补一半）
    final fresh = await db.noteIdsWithoutChunks();
    expect(fresh, isNot(contains(note.id)),
        reason: '刚写过一片，它不该出现在"没切过片"的名单里');
  });

  test('v1 老库升到 v7 后，note_summaries 表被删掉', () async {
    final t = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    seedV1([
      {'id': 'n1', 'folder_id': null, 'is_inbox': 1, 'ts': t, 'title': 'A'},
    ]);

    final db = openCurrent();
    addTearDown(db.close);
    await db.allActiveNotes(); // 触发迁移

    final tables = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
        .get();
    final names = tables.map((r) => r.read<String>('name')).toSet();

    // v1 的建表脚本里是有这张表的（见文件顶部），v7 必须清掉：
    // 它是「AI 整理要点」的落库表，该功能移除后一直只写不读。
    expect(names.contains('note_summaries'), isFalse,
        reason: 'v7 应当删掉 note_summaries');

    // v4 建的 ai_note_summaries 已在 v12 删除（卡片流不再用摘要）
    expect(names.contains('ai_note_summaries'), isFalse);
    // `note_ai_tags` 和它同批建出来，但只写不读，已被 v8 删掉
    // （见下面"v1 老库升到 v8"那条）
    expect(names.contains('note_ai_tags'), isFalse,
        reason: 'v8 应当删掉 note_ai_tags');

    expect(await db.allActiveNotes(), hasLength(1));
  });

  test('v1 老库升到 v6 后，记忆卡片相关表被删掉', () async {
    final t = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    seedV1([
      {'id': 'n1', 'folder_id': null, 'is_inbox': 1, 'ts': t, 'title': 'A'},
    ]);

    final db = openCurrent();
    addTearDown(db.close);
    await db.allActiveNotes(); // 触发迁移

    final tables = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
        .get();
    final names = tables.map((r) => r.read<String>('name')).toSet();

    // v1 的建表脚本里是有这三张表的（见文件顶部的 seedV1 DDL），
    // v6 迁移必须把它们清掉——否则老库里会留下一堆没人读的死表。
    expect(names.contains('card_decks'), isFalse, reason: 'v6 应当删掉 card_decks');
    expect(names.contains('cards'), isFalse, reason: 'v6 应当删掉 cards');
    expect(names.contains('reviews'), isFalse, reason: 'v6 应当删掉 reviews');

    // 笔记本身一条都不能少（删表不该牵连数据）
    expect(await db.allActiveNotes(), hasLength(1));
  });

  test('v1 老库升到最新后，AI 摘要表已被删掉', () async {
    final t = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    seedV1([
      {'id': 'n1', 'folder_id': null, 'is_inbox': 1, 'ts': t, 'title': 'A'},
    ]);

    final db = openCurrent();
    addTearDown(db.close);
    await db.allActiveNotes(); // 触发迁移

    final names = (await db
            .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
            .get())
        .map((r) => r.read<String>('name'))
        .toSet();

    // v4 建的这张表（v9 改名为 ai_note_summaries）已在 v12 删除
    expect(names.contains('ai_note_summaries'), isFalse,
        reason: 'v12 应当删掉 ai_note_summaries');
    expect(names.contains('note_ai_summaries'), isFalse);
  });

  test('全新库（无 v1 文件）走 onCreate，表都建出来了', () async {
    final db = openCurrent();
    addTearDown(db.close);

    // onCreate 路径：库是空的，但表必须都在
    final tables = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
        .get();
    final names = tables.map((r) => r.read<String>('name')).toSet();
    // 关键表抽查：笔记库改名后的 notebooks、笔记、卡片流预留
    expect(names.contains('notebooks'), isTrue);
    expect(names.contains('notes'), isTrue);
    expect(names.contains('feed_reserve'), isTrue);
    expect(names.contains('ai_note_summaries'), isFalse,
        reason: 'v12 已删除 AI 摘要表');
    expect(names.contains('app_kv'), isTrue);
    expect(names.contains('settings'), isFalse,
        reason: 'v9 之后 key-value 表叫 app_kv');
    // v9 删掉的手动标签表，全新库也不该再建出来
    expect(names.contains('tags'), isFalse,
        reason: 'v9 已删除用户手动标签的 tags 表');
    expect(names.contains('note_tags'), isFalse,
        reason: 'v9 已删除用户手动标签的 note_tags 表');
    // v8 删掉的两张死表，全新库也不该再建出来
    expect(names.contains('note_feed_state'), isFalse,
        reason: 'v8 已删除该表');
    expect(names.contains('note_ai_tags'), isFalse,
        reason: 'v8 已删除该表');
    // 记忆卡片已随功能删除：全新库不该再建这三张表
    expect(names.contains('cards'), isFalse, reason: '记忆卡片功能已删除');
    expect(names.contains('card_decks'), isFalse, reason: '记忆卡片功能已删除');
    expect(names.contains('reviews'), isFalse, reason: '记忆卡片功能已删除');
    // 「AI 整理要点」也删了，它的落库表同样不该再建
    expect(names.contains('note_summaries'), isFalse, reason: 'AI 整理要点已删除');
    expect(names.contains('folders'), isFalse, reason: 'v3 之后不该再有 folders');
    expect(await db.allActiveNotes(), isEmpty);
  });
}
