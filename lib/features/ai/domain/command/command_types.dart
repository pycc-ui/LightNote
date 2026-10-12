/// 命令语言的**语法模型**（AST）与结果类型。
///
/// 设计见 docs/命令语言设计.md：AI 不再调用 22 个 function-calling 工具，
/// 而是提交一段 shell 风格脚本，由 App 的解析器 / 解释器执行。
///
/// 这里只放纯数据（不碰数据库、不碰 UI），所以解析器与解释器都能单独测。
library;

/// 脚本里允许出现的命令名（白名单）。写了别的 → 语法错误。
///
/// 与 docs/命令语言设计.md 的「命令清单（9 个）」一字对应。
/// 注意：`run` 本身不是命令，是承载脚本的工具名。
const kCommandNames = <String>{
  'ls',
  'stat',
  'sed',
  'grep',
  'echo',
  'rm',
  'mkdir',
  'mv',
};

/// 解析阶段的错误（整段脚本**拒绝执行**，带上出错行号）。
class CommandSyntaxError implements Exception {
  const CommandSyntaxError(this.message, this.line);

  final String message;

  /// 1 起算的行号。
  final int line;

  @override
  String toString() => '第 $line 行：$message';
}

/// 执行阶段由**宿主命令处理体**抛出的可读失败。
///
/// 它只让**当前这条命令**失败，脚本继续往下跑（见设计 §8.4）。
/// 引用了未定义变量则不是这个异常，而是 [_AbortScript]（中止整段）。
class CommandFail implements Exception {
  const CommandFail(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 中止**整段脚本**的错误（目前只有"引用未定义变量"一种）。
class AbortScript implements Exception {
  const AbortScript(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 一条命令的执行结果。
class CmdResult {
  const CmdResult({required this.ok, required this.output});
  const CmdResult.ok(this.output) : ok = true;
  const CmdResult.fail(this.output) : ok = false;

  /// 成功（退出码 0）→ `if` 才执行函数体。
  final bool ok;

  /// 回灌给模型看的文本（成功是结果，失败是"怎么改"的建议）。
  final String output;
}

/// 一条命令的执行记录（解释器产出，供结果格式化）。
class CommandRecord {
  const CommandRecord({
    required this.line,
    required this.source,
    required this.ok,
    required this.output,
  });

  /// 命令在脚本里的行号。
  final int line;

  /// 已插值后的命令文本（`$变量` 已替换），回灌时看得见真实参数。
  final String source;

  final bool ok;
  final String output;
}

/// 一次脚本执行的完整结果。
class ScriptRun {
  const ScriptRun({
    required this.records,
    required this.aborted,
    this.abortReason,
  });

  final List<CommandRecord> records;

  /// 是否中途整段中止（语法错误在解析期就拦下了，这里只有"未定义变量"等）。
  final bool aborted;
  final String? abortReason;

  /// 把执行记录拼成一段**结构化的回灌文本**（设计 §11.3 的「结果格式化」）。
  ///
  /// 每条命令都以 `$ <命令>` 起头，后面跟它的输出 —— 模型一眼能看出
  /// "哪条命令产出了哪段结果、哪条失败了"，而不是拿到一堆拼在一起的裸文本。
  String format() {
    final b = StringBuffer();
    for (final r in records) {
      // `\$` 转义：输出的是字面 `$ `，让模型一眼看出这是"命令 → 输出"。
      b.writeln('\$ ${r.source}');
      b.writeln(r.output.trimRight().isEmpty ? '（无输出）' : r.output.trimRight());
      b.writeln();
    }
    if (aborted && abortReason != null) {
      b.writeln('⚠️ 脚本已中止：$abortReason');
    }
    return b.toString().trimRight();
  }
}

// ============================================================================
// AST
// ============================================================================

/// 一条语句。`line` 是它在脚本里的行号（报错用）。
sealed class Stmt {
  const Stmt(this.line);
  final int line;
}

/// 整行注释 / 空行（解析时就已经不产出，这里保留类型只为完整）。
class CommentStmt extends Stmt {
  const CommentStmt(super.line);
}

/// `set 名字 = 值`
class SetStmt extends Stmt {
  const SetStmt(super.line, this.name, this.value);
  final String name;

  /// 赋值右侧的原始文本（可能含 `$变量`，执行时插值）。
  final String value;
}

/// 重定向方向。
enum Redirection { none, overwrite, append }

/// 一条命令语句，如 `sed -n '1,5p' 工作笔记/项目A`。
class CommandStmt extends Stmt {
  const CommandStmt(
    super.line,
    this.name,
    this.args, {
    this.redirect = Redirection.none,
  });

  final String name;

  /// 参数（已分词，可能含 `$变量`；引号内的空格被保留在一个参数里）。
  final List<String> args;

  /// 只有 `echo` 允许重定向。
  final Redirection redirect;
}

/// `for` 的列表来源：命令结果，或字面量列表。
sealed class ForSource {
  const ForSource();
}

class ForCommand extends ForSource {
  const ForCommand(this.command);
  final CommandStmt command;
}

class ForList extends ForSource {
  const ForList(this.items);
  final List<String> items;
}

/// `for 变量 in 列表 ... end`
class ForStmt extends Stmt {
  const ForStmt(super.line, this.variable, this.source, this.body);
  final String variable;
  final ForSource source;
  final List<Stmt> body;
}

/// `if 命令 ... end`（不支持 else / elif / 嵌套）
class IfStmt extends Stmt {
  const IfStmt(super.line, this.condition, this.body);
  final CommandStmt condition;
  final List<Stmt> body;
}

/// 一段解析好的脚本。
class ScriptProgram {
  const ScriptProgram(this.statements);
  final List<Stmt> statements;
}
