import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/db/ai_functions.dart';
import '../../../core/db/app_database.dart';
import '../../../core/util/app_params.dart';
import 'sql_guard.dart';
import 'tool_types.dart';

/// **App 侧的工具执行器**：AI 提出调用 → 这里真正去做。
///
/// 现在只有两种调用：`sql`（一条 SQL）与 `askUser`（挂起提问，由对话流程接管，
/// 不走这里）。所有笔记操作都发生在 SQL 里 —— 读是查表，写是调用 UDF。
///
/// ## App 只做一件事：把 SQL 挡在危险区之外
///
/// 业务约束不在这里：它们在 UDF 的实现代码里（core/db/ai_udfs.dart），
/// AI 绕不过去。这里只做 [SqlGuard] 的放行判定，放行之后就交给 SQLite，
/// **没有确认弹层、没有撤销栈** —— 那是上一版（命令语言）的东西，
/// 每写一次都要用户点一下，既慢又拦不住真正危险的批量操作。
///
/// ## 顺手补一件 drift 不知道的事
///
/// UDF 里的写操作走的是**原始连接**（SQLite 回调里只能这样），drift 不知道
/// 有表变了 —— 不通知的话，界面上的 stream 查询不会刷新，用户看到的是
/// 「AI 说改好了，列表没变」。所以执行完写相关的 SQL 之后手动通知一次。
///
/// ## 错误也是「结果」
///
/// 语法错、函数报错、被安全规则拒绝……一律走 [ToolResult.failure] 或带可读文本的
/// 成功结果。模型靠这些话换方案。抛异常会把整轮对话打断。
class ToolExecutor {
  ToolExecutor(this._db);

  final AppDatabase _db;

  /// 新一轮开始。SQL 没有「每轮预算」这回事，留着是为了不改 AgentLoop 的调用形状。
  void beginTurn() {}

  /// 执行一个工具。
  ///
  /// [history] 保留是为了不改 `AgentLoop` 的调用形状；两个工具都用不到它。
  Future<ToolResult> execute(
    String name,
    Map<String, Object?> args, {
    List<AiMessage> history = const [],
  }) async {
    try {
      switch (name) {
        case 'sql':
          return await _runSql(args);
        case 'askUser':
          // 由对话流程（AgentLoop）接管，不该走到执行器。
          return ToolResult.failure('`askUser` 由对话流程处理，不该走到执行器。');
        default:
          return ToolResult.failure(
            '没有叫 `$name` 的工具。现在只有 `sql`（执行一条 SQL）与 `askUser`。',
          );
      }
    } catch (e) {
      return ToolResult.failure('执行 `$name` 时出错：$e');
    }
  }

  /// `sql`：安全校验 → 交给 SQLite → 把结果集整理成 JSON 回灌。
  Future<ToolResult> _runSql(Map<String, Object?> a) async {
    final query = _str(a, 'query');
    if (query == null) {
      return ToolResult.failure('sql 需要 `query`（一条 SQL 语句）。');
    }

    final check = SqlGuard.check(query);
    if (!check.ok) return ToolResult.failure(check.reason!);

    try {
      final rows = await _db.customSelect(query).get();
      // 顺手拿到「这次有没有改笔记数据」：判定本来就在做（见 _notifyIfWrite），
      // 结果还要往上传，供上层攒「本轮执行记录」（ToolResult.mutated）。
      final mutated = _notifyIfWrite(query);
      // UDF 的返回值**本身就是最终形状**：`SELECT func(...)` 只回一行一列，
      // 那格是一段 `{ok, description, data}` JSON —— 直接采纳，别套进 rows 里
      //（套了就变成 AI 看到 `[{ "func(...)": "{\"ok\":…}" }]`，多一层解析）。
      final udf = _udfResultOf(rows);
      if (udf != null) return ToolResult.raw(udf, mutated: mutated);
      return ToolResult.success(_pack(rows));
    } catch (e) {
      // 把 SQLite 的报错原样交给模型：`no such function: xxx` /
      // `no such column: yyy` 这类话它读得懂，比我们翻译一遍更有用。
      return ToolResult.failure('SQL 执行失败：$e');
    }
  }

