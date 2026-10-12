/// 命令脚本的**解释器**：按顺序执行 [ScriptProgram] 里的语句。
///
/// 它只负责四件事（设计 §5 的四个原语 + 结果汇总）：
///   · 变量定义与引用插值（`set` / `$名字`）
///   · 循环（`for … in 列表`）
///   · 条件（`if 命令`）
///   · 把每条命令的结果按顺序记进 [ScriptRun]
///
/// **具体的 9 个命令怎么执行**由注入的 [CommandHost] 决定（连数据库、弹确认框
/// 都在宿主里），所以解释器本身不碰 AppDatabase，能脱离数据库单测。
///
/// 设计见 docs/命令语言设计.md 第 5、8 节。
library;

import '../../../core/util/app_params.dart';
import 'command_types.dart';

/// 命令宿主：9 个命令的真正实现。
///
/// 参数是**已插值**的字符串列表（`$变量` 已替换）；返回值是 [CmdResult]。
/// 写命令（echo / sed 的 c/d/i/a / rm / mkdir / mv）由宿主负责**逐条弹确认**：
/// 用户拒绝时返回 `CmdResult.fail('用户拒绝…')`，解释器据此跳过这条、继续下一条。
///
/// 执行上限（设计 §8.6）见 `CommandLimits`（在 `app_params.dart`）。
abstract class CommandHost {
  Future<CmdResult> ls(List<String> args);
  Future<CmdResult> stat(List<String> args);
  Future<CmdResult> sed(List<String> args);
  Future<CmdResult> grep(List<String> args);
  Future<CmdResult> echo(List<String> args, {required bool append});
  Future<CmdResult> rm(List<String> args);
  Future<CmdResult> mkdir(List<String> args);
  Future<CmdResult> mv(List<String> args);
}

class CommandInterpreter {
  CommandInterpreter(this.host);

  final CommandHost host;

  /// 变量名字符（中文 / 英文 / 数字 / 下划线）。
  static final _varChar = RegExp(r'[A-Za-z0-9_\u4e00-\u9fff]');

  Future<ScriptRun> run(ScriptProgram program) async {
    final records = <CommandRecord>[];
    final vars = <String, String>{};
    final sw = Stopwatch()..start();
    var count = 0;
    String? abort;

    Future<void> execStmts(List<Stmt> stmts) async {
      for (final s in stmts) {
        if (abort != null) return;
        if (sw.elapsed > CommandLimits.budget) {
          abort =
              '脚本执行超时（${CommandLimits.budget.inSeconds} 秒）。请缩小范围。';
          return;
        }
        switch (s) {
          case CommentStmt():
            break;

          case SetStmt(:final name, :final value):
            vars[name] = _interpolate(value, vars, s.line);

          case CommandStmt():
            if (count >= CommandLimits.maxCommands) {
              abort = '脚本命令条数超过上限（${CommandLimits.maxCommands} 条）。'
                  '请缩小范围、分次执行。';
              return;
            }
            count++;
            records.add(await _runCommand(s, vars));

          case IfStmt(:final condition, :final body):
            if (count >= CommandLimits.maxCommands) {
              abort = '脚本命令条数超过上限（${CommandLimits.maxCommands} 条）。';
              return;
            }
            count++;
            final cond = await _runCommand(condition, vars);
            records.add(cond);
            if (cond.ok) await execStmts(body);

          case ForStmt(:final variable, :final source, :final body):
            final List<String> items;
            if (source is ForCommand) {
              if (count >= CommandLimits.maxCommands) {
                abort = '脚本命令条数超过上限（${CommandLimits.maxCommands} 条）。';
                return;
              }
              count++;
              items = await _listOfCommand(source.command, vars, records);
            } else {
              items = [
                for (final t in (source as ForList).items)
                  _interpolate(t, vars, s.line),
              ];
            }
            if (items.length > CommandLimits.maxIterations) {
              abort = '单次 `for` 循环超过上限（${CommandLimits.maxIterations} 次）。';
              return;
            }
            for (final it in items) {
              if (abort != null) break;
              vars[variable] = it;
              await execStmts(body);
            }
        }
      }
    }

    try {
      await execStmts(program.statements);
    } on AbortScript catch (e) {
      abort = e.message;
    }

    sw.stop();
    return ScriptRun(
      records: records,
      aborted: abort != null,
      abortReason: abort,
    );
  }

