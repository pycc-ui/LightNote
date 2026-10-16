import 'dart:convert';

/// 「这一轮现在在做什么」—— 界面那条**任务栏**读的就是它。
///
/// 只在内存里（不落库）：它是"此刻的进度"，进程一没就没有意义 ——
/// 重启之后那一轮本来也不在了。跨启动要留的是**结果**（消息正文 + 思维链）。
class AgentProgress {
  const AgentProgress({
    required this.round,
    required this.budget,
    this.current,
    this.steps = const [],
  });

  /// 第几轮（0 起，**跨挂起累计**）。界面上显示时 +1。
  final int round;

  /// 这次允许用到第几轮（用户点过「继续」之后会变大）。
  final int budget;

  /// 此刻正在做的（**人话**）。null = 正在思考 / 正在写正文（没有工具在跑）。
  final String? current;

  /// 已经做完的步骤（**人话**）。只留最近几条，见 [maxSteps]。
  final List<String> steps;

  /// 步骤最多留几条。
  ///
  /// 留最近的：任务栏是"现在在干嘛"，一次 45 轮的任务真列全了也没人看，
  /// 而且会越来越长。
  static const maxSteps = 12;

  /// 有没有值得显示的东西（空进度就别占地方）。
  bool get isEmpty => current == null && steps.isEmpty;

  AgentProgress copyWith({
    int? round,
    int? budget,
    String? current,
    bool clearCurrent = false,
    List<String>? steps,
  }) =>
      AgentProgress(
        round: round ?? this.round,
        budget: budget ?? this.budget,
        current: clearCurrent ? null : (current ?? this.current),
        steps: steps ?? this.steps,
      );

  /// 记一步做完（[detail] 优先：那是 UDF 给的、带具体对象的一句话）。
  AgentProgress withStep(String detail) {
    final next = [...steps, detail];
    return copyWith(
      current: null,
      clearCurrent: true,
      steps: next.length <= maxSteps
          ? next
          : next.sublist(next.length - maxSteps),
    );
  }
}

/// 把一次工具调用翻译成**人话**。
///
/// ## 为什么需要这一层
///
/// AI 干活的方式是**写 SQL**：`read_note_batch` / `outline_notes` 这些都不是
/// 独立的工具，而是嵌在 `sql` 这个工具里的函数调用。所以
/// `AgentToolStarted.name` 拿到的基本永远是 `'sql'` —— 直接显示它等于什么都没说。
///
/// 真要有用，就得看**它写的 SQL 在动什么东西**：读正文、拿目录、搜索、
/// 写笔记、删笔记……
///
/// ## 两条原则
///
/// 1. **不把 SQL 摆给用户看**。SQL 是 AI 的母语，不是用户的 —— 用户要知道的是
///    "它在读笔记"，不是 `SELECT read_note_batch(...)`。
/// 2. **一个人话一个函数，不许漏**。漏了的表现是任务栏里露出一串英文下划线
///    （`read_note_batch`），那正是这一层要消灭的东西。所以 [describe] 的最后
///    一条兜底是"照着 SQL 里出现的函数名认"，再兜底才是"执行命令"。
abstract final class ToolLabels {
  /// 一次调用 → 一句话（如「读正文（3 篇）」）。
  ///
  /// [arguments] 是模型给的参数 JSON 原文（`{"sql": "SELECT …"}`）。
  /// 解析失败不抛异常：标签是给人看的，认不出来也不能影响干活。
  static String describe(String name, String arguments) {
    switch (name) {
      case 'askUser':
        return '问你一个问题';
      case 'finish':
        return '收尾';
      case 'sql':
        return _fromSql(_sqlOf(arguments), arguments);
      default:
        return name;
    }
  }

  /// 从参数 JSON 里取出 SQL 原文。
  static String _sqlOf(String arguments) {
    try {
      final m = jsonDecode(arguments);
      if (m is Map && m['sql'] is String) return m['sql'] as String;
    } catch (_) {
      // 参数不是合法 JSON（理论上不该发生）——当作没 SQL，走兜底
    }
    return '';
  }

  /// SQL → 人话。
  static String _fromSql(String sql, String rawArgs) {
    if (sql.trim().isEmpty) return '执行命令';
    final s = sql.toLowerCase();

    // ---- 写 ----
    if (s.contains('create_notes_batch(') || s.contains('duplicate_note(')) {
      return _withCount('新建笔记', rawArgs, s);
    }
    if (s.contains('update_notes_batch(') ||
        s.contains('append_notes_batch(') ||
        s.contains('insert_after(') ||
        s.contains('insert_before(') ||
        s.contains('prepend_to_note(')) {
      return _withCount('改笔记', rawArgs, s);
    }
    if (s.contains('rename_note(') || s.contains('rename_notebook(')) {
      return '改名';
    }
    if (s.contains('move_notes_batch(')) return _withCount('移动笔记', rawArgs, s);
    if (s.contains('delete_notes_batch(')) return _withCount('删笔记', rawArgs, s);
    if (s.contains('delete_notebook(')) return '删笔记库';
    if (s.contains('create_notebook(')) return '新建笔记库';

    // ---- 读 ----
    if (s.contains('outline_notes(')) return _withCount('拿目录', rawArgs, s);
    if (s.contains('read_note_batch(')) return _withCount('读正文', rawArgs, s);
    if (s.contains('read_around(')) return '读上下文';
    if (s.contains('search_notes(') || s.contains('search_in_note(')) {
      return '搜索笔记';
    }
    if (s.contains('find_in_note(')) return '找关键词';
    if (s.contains('recent_notes(')) return '看最近的笔记';
    if (s.contains('count_notes(')) return '数一下';
    if (s.contains('list_notebooks(') || s.contains('list_notes(')) {
      return '列清单';
    }
    if (s.contains('list_unfiled(')) return '看轻笔记';
    if (s.startsWith('select') || s.startsWith('with')) return '查笔记';
    return '执行命令';
  }

  /// 参数里带了一批 id 的话，把数量说出来（「读正文（3 篇）」）。
  ///
  /// 数 `"id"` 的出现次数：批量函数的参数就是 `[{id, …}, {id, …}]`，
  /// 而**单个**函数（`read_note_batch('n1', 0, 200)`）里一个 `"id"` 都没有 ——
  /// 那种就退回不带数量的说法。
  static String _withCount(String label, String rawArgs, String sql) {
    // 参数 JSON 里带转义的引号（`\"id\"`），SQL 里则是裸的 —— 两种都数
    final n = RegExp(r'\\?"id\\?"\s*:').allMatches(rawArgs).length;
    if (n <= 0) return label;
    return '$label（$n 篇）';
  }
}
