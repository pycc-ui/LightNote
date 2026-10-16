import '../../../core/db/ai_functions.dart';
import '../../../core/util/app_params.dart';

/// 一条 SQL 的**放行判定**。
class SqlCheck {
  const SqlCheck._(this.ok, this.reason, this.returnsRows);

  factory SqlCheck.allow({required bool returnsRows}) =>
      SqlCheck._(true, null, returnsRows);

  factory SqlCheck.reject(String reason) => SqlCheck._(false, reason, false);

  final bool ok;

  /// 不放行的原因。**写给模型看的**：它要靠这句话改写法。
  final String? reason;

  /// 这条语句会返回行（SELECT / WITH）
  final bool returnsRows;
}

/// `sql` 工具的**安全检查**：AI 发来的 SQL 在这里过一遍，不合格就整条拒绝。
///
/// ## 这不是「过滤关键字」，是「划定一条通道」
///
/// 设计初稿只打算拒 DROP / ALTER / ATTACH / PRAGMA / VACUUM 五个词。那条规则
/// 几乎不设防，在 sqlite 里跑一遍就能看出来：
///
///   DELETE FROM notes;                    -- 通过，整库笔记没了
///   UPDATE notes SET content = '';        -- 通过
///   INSERT INTO notes (...) VALUES (...); -- 通过
///   SELECT * FROM pragma_table_info(...)  -- 通过（pragma_ 带下划线，不匹配 PRAGMA）
///
/// 而《AI 操作数据库设计》的核心承诺是「约束装在 UDF 里，AI 绕不过去」。
/// 只要还能直接写表，这句承诺就是假的：锚点唯一、标题截断、派生字段口径
/// 全部可以绕过。所以这里的规则改成**只放行查询**：
///
///   1. 一次只有一条语句（分号只能出现在结尾）；
///   2. 必须以 SELECT / WITH 开头；
///   3. 正文（剥掉字符串字面量与注释之后）里不许出现 UPDATE / INSERT /
///      DELETE / REPLACE INTO 这类写语句，也不许出现 DDL 与 PRAGMA；
///   4. **非 read 函数不许和 FROM / JOIN 出现在同一条语句里** —— 那会对每一行
///      调一次，批量函数还要再乘以批量条数。
///
/// 写操作因此**只能**走 ai_functions 里的函数 —— 它们以 SELECT 开头、
/// 由 UDF 内部完成写入，正好落在通道里。
///
/// ## 为什么必须先剥掉字符串字面量
///
/// 用户正文里本来就可能有这些词（比如「把 delete 那段删掉」）。不剥的话，
/// 一句正常的 update_notes_batch 会被自己的参数误伤 —— 那是「安全规则」
/// 变成「功能坏了」的经典写法。
class SqlGuard {
  SqlGuard._();

  /// 一律禁止的写法。**按词匹配**，所以 `updated_at` / `delete_notes_batch`
  /// 这类带下划线的列名与函数名不会被误伤（下划线是词字符）。
  static const _forbidden = <String>[
    'DROP',
    'ALTER',
    'CREATE',
    'ATTACH',
    'DETACH',
    'PRAGMA',
    'VACUUM',
    'REINDEX',
    'UPDATE',
    'INSERT',
    'DELETE',
    'TRIGGER',
  ];

  /// REPLACE 单独处理：它既是 SQLite 的内置**函数**（读查询里合法），
  /// 又是插入语句 REPLACE INTO。只拦后者。
  static final _replaceInto = RegExp(r'\bREPLACE\s+INTO\b');

  static final _selectOrWith = RegExp(r'^(SELECT|WITH)\b');

  /// 非 read 函数的**调用点**（名字后面跟左括号）。
  ///
  /// 名单来自清单的 category（[kAiNonReadFunctions]），不在这里抄一份：
  /// 抄了就会和 `ai_functions.dart` 分叉，而分叉的表现是「新加的写函数
  /// 可以嵌在 FROM 里按行调用」—— 那种问题没人会主动去发现。
  static final _nonReadCall = RegExp(
    '\\b(${kAiNonReadFunctions.join('|')})\\s*\\(',
    caseSensitive: false,
  );

  static final _hasFrom = RegExp(r'\b(FROM|JOIN)\b');

  /// 拒绝理由要写成**能照着改**的样子：模型下一轮要么去掉 FROM，要么改用读函数。
  static const _writeWithFromReason =
      '写函数不能出现在带 FROM / JOIN 的查询里：那会对每一行调一次'
      '（SELECT update_notes_batch(…) FROM notes 会逐行改库，批量函数还要乘以批量条数）。'
      '写操作一次只作用于参数里点名的那几篇：'
      'SELECT update_notes_batch(\'[…] JSON 数组 …\')；'
      '要挑对象就先用读函数查 id，再拿 id 去调写函数。'
      '读函数（read_note_batch / outline_notes / search_notes …）可以嵌在查询里。';

