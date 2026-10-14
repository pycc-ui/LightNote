import 'dart:convert';

import 'package:drift/drift.dart' show GeneratedDatabase;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../util/ai_limits.dart';
import '../util/text_utils.dart';

// ============================================================================
// AI 操作数据库的实现层
// ============================================================================
//
// AI 的操作语言是 **SQL**，业务约束装在 **SQLite 自定义函数（UDF）** 里：
//
//   AI 写：SELECT replace_unique('n1', '主要风险是时间紧', '风险已识别');
//   SQLite：按名字查到我们注册的 Dart 函数 → 调它 → 拿到 JSON 字符串当结果
//
// 于是约束（锚点必须唯一、正文硬上限、派生字段口径、删库不删笔记……）
// 全部落在**函数体**里。AI 只能看见函数名和返回值，改不了规则，也绕不过去。
// 函数清单（AI 怎么知道有哪些函数）在 ai_functions.dart + ai_functions 表。
//
// ## 三条必须知道的约束
//
// 1. **回调是同步的**。sqlite3.dart 的 createFunction 给的是同步回调，
//    所以这里只有「读一行 → 算 → 写回去」这种同步动作，一行 await 都不能有。
//    副作用（让界面刷新、重建切片）全部放到函数外面（见 ToolExecutor）。
//
// 2. **只在同一条连接上干活**。函数体里用 sqlite3.Database 直接拼 SQL，
//    不走 drift：驱动是本进程的 C 库，函数体在它内部被回调，此刻用同一个句柄
//    再执行一条语句是安全的（SQLite 允许同连接嵌套语句），但**不能**去 await
//    一个 drift 的 Future —— 那是另一条异步路径，会把回调卡死。
//
// 3. **注册发生在开库的 setup 回调里**，它跑在 drift 的背景 isolate 中，
//    所以本文件里跨 isolate 的东西都必须是顶层函数（见 installAiUdfs）。
//
// ## 与 App 自己写库的关系
//
// App 的界面走 drift 仓储，AI 走这里的 UDF，两条路径写同一张表、同一套口径：
// excerpt / word_count 都调 TextUtils（那是唯一的口径），时间戳都写 Unix 秒
//（drift 默认的 DateTime 存储格式）。改这里时对着 note_repository.dart 看一遍。

/// 当前注册了 UDF 的连接。
///
/// 顶层变量而不是参数：UDF 回调只能拿到 SqliteArguments，拿不到外部作用域。
/// 每个 isolate 有自己的一份，而注册与调用**总是在同一个 isolate**（见文件头），
/// 所以这里不会读到别的 isolate 的句柄。
Database? _udfDb;

const _uuid = Uuid();

/// 把 25 个函数注册到一条连接上。**开库时调用一次**（见 AppDatabase 的 _openConnection）。
///
/// ⚠️ 这个函数会被 drift 送到**背景 isolate** 里执行，所以它必须是顶层函数，
/// 不能写成闭包：闭包捕获的对象在 Dart 里不允许跨 isolate 传。
void installAiUdfs(Database db) {
  _udfDb = db;
  for (final entry in _functions.entries) {
    db.createFunction(
      functionName: entry.key,
      argumentCount: const AllowedArgumentCount.any(),
      function: entry.value,
    );
  }
}

/// 全部函数：名字 → 实现。名字**必须与 ai_functions.dart 的清单一致**。
const _functions = <String, ScalarFunction>{
  'list_notebooks': _listNotebooks,
  'list_notes': _listNotes,
  'list_unfiled': _listUnfiled,
  'stat_note': _statNote,
  'read_preview': _readPreview,
  'read_around': _readAround,
  'find_in_note': _findInNote,
  'search_notes': _searchNotes,
  'search_in_note': _searchInNote,
  'count_notes': _countNotes,
  'recent_notes': _recentNotes,
  'create_note': _createNote,
  'create_notebook': _createNotebook,
  'duplicate_note': _duplicateNote,
  'replace_unique': _replaceUnique,
  'delete_unique': _deleteUnique,
  'insert_after': _insertAfter,
  'insert_before': _insertBefore,
  'append_to_note': _appendToNote,
  'prepend_to_note': _prependToNote,
  'rename_note': _renameNote,
  'move_note': _moveNote,
  'rename_notebook': _renameNotebook,
  'delete_note': _deleteNote,
  'delete_notebook': _deleteNotebook,
};

// ============================================================================
// 触发器
// ============================================================================

