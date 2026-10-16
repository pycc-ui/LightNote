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
//   AI 写：SELECT update_notes_batch('[{"id":"n1","old":"主要风险是时间紧","new":"风险已识别"}]');
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

/// 把 26 个函数注册到一条连接上。**开库时调用一次**（见 AppDatabase 的 _openConnection）。
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
  'outline_notes': _outlineNotes,
  'list_notes': _listNotes,
  'list_unfiled': _listUnfiled,
  'read_note_batch': _readNoteBatch,
  'read_around': _readAround,
  'find_in_note': _findInNote,
  'search_notes': _searchNotes,
  'search_in_note': _searchInNote,
  'count_notes': _countNotes,
  'recent_notes': _recentNotes,
  'create_notebook': _createNotebook,
  'duplicate_note': _duplicateNote,
  'create_notes_batch': _createNotesBatch,
  'insert_after': _insertAfter,
  'insert_before': _insertBefore,
  'prepend_to_note': _prependToNote,
  'rename_note': _renameNote,
  'rename_notebook': _renameNotebook,
  'update_notes_batch': _updateNotesBatch,
  'append_notes_batch': _appendNotesBatch,
  'move_notes_batch': _moveNotesBatch,
  'delete_notebook': _deleteNotebook,
  'delete_notes_batch': _deleteNotesBatch,
  'finish': _finish,
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

/// 成功结果的统一形状：`{ok, description, data}`。
///
/// `description` 是**给模型看的一句话操作摘要**（如「删除笔记 n1「会议记录」」）。
/// 历史压缩只会压 `data`、保留 `ok` 与 `description`，
/// 于是模型下一轮仍知道"刚才做了什么"（见 agent_loop.dart 的 _compressToolResult）。
String _ok(Object? data, {required String description}) =>
    _json({'ok': true, 'description': description, 'data': data});

/// 描述里的短引用：压到 [max] 字，超了加省略号。
String _short(String s, {int max = 30}) =>
    s.length <= max ? s : '${s.substring(0, max)}…';

/// 批量函数内部用它把某一项的失败冒泡出去 → 整批回滚。
class _BatchError implements Exception {
  _BatchError(this.message);
  final String message;
}

/// 解析批量函数的 JSON 数组参数。
///
/// 返回 `(items, error)`：任一项不合法就把整体当错误（不做部分处理）。
/// 上限 [SqlLimits.maxBatchSize]，超了**拒绝**。
({List<Object?> items, String? error}) _parseBatch(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return (items: const [], error: '批量函数需要一个 JSON 数组字符串。');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return (
      items: const [],
      error: '参数不是合法 JSON。SQL 里用单引号包数组、JSON 内层用双引号。',
    );
  }
  if (decoded is! List) {
    return (items: const [], error: '批量参数必须是 JSON 数组。');
  }
  if (decoded.isEmpty) {
    return (items: const [], error: '批量数组不能为空。');
  }
  if (decoded.length > SqlLimits.maxBatchSize) {
    return (
      items: const [],
      error: '一次最多 ${SqlLimits.maxBatchSize} 条，收到 ${decoded.length} 条。',
    );
  }
  return (items: decoded, error: null);
}

/// 取一项里的字符串字段（缺键返回 null）。
String? _itemStr(Map<String, Object?> item, String key) {
  final v = item[key];
  if (v == null) return null;
  return v is String ? v : v.toString();
}

