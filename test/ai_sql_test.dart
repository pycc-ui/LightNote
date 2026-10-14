// AI 的 SQL 通道：安全校验（SqlGuard）与 25 个 UDF 的行为。
//
// 分两块测，因为它们的失败方式完全不同：
//   · SqlGuard 是**纯逻辑**，不连库，逐条喂样例就行；
//   · UDF 得真的跑一次 SQLite —— 用原生 sqlite3 开**内存库**，手工建出
//     notes / notebooks / note_chunks，再把 UDF 注册上去。**不经过 drift**：
//     这一层的契约就是「SQL 进、JSON 出」，套上 drift 反而会把被测对象
//     换成 drift 的行为。（触发器也手工建一次，用的是同一份常量。）
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:lightnote/core/db/ai_functions.dart';
import 'package:lightnote/core/db/ai_udfs.dart';
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

  /// 同上，但把返回值当成 JSON 解出来（UDF 的失败也是这种形状）。
  Map<String, Object?> json(String sql, [List<Object?> params = const []]) =>
      jsonDecode(one(sql, params)! as String) as Map<String, Object?>;

  String text(String sql, [List<Object?> params = const []]) =>
      one(sql, params)! as String;

  group('SqlGuard：只放行一条查询', () {
    test('放行：SELECT / WITH、嵌了 UDF、参数里有危险词', () {
      const ok = [
        'SELECT 1',
        'SELECT * FROM notes WHERE deleted_at IS NULL',
        "SELECT replace_unique('n1', 'a', 'b')",
        "SELECT delete_unique('n1', 'a')",
        'WITH x AS (SELECT 1 AS a) SELECT * FROM x',
        'SELECT 1;',
        // 参数里出现 delete / update 是**正常正文**：
        // 安全检查不能把功能弄坏（这是最容易写错的一条）
        "SELECT replace_unique('n1', 'delete 这段', 'update 那段')",
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

    test('拒绝的理由要能教模型改写法', () {
      expect(SqlGuard.check('DELETE FROM notes').reason, contains('ai_functions'));
    });
  });

  group('UDF：读', () {
    test('list_notebooks / list_notes / list_unfiled 只给元信息', () {
      final notebooks = jsonDecode(text('SELECT list_notebooks()')) as List;
      expect(notebooks.single['name'], '工作');

      final notes = jsonDecode(text("SELECT list_notes('nb1')")) as List;
      expect(notes.single['title'], '项目A');
      expect((notes.single as Map).containsKey('content'), isFalse,
          reason: '列表只给 id / title / updated_at');

      final unfiled = jsonDecode(text('SELECT list_unfiled()')) as List;
      expect(unfiled.single['id'], 'n2');
    });

    test('stat_note 不给正文', () {
      final j = json("SELECT stat_note('n1')");
      expect(j['title'], '项目A');
      expect(j['notebook_id'], 'nb1');
      expect(j['char_count'], body.length);
      expect(j.containsKey('content'), isFalse);
    });

    test('read_preview 从 offset 起', () {
      expect(text("SELECT read_preview('n1', 0, 3)"), body.substring(0, 3));
      expect(text("SELECT read_preview('n1', 2, 3)"), body.substring(2, 5));
    });

    test('read_around 是前后各 N 个字符（不是按行）', () {
      const kw = '主要风险是时间紧';
      final got = text("SELECT read_around('n1', '$kw', 5)");
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
      final j = json("SELECT find_in_note('n1', '风险')");
      expect(j['count'], 2);
      final positions = (j['positions'] as List).cast<int>();
      expect(positions.length, 2);
      expect(body.substring(positions.first, positions.first + 2), '风险');
    });

    test('search_notes 只回 id / title / snippet', () {
      final rows = jsonDecode(text("SELECT search_notes('项目A', 10)")) as List;
      expect(rows.single['id'], 'n1');
      expect(rows.single['snippet'], isNotEmpty);
    });

    test('search_in_note 的 offset 能直接喂给 read_preview', () {
      final hits =
          jsonDecode(text("SELECT search_in_note('n1', '风险', 10)")) as List;
      expect(hits.length, 2);
      final off = hits.first['offset'] as int;
      expect(body.substring(off, off + 2), '风险');
      expect(text("SELECT read_preview('n1', $off, 6)").startsWith('风险'), isTrue);
    });

    test('count_notes / recent_notes', () {
      expect(one('SELECT count_notes(NULL)'), 2);
      expect(one("SELECT count_notes('nb1')"), 1);
      expect((jsonDecode(text('SELECT recent_notes(5)')) as List).length, 2);
    });

    test('函数能嵌在 SQL 里，一次调用拿多列', () {
      final rows = db.select(
        'SELECT id, title, read_preview(id, 0, 4) AS head, stat_note(id) AS meta '
        'FROM notes WHERE deleted_at IS NULL ORDER BY id',
      );
      expect(rows.length, 2);
      expect(rows.first['head'], body.substring(0, 4));
      expect(jsonDecode(rows.first['meta'] as String)['title'], '项目A');
    });
  });

  group('UDF：写', () {
    test('replace_unique 成功：正文、派生字段、切片一起处理', () {
      // 先埋一片，验证触发器会把它清掉
      db.execute(
        'INSERT INTO note_chunks (note_id, idx, start_offset, end_offset, '
        'char_count, content_hash, created_at) VALUES (?, 0, 0, 5, 5, 1, ?)',
        ['n1', 1],
      );

      expect(json("SELECT replace_unique('n1', '主要风险是时间紧', '风险已识别')")['ok'],
          true);

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

    test('replace_unique 锚点不唯一 / 不存在 → 拒绝，且一个字都不动', () {
      final dup = json("SELECT replace_unique('n1', '风险', 'X')");
      expect(dup['ok'], false);
      expect(dup['error'], contains('2'));
      final missing = json("SELECT replace_unique('n1', '压根没有', 'X')");
      expect(missing['ok'], false);
      expect(db.select("SELECT content FROM notes WHERE id = 'n1'").single['content'],
          body);
    });

    test('insert_after / append_to_note', () {
      expect(json("SELECT insert_after('n1', '最后是结论。', '（补记）')")['ok'], true);
      var content = db.select("SELECT content FROM notes WHERE id = 'n1'").single['content']
          as String;
      expect(content, contains('最后是结论。\n（补记）'));

      expect(json("SELECT append_to_note('n1', '结尾')")['ok'], true);
      content = db.select("SELECT content FROM notes WHERE id = 'n1'").single['content']
          as String;
      expect(content.endsWith('\n结尾'), isTrue);
    });

    test('create_note：不传库进「我的轻笔记」，传库则归档', () {
      final inbox = json("SELECT create_note('新笔记', '正文')");
      final id = inbox['note_id'] as String;
      final row = db.select('SELECT * FROM notes WHERE id = ?', [id]).single;
      expect(row['is_inbox'], 1);
      expect(row['notebook_id'], isNull);
      expect(row['source'], 'ai');
      expect(row['word_count'], TextUtils.wordCountOfMarkdown('正文'));

      final filed = json("SELECT create_note('归档的', '正文', 'nb1')");
      final filedRow =
          db.select('SELECT * FROM notes WHERE id = ?', [filed['note_id']]).single;
      expect(filedRow['is_inbox'], 0);
      expect(filedRow['notebook_id'], 'nb1');
    });

    test('create_note 的库 id 不存在 → 失败（不能悄悄塞进收件箱）', () {
      expect(json("SELECT create_note('x', 'y', '没有这个库')")['ok'], false);
    });

    test('move_note 传 NULL 时 is_inbox 一起改', () {
      expect(json("SELECT move_note('n1', NULL)")['ok'], true);
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

    test('正文超过 100KB 要拒绝，而不是截断', () {
      final huge = List.filled(101 * 1024, 'a').join();
      final j = json("SELECT append_to_note('n1', ?)", [huge]);
      expect(j['ok'], false);
      expect(j['error'], contains('100KB'));
      expect(db.select("SELECT content FROM notes WHERE id = 'n1'").single['content'],
          body, reason: '失败就不该动正文');
    });

    test('duplicate_note 复制内容与归属，但不置顶、不带切片', () {
      final j = json("SELECT duplicate_note('n1')");
      final row =
          db.select('SELECT * FROM notes WHERE id = ?', [j['new_note_id']]).single;
      expect(row['content'], body);
      expect(row['notebook_id'], 'nb1');
      expect(row['pinned'], 0);
    });
  });

  group('UDF：删', () {
    test('delete_note 是逻辑删除（正文还在）', () {
      expect(json("SELECT delete_note('n1')")['ok'], true);
      final row = db.select("SELECT * FROM notes WHERE id = 'n1'").single;
      expect(row['deleted_at'], isNotNull);
      expect(row['content'], body);
      // 已删的笔记：读侧一律看不见，再删也要报错
      expect(json("SELECT stat_note('n1')")['ok'], false);
      expect(json("SELECT delete_note('n1')")['ok'], false);
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
      expect(kAiWriteFunctions.length, kAiFunctions.length - 11,
          reason: '读是 11 个，其余都是写');
      expect(kAiWriteFunctions.contains('replace_unique'), isTrue);
      expect(kAiWriteFunctions.contains('list_notes'), isFalse);
    });
  });
}