/// 开库时执行（幂等）。
///
/// 放在 beforeOpen 而不是迁移里：迁移只在新版本第一次打开时跑一次，
/// 而「老库的触发器被谁手工删了」这种事，只有每次打开都对一遍才修得回来。
Future<void> installAiTriggers(GeneratedDatabase db) async {
  for (final sql in kAiTriggerStatements) {
    await db.customStatement(sql);
  }
}

/// AI 操作层的触发器。
///
/// **只有一件事：正文变了就清掉这篇笔记的切片。**
///
/// 为什么不顺手把 excerpt / word_count 也算在这里（设计初稿是那么写的）：
/// SQL 里复现不了 App 的口径 —— TextUtils.excerpt 要**剥掉 Markdown**、
/// wordCountOfMarkdown 是「中文按字 + 英文按词」。SQL 版只能写出
/// substr(content, 1, 200) 和 length(content)，那会让同一篇笔记
/// 「手写一个字数、AI 改一下变成另一个字数」（note_repository.dart 的类注释
/// 把这条口径不一致列为必须避免的事）。所以派生字段由 UDF 用 Dart 算好、
/// 和正文同一条 UPDATE 写下去，触发器只干 SQL 干得了的那件事。
///
/// 清切片必须做、而且必须由触发器兜底：切片只存偏移（不存正文），
/// 正文一改偏移就全错，而错了不会报错、只会让搜索跳到别的地方
///（见 tables.dart 里 note_chunks 的说明）。
const kAiTriggerStatements = <String>[
  '''
CREATE TRIGGER IF NOT EXISTS ai_notes_content_changed
AFTER UPDATE OF content ON notes
WHEN OLD.content IS NOT NEW.content
BEGIN
  DELETE FROM note_chunks WHERE note_id = NEW.id;
END
''',
];

// ============================================================================
// 参数 / 结果
// ============================================================================

const _noDb = 'AI 数据库函数没装到这条连接上（见 core/db/ai_udfs.dart）。';

/// drift 把 DateTime 存成 **Unix 秒**（storeDateTimeAsText 默认关）。
/// 写时间戳必须用这个：写毫秒会让「最近更新」排序与相对时间全乱。
int _now() => DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;

/// 第 i 个参数（没传就是 null，由函数体给默认值）。
Object? _arg(SqliteArguments c, int i) => i < c.length ? c[i] : null;

String? _str(SqliteArguments c, int i) {
  final v = _arg(c, i);
  if (v == null) return null;
  return v is String ? v : v.toString();
}

/// 取一个整数参数并夹到 [min, max]。取不到 / 不是数就用 fallback。
int _num(SqliteArguments c, int i, int fallback, {required int min, required int max}) {
  final v = _arg(c, i);
  final int n;
  if (v is int) {
    n = v;
  } else if (v is num) {
    n = v.toInt();
  } else if (v is String) {
    n = int.tryParse(v) ?? fallback;
  } else {
    n = fallback;
  }
  return n.clamp(min, max).toInt();
}

/// 把结果写成一行 JSON。**所有函数的返回值都是文本**，
/// 这样 AI 看到的形状永远一致：成功是数据，失败是 {ok:false,error}。
String _json(Object? value) => jsonEncode(value);

String _err(String message) =>
    jsonEncode({'ok': false, 'error': message});

/// 函数体统一的开场：拿连接（没装好返回 null，调用方回错）。
Database? _dbOf() => _udfDb;

Row? _noteRow(String id) {
  final rows = _udfDb!.select(
    'SELECT * FROM notes WHERE id = ? AND deleted_at IS NULL',
    [id],
  );
  return rows.isEmpty ? null : rows.first;
}

Row? _notebookRow(String id) {
  final rows = _udfDb!.select(
    'SELECT * FROM notebooks WHERE id = ? AND deleted_at IS NULL',
    [id],
  );
  return rows.isEmpty ? null : rows.first;
}

/// 时间列 → ISO 8601（UTC）。
///
/// 秒和毫秒都认（drift 默认写秒；万一哪天开了 storeDateTimeAsText，
/// 这里会拿到字符串，那就原样返回）。
String _iso(Object? v) {
  if (v == null) return '';
  if (v is int) {
    final ms = v > 100000000000 ? v : v * 1000;
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();
  }
  return v.toString();
}

// ============================================================================
// 文本工具
// ============================================================================

bool _isLowSurrogate(int c) => c >= 0xDC00 && c <= 0xDFFF;