/// 把一批写操作包进一个事务：任一项失败（抛 [_BatchError]）全部回滚。
T _tx<T>(T Function() body) {
  final db = _udfDb!;
  db.execute('BEGIN');
  try {
    final r = body();
    db.execute('COMMIT');
    return r;
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

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
/// 正文尺寸校验。[existing] 是**改已有笔记时**的旧正文（新建传 null）。
///
/// 规则是「**只管增长**」：`新字节数 ≤ max(旧字节数, 硬上限)` 就放行。
///
/// 为什么不是简单的一刀切：硬上限从 100KB 收到 50KB 之后，**老库里已经有**
/// 按旧上限写下的笔记。一刀切会把用户卡死 —— 打开那篇 80KB 的、改一个字都存不了，
/// 唯一的出路是编辑器里那个"裁剪到软上限"，而那是**删内容且不可撤销**。
/// 于是规则定为：老笔记不被锁死，但**也不能再变长**（上限管的是增长）。
String? _checkSize(String content, {String? existing}) {
  final now = AiLimits.byteLength(content);
  if (now <= AiLimits.noteHardBytes) return null;
  if (existing != null && now <= AiLimits.byteLength(existing)) return null;
  final kb = AiLimits.noteHardBytes ~/ 1024;
  return '正文超过 ${kb}KB 上限，已拒绝。'
      '请拆成多篇，或改用 update_notes_batch 只改需要的段落。';
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
  // 改已有笔记：把旧正文带进去比较（老的超限笔记只要不变长就放行，见 _checkSize）
  final old = _udfDb!
      .select('SELECT content FROM notes WHERE id = ?', [noteId]);
  final oldContent = old.isEmpty ? null : (old.first['content'] as String?);
  final sizeErr = _checkSize(content, existing: oldContent);
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
  final data = [
    for (final r in rows) {'id': r['id'], 'name': r['name']},
  ];
  return _ok(data, description: '列出所有笔记库（${data.length} 个）');
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
  final data = [for (final r in rows) _brief(r)];
  return _ok(data, description: '列出笔记库 $id 的笔记（${data.length} 篇）');
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
  final data = [for (final r in rows) _brief(r)];
  return _ok(data, description: '列出「我的轻笔记」（${data.length} 篇）');
}

/// 从第 offset 个字符起读 chars 个字符。
///
/// chars 有硬上限（SqlLimits.maxReadChars）。但要知道它只是**函数这一层的**上限：
/// AI 仍然可以直接 `SELECT content` 把整篇拿走。真正拦住「读全文」的是 prompt
/// 与「读一次要烧一次上下文」的成本，不是这个 clamp —— 别把它当成安全边界。
/// `outline_notes(json)`：一次拿多篇的**目录 + 摘要**（不含正文）。
///
/// `json` = `["n1","n2"]` 或 `[{"id":"n1"}]`，上限 [SqlLimits.maxOutlineNotes] 篇。
/// 返回 `[{id, title, notebook_id, chars, excerpt, created_at, updated_at,
/// sections:[{level, heading, offset, chars}]}]`。
///
/// ## 三个刻意的设计
///
/// 1. **目录来自原文的 Markdown 标题（`#` 到 `######`），不是切片**。
///    标题是原文自带的结构，模型看的就是它自己也能看懂的文档结构；因此本函数
///    **不依赖 `NoteChunker`、也不读 `note_chunks` 表** —— 不会出现"表里的片是旧的、
///    和现算的对不上"那种静默错读。两者目的本就不同：片是给搜索/卡片流分块的，
///    目录是给人（和模型）看章节的，不该一致。
/// 2. **只给 `offset` + `chars`，不给片号**。模型只需要"从第几个字符读多少"，
///    偏移是文本自带的坐标；片号是我们发明的，它还永远算不出下一片在哪。
/// 3. **`excerpt` 直接带回来**（`notes.excerpt` 列一直在维护）——
///    选材时看它比读正文便宜几十倍。
///
/// ⚠️ 一节可能超过 `read_note_batch` 的单条上限 → 那时靠 `next_offset` 接着读。
/// 没有标题的笔记 → `sections: []`，模型按 `chars` 直接读整篇。
Object? _outlineNotes(SqliteArguments c) {
  if (_dbOf() == null) return _err(_noDb);

  final raw = _str(c, 0);
  if (raw == null || raw.trim().isEmpty) {
    return _err('outline_notes 需要 JSON 数组，如 outline_notes(\'["n1","n2"]\')。'
        'id 从 list_notes / recent_notes / search_notes 拿。');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return _err('参数不是合法 JSON。SQL 里用单引号包数组、JSON 内层用双引号。');
  }
  if (decoded is! List || decoded.isEmpty) {
    return _err('outline_notes 的参数必须是**非空**的 JSON 数组。');
  }
  if (decoded.length > SqlLimits.maxOutlineNotes) {
    return _err('一次最多 ${SqlLimits.maxOutlineNotes} 篇，收到 ${decoded.length} 篇。');
  }

  final out = <Map<String, Object?>>[];
  for (var i = 0; i < decoded.length; i++) {
    final e = decoded[i];
    final id = e is String ? e : (e is Map ? (_itemStr(e.cast<String, Object?>(), 'id') ?? '') : '');
    final nid = id.trim();
    if (nid.isEmpty) return _err('第 ${i + 1} 条缺 id。');
    final row = _noteRow(nid);
    if (row == null) {
      out.add({'id': nid, 'error': '没有这篇笔记（或它已被删除）'});
      continue;
    }
    final content = (row['content'] as String?) ?? '';
    out.add({
      'id': nid,
      'title': (row['title'] as String?) ?? '',
      'notebook_id': row['notebook_id'],
      'chars': content.length,
      'excerpt': (row['excerpt'] as String?) ?? '',
      'created_at': _iso(row['created_at']),
      'updated_at': _iso(row['updated_at']),
      'sections': _headingsOf(content),
    });
  }
  return _ok(out,
      description: '读取 ${out.length} 篇笔记的目录与摘要');
}

/// 扫 Markdown 标题，给出「节」列表：`[{level, heading, offset, chars}]`。
///
/// 一"节"的范围 = **从一个标题到下一个同级或更高级标题**（子标题算在父节里）。
/// 最后漏掉的那一节（没有下一标题）一直延到正文末尾。
///
/// 只认行首的 `#`（允许前置空格）：`# 标题` 是标题，`正文里的 # 号` 不是。
/// 代码围栏（```）里的 `#` 也不算 —— 那是代码注释，不是标题。
List<Map<String, Object?>> _headingsOf(String content) {
  if (content.isEmpty) return const [];

  // 先收集所有标题的位置与层级
  final heads = <({int level, String text, int start})>[];
  var inFence = false;
  var pos = 0;
  for (final line in content.split('\n')) {
    final lineStart = pos;
    pos += line.length + 1; // +1 = 换行
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    if (!trimmed.startsWith('#')) continue;
    var level = 0;
    while (level < trimmed.length && trimmed[level] == '#') {
      level++;
    }
    if (level > 6) continue; // `#######` 不是标题
    final text = trimmed.substring(level).trim();
    if (text.isEmpty) continue; // 光一个 `#` 不算标题
    heads.add((level: level, text: text, start: lineStart));
  }
  if (heads.isEmpty) return const [];

  // 每一节的结束位置 = 下一个"同级或更高级"标题的起点；最后一节到正文末尾
  final out = <Map<String, Object?>>[];
  for (var i = 0; i < heads.length; i++) {
    final h = heads[i];
    var end = content.length;
    for (var j = i + 1; j < heads.length; j++) {
      if (heads[j].level <= h.level) {
        end = heads[j].start;
        break;
      }
    }
    final text = _slice(content, h.start, end);
    out.add({
      'level': h.level,
      'heading': h.text,
      'offset': h.start,
      'chars': text.length,
    });
  }
  return out;
}

/// `read_note_batch(note_id, offset, chars)` 或 `read_note_batch(json)`。
///
/// **一个函数两种形式，按参数个数分发**（注册时用的是 `AllowedArgumentCount.any()`）：
///
///   · 三参数 = 读**一篇**的一段（沿用原来 `read_preview` 的写法）
///   · 一参数 = JSON 数组，读**一批**：`[{"id":"n1","offset":3120,"chars":700}, {"id":"n2"}]`
///
/// ## 为什么改名叫 `*_batch`
///
/// 命名要体现作用（与 `create_notes_batch` / `update_notes_batch` 同一约定：
/// **批量函数也用于单次**）。原来的 `read_preview` 只能读一篇一段，
/// 聚合类任务要读 7 篇就得 7+ 轮 —— 这是"整理 7 篇做不完"的直接原因。
///
/// ## 两条硬规矩
///
/// 1. **只认 offset，不认片号**。片是 App 派生的组织方式；让模型用片号读，
///    它就得理解我们的切片算法，而且 `note_chunks` 表可能是旧的（懒回填），
///    两套片号口径不同时会**静默读到别的内容**。
/// 2. **截断要说清、并给出 `next_offset`**：模型不用自己算 `offset + chars`
///    （那正是"让模型自己算 offset"的老毛病），拿着 next_offset 接着读就行。
///
/// 整批超上限 → **整批拒绝**（不截断），与写函数的 `maxBatchSize` 同一原则：
/// 截断会让模型以为整批都读到了，然后基于半截素材下结论。
Object? _readNoteBatch(SqliteArguments c) {
  if (_dbOf() == null) return _err(_noDb);

  // ---- 形式二：一参数 = 批量 ----
  if (c.length == 1) {
    final raw = _str(c, 0);
    if (raw == null || raw.trim().isEmpty) {
      return _err('read_note_batch 需要 JSON 数组，'
          '如 read_note_batch(\'[{"id":"n1","offset":0,"chars":700}]\')；'
          '读单篇也可以直接写 read_note_batch(\'n1\', 0, 200)。');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return _err('参数不是合法 JSON。要么给三个参数（id, offset, chars），'
          '要么给一个 JSON 数组。');
    }
    if (decoded is! List || decoded.isEmpty) {
      return _err('批量形式要给**非空**的 JSON 数组。');
    }
    if (decoded.length > SqlLimits.maxBatchReadNotes) {
      return _err('一次最多读 ${SqlLimits.maxBatchReadNotes} 条，'
          '收到 ${decoded.length} 条。请分批读（先读最要紧的那几篇）。',
          );
    }

    final out = <Map<String, Object?>>[];
    var total = 0;
    for (var i = 0; i < decoded.length; i++) {
      final e = decoded[i];
      if (e is! Map) return _err('第 ${i + 1} 条不是对象。');
      final m = e.cast<String, Object?>();
      final id = (_itemStr(m, 'id') ?? '').trim();
      if (id.isEmpty) return _err('第 ${i + 1} 条缺 id。');
      final row = _noteRow(id);
      if (row == null) {
        out.add({'id': id, 'error': '没有这篇笔记（或它已被删除）'});
        continue;
      }
      final content = (row['content'] as String?) ?? '';
      final offset = _intOf(m['offset'], 0).clamp(0, content.length);
      final chars = _intOf(m['chars'], SqlLimits.maxBatchReadCharsPerNote)
          .clamp(1, SqlLimits.maxBatchReadCharsPerNote);
      final end = offset + chars > content.length ? content.length : offset + chars;
      final text = _slice(content, offset, end);
      final truncated = end < content.length;
      total += text.length;
      if (total > SqlLimits.maxBatchReadChars) {
        return _err('这一批超过 ${SqlLimits.maxBatchReadChars} 字上限了。'
            '请**分批读**：先挑最要紧的几篇，读完再读下一批。');
      }
      out.add({
        'id': id,
        'title': (row['title'] as String?) ?? '',
        'offset': offset,
        'chars': text.length,
        'content': text,
        if (truncated) 'truncated': true,
        // 截断了就告诉它从哪接着读，别让它自己算
        if (truncated) 'next_offset': end,
      });
    }
    return _ok(out,
        description: '读取 ${out.length} 篇笔记的正文'
            '（共 ${out.where((e) => e['content'] != null).length} 篇有内容）');
  }

  // ---- 形式一：三参数 = 单篇的一段 ----
  final id = _str(c, 0);
  if (id == null || id.isEmpty) return _err('read_note_batch 需要 note_id。');
  final row = _noteRow(id);
  if (row == null) return _err('没有 id = $id 的笔记（或它已被删除）。');
  final content = (row['content'] as String?) ?? '';
  final offset = _num(c, 1, 0, min: 0, max: content.length);
  final chars = _num(c, 2, SqlLimits.maxBatchReadCharsPerNote,
      min: 1, max: SqlLimits.maxBatchReadCharsPerNote);
  final end = offset + chars > content.length ? content.length : offset + chars;
  final text = _slice(content, offset, end);
  final truncated = end < content.length;
  return _ok({
    'id': id,
    'title': (row['title'] as String?) ?? '',
    'offset': offset,
    'chars': text.length,
    'content': text,
    if (truncated) 'truncated': true,
    if (truncated) 'next_offset': end,
  }, description: '读取笔记 $id 的第 $offset-$end 字符'
      '${truncated ? '（还有后续，用 next_offset 接着读）' : ''}');
}

/// 从 JSON 值里取整数（缺省 / 不是数就用 [fallback]）。
int _intOf(Object? v, int fallback) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
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
  final data = '$head${_slice(content, from, to)}$tail';
  return _ok(data, description: '读取笔记 $id 中「${_short(keyword)}」周围内容');
}

/// 数关键词出现几次、都在哪。**改之前的侦察工具**：
/// update_notes_batch 要求锚点唯一，先用它确认。
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
  final count = _hits(content, keyword).count;
  final data = {
    'count': count,
    'positions': _allHits(content, keyword, SqlLimits.maxFindPositions),
  };
  return _ok(data,
      description: '在笔记 $id 中查找「${_short(keyword)}」（$count 次）');
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
  return _ok(out, description: '搜索「${_short(keyword)}」（返回 ${out.length} 条）');
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
  return _ok(out, description: '在笔记 $id 中搜索「${_short(keyword)}」（${out.length} 处）');
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
  final n = rows.first['n'];
  if (nb == null || nb.isEmpty) {
    return _ok(n, description: '统计全部笔记数（$n 篇）');
  }
  return _ok(n, description: '统计笔记库 $nb 的笔记数（$n 篇）');
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
  final data = [for (final r in rows) _brief(r)];
  return _ok(data, description: '列出最近 $limit 篇笔记');
}

