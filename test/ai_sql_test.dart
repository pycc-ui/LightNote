// AI 的 SQL 通道：安全校验（SqlGuard）与 25 个 UDF 的行为。
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
// v4：多了 mark_functions —— 它写的是 app_kv（"哪几个函数的详情常驻"），
// 所以这里也建一张最小的 app_kv。
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
        "SELECT update_notes_batch('[{\"id\":\"n1\"}]')",
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

    test('拒绝的理由要能教模型改写法', () {
      expect(SqlGuard.check('DELETE FROM notes').reason, contains('ai_functions'));
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

    test('stat_note 不给正文', () {
      final d = data("SELECT stat_note('n1')") as Map;
      expect(d['title'], '项目A');
      expect(d['notebook_id'], 'nb1');
      expect(d['char_count'], body.length);
      expect(d.containsKey('content'), isFalse);
    });

    test('read_preview 从 offset 起', () {
      expect(data("SELECT read_preview('n1', 0, 3)"), body.substring(0, 3));
      expect(data("SELECT read_preview('n1', 2, 3)"), body.substring(2, 5));
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

    test('search_in_note 的 offset 能直接喂给 read_preview', () {
      final hits = data("SELECT search_in_note('n1', '风险', 10)") as List;
      expect(hits.length, 2);
      final off = (hits.first as Map)['offset'] as int;
      expect(body.substring(off, off + 2), '风险');
      expect((data("SELECT read_preview('n1', $off, 6)") as String).startsWith('风险'),
          isTrue);
    });

    test('count_notes / recent_notes', () {
      expect(data('SELECT count_notes(NULL)'), 2);
      expect(data("SELECT count_notes('nb1')"), 1);
      expect((data('SELECT recent_notes(5)') as List).length, 2);
    });

    test('函数能嵌在 SQL 里，一次调用拿多列', () {
      final rows = db.select(
        'SELECT id, title, read_preview(id, 0, 4) AS head, stat_note(id) AS meta '
        'FROM notes WHERE deleted_at IS NULL ORDER BY id',
      );
      expect(rows.length, 2);
      // 嵌在列里时，该列仍是 UDF 返回的 JSON 文本 → 解出来看 data
      expect(jsonDecode(rows.first['head'] as String)['data'], body.substring(0, 4));
      expect(jsonDecode(rows.first['meta'] as String)['data']['title'], '项目A');
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

    test('正文超过 100KB 要拒绝，而不是截断', () {
      final huge = List.filled(101 * 1024, 'a').join();
      final payload = jsonEncode([
        {'id': 'n1', 'content': huge}
      ]);
      final j = json('SELECT append_notes_batch(?)', [payload]);
      expect(j['ok'], false);
      expect(j['error'], contains('100KB'));
      expect(db.select("SELECT content FROM notes WHERE id = 'n1'").single['content'],
          body, reason: '失败就不该动正文');
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
      expect(json("SELECT stat_note('n1')")['ok'], false);
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

  group('UDF：系统（mark_functions）', () {
    /// app_kv 里现在存着哪几个名字（按同一个解析函数读回来）。
    List<String> pinned() {
      final rows = db.select('SELECT value FROM app_kv WHERE key = ?',
          [kAiPinnedFunctionsKey]);
      if (rows.isEmpty) return const [];
      return parsePinnedFunctions(rows.first['value'] as String?);
    }

    test('标记后写进 app_kv，description 说清加载了几个', () {
      final r = json("SELECT mark_functions('[\"search_notes\",\"read_preview\"]')");

      expect(r['ok'], true);
      expect(pinned(), ['search_notes', 'read_preview']);
      expect(r['description'], contains('2'),
          reason: 'description 要带实际条数（AI 靠它确认标记生效）');
      expect((r['data'] as Map)['added'], ['search_notes', 'read_preview']);
    });

    test('只增不减：再标一个，之前的还在', () {
      json("SELECT mark_functions('[\"search_notes\"]')");
      json("SELECT mark_functions('[\"create_notes_batch\"]')");

      expect(pinned(), ['search_notes', 'create_notes_batch'],
          reason: '没有 unmark，后标记的追加在后面');
    });

    test('重复标记同一个 → 不重复，也不报错', () {
      json("SELECT mark_functions('[\"search_notes\"]')");
      final r = json("SELECT mark_functions('[\"search_notes\"]')");

      expect(r['ok'], true);
      expect(pinned(), ['search_notes']);
      expect(r['description'], contains('已在'),
          reason: '要说清「本来就有」，别让 AI 以为又加载了一遍');
    });

    test('未知函数名 → 整批拒绝，且一个字都不写', () {
      final r = json(
          "SELECT mark_functions('[\"search_notes\",\"search_note\"]')");

      expect(r['ok'], false);
      expect(r['error'], contains('search_note'));
      expect(pinned(), isEmpty,
          reason: '整批拒绝：不能"标一半"，那会让 AI 以为两个都加载了');
    });

    test('超过上限：装得下的装，没装上的点名说出来', () {
      // 先占满前 11 个（读），再要 6 个 → 只能再进 [SqlLimits.maxPinnedFunctions] - 11 个
      final reads = [
        for (final f in kAiFunctions)
          if (f.category == 'read') f.name,
      ];
      expect(reads, hasLength(11));
      json("SELECT mark_functions('${jsonEncode(reads)}')");

      const more = [
        'create_notebook',
        'duplicate_note',
        'create_notes_batch',
        'insert_after',
        'insert_before',
        'prepend_to_note',
      ];
      final r = json("SELECT mark_functions('${jsonEncode(more)}')");

      final fit = SqlLimits.maxPinnedFunctions - reads.length;
      expect(r['ok'], true);
      expect(pinned(), hasLength(SqlLimits.maxPinnedFunctions));
      expect((r['data'] as Map)['dropped'],
          more.sublist(fit), reason: '装不下的要一个个点名');
      expect(r['description'], contains('未加载'),
          reason: 'AI 必须知道哪几个没加载，不然它会以为详情都在 prompt 里');
    });

    test('参数不是数组 / 空数组 / 坏 JSON → 可读的错', () {
      for (final bad in ['null', "'{}'", "'[]'", "'not json'"]) {
        final r = json('SELECT mark_functions($bad)');
        expect(r['ok'], false, reason: 'mark_functions($bad) 应当被拒');
        expect(r['error'], isNotEmpty);
      }
      expect(pinned(), isEmpty);
    });

    test('上限已满再标 → 说清「没有新增」，不谎报标记成功', () {
      final all = [for (final f in kAiFunctions) f.name];
      json("SELECT mark_functions("
          "'${jsonEncode(all.take(SqlLimits.maxPinnedFunctions).toList())}')");
      expect(pinned(), hasLength(SqlLimits.maxPinnedFunctions));

      final extra = all[SqlLimits.maxPinnedFunctions];
      final r = json("SELECT mark_functions('[\"$extra\"]')");

      expect(r['ok'], true, reason: '不是错误，只是没装下');
      expect((r['data'] as Map)['added'], isEmpty);
      expect(r['description'], contains('已达上限'));
      expect(r['description'], contains(extra));
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
      // 25 = 11 读 + 3 建 + 8 改 + 2 删 + 1 系统
      expect(kAiWriteFunctions.length, 13, reason: '建 3 + 改 8 + 删 2');
      expect(kAiWriteFunctions.contains('update_notes_batch'), isTrue);
      expect(kAiWriteFunctions.contains('list_notes'), isFalse);
      // 系统类的 mark_functions 只动 app_kv，不算「写笔记」
      //（混进来的话执行器会白刷三张笔记表）
      expect(kAiWriteFunctions.contains('mark_functions'), isFalse);
      expect(kAiKvFunctions, {'mark_functions'});
      // v3：被批量版覆盖的单次函数不该还在名单里
      expect(kAiWriteFunctions.contains('replace_unique'), isFalse);
      expect(kAiWriteFunctions.contains('create_note'), isFalse);
    });
  });
}