/// 按**字符**切一段，不切坏代理对（emoji 这类字符由两个码元组成，
/// 切一半会渲染成方框）。偏移按 Dart 的 UTF-16 码元算，与 read_preview
/// 的 offset 口径一致。
String _slice(String text, int start, int end) {
  var s = start.clamp(0, text.length).toInt();
  var e = end.clamp(0, text.length).toInt();
  if (s > e) {
    final t = s;
    s = e;
    e = t;
  }
  if (s > 0 && s < text.length && _isLowSurrogate(text.codeUnitAt(s))) s -= 1;
  if (e > 0 && e < text.length && _isLowSurrogate(text.codeUnitAt(e))) e -= 1;
  return text.substring(s, e);
}

/// keyword 在 text 里的出现次数与第一次的位置（找不到时 first 为 -1）。
({int count, int first}) _hits(String text, String keyword) {
  var count = 0;
  var first = -1;
  var from = 0;
  while (true) {
    final i = text.indexOf(keyword, from);
    if (i < 0) break;
    if (first < 0) first = i;
    count++;
    from = i + keyword.length;
  }
  return (count: count, first: first);
}

/// 命中位置前后各 40 字（SqlLimits.snippetRadius），换行压成空格。
String _snippet(String content, int index, int matchLength) {
  const radius = SqlLimits.snippetRadius;
  final from = index - radius < 0 ? 0 : index - radius;
  final to = (index + matchLength + radius).clamp(0, content.length).toInt();
  final text = _slice(content, from, to).replaceAll(RegExp(r'\s+'), ' ').trim();
  final head = from > 0 ? '…' : '';
  final tail = to < content.length ? '…' : '';
  return '$head$text$tail';
}

String _likePattern(String keyword) {
  final escaped = keyword
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');
  return '%$escaped%';
}

/// 写正文前的硬上限检查。超了**拒绝**、不截断：静默截断等于悄悄吃掉用户的字，
/// 而模型还会以为写成功了（上限与 App 的「拒绝保存」是同一个 100KB）。
String? _checkSize(String content) {
  if (AiLimits.byteLength(content) <= AiLimits.noteHardBytes) return null;
  final kb = AiLimits.noteHardBytes ~/ 1024;
  return '正文超过 ${kb}KB 上限，已拒绝。'
      '请拆成多篇，或改用 replace_unique 只改需要的段落。';
}

/// 锚点必须在正文里**唯一出现**，否则拒绝。
///
/// 这是这一版约束的核心：不唯一就动手改，等于让模型赌一把 ——
/// 赌错了用户看不见（改错了地方，正文照样「保存成功」）。
/// 所以宁可让它失败一次、拿到一句可读的抱怨（把锚点写长一点再试），
/// 也不要静默改错。
String? _anchorError(String content, String anchor) {
  if (anchor.isEmpty) return '锚点不能是空字符串。';
  final h = _hits(content, anchor);
  if (h.count == 0) {
    return '正文里没有「$anchor」。先用 read_around / find_in_note 看清原文再改。';
  }
  if (h.count > 1) {
    return '「$anchor」在正文里出现 ${h.count} 次，不唯一，已拒绝。'
        '把锚点写长一点（带上前后几个字）再试。';
  }
  return null;
}

/// 正文 + 派生字段一条 UPDATE 写完（见文件头与 kAiTriggerStatements）。
/// 返回错误文本；成功返回 null。
String? _writeContent(String noteId, String content) {
  final sizeErr = _checkSize(content);
  if (sizeErr != null) return sizeErr;
  _udfDb!.execute(
    'UPDATE notes SET content = ?, excerpt = ?, word_count = ?, updated_at = ? '
    'WHERE id = ?',
    [
      content,
      TextUtils.excerpt(content),
      TextUtils.wordCountOfMarkdown(content),
      _now(),
      noteId,
    ],
  );
  return null;
}


/// LIKE 通配的转义声明。
///
/// 用 Dart 的**原始字符串**写反斜杠：不这么做就得数反斜杠的个数
///（`ESCAPE '\\'` 在 Dart 里要写四个），最容易数错的就是这里。
const _likeEscape = r" ESCAPE '\'";

/// 列表页用的三列：不带正文（正文按需用 read_preview / read_around 拿）。
Map<String, Object?> _brief(Row r) => {
  'id': r['id'],
  'title': r['title'],
  'updated_at': _iso(r['updated_at']),
};

/// keyword 的全部命中位置（最多 max 个）。
List<int> _allHits(String text, String keyword, int max) {
  final out = <int>[];
  var from = 0;
  while (out.length < max) {
    final i = text.indexOf(keyword, from);
    if (i < 0) break;
    out.add(i);
    from = i + keyword.length;
  }
  return out;
}