// ============================================================================
// 创建（3 个）
// ============================================================================

/// notebook_id 校验：null = 「我的轻笔记」；否则必须存在。
String? _checkNotebook(String? notebookId) {
  if (notebookId == null) return null;
  if (_notebookRow(notebookId) == null) {
    return '没有 id = $notebookId 的笔记库。先用 list_notebooks 确认；'
        '要放进「我的轻笔记」就把 notebook_id 传 null。';
  }
  return null;
}

/// 插一篇笔记，返回新 id。与 NoteRepository._create 写同一组列：
/// source 记 'ai'（这张表当初就为此留了该取值），派生字段走 TextUtils，时间戳是 Unix 秒。
String _insertNote(String title, String content, String? notebookId) {
  final id = _uuid.v4();
  final now = _now();
  _udfDb!.execute(
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
  return id;
}

/// 批量新建笔记。参数是 JSON 数组字符串 `[{title, content, notebook_id?}]`（≤10）。
///
/// **单次也用它**（数组里放一个元素）：所以没有 create_note 了 —— AI 只学一种写法。
/// 整批包在一个事务里，任一条失败全部回滚。
Object? _createNotesBatch(SqliteArguments c) {
  if (_dbOf() == null) return _err(_noDb);
  final parsed = _parseBatch(_str(c, 0));
  if (parsed.error != null) return _err(parsed.error!);

  final items = <({String title, String content, String? notebookId})>[];
  for (var i = 0; i < parsed.items.length; i++) {
    final e = parsed.items[i];
    if (e is! Map) return _err('第 ${i + 1} 条不是对象。');
    final m = e.cast<String, Object?>();
    final title = (_itemStr(m, 'title') ?? '').trim();
    final content = _itemStr(m, 'content') ?? '';
    var notebookId = _itemStr(m, 'notebook_id');
    if (notebookId != null && notebookId.isEmpty) notebookId = null;
    final nbErr = _checkNotebook(notebookId);
    if (nbErr != null) return _err('第 ${i + 1} 条：$nbErr');
    final sizeErr = _checkSize(content);
    if (sizeErr != null) return _err('第 ${i + 1} 条：$sizeErr');
    items.add((
      title: safeTruncate(title, AiLimits.titleHardMax),
      content: content,
      notebookId: notebookId,
    ));
  }

  final List<String> ids;
  try {
    ids = _tx(() {
      final out = <String>[];
      for (final it in items) {
        out.add(_insertNote(it.title, it.content, it.notebookId));
      }
      return out;
    });
  } catch (e) {
    return _err('批量新建失败：$e');
  }

  return _ok({'note_ids': ids}, description: _createBatchDesc(items));
}

String _createBatchDesc(
    List<({String title, String content, String? notebookId})> items) {
  if (items.length == 1) {
    final it = items.first;
    final target = it.notebookId == null ? '「我的轻笔记」' : '笔记库 ${it.notebookId}';
    final title = it.title.isEmpty ? '（无标题）' : '「${_short(it.title)}」';
    return '新建 1 篇笔记$title到$target';
  }
  final targets = {for (final it in items) it.notebookId};
  if (targets.length == 1) {
    final nb = targets.first;
    final target = nb == null ? '「我的轻笔记」' : '笔记库 $nb';
    return '批量新建 ${items.length} 篇笔记到$target';
  }
  return '批量新建 ${items.length} 篇笔记';
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
  return _ok({'notebook_id': id}, description: '新建笔记库「${_short(name)}」');
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
  return _ok({'new_note_id': newId}, description: '复制笔记 $id → $newId');
}

// ============================================================================
// 修改（8 个）
// ============================================================================

/// 批量改正文。参数是 JSON 数组字符串 `[{id, old, new}]`（≤10）；
/// `new` 为空串 = 删掉 old 那段（等价于旧的 delete_unique）。
///
/// `old` 必须在对应笔记的正文里**唯一出现**（0 次或多次都拒绝）。
/// 校验 + 写入在同一个事务里：同一篇被改两次时，后一条看到的是前一条的结果；
/// 任一条失败整批回滚。
Object? _updateNotesBatch(SqliteArguments c) {
  if (_dbOf() == null) return _err(_noDb);
  final parsed = _parseBatch(_str(c, 0));
  if (parsed.error != null) return _err(parsed.error!);

  final items = <({String id, String old, String added})>[];
  for (var i = 0; i < parsed.items.length; i++) {
    final e = parsed.items[i];
    if (e is! Map) return _err('第 ${i + 1} 条不是对象。');
    final m = e.cast<String, Object?>();
    final id = _itemStr(m, 'id');
    final old = _itemStr(m, 'old');
    final added = _itemStr(m, 'new') ?? '';
    if (id == null || id.isEmpty || old == null || old.isEmpty) {
      return _err('第 ${i + 1} 条需要 id 与 old。');
    }
    items.add((id: id, old: old, added: added));
  }

  final List<String> ids;
  try {
    ids = _tx(() {
      final out = <String>[];
      for (var i = 0; i < items.length; i++) {
        final it = items[i];
        final note = _noteRow(it.id);
        if (note == null) {
          throw _BatchError('第 ${i + 1} 条：没有 id = ${it.id} 的笔记（或它已被删除）。');
        }
        final content = (note['content'] as String?) ?? '';
        final bad = _anchorError(content, it.old);
        if (bad != null) throw _BatchError('第 ${i + 1} 条：$bad');
        final writeErr = _writeContent(it.id, content.replaceFirst(it.old, it.added));
        if (writeErr != null) throw _BatchError('第 ${i + 1} 条：$writeErr');
        out.add(it.id);
      }
      return out;
    });
  } on _BatchError catch (e) {
    return _err(e.message);
  } catch (e) {
    return _err('批量修改失败：$e');
  }

  final String desc;
  if (items.length == 1) {
    final it = items.first;
    desc = it.added.isEmpty
        ? '修改 1 篇笔记：删除「${_short(it.old)}」'
        : '修改 1 篇笔记：替换「${_short(it.old)}」→「${_short(it.added)}」';
  } else {
    desc = '批量修改 ${items.length} 篇笔记';
  }
  return _ok({'note_ids': ids}, description: desc);
}

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
  return _ok({'note_id': id},
      description: '在笔记 $id 的「${_short(anchor)}」${after ? '后' : '前'}插入内容');
}