  /// 跑一条命令：插值参数 → 派发到宿主。
  Future<CommandRecord> _runCommand(
    CommandStmt s,
    Map<String, String> vars,
  ) async {
    final args = [
      for (final a in s.args) _interpolate(a, vars, s.line),
    ];
    final display = _display(s.name, args, s.redirect);

    late final CmdResult r;
    try {
      switch (s.name) {
        case 'ls':
          r = await host.ls(args);
        case 'stat':
          r = await host.stat(args);
        case 'sed':
          r = await host.sed(args);
        case 'grep':
          r = await host.grep(args);
        case 'echo':
          if (s.redirect == Redirection.none) {
            // `echo "内容" 笔记`（没写重定向）几乎一定是笔误：明确要求写 `>` / `>>`，
            // 否则会把第二段文本当成笔记名、当成"覆盖"执行。
            r = CmdResult.fail(
              '`echo` 必须带重定向：`echo "内容" > <笔记>`（覆盖）或 `>> <笔记>`（追加）。',
            );
          } else {
            r = await host.echo(args, append: s.redirect == Redirection.append);
          }
        case 'rm':
          r = await host.rm(args);
        case 'mkdir':
          r = await host.mkdir(args);
        case 'mv':
          r = await host.mv(args);
        default:
          // 解析期已经拦过白名单，这里兜底。
          r = CmdResult.fail('不支持的命令 `$s.name`。');
      }
    } on CommandFail catch (e) {
      // 单条命令失败 → 记下来，继续下一条（设计 §8.4）。
      r = CmdResult.fail(e.message);
    }

    return CommandRecord(
      line: s.line,
      source: display,
      ok: r.ok,
      output: r.output,
    );
  }

  /// `for … in <命令>`：跑命令，把输出按行拆成列表项（同时记一条执行记录）。
  Future<List<String>> _listOfCommand(
    CommandStmt cmd,
    Map<String, String> vars,
    List<CommandRecord> records,
  ) async {
    final rec = await _runCommand(cmd, vars);
    records.add(rec);
    if (!rec.ok) return const [];
    return [
      for (final l in rec.output.split('\n'))
        if (l.trim().isNotEmpty) l.trim(),
    ];
  }

  /// 回灌文本里的命令展示（插值后的）。
  static String _display(String name, List<String> args, Redirection redirect) {
    final b = StringBuffer(name);
    for (final a in args) {
      b.write(' ');
      b.write(a.contains(' ') ? '"$a"' : a);
    }
    if (redirect == Redirection.overwrite) b.write(' >');
    if (redirect == Redirection.append) b.write(' >>');
    return b.toString();
  }

  /// 变量插值。引用不存在的变量 → [AbortScript]（**中止整段脚本**）。
  static String _interpolate(String raw, Map<String, String> vars, int line) {
    if (!raw.contains(r'$')) return raw;
    final b = StringBuffer();
    var i = 0;
    while (i < raw.length) {
      final ch = raw[i];
      if (ch != r'$') {
        b.write(ch);
        i++;
        continue;
      }
      var j = i + 1;
      final sb = StringBuffer();
      while (j < raw.length && _varChar.hasMatch(raw[j])) {
        sb.write(raw[j]);
        j++;
      }
      final name = sb.toString();
      if (name.isEmpty) {
        throw AbortScript('第 $line 行：`\$` 后面要跟变量名。');
      }
      final v = vars[name];
      if (v == null) {
        throw AbortScript(
          '第 $line 行：引用未定义的变量 `$name`。'
          '提示：先用 `set $name = ...` 定义它。',
        );
      }
      b.write(v);
      i = j;
    }
    return b.toString();
  }
}