/// 笔记开头 80 字，给「只命中标题」的搜索结果当片段用。
String _head(String content) {
  final text = _slice(content, 0, 80).replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty) return '（空笔记）';
  return '$text…';
}

// ============================================================================
// 读（11 个）
// ============================================================================

/// 列全部笔记库。AI 拿 notebook_id 的唯一入口。
Object? _listNotebooks(SqliteArguments c) {
  final db = _dbOf();
  if (db == null) return _err(_noDb);
  final rows = db.select(
    'SELECT id, name FROM notebooks WHERE deleted_at IS NULL '
    'ORDER BY sort_order, name',
  );
  return _json([
    for (final r in rows) {'id': r['id'], 'name': r['name']},
  ]);
}

Object? _listNotes(SqliteArguments c) {
  final db = _dbOf();
  if (db == null) return _err(_noDb);
  final id = _str(c, 0);
  if (id == null || id.isEmpty) {
    return _err(
        'list_notes 需要 notebook_id。先用 list_notebooks 拿 id；要列未归档的笔记用 list_unfiled。');
  }
  final rows = db.select(
    'SELECT id, title, updated_at FROM notes '
    'WHERE notebook_id = ? AND deleted_at IS NULL ORDER BY updated_at DESC',
    [id],
  );
  return _json([for (final r in rows) _brief(r)]);
}

/// 未归档的笔记 =「我的轻笔记」。
///
/// 条件与 App 的 watchInboxNotes 一致：is_inbox = 1 **且** notebook_id 为空。
/// 两个条件都要：只看 is_inbox 会把「已归档但笔记库被删」的历史残留也算进来。
Object? _listUnfiled(SqliteArguments c) {
  final db = _dbOf();
  if (db == null) return _err(_noDb);
  final rows = db.select(
    'SELECT id, title, updated_at FROM notes '
    'WHERE is_inbox = 1 AND notebook_id IS NULL AND deleted_at IS NULL '
    'ORDER BY updated_at DESC',
  );
  return _json([for (final r in rows) _brief(r)]);
}

/// 元信息。**故意不给正文、不给行数**：正文要按需读（read_preview / read_around），
/// 一次把几万字灌进上下文，是这个 App 最不想付的账。
Object? _statNote(SqliteArguments c) {
  if (_dbOf() == null) return _err(_noDb);
  final id = _str(c, 0);
  if (id == null || id.isEmpty) return _err('stat_note 需要 note_id。');
  final row = _noteRow(id);
  if (row == null) return _err('没有 id = $id 的笔记（或它已被删除）。');
  final content = (row['content'] as String?) ?? '';
  return _json({
    'title': row['title'],
    'notebook_id': row['notebook_id'],
    'char_count': content.length,
    'created_at': _iso(row['created_at']),
    'updated_at': _iso(row['updated_at']),
  });
}

/// 从第 offset 个字符起读 chars 个字符。
///
/// chars 有硬上限（SqlLimits.maxReadChars）。但要知道它只是**函数这一层的**上限：
/// AI 仍然可以直接 `SELECT content` 把整篇拿走。真正拦住「读全文」的是 prompt
/// 与「读一次要烧一次上下文」的成本，不是这个 clamp —— 别把它当成安全边界。
Object? _readPreview(SqliteArguments c) {
  if (_dbOf() == null) return _err(_noDb);
  final id = _str(c, 0);
  if (id == null || id.isEmpty) return _err('read_preview 需要 note_id。');
  final row = _noteRow(id);
  if (row == null) return _err('没有 id = $id 的笔记（或它已被删除）。');
  final content = (row['content'] as String?) ?? '';
  final offset = _num(c, 1, 0, min: 0, max: content.length);
  final chars = _num(c, 2, SqlLimits.defaultReadChars,
      min: 1, max: SqlLimits.maxReadChars);
  final end = offset + chars > content.length ? content.length : offset + chars;
  return _slice(content, offset, end);
}

/// 关键词前后各 chars 个字符。**按字符，不按行** ——
/// 笔记正文是 Markdown，长段落可能是一整行，按行取等于把半篇灌进上下文。
Object? _readAround(SqliteArguments c) {
  if (_dbOf() == null) return _err(_noDb);
  final id = _str(c, 0);
  if (id == null || id.isEmpty) return _err('read_around 需要 note_id 与 keyword。');
  final keyword = _str(c, 1);
  if (keyword == null || keyword.isEmpty) {
    return _err('read_around 需要 note_id 与 keyword。');
  }
  final row = _noteRow(id);
  if (row == null) return _err('没有 id = $id 的笔记（或它已被删除）。');
  final content = (row['content'] as String?) ?? '';
  final chars = _num(c, 2, SqlLimits.defaultReadChars,
      min: 1, max: SqlLimits.maxReadChars);
  final idx = content.indexOf(keyword);
  if (idx < 0) {
    return _err('正文里没有「$keyword」。先用 search_in_note 看看这篇里都有什么。');
  }
  final from = idx - chars < 0 ? 0 : idx - chars;
  final to = (idx + keyword.length + chars).clamp(0, content.length).toInt();
  final head = from > 0 ? '…' : '';
  final tail = to < content.length ? '…' : '';
  return '$head${_slice(content, from, to)}$tail';
}