Object? _insertAfter(SqliteArguments c) => _insertAt(c, after: true);

Object? _insertBefore(SqliteArguments c) => _insertAt(c, after: false);

/// 批量追加到正文末尾。参数是 JSON 数组字符串 `[{id, content}]`（≤10）。
///
/// 单次也用它（数组放一个元素），所以没有 append_to_note 了。自动补换行。
/// 整批一个事务，任一条失败全部回滚。
Object? _appendNotesBatch(SqliteArguments c) {
  if (_dbOf() == null) return _err(_noDb);
  final parsed = _parseBatch(_str(c, 0));
  if (parsed.error != null) return _err(parsed.error!);

  final items = <({String id, String added})>[];
  for (var i = 0; i < parsed.items.length; i++) {
    final e = parsed.items[i];
    if (e is! Map) return _err('第 ${i + 1} 条不是对象。');
    final m = e.cast<String, Object?>();
    final id = _itemStr(m, 'id');
    final added = _itemStr(m, 'content');
    if (id == null || id.isEmpty || added == null) {
      return _err('第 ${i + 1} 条需要 id 与 content。');
    }
    items.add((id: id, added: added));
  }

  final List<String> ids;
  try {
    ids = _tx(() {
      final out = <String>[];
      for (var i = 0; i < items.length; i++) {
        final it = items[i];
        final note = _noteRow(it.id);
        if (note == null) {
          throw _BatchError('第 ${i + 1} 条：没有 id = ${it.id} 的笔记（或它已被删除）。');
        }
        final content = (note['content'] as String?) ?? '';
        final String next;
        if (content.isEmpty) {
          next = it.added;
        } else if (content.endsWith('\n')) {
          next = '$content${it.added}';
        } else {
          next = '$content\n${it.added}';
        }
        final writeErr = _writeContent(it.id, next);
        if (writeErr != null) throw _BatchError('第 ${i + 1} 条：$writeErr');
        out.add(it.id);
      }
      return out;
    });
  } on _BatchError catch (e) {
    return _err(e.message);
  } catch (e) {
    return _err('批量追加失败：$e');
  }

  final desc = items.length == 1
      ? '追加到 1 篇笔记（${items.first.added.length} 字）'
      : '批量追加到 ${items.length} 篇笔记';
  return _ok({'note_ids': ids}, description: desc);
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
  return _ok({'note_id': id}, description: '在笔记 $id 开头插入内容（${added.length} 字）');
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
  return _ok({'note_id': id}, description: '重命名笔记 $id → 「${_short(rawTitle.trim())}」');
}

