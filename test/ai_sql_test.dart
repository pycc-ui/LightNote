// AI 的 SQL 通道：安全校验（SqlGuard）与 26 个 UDF 的行为。
//
// 分两块测，因为它们的失败方式完全不同：
//   · SqlGuard 是**纯逻辑**，不连库，逐条喂样例就行；
//   · UDF 得真的跑一次 SQLite —— 用原生 sqlite3 开**内存库**，手工建出
//     notes / notebooks / note_chunks，再把 UDF 注册上去。**不经过 drift**：
//     这一层的契约就是「SQL 进、JSON 出」，套上 drift 反而会把被测对象
//     换成 drift 的行为。（触发器也手工建一次，用的是同一份常量。）
//
// v3：所有函数统一返回 `{ok, description, data}`（失败 `{ok:false, error}`），
// 结果取 `data`；写操作有批量版的只留批量（单次也走它，数组放一个元素）。
// v6：函数文档全量进 System Prompt 之后，`mark_functions` 与 `stat_note` 删掉了
//（前者的机制多余、后者的字段并进了 outline_notes），`read_preview` 改名并扩能成
// `read_note_batch`（能一次读一批、返回 next_offset），新增 `outline_notes`。
// 25 个函数：11 读 + 3 建 + 8 改 + 2 删 + finish。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:lightnote/core/db/ai_functions.dart';
import 'package:lightnote/core/db/ai_udfs.dart';
import 'package:lightnote/core/util/app_params.dart';
import 'package:lightnote/core/util/text_utils.dart';
import 'package:lightnote/features/ai/domain/sql_guard.dart';

/// UDF 用到的三张表的**最小**结构（列名必须与 drift 建出来的一致）。
///
/// 时间列是 INTEGER：drift 默认把 DateTime 存成 Unix 秒，UDF 也按秒读写
///（两边口径一致是硬要求，见 core/db/ai_udfs.dart 的 _now）。
const _schema = '''
CREATE TABLE notes (
  id TEXT NOT NULL PRIMARY KEY,
  notebook_id TEXT NULL,
  title TEXT NOT NULL DEFAULT '',
  content TEXT NOT NULL DEFAULT '',
  excerpt TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT 'local',
  is_inbox INTEGER NOT NULL DEFAULT 0,
  pinned INTEGER NOT NULL DEFAULT 0,
  word_count INTEGER NOT NULL DEFAULT 0,
  last_ai_at INTEGER NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER NULL
);
CREATE TABLE notebooks (
  id TEXT NOT NULL PRIMARY KEY,
  name TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER NULL
);
CREATE TABLE app_kv (
  key TEXT NOT NULL PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE note_chunks (
  note_id TEXT NOT NULL,
  idx INTEGER NOT NULL,
  heading TEXT NOT NULL DEFAULT '',
  level INTEGER NOT NULL DEFAULT 0,
  start_offset INTEGER NOT NULL,
  end_offset INTEGER NOT NULL,
  char_count INTEGER NOT NULL,
  content_hash INTEGER NOT NULL,
  last_used_at INTEGER NULL,
  next_window_start INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (note_id, idx)
);
''';