/// 数关键词出现几次、都在哪。**改之前的侦察工具**：
/// replace_unique 要求锚点唯一，先用它确认。
Object? _findInNote(SqliteArguments c) {
  if (_dbOf() == null) return _err(_noDb);
  final id = _str(c, 0);
  final keyword = _str(c, 1);
  if (id == null || id.isEmpty || keyword == null || keyword.isEmpty) {
    return _err('find_in_note 需要 note_id 与 keyword。');
  }
  final row = _noteRow(id);
  if (row == null) return _err('没有 id = $id 的笔记（或它已被删除）。');
  final content = (row['content'] as String?) ?? '';
  return _json({
    'count': _hits(content, keyword).count,
    'positions': _allHits(content, keyword, SqlLimits.maxFindPositions),
  });
}

/// 全库搜标题 + 正文。
///
/// 只回 id / title / snippet，**不回正文**：命中之后用 read_around 定位那一段，
/// 比把整篇灌进来便宜得多。
Object? _searchNotes(SqliteArguments c) {
  final db = _dbOf();
  if (db == null) return _err(_noDb);
  final keyword = (_str(c, 0) ?? '').trim();
  if (keyword.isEmpty) return _err('search_notes 需要 keyword。');
  final limit = _num(c, 1, SqlLimits.defaultSearchLimit,
      min: 1, max: SqlLimits.maxSearchLimit);
  final pattern = _likePattern(keyword);
  final rows = db.select(
    'SELECT id, title, content FROM notes WHERE deleted_at IS NULL '
    'AND (title LIKE ?$_likeEscape OR content LIKE ?$_likeEscape) '
    'ORDER BY updated_at DESC LIMIT ?',
    [pattern, pattern, limit],
  );
  final lower = keyword.toLowerCase();
  final out = <Map<String, Object?>>[];
  for (final r in rows) {
    final content = (r['content'] as String?) ?? '';
    final idx = content.toLowerCase().indexOf(lower);
    out.add({
      'id': r['id'],
      'title': r['title'],
      'snippet': idx >= 0 ? _snippet(content, idx, keyword.length) : _head(content),
    });
  }
  return _json(out);
}

/// 在一篇笔记里找全部命中。offset 可以直接喂给 read_preview。
Object? _searchInNote(SqliteArguments c) {
  if (_dbOf() == null) return _err(_noDb);
  final id = _str(c, 0);
  final keyword = _str(c, 1);
  if (id == null || id.isEmpty || keyword == null || keyword.isEmpty) {
    return _err('search_in_note 需要 note_id 与 keyword。');
  }
  final limit = _num(c, 2, SqlLimits.defaultSnippetLimit,
      min: 1, max: SqlLimits.maxSnippetLimit);
  final row = _noteRow(id);
  if (row == null) return _err('没有 id = $id 的笔记（或它已被删除）。');
  final content = (row['content'] as String?) ?? '';
  final lowerContent = content.toLowerCase();
  final lower = keyword.toLowerCase();
  final out = <Map<String, Object?>>[];
  var from = 0;
  while (out.length < limit) {
    final i = lowerContent.indexOf(lower, from);
    if (i < 0) break;
    out.add({'offset': i, 'snippet': _snippet(content, i, keyword.length)});
    from = i + keyword.length;
  }
  return _json(out);
}

/// 数条数。传 NULL 数全部（含未归档），传笔记库 id 只数这个库。
Object? _countNotes(SqliteArguments c) {
  final db = _dbOf();
  if (db == null) return _err(_noDb);
  final nb = _str(c, 0);
  final ResultSet rows = (nb == null || nb.isEmpty)
      ? db.select('SELECT COUNT(*) AS n FROM notes WHERE deleted_at IS NULL')
      : db.select(
          'SELECT COUNT(*) AS n FROM notes WHERE deleted_at IS NULL '
          'AND notebook_id = ?',
          [nb],
        );
  return rows.first['n'];
}