/// 批量移动笔记。参数是 JSON 数组字符串 `[{id, notebook_id}]`（≤10）；
/// `notebook_id` 为 null = 移回「我的轻笔记」。
///
/// is_inbox 跟着一起改：它和 notebook_id 是同一个意思的两种表示
///（见 AppDatabase.moveNoteToNotebook），只改一个会留下
/// 「已归档但没有笔记库」的行 —— 那种行在两个入口都看不见。
/// 整批一个事务，任一条失败全部回滚。
Object? _moveNotesBatch(SqliteArguments c) {
  if (_dbOf() == null) return _err(_noDb);
  final parsed = _parseBatch(_str(c, 0));
  if (parsed.error != null) return _err(parsed.error!);

  final items = <({String id, String? notebookId})>[];
  for (var i = 0; i < parsed.items.length; i++) {
    final e = parsed.items[i];
    if (e is! Map) return _err('第 ${i + 1} 条不是对象。');
    final m = e.cast<String, Object?>();
    final id = _itemStr(m, 'id');
    if (id == null || id.isEmpty) return _err('第 ${i + 1} 条需要 id。');
    var notebookId = _itemStr(m, 'notebook_id');
    if (notebookId != null && notebookId.isEmpty) notebookId = null;
    final nbErr = _checkNotebook(notebookId);
    if (nbErr != null) return _err('第 ${i + 1} 条：$nbErr');
    items.add((id: id, notebookId: notebookId));
  }

  final List<String> ids;
  try {
    ids = _tx(() {
      final out = <String>[];
      for (var i = 0; i < items.length; i++) {
        final it = items[i];
        if (_noteRow(it.id) == null) {
          throw _BatchError('第 ${i + 1} 条：没有 id = ${it.id} 的笔记（或它已被删除）。');
        }
        if (it.notebookId == null) {
          _udfDb!.execute(
            'UPDATE notes SET notebook_id = NULL, is_inbox = 1, updated_at = ? WHERE id = ?',
            [_now(), it.id],
          );
        } else {
          _udfDb!.execute(
            'UPDATE notes SET notebook_id = ?, is_inbox = 0, updated_at = ? WHERE id = ?',
            [it.notebookId, _now(), it.id],
          );
        }
        out.add(it.id);
      }
      return out;
    });
  } on _BatchError catch (e) {
    return _err(e.message);
  } catch (e) {
    return _err('批量移动失败：$e');
  }

  final String desc;
  if (items.length == 1) {
    final it = items.first;
    final target = it.notebookId == null ? '「我的轻笔记」' : '笔记库 ${it.notebookId}';
    desc = '移动笔记 ${it.id} 到$target';
  } else {
    final targets = {for (final it in items) it.notebookId};
    if (targets.length == 1) {
      final nb = targets.first;
      final target = nb == null ? '「我的轻笔记」' : '笔记库 $nb';
      desc = '批量移动 ${items.length} 篇笔记到$target';
    } else {
      desc = '批量移动 ${items.length} 篇笔记';
    }
  }
  return _ok({'note_ids': ids}, description: desc);
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
  return _ok({'notebook_id': id}, description: '重命名笔记库 $id → 「${_short(name)}」');
}