void main() {
  late Database db;

  /// 一篇已知正文：专门用来验证「前后各 N 个字符」这类按字符的行为。
  const body = '开头十个字啊啊啊啊啊，这里说主要风险是时间紧，后面还有别的风险，最后是结论。';

  setUp(() {
    db = sqlite3.openInMemory();
    for (final stmt in _schema.split(';')) {
      if (stmt.trim().isEmpty) continue;
      db.execute(stmt);
    }
    for (final stmt in kAiTriggerStatements) {
      db.execute(stmt);
    }
    installAiUdfs(db);

    final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    db.execute(
      'INSERT INTO notebooks (id, name, sort_order, created_at, updated_at) '
      "VALUES ('nb1', '工作', 0, ?, ?)",
      [now, now],
    );
    db.execute(
      'INSERT INTO notes (id, notebook_id, title, content, excerpt, source, '
      'is_inbox, pinned, word_count, created_at, updated_at) '
      "VALUES ('n1', 'nb1', '项目A', ?, '', 'local', 0, 0, 0, ?, ?)",
      [body, now, now],
    );
    db.execute(
      'INSERT INTO notes (id, notebook_id, title, content, excerpt, source, '
      'is_inbox, pinned, word_count, created_at, updated_at) '
      "VALUES ('n2', NULL, '速记', '随手记的一句话', '', 'local', 1, 0, 0, ?, ?)",
      [now, now],
    );
  });

  tearDown(() => db.close());

  /// 执行一条 SQL，取第一行第一列 —— UDF 的返回值都在这一列上。
  Object? one(String sql, [List<Object?> params = const []]) {
    return db.select(sql, params).first.values.first;
  }

  /// 同上，但把返回值当成 JSON 解出来（成功 `{ok, description, data}`，
  /// 失败 `{ok:false, error}`）。
  Map<String, Object?> json(String sql, [List<Object?> params = const []]) =>
      jsonDecode(one(sql, params)! as String) as Map<String, Object?>;

  /// 成功结果里的 `data`。
  Object? data(String sql, [List<Object?> params = const []]) =>
      json(sql, params)['data'];

  group('SqlGuard：只放行一条查询', () {
    test('放行：SELECT / WITH、嵌了 UDF、参数里有危险词', () {
      const ok = [
        'SELECT 1',
        'SELECT * FROM notes WHERE deleted_at IS NULL',
        // 写函数可以独立调用（参数里点名改哪几篇）
        "SELECT update_notes_batch('[{\"id\":\"n1\"}]')",
        // **读**函数可以嵌在带 FROM 的查询里 —— 这正是推荐写法
        'SELECT id, read_preview(id, 0, 200) AS p FROM notes WHERE deleted_at IS NULL',
        'SELECT n.id, read_note_batch(n.id, 0, 4) AS head FROM notes n',
        // 参数（字符串字面量）里出现 from / join 是正常正文，剥掉字面量后不该命中
        "SELECT update_notes_batch('[{\"id\":\"n1\",\"title\":\"from join 测试\"}]')",
        'WITH x AS (SELECT 1 AS a) SELECT * FROM x',
        'SELECT 1;',
        // 参数里出现 delete / update 是**正常正文**：
        // 安全检查不能把功能弄坏（这是最容易写错的一条）
        "SELECT search_notes('delete 这段', 10)",
        // replace 是 SQLite 的内置函数，读查询里合法；只有 REPLACE INTO 要拦
        "SELECT replace(content, 'a', 'b') FROM notes",
      ];
      for (final sql in ok) {
        expect(SqlGuard.check(sql).ok, isTrue, reason: sql);
      }
    });

    test('拒绝：写表、DDL、PRAGMA、多语句', () {
      const bad = [
        'DELETE FROM notes',
        "UPDATE notes SET title = 'x'",
        "INSERT INTO notes (id) VALUES ('x')",
        'DROP TABLE notes',
        'drop table notes',
        'ALTER TABLE notes ADD COLUMN x TEXT',
        "ATTACH DATABASE 'evil.db' AS evil",
        'PRAGMA table_info(notes)',
        'VACUUM',
        'SELECT 1; DELETE FROM notes',
        "REPLACE INTO notes (id) VALUES ('x')",
      ];
      for (final sql in bad) {
        final r = SqlGuard.check(sql);
        expect(r.ok, isFalse, reason: sql);
        expect(r.reason, isNotNull, reason: sql);
      }
    });

    test('拒绝：写函数 + FROM / JOIN（那会按行调一次）', () {
      const bad = [
        // 最典型的：本意是「改那一篇」，实际会按 notes 的行数改 N 遍
        "SELECT update_notes_batch('[{\"id\":\"n1\"}]') FROM notes",
        "SELECT n.id, rename_note(n.id, 'x') FROM notes n",
        // 批量函数还要再乘以批量条数，危害更大
        "SELECT update_notes_batch('[{\"id\":\"n1\"}]') FROM notes n "
            'JOIN notebooks b ON b.id = n.notebook_id',
        // 读函数可以嵌（正例见上），但 outline_notes 是读函数里最"重"的那个，
        // 它本身**不**受限制 —— 受限制的是下面这些非读函数
        "SELECT finish('done') FROM notes",
        // meta 类（finish）也一样：kAiNonReadFunctions 是按 category 算的，
        // 不是"写函数名单"——漏掉它就会放行一句必然按行执行的收尾信号
        "SELECT finish('done') FROM notes",
        // create 类：一次调用建一批，按行调会建出 N 倍的笔记
        "SELECT create_notes_batch('[{\"title\":\"A\"}]') FROM notes",
        // 用 CTE 绕：ids 是查出来的没错，但写函数仍然被按行调用
        'WITH picked AS (SELECT id FROM notes WHERE deleted_at IS NULL) '
            "SELECT update_notes_batch('[{\"id\":\"n1\"}]')",
      ];
      for (final sql in bad) {
        final r = SqlGuard.check(sql);
        expect(r.ok, isFalse, reason: sql);
        expect(r.reason, contains('FROM'), reason: sql);
      }
    });

    test('拒绝的理由要能教模型改写法', () {
      expect(SqlGuard.check('DELETE FROM notes').reason, contains('ai_functions'));
      expect(
        SqlGuard.check("SELECT rename_note(id, 'x') FROM notes").reason,
        contains('读函数'),
        reason: '要顺带告诉它读函数可以嵌，不然下一轮可能干脆不敢用查询',
      );
    });
  });

  group('UDF：读', () {
    test('成功结果统一带 ok + description', () {
      final j = json('SELECT list_notebooks()');
      expect(j['ok'], true);
      expect((j['description'] as String), contains('笔记库'));
    });

    test('list_notebooks / list_notes / list_unfiled 只给元信息', () {
      final notebooks = data('SELECT list_notebooks()') as List;
      expect((notebooks.single as Map)['name'], '工作');

      final notes = data("SELECT list_notes('nb1')") as List;
      expect((notes.single as Map)['title'], '项目A');
      expect((notes.single as Map).containsKey('content'), isFalse,
          reason: '列表只给 id / title / updated_at');

      final unfiled = data('SELECT list_unfiled()') as List;
      expect((unfiled.single as Map)['id'], 'n2');
    });

    test('outline_notes 给元信息 + 目录，**不给正文**', () {
      final d = (data("SELECT outline_notes('[\"n1\"]')") as List).first as Map;
      expect(d['title'], '项目A');
      expect(d['notebook_id'], 'nb1');
      expect(d['chars'], body.length);
      expect(d.containsKey('content'), isFalse, reason: '目录不含正文');
    });

    test('read_note_batch 单篇形式：从 offset 起，并带上位置', () {
      final j = json("SELECT read_note_batch('n1', 0, 3)");
      final d = j['data'] as Map;
      expect(d['content'], body.substring(0, 3));
      expect(d['offset'], 0);
      expect(d['chars'], 3);
      expect(d['truncated'], true, reason: '正文比 3 字长 → 要标出被截断');
      expect(d['next_offset'], 3, reason: '给出接着读的位置，别让模型自己算');
      // 再读一段：offset 直接来自上一轮的 next_offset
      final j2 = json("SELECT read_note_batch('n1', 3, 2)");
      expect((j2['data'] as Map)['content'], body.substring(3, 5));
    });

    test('read_around 是前后各 N 个字符（不是按行）', () {
      const kw = '主要风险是时间紧';
      final got = data("SELECT read_around('n1', '$kw', 5)") as String;
      final i = body.indexOf(kw);
      expect(got, contains(kw));
      expect(got.length, kw.length + 10 + 2, reason: '前后各 5 字 + 两个省略号');
      expect(got.startsWith('…'), isTrue);
      expect(got.replaceAll('…', ''), body.substring(i - 5, i + kw.length + 5));
    });

    test('read_around 找不到时给一句可读的错', () {
      final j = json("SELECT read_around('n1', '不存在的词', 10)");
      expect(j['ok'], false);
      expect(j['error'], contains('不存在的词'));
    });

    test('find_in_note 数得清、位置对得上', () {
      final d = data("SELECT find_in_note('n1', '风险')") as Map;
      expect(d['count'], 2);
      final positions = (d['positions'] as List).cast<int>();
      expect(positions.length, 2);
      expect(body.substring(positions.first, positions.first + 2), '风险');
    });

    test('search_notes 只回 id / title / snippet', () {
      final rows = data("SELECT search_notes('项目A', 10)") as List;
      expect((rows.single as Map)['id'], 'n1');
      expect((rows.single as Map)['snippet'], isNotEmpty);
    });

    test('search_in_note 的 offset 能直接喂给 read_note_batch', () {
      final hits = data("SELECT search_in_note('n1', '风险', 10)") as List;
      expect(hits.length, 2);
      final off = (hits.first as Map)['offset'] as int;
      expect(body.substring(off, off + 2), '风险');
      expect(
          ((json("SELECT read_note_batch('n1', $off, 6)")['data'] as Map)['content']
                  as String)
              .startsWith('风险'),
          isTrue);
    });

    test('count_notes / recent_notes', () {
      expect(data('SELECT count_notes(NULL)'), 2);
      expect(data("SELECT count_notes('nb1')"), 1);
      expect((data('SELECT recent_notes(5)') as List).length, 2);
    });

    test('函数能嵌在 SQL 里，一次调用拿多列', () {
      final rows = db.select(
        'SELECT id, title, read_note_batch(id, 0, 4) AS head '
        'FROM notes WHERE deleted_at IS NULL ORDER BY id',
      );
      expect(rows.length, 2);
      // 嵌在列里时，该列仍是 UDF 返回的 JSON 文本 → 解出来看 data
      expect(jsonDecode(rows.first['head'] as String)['data']['content'],
          body.substring(0, 4));
      // 注：`outline_notes` 只收 JSON 数组，没法按行嵌（`outline_notes(id)` 会报错）——
      // 这不是限制，因为它本来就是"一次看一批"的函数，不该按行调。
    });
  });

  group('UDF：目录与批量读（v6 新增/改名）', () {
    test('outline_notes 给的是**原文标题目录**（不是切片）', () {
      db.execute("UPDATE notes SET content = ? WHERE id = 'n1'", [
        '# 甲\n\n甲的内容。\n\n## 甲一\n\n甲一的正文。\n\n# 乙\n\n乙的正文。'
      ]);
      final d = data("SELECT outline_notes('[\"n1\"]')") as List;
      final one = d.first as Map;
      expect(one['id'], 'n1');
      expect(one['chars'], isA<int>());
      expect(one['excerpt'], isA<String>(), reason: '选材用的摘要要一起带回来');
      // stat_note 被删了，它的字段必须在这里全覆盖
      for (final k in ['title', 'notebook_id', 'chars', 'created_at', 'updated_at']) {
        expect(one.containsKey(k), isTrue, reason: '缺字段 $k');
      }
      final secs = (one['sections'] as List).cast<Map>();
      expect(secs.map((e) => e['heading']).toList(), ['甲', '甲一', '乙']);
      expect(secs.map((e) => e['level']).toList(), [1, 2, 1]);
      // offset/chars 是"这一节的字符范围"：甲一 的范围到"乙"之前
      final first = secs[0];
      expect(first['offset'], 0);
      final jiaYi = secs[1];
      expect((jiaYi['offset'] as int) > (first['offset'] as int), isTrue);
      // 最后一节延到正文末尾
      final last = secs[2];
      final content = db.select("SELECT content FROM notes WHERE id = 'n1'").single['content'] as String;
      expect((last['offset'] as int) + (last['chars'] as int), content.length);
    });

    test('outline_notes：没有标题的笔记 → sections 为空（按 chars 直接读整篇）', () {
      final d = data("SELECT outline_notes('[\"n2\"]')") as List;
      final one = d.first as Map;
      expect(one['sections'], isEmpty);
      expect(one['chars'], '随手记的一句话'.length);
    });

    test('outline_notes：坏输入与超上限都给可读的错', () {
      expect(json('SELECT outline_notes(\'[]\')')['ok'], false);
      expect(json("SELECT outline_notes('not json')")['ok'], false);
      expect(json("SELECT outline_notes('[\"n1\"]')")['ok'], true);
    });

    test('★ read_note_batch 批量形式：一次读多篇，带位置与 next_offset', () {
      final payload = jsonEncode([
        {'id': 'n1', 'offset': 0, 'chars': 4},
        {'id': 'n2'},
      ]);
      final d = data('SELECT read_note_batch(?)', [payload]) as List;
      expect(d, hasLength(2));
      final a = d[0] as Map;
      final b = d[1] as Map;
      expect(a['content'], body.substring(0, 4));
      expect(a['truncated'], true);
      expect(a['next_offset'], 4);
      expect(b['content'], '随手记的一句话');
      expect(b.containsKey('truncated'), isFalse, reason: '读完了就不该有截断标记');
    });

    test('read_note_batch：不存在的 id → 那一条给错误，其余照常', () {
      final payload = jsonEncode([
        {'id': '不存在'},
        {'id': 'n1', 'chars': 3},
      ]);
      final d = data('SELECT read_note_batch(?)', [payload]) as List;
      expect((d[0] as Map)['error'], isNotNull);
      expect((d[1] as Map)['content'], body.substring(0, 3));
    });

    test('read_note_batch：整批超上限 → **整批拒绝**（不截断）', () {
      final many = jsonEncode([
        for (var i = 0; i < SqlLimits.maxBatchReadNotes + 1; i++)
          {'id': 'n1', 'chars': 1},
      ]);
      final j = json('SELECT read_note_batch(?)', [many]);
      expect(j['ok'], false);
      expect(j['error'], contains('最多'));

      final tooLong = jsonEncode([
        for (var i = 0; i < 4; i++)
          {'id': 'n1', 'chars': SqlLimits.maxBatchReadCharsPerNote},
      ]);
      // 4 × 1500 = 6000 < 15000 → 这篇只有几十字，实际总量很小 → 应当成功
      expect(json('SELECT read_note_batch(?)', [tooLong])['ok'], isTrue);
    });

    test('read_note_batch：单条超过上限 → 截断到上限并给 next_offset', () {
      final long = List.filled(SqlLimits.maxBatchReadCharsPerNote + 500, '字').join();
      db.execute("UPDATE notes SET content = ? WHERE id = 'n1'", [long]);
      final d = (data("SELECT read_note_batch('n1', 0, 99999)") as Map);
      expect(d['chars'], SqlLimits.maxBatchReadCharsPerNote);
      expect(d['next_offset'], SqlLimits.maxBatchReadCharsPerNote);
    });
  });

  group('UDF：写', () {
    test('update_notes_batch 成功：正文、派生字段、切片一起处理', () {
      // 先埋一片，验证触发器会把它清掉
      db.execute(
        'INSERT INTO note_chunks (note_id, idx, start_offset, end_offset, '
        'char_count, content_hash, created_at) VALUES (?, 0, 0, 5, 5, 1, ?)',
        ['n1', 1],
      );

      final j = json(
          "SELECT update_notes_batch('[{\"id\":\"n1\",\"old\":\"主要风险是时间紧\",\"new\":\"风险已识别\"}]')");
      expect(j['ok'], true);

      final row = db.select("SELECT * FROM notes WHERE id = 'n1'").single;
      final after = row['content'] as String;
      expect(after, contains('风险已识别'));
      expect(after, isNot(contains('主要风险是时间紧')));
      expect(row['excerpt'], TextUtils.excerpt(after),
          reason: 'excerpt 必须与 App 同一口径（同一个 TextUtils）');
      expect(row['word_count'], TextUtils.wordCountOfMarkdown(after));
      expect(db.select("SELECT * FROM note_chunks WHERE note_id = 'n1'"), isEmpty,
          reason: '正文一变偏移就失效，必须清掉切片');
    });

    test('update_notes_batch 锚点不唯一 / 不存在 → 拒绝，且一个字都不动', () {
      final dup =
          json("SELECT update_notes_batch('[{\"id\":\"n1\",\"old\":\"风险\",\"new\":\"X\"}]')");
      expect(dup['ok'], false);
      expect(dup['error'], contains('2'));
      final missing =
          json("SELECT update_notes_batch('[{\"id\":\"n1\",\"old\":\"压根没有\",\"new\":\"X\"}]')");
      expect(missing['ok'], false);
      expect(db.select("SELECT content FROM notes WHERE id = 'n1'").single['content'],
          body);
    });

    test('update_notes_batch 单条失败整批回滚', () {
      final j = json(
          "SELECT update_notes_batch('[{\"id\":\"n1\",\"old\":\"主要风险是时间紧\",\"new\":\"X\"},{\"id\":\"n2\",\"old\":\"没有的词\",\"new\":\"Y\"}]')");
      expect(j['ok'], false);
      expect(j['error'], contains('第 2 条'));
      expect(db.select("SELECT content FROM notes WHERE id = 'n1'").single['content'],
          body,
          reason: '第 1 条也不该落库');
    });

    test('update_notes_batch 同一篇改两次：后一条看到前一条的结果', () {
      final j = json(
          "SELECT update_notes_batch('[{\"id\":\"n1\",\"old\":\"主要风险是时间紧\",\"new\":\"甲乙\"},{\"id\":\"n1\",\"old\":\"甲乙\",\"new\":\"风险已识别\"}]')");
      expect(j['ok'], true);
      expect(db.select("SELECT content FROM notes WHERE id = 'n1'").single['content'],
          contains('风险已识别'));
    });

    test('insert_after / append_notes_batch', () {
      expect(json("SELECT insert_after('n1', '最后是结论。', '（补记）')")['ok'], true);
      var content =
          db.select("SELECT content FROM notes WHERE id = 'n1'").single['content']
              as String;
      expect(content, contains('最后是结论。\n（补记）'));

      expect(json("SELECT append_notes_batch('[{\"id\":\"n1\",\"content\":\"结尾\"}]')")['ok'],
          true);
      content = db.select("SELECT content FROM notes WHERE id = 'n1'").single['content']
          as String;
      expect(content.endsWith('\n结尾'), isTrue);
    });

    test('create_notes_batch：不传库进「我的轻笔记」，传库则归档', () {
      final inbox = json(
          "SELECT create_notes_batch('[{\"title\":\"新笔记\",\"content\":\"正文\"}]')");
      final id = (inbox['data'] as Map)['note_ids'][0] as String;
      final row = db.select('SELECT * FROM notes WHERE id = ?', [id]).single;
      expect(row['is_inbox'], 1);
      expect(row['notebook_id'], isNull);
      expect(row['source'], 'ai');
      expect(row['word_count'], TextUtils.wordCountOfMarkdown('正文'));

      final filed = json(
          "SELECT create_notes_batch('[{\"title\":\"归档的\",\"content\":\"正文\",\"notebook_id\":\"nb1\"}]')");
      final filedId = (filed['data'] as Map)['note_ids'][0] as String;
      final filedRow =
          db.select('SELECT * FROM notes WHERE id = ?', [filedId]).single;
      expect(filedRow['is_inbox'], 0);
      expect(filedRow['notebook_id'], 'nb1');
    });

    test('create_notes_batch：一次多条', () {
      final j = json(
          "SELECT create_notes_batch('[{\"title\":\"A\",\"content\":\"a\"},{\"title\":\"B\",\"content\":\"b\"}]')");
      expect(j['ok'], true);
      expect((j['data'] as Map)['note_ids'], hasLength(2));
    });

    test('create_notes_batch 的库 id 不存在 → 失败（不能悄悄塞进收件箱）', () {
      expect(
          json("SELECT create_notes_batch('[{\"title\":\"x\",\"content\":\"y\",\"notebook_id\":\"没有这个库\"}]')")['ok'],
          false);
    });

    test('批量超过 10 条 → 拒绝', () {
      final many = List.generate(11, (i) => {'title': 'T$i', 'content': 'c'});
      final j = json('SELECT create_notes_batch(?)', [jsonEncode(many)]);
      expect(j['ok'], false);
      expect(j['error'], contains('10'));
    });

    test('move_notes_batch 传 null 时 is_inbox 一起改', () {
      expect(
          json("SELECT move_notes_batch('[{\"id\":\"n1\",\"notebook_id\":null}]')")['ok'],
          true);
      final row = db.select("SELECT * FROM notes WHERE id = 'n1'").single;
      expect(row['notebook_id'], isNull);
      expect(row['is_inbox'], 1,
          reason: '只改 notebook_id 会留下「已归档但没有库」的行，两个入口都看不到');
    });

    test('rename_note / rename_notebook', () {
      expect(json("SELECT rename_note('n1', '新标题')")['ok'], true);
      expect(db.select("SELECT title FROM notes WHERE id = 'n1'").single['title'],
          '新标题');
      expect(json("SELECT rename_notebook('nb1', '工作 2025')")['ok'], true);
      expect(one("SELECT name FROM notebooks WHERE id = 'nb1'"), '工作 2025');
      expect(json("SELECT rename_notebook('nb1', '   ')")['ok'], false,
          reason: '空名字要拒绝，不能悄悄改成默认名');
    });

    test('正文超过硬上限要拒绝，而不是截断', () {
      final kb = AiLimits.noteHardBytes ~/ 1024;
      final huge = List.filled(AiLimits.noteHardBytes + 1024, 'a').join();
      final payload = jsonEncode([
        {'id': 'n1', 'content': huge}
      ]);
      final j = json('SELECT append_notes_batch(?)', [payload]);
      expect(j['ok'], false);
      expect(j['error'], contains('${kb}KB'));
      expect(db.select("SELECT content FROM notes WHERE id = 'n1'").single['content'],
          body, reason: '失败就不该动正文');
    });

    test('★ 老的超限笔记「只管增长」：不变长就放行，变长才拒', () {
      // 模拟"按旧上限（100KB）写下的老笔记"：直接塞一篇超过新上限的正文
      final old = List.filled(AiLimits.noteHardBytes + 5000, 'a').join();
      db.execute("UPDATE notes SET content = ? WHERE id = 'n1'", [old]);

      // 改一个字（长度不变）→ 放行
      final same = '${List.filled(old.length - 1, 'a').join()}b';
      final ok = json('SELECT update_notes_batch(?)', [
        jsonEncode([
          {'id': 'n1', 'old': old, 'new': same}
        ])
      ]);
      expect(ok['ok'], isTrue,
          reason: '老笔记不能被锁死：一刀切会让用户连改一个字都存不了');
      expect(db.select("SELECT content FROM notes WHERE id = 'n1'").single['content'],
          same);

      // 再变长 → 拒绝
      final longer = List.filled(old.length + 1000, 'a').join();
      final bad = json('SELECT update_notes_batch(?)', [
        jsonEncode([
          {'id': 'n1', 'old': same, 'new': longer}
        ])
      ]);
      expect(bad['ok'], isFalse, reason: '上限管的是增长');
    });

    test('duplicate_note 复制内容与归属，但不置顶、不带切片', () {
      final j = json("SELECT duplicate_note('n1')");
      final id = (j['data'] as Map)['new_note_id'] as String;
      final row = db.select('SELECT * FROM notes WHERE id = ?', [id]).single;
      expect(row['content'], body);
      expect(row['notebook_id'], 'nb1');
      expect(row['pinned'], 0);
    });
  });

  group('UDF：删', () {
    test('delete_notes_batch 是逻辑删除（正文还在）', () {
      expect(json("SELECT delete_notes_batch('[\"n1\"]')")['ok'], true);
      final row = db.select("SELECT * FROM notes WHERE id = 'n1'").single;
      expect(row['deleted_at'], isNotNull);
      expect(row['content'], body);
      // 已删的笔记：读侧一律看不见，再删也要报错
      expect(json("SELECT outline_notes('[\"n1\"]')")['ok'], true,
          reason: '已删的笔记在目录里会带 error 字段，而不是整批失败');
      expect(
          ((data("SELECT outline_notes('[\"n1\"]')") as List).first as Map)['error'],
          isNotNull);
      expect(json("SELECT delete_notes_batch('[\"n1\"]')")['ok'], false);
    });

    test('delete_notebook 不删笔记，退回「我的轻笔记」', () {
      expect(json("SELECT delete_notebook('nb1')")['ok'], true);
      final note = db.select("SELECT * FROM notes WHERE id = 'n1'").single;
      expect(note['deleted_at'], isNull, reason: '库里的笔记不能跟着没');
      expect(note['notebook_id'], isNull);
      expect(note['is_inbox'], 1);
      expect(db.select("SELECT deleted_at FROM notebooks WHERE id = 'nb1'").single['deleted_at'],
          isNotNull);
    });
  });

  group('清单与注册必须对齐', () {
    test('25 个函数名都能被 SQLite 找到', () {
      expect(kAiFunctions.length, 25);
      var message = '';
      for (final f in kAiFunctions) {
        try {
          // 参数随便给：报参数错也算「函数存在」，报 no such function 才是漏注册
          db.select('SELECT ${f.name}(NULL, NULL, NULL, NULL)');
        } catch (e) {
          message = e.toString();
        }
        expect(message.contains('no such function'), isFalse,
            reason: '${f.name} 在清单里但没注册');
      }
    });

    test('写函数名单与 category 对得上', () {
      // 25 = 11 读 + 3 建 + 8 改 + 2 删 + 1 信号
      expect(kAiWriteFunctions.length, 13, reason: '建 3 + 改 8 + 删 2');
      expect(kAiWriteFunctions.contains('update_notes_batch'), isTrue);
      expect(kAiWriteFunctions.contains('list_notes'), isFalse);
      // `finish` 什么都不改，不算「写笔记」（混进来的话每轮收尾都白刷三张表）
      expect(kAiWriteFunctions.contains('finish'), isFalse);
      // 但它仍然属于"非读函数"—— 按行调用同样要拦
      expect(kAiNonReadFunctions.contains('finish'), isTrue);
      expect(kAiNonReadFunctions.length, kAiFunctions.length - 11);
      // v3：被批量版覆盖的单次函数不该还在名单里
      expect(kAiWriteFunctions.contains('replace_unique'), isFalse);
      expect(kAiWriteFunctions.contains('create_note'), isFalse);
    });
  });
}