Object? _recentNotes(SqliteArguments c) {
  final db = _dbOf();
  if (db == null) return _err(_noDb);
  final limit = _num(c, 0, SqlLimits.defaultRecentLimit,
      min: 1, max: SqlLimits.maxSearchLimit);
  final rows = db.select(
    'SELECT id, title, updated_at FROM notes WHERE deleted_at IS NULL '
    'ORDER BY updated_at DESC LIMIT ?',
    [limit],
  );
  return _json([for (final r in rows) _brief(r)]);
}

// ============================================================================
// 创建（3 个）
// ============================================================================

/// 新建笔记。notebook_id 省略或传 NULL = 进「我的轻笔记」。
///
/// 与 NoteRepository._create 写的是同一组列：source 记 'ai'（这张表当初就为此
/// 留了这个取值），派生字段走 TextUtils，时间戳是 Unix 秒。
Object? _createNote(SqliteArguments c) {
  final db = _dbOf();
  if (db == null) return _err(_noDb);
  final title = safeTruncate((_str(c, 0) ?? '').trim(), AiLimits.titleHardMax);
  final content = _str(c, 1) ?? '';
  var notebookId = _str(c, 2);
  if (notebookId != null && notebookId.isEmpty) notebookId = null;
  if (notebookId != null && _notebookRow(notebookId) == null) {
    return _err(
        '没有 id = $notebookId 的笔记库。先用 list_notebooks 确认；要放进「我的轻笔记」就传 NULL。');
  }
  final sizeErr = _checkSize(content);
  if (sizeErr != null) return _err(sizeErr);

  final id = _uuid.v4();
  final now = _now();
  db.execute(
    'INSERT INTO notes (id, notebook_id, title, content, excerpt, source, is_inbox, '
    'pinned, word_count, last_ai_at, created_at, updated_at, deleted_at) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, NULL)',
    [
      id,
      notebookId,
      title,
      content,
      TextUtils.excerpt(content),
      'ai',
      notebookId == null ? 1 : 0,
      0,
      TextUtils.wordCountOfMarkdown(content),
      now,
      now,
    ],
  );
  return _json({'ok': true, 'note_id': id});
}

Object? _createNotebook(SqliteArguments c) {
  final db = _dbOf();
  if (db == null) return _err(_noDb);
  final name = (_str(c, 0) ?? '').trim();
  if (name.isEmpty) return _err('笔记库名不能为空。');
  final id = _uuid.v4();
  final now = _now();
  db.execute(
    'INSERT INTO notebooks (id, name, sort_order, created_at, updated_at, deleted_at) '
    'VALUES (?, ?, 0, ?, ?, NULL)',
    [id, safeTruncate(name, AiLimits.titleHardMax), now, now],
  );
  return _json({'ok': true, 'notebook_id': id});
}

/// 复制一篇笔记。
///
/// 复制出来的**不置顶、没有切片**：切片会在第一次被读到时按需现切
///（NoteChunkRepository 的懒回填），所以这里不用管它。
Object? _duplicateNote(SqliteArguments c) {
  final db = _dbOf();
  if (db == null) return _err(_noDb);
  final id = _str(c, 0);
  if (id == null || id.isEmpty) return _err('duplicate_note 需要 note_id。');
  final src = _noteRow(id);
  if (src == null) return _err('没有 id = $id 的笔记（或它已被删除）。');

  final content = (src['content'] as String?) ?? '';
  final newId = _uuid.v4();
  final now = _now();
  db.execute(
    'INSERT INTO notes (id, notebook_id, title, content, excerpt, source, is_inbox, '
    'pinned, word_count, last_ai_at, created_at, updated_at, deleted_at) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, NULL, ?, ?, NULL)',
    [
      newId,
      src['notebook_id'],
      src['title'],
      content,
      TextUtils.excerpt(content),
      src['source'],
      src['is_inbox'],
      TextUtils.wordCountOfMarkdown(content),
      now,
      now,
    ],
  );
  return _json({'ok': true, 'new_note_id': newId});
}

// ============================================================================
// 修改（9 个）
// ============================================================================