// ============================================================================
// 删除（2 个）
// ============================================================================

/// 批量删笔记。参数是 JSON 数组字符串 `["id1","id2",...]`（≤10）。
///
/// 单次也用它（数组放一个元素），所以没有 delete_note 了。
/// 删 = **逻辑删除**（deleted_at 置位，行还在）+ 清切片：
/// 切片表的外键虽带 CASCADE，但软删除不触发行级联，留着片会让搜索
/// 把「命中哪一片」算到已删笔记头上。整批一个事务，任一条失败全部回滚。
///
/// 设计上这是**不可撤销**的：界面上没有回收站入口，所以 prompt 明确要求
/// 「只在用户明确要求删的时候才调」，且没有确认层。
Object? _deleteNotesBatch(SqliteArguments c) {
  if (_dbOf() == null) return _err(_noDb);
  final parsed = _parseBatch(_str(c, 0));
  if (parsed.error != null) return _err(parsed.error!);

  final ids = <String>[];
  for (var i = 0; i < parsed.items.length; i++) {
    final e = parsed.items[i];
    final id = e is String ? e : e?.toString();
    if (id == null || id.isEmpty) return _err('第 ${i + 1} 条不是有效的笔记 id。');
    ids.add(id);
  }

  // 标题用于描述：删除后查不到了，先记下。
  final titles = <String, String>{};
  for (final id in ids) {
    final row = _noteRow(id);
    if (row == null) return _err('没有 id = $id 的笔记（或它已被删除）。');
    titles[id] = (row['title'] as String?) ?? '';
  }

  final now = _now();
  try {
    _tx(() {
      for (final id in ids) {
        _udfDb!.execute(
          'UPDATE notes SET deleted_at = ?, updated_at = ? WHERE id = ?',
          [now, now, id],
        );
        _udfDb!.execute('DELETE FROM note_chunks WHERE note_id = ?', [id]);
      }
      return null;
    });
  } catch (e) {
    return _err('批量删除失败：$e');
  }

  final String desc;
  if (ids.length == 1) {
    final t = titles[ids.first]!;
    desc = '删除笔记 ${ids.first}${t.isEmpty ? '' : '「${_short(t)}」'}';
  } else {
    desc = '批量删除 ${ids.length} 篇笔记';
  }
  return _ok({'note_ids': ids}, description: desc);
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
  final nb = _notebookRow(id);
  if (nb == null) {
    return _err('没有 id = $id 的笔记库（或它已被删除）。先用 list_notebooks 确认。');
  }
  final name = (nb['name'] as String?) ?? '';
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
  return _ok({'notebook_id': id},
      description: '删除笔记库 $id「${_short(name)}」（笔记退回轻笔记）');
}