  /// 校验一条 SQL。
  static SqlCheck check(String raw) {
    final sql = raw.trim();
    if (sql.isEmpty) return SqlCheck.reject('SQL 是空的。');
    if (sql.length > SqlLimits.maxStatementChars) {
      return SqlCheck.reject(
          '这条 SQL 太长了（上限 ${SqlLimits.maxStatementChars} 字符）。'
          '请缩小范围，不要把整篇正文塞进 SQL 里。');
    }

    final code = _stripLiterals(sql);
    if (_statementCount(code) > 1) {
      return SqlCheck.reject('一次只能执行一条语句（分号只能出现在末尾）。请拆成多次调用。');
    }
    if (!_selectOrWith.hasMatch(code.trimLeft())) {
      return SqlCheck.reject(
          '只允许 SELECT / WITH 查询。写操作请调用 ai_functions 里的函数'
          '（SELECT name, signature FROM ai_functions 查清单）。');
    }

    final upper = code.toUpperCase();
    for (final kw in _forbidden) {
      if (RegExp('\\b$kw\\b').hasMatch(upper)) {
        return SqlCheck.reject(_reasonOf(kw));
      }
    }
    if (_replaceInto.hasMatch(upper)) {
      return SqlCheck.reject(_reasonOf('REPLACE INTO'));
    }

    // 写函数不能嵌进带 FROM / JOIN 的语句：那会**逐行**调一次。
    //
    // 这条不是洁癖，是数据事故：`SELECT update_notes_batch(...) FROM notes`
    // 在有 200 篇笔记的库上会改 200 轮，而 AI 的本意通常只是「改那一篇」。
    // 读函数不受限制 —— 它们本来就是拿来嵌在查询里的
    //（SELECT id, read_note_batch(id, 0, 200) FROM notes 是推荐写法）。
    if (_nonReadCall.hasMatch(code) && _hasFrom.hasMatch(upper)) {
      return SqlCheck.reject(_writeWithFromReason);
    }
    return SqlCheck.allow(returnsRows: true);
  }

  static String _reasonOf(String kw) {
    const writes = {'UPDATE', 'INSERT', 'DELETE', 'REPLACE INTO'};
    if (writes.contains(kw)) {
      return '不允许直接写表（$kw）。写操作要走 ai_functions 里的函数：'
          'SELECT name, signature FROM ai_functions 查有哪些，再调用它们。';
    }
    return '不允许执行 $kw（危险语句）。';
  }

  /// 去掉字符串字面量、标识符引号与注释，其余原样保留。
  ///
  /// 保留引号本身（换成一对空引号），这样词边界不会被粘起来：
  /// 整个删掉会让前后两个词贴在一起，反而造出新的匹配。
  static String _stripLiterals(String sql) {
    final out = StringBuffer();
    var i = 0;
    while (i < sql.length) {
      final ch = sql[i];
      if (ch == "'") {
        out.write("''");
        i++;
        while (i < sql.length) {
          if (sql[i] == "'") {
            if (i + 1 < sql.length && sql[i + 1] == "'") {
              i += 2;
              continue;
            }
            i++;
            break;
          }
          i++;
        }
        continue;
      }
      if (ch == '"' || ch == '`' || ch == '[') {
        final close = ch == '[' ? ']' : ch;
        out.write('$ch$close');
        i++;
        while (i < sql.length && sql[i] != close) {
          i++;
        }
        i++;
        continue;
      }
      if (ch == '-' && i + 1 < sql.length && sql[i + 1] == '-') {
        while (i < sql.length && sql[i] != '\n') {
          i++;
        }
        out.write(' ');
        continue;
      }
      if (ch == '/' && i + 1 < sql.length && sql[i + 1] == '*') {
        i += 2;
        while (i + 1 < sql.length && !(sql[i] == '*' && sql[i + 1] == '/')) {
          i++;
        }
        i += 2;
        out.write(' ');
        continue;
      }
      out.write(ch);
      i++;
    }
    return out.toString();
  }

  /// 去掉字面量之后还剩几个分号（末尾那一个不算）。
  static int _statementCount(String code) {
    var count = 0;
    for (var i = 0; i < code.length; i++) {
      if (code[i] != ';') continue;
      final rest = code.substring(i + 1).trim();
      if (rest.isNotEmpty) count++;
    }
    return count;
  }
}