/// replace_unique / delete_unique 的公共实现。
///
/// delete_unique 等价于把 old 换成空串 —— 两者共用一条路径，
/// 所以「锚点必须唯一」这条规则不可能只在其中一个上生效。
Object? _uniqueReplace(SqliteArguments c, {required bool remove}) {
  final db = _dbOf();
  if (db == null) return _err(_noDb);
  final id = _str(c, 0);
  final old = _str(c, 1);
  final added = remove ? '' : _str(c, 2);
  if (id == null || id.isEmpty || old == null || added == null) {
    return _err(remove
            ? 'delete_unique 需要 note_id 与 old 两个参数。'
            : 'replace_unique 需要 note_id、old、new 三个参数。');
  }
  final note = _noteRow(id);
  if (note == null) return _err('没有 id = $id 的笔记（或它已被删除）。');
  final content = (note['content'] as String?) ?? '';
  final bad = _anchorError(content, old);
  if (bad != null) return _err(bad);
  final writeErr = _writeContent(id, content.replaceFirst(old, added));
  if (writeErr != null) return _err(writeErr);
  return _json({'ok': true});
}

Object? _replaceUnique(SqliteArguments c) => _uniqueReplace(c, remove: false);

Object? _deleteUnique(SqliteArguments c) => _uniqueReplace(c, remove: true);

/// insert_after / insert_before 的公共实现。
///
/// 插入的内容自带一个换行：这两个函数的用途是「在这一段前后加一句」，
/// 而 Markdown 里不加换行会把新内容接进原来那一行，读起来是错的。
Object? _insertAt(SqliteArguments c, {required bool after}) {
  final db = _dbOf();
  if (db == null) return _err(_noDb);
  final id = _str(c, 0);
  final anchor = _str(c, 1);
  final added = _str(c, 2);
  if (id == null || id.isEmpty || anchor == null || added == null) {
    final name = after ? 'insert_after' : 'insert_before';
    return _err('$name 需要 note_id、anchor、content 三个参数。');
  }
  final note = _noteRow(id);
  if (note == null) return _err('没有 id = $id 的笔记（或它已被删除）。');
  final content = (note['content'] as String?) ?? '';
  final bad = _anchorError(content, anchor);
  if (bad != null) return _err(bad);

  final at = content.indexOf(anchor);
  final String next;
  if (after) {
    final cut = at + anchor.length;
    next = '${_slice(content, 0, cut)}\n$added${_slice(content, cut, content.length)}';
  } else {
    next = '${_slice(content, 0, at)}$added\n${_slice(content, at, content.length)}';
  }
  final writeErr = _writeContent(id, next);
  if (writeErr != null) return _err(writeErr);
  return _json({'ok': true});
}

Object? _insertAfter(SqliteArguments c) => _insertAt(c, after: true);

Object? _insertBefore(SqliteArguments c) => _insertAt(c, after: false);

Object? _appendToNote(SqliteArguments c) {
  final db = _dbOf();
  if (db == null) return _err(_noDb);
  final id = _str(c, 0);
  final added = _str(c, 1);
  if (id == null || id.isEmpty || added == null) {
    return _err('append_to_note 需要 note_id 与 content。');
  }
  final note = _noteRow(id);
  if (note == null) return _err('没有 id = $id 的笔记（或它已被删除）。');
  final content = (note['content'] as String?) ?? '';
  final String next;
  if (content.isEmpty) {
    next = added;
  } else if (content.endsWith('\n')) {
    next = '$content$added';
  } else {
    next = '$content\n$added';
  }
  final writeErr = _writeContent(id, next);
  if (writeErr != null) return _err(writeErr);
  return _json({'ok': true});
}

Object? _prependToNote(SqliteArguments c) {
  final db = _dbOf();
  if (db == null) return _err(_noDb);
  final id = _str(c, 0);
  final added = _str(c, 1);
  if (id == null || id.isEmpty || added == null) {
    return _err('prepend_to_note 需要 note_id 与 content。');
  }
  final note = _noteRow(id);
  if (note == null) return _err('没有 id = $id 的笔记（或它已被删除）。');
  final content = (note['content'] as String?) ?? '';
  final next = content.isEmpty ? added : '$added\n$content';
  final writeErr = _writeContent(id, next);
  if (writeErr != null) return _err(writeErr);
  return _json({'ok': true});
}

Object? _renameNote(SqliteArguments c) {
  final db = _dbOf();
  if (db == null) return _err(_noDb);
  final id = _str(c, 0);
  final rawTitle = _str(c, 1);
  if (id == null || id.isEmpty || rawTitle == null) {
    return _err('rename_note 需要 note_id 与 new_title。');
  }
  if (_noteRow(id) == null) {
    return _err('没有 id = $id 的笔记（或它已被删除）。');
  }
  db.execute(
    'UPDATE notes SET title = ?, updated_at = ? WHERE id = ?',
    [safeTruncate(rawTitle.trim(), AiLimits.titleHardMax), _now(), id],
  );
  return _json({'ok': true});
}