  /// 结果恰好「一行一列、且那格是含 `ok` 键的 JSON」→ 认作 UDF 的返回，返回原串；
  /// 否则返回 null（普通查询，交给 [_pack]）。
  static String? _udfResultOf(List<QueryRow> rows) {
    if (rows.length != 1) return null;
    final cells = rows.first.data.values;
    if (cells.length != 1) return null;
    final v = cells.first;
    if (v is! String || !v.trimLeft().startsWith('{')) return null;
    try {
      final m = jsonDecode(v);
      if (m is Map && m.containsKey('ok')) return v;
    } catch (_) {}
    return null;
  }

  /// 结果集 → 回灌的形状。
  ///
  /// 每次查询都可能很大（`SELECT * FROM notes` 就是整个库），所以两道闸：
  /// 行数与字符数。截断了要**说出来**，否则模型会以为这就是全部结果，
  /// 然后基于半截数据下结论。
  Object _pack(List<QueryRow> rows) {
    final out = <Map<String, Object?>>[];
    var chars = 0;
    var cut = false;
    for (final r in rows) {
      if (out.length >= SqlLimits.maxResultRows) {
        cut = true;
        break;
      }
      final row = <String, Object?>{};
      r.data.forEach((k, v) => row[k] = _plain(v));
      final size = jsonEncode(row).length;
      if (chars + size > SqlLimits.maxResultChars) {
        cut = true;
        break;
      }
      chars += size;
      out.add(row);
    }
    return {
      'rows': out,
      'row_count': out.length,
      'total_rows': rows.length,
      if (cut)
        'note': '结果已截断（一次最多回 ${SqlLimits.maxResultRows} 行 / '
            '${SqlLimits.maxResultChars} 字符）。要更多请加 WHERE 或 LIMIT。',
    };
  }

  /// SQLite 的值 → JSON 能编码的值。
  ///
  /// 二进制列（本项目暂时没有）不塞进上下文，换成一句说明 —— 一串 base64
  /// 只会白烧 token。
  Object? _plain(Object? v) {
    if (v == null || v is num || v is String || v is bool) return v;
    if (v is Uint8List) return '（二进制 ${v.length} 字节，略）';
    return v.toString();
  }

  /// 这次 SQL 可能写过数据 → 通知 drift 的 stream 查询。
  ///
  /// 判定办法很土但够用：看 SQL 里有没有出现写函数的**名字**。
  /// 假阳性（名字出现在字符串里）只会多刷新一次，无害；
  /// 假阴性不可能出现 —— 没调写函数就没写数据。
  ///
  /// 两类分开：改笔记的函数通知三张笔记表；`system` 类（动 `app_kv` 的那些）
  /// （它改的是"加载哪几个函数详情"，与笔记无关，通知笔记表是白刷）。
  /// 返回**这次 SQL 有没有改笔记数据**（`kAiWriteFunctions` 里出现过名字）。
  bool _notifyIfWrite(String sql) {
    final lower = sql.toLowerCase();
    bool hit(Set<String> names) {
      for (final name in names) {
        if (lower.contains(name)) return true;
      }
      return false;
    }

    if (!hit(kAiWriteFunctions)) return false;
    _db.notifyUpdates({
      const TableUpdate('notes'),
      const TableUpdate('notebooks'),
      const TableUpdate('note_chunks'),
    });
    return true;
  }

  // ==========================================================================
  // 参数读取
  // ==========================================================================

  static String? _str(Map<String, Object?> a, String key) {
    final v = a[key];
    if (v == null) return null;
    final s = v is String ? v : v.toString();
    return s.trim().isEmpty ? null : s;
  }

  /// 把模型给的 `arguments`（JSON 字符串）解析成 map。
  ///
  /// 解析不出来时返回空 map —— 后面的参数校验会给出「缺 query」这种
  /// **具体**的抱怨，比「JSON 坏了」更容易让模型纠正。
  static Map<String, Object?> parseArgs(String raw) {
    if (raw.trim().isEmpty) return const {};
    try {
      final v = jsonDecode(raw);
      if (v is Map) return v.cast<String, Object?>();
      return const {};
    } catch (_) {
      return const {};
    }
  }
}