// ============================================================================
// 系统（1 个）
// ============================================================================


// ============================================================================
// 信号（1 个）
// ============================================================================

/// `finish(reason)`：**声明完成**的信号函数 —— **不改任何数据**。
///
/// ## 为什么需要一个"什么都没做"的函数
///
/// `AgentLoop` 原来的终止条件是「这一轮没提工具」。那只能说明模型**没提工具**，
/// 说明不了「任务做完了」—— 它可能只说了一句「我先看看」就停了，
/// 而这一轮就此结束，用户拿到一句没头没尾的话。
///
/// 有了这个信号，「完成」第一次变成**机器可读**的一件事，而且成本是 0：
/// 模型是「边写结论边调 finish」的（同一轮里），循环收到就直接结束，
/// **不会再发一轮请求**。（若按普通工具回灌结果，每个任务都要多跑一轮 —— 
/// 每次「读完笔记给结论」都多烧一次调用，那是纯浪费。）
///
/// ⚠️ 返回里的 `finished: true` 是**三处共用的约定**：
///   · 这里（函数返回值）、
///   · `ToolResult.raw()`（认这一格，置 `ToolResult.finished`）、
///   · `AgentLoop`（据 `finished` 收尾）。
/// 改名要三处一起改 —— 这是本文件里唯一一个"返回值参与控制流"的函数。
Object? _finish(SqliteArguments c) {
  final reason = (_str(c, 0) ?? '').trim();
  // 不碰数据库（连连接都不需要）：它只是把"做完了"这件事说出来。
  return _ok(
    {'finished': true, 'reason': reason},
    description: reason.isEmpty ? '完成（未说明做了什么）' : reason,
  );
}