/// 移动笔记。notebook_id 传 NULL = 移回「我的轻笔记」。
///
/// is_inbox 跟着一起改：它和 notebook_id 是同一个意思的两种表示
///（见 AppDatabase.moveNoteToNotebook），只改一个会留下
/// 「已归档但没有笔记库」的行 —— 那种行在两个入口都看不见。
Object? _moveNote(SqliteArguments c) {
  final db = _dbOf();
  if (db == null) return _err(_noDb);
  final id = _str(c, 0);
  if (id == null || id.isEmpty) return _err('move_note 需要 note_id。');
  if (_noteRow(id) == null) {
    return _err('没有 id = $id 的笔记（或它已被删除）。');
  }
  var notebookId = _str(c, 1);
  if (notebookId != null && notebookId.isEmpty) notebookId = null;
  if (notebookId != null && _notebookRow(notebookId) == null) {
    return _err(
        '没有 id = $notebookId 的笔记库。先用 list_notebooks 确认；要移回「我的轻笔记」就传 NULL。');
  }
  if (notebookId == null) {
    db.execute(
      'UPDATE notes SET notebook_id = NULL, is_inbox = 1, updated_at = ? WHERE id = ?',
      [_now(), id],
    );
  } else {
    db.execute(
      'UPDATE notes SET notebook_id = ?, is_inbox = 0, updated_at = ? WHERE id = ?',
      [notebookId, _now(), id],
    );
  }
  return _json({'ok': true});
}

Object? _renameNotebook(SqliteArguments c) {
  final db = _dbOf();
  if (db == null) return _err(_noDb);
  final id = _str(c, 0);
  final name = (_str(c, 1) ?? '').trim();
  if (id == null || id.isEmpty) {
    return _err('rename_notebook 需要 notebook_id 与 new_name。');
  }
  if (name.isEmpty) return _err('笔记库名不能为空。');
  if (_notebookRow(id) == null) {
    return _err('没有 id = $id 的笔记库（或它已被删除）。先用 list_notebooks 确认。');
  }
  db.execute(
    'UPDATE notebooks SET name = ?, updated_at = ? WHERE id = ?',
    [safeTruncate(name, AiLimits.titleHardMax), _now(), id],
  );
  return _json({'ok': true});
}

// ============================================================================
// 删除（2 个）
// ============================================================================

/// 删笔记 = **逻辑删除**（deleted_at 置位，行还在）+ 清切片。
///
/// 与 NoteRepository.softDelete 完全一致，包括「显式清切片」那一步：
/// 切片表的外键虽然带 CASCADE，但软删除不会触发行级联，
/// 留着片会让搜索把「命中哪一片」算到已经删掉的笔记头上。
///
/// 设计上这是**不可撤销**的：界面上没有回收站入口，所以 prompt 明确要求
/// 「只在用户明确要求删的时候才调」，且没有确认层。
Object? _deleteNote(SqliteArguments c) {
  final db = _dbOf();
  if (db == null) return _err(_noDb);
  final id = _str(c, 0);
  if (id == null || id.isEmpty) return _err('delete_note 需要 note_id。');
  if (_noteRow(id) == null) {
    return _err('没有 id = $id 的笔记（或它已被删除）。');
  }
  final now = _now();
  db.execute(
    'UPDATE notes SET deleted_at = ?, updated_at = ? WHERE id = ?',
    [now, now, id],
  );
  db.execute('DELETE FROM note_chunks WHERE note_id = ?', [id]);
  return _json({'ok': true});
}

/// 删笔记库：**库里的笔记不删**，退回「我的轻笔记」。
///
/// 顺序与 AppDatabase.softDeleteNotebook 一致：先把笔记挪出去，再删库。
/// 反过来的话，中间失败会留下「笔记指向一个已删的库」—— 那种笔记
/// 只在「最近笔记」里看得见，库页里找不到。
Object? _deleteNotebook(SqliteArguments c) {
  final db = _dbOf();
  if (db == null) return _err(_noDb);
  final id = _str(c, 0);
  if (id == null || id.isEmpty) return _err('delete_notebook 需要 notebook_id。');
  if (_notebookRow(id) == null) {
    return _err('没有 id = $id 的笔记库（或它已被删除）。先用 list_notebooks 确认。');
  }
  final now = _now();
  db.execute(
    'UPDATE notes SET notebook_id = NULL, is_inbox = 1, updated_at = ? '
    'WHERE notebook_id = ? AND deleted_at IS NULL',
    [now, id],
  );
  db.execute(
    'UPDATE notebooks SET deleted_at = ?, updated_at = ? WHERE id = ?',
    [now, now, id],
  );
  return _json({'ok': true});
}
