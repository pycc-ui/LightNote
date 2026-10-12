/// 命令脚本的**解析器**：把一段脚本文本切成 AST（[ScriptProgram]）。
///
/// 三件事在这一层做完：
///   1. **分词**：按行切、识别引号与重定向符；
///   2. **语法**：`set` / `for` / `if` / `end` 的配对（只允许一层，不嵌套）；
///   3. **白名单**：命令名不在 [kCommandNames] 里、或写了不支持的特性
///      （管道、命令替换、通配符……）一律报 [CommandSyntaxError]。
///
/// 注意这里**不做变量插值**（那是执行期的事，见 `command_interpreter.dart`），
/// 只保留原始文本 —— 因为 `set` 定义之前就可能引用同名变量，解析期无从判断。
///
/// 设计见 docs/命令语言设计.md 第 5、6 节。
library;

import 'command_types.dart';

/// 解析入口。语法错误抛 [CommandSyntaxError]。
ScriptProgram parseScript(String source) => _Parser(source.split('\n')).parse();

/// 特殊字符 → 报错信息。它们在"未加引号"时出现即非法。
///
/// 引号**里面**的字符不经过这里 —— `echo "含 * 的文本"` 是合法的。
const _specialErrors = <String, String>{
  '|': '不支持管道。',
  ';': '不支持一行写多条命令（不要用 `;`）。',
  '&': '不支持后台执行 / 逻辑运算符 `&&`。',
  '<': '不支持输入重定向。',
  '`': '不支持反引号命令替换。',
  r'$(': '不支持命令替换 `\$(…)`。',
  '*': '不支持通配符 `*`。',
  '?': '不支持通配符 `?`。',
  '[': '不支持通配符 `[…]`。',
  ']': '不支持通配符 `[…]`。',
  '(': '不支持括号。',
  ')': '不支持括号。',
};

class _Parser {
  _Parser(this._lines);

  final List<String> _lines;
  int _i = 0;

  /// 变量名允许的字符（中文 / 英文 / 数字 / 下划线）。
  static final _varChar = RegExp(r'[A-Za-z0-9_\u4e00-\u9fff]');

  ScriptProgram parse() {
    final stmts = _block(inBlock: false);
    // `_block(inBlock:false)` 只在遇到多余 `end` 或读到末尾时返回；
    // 前者已在循环里抛错，走到这里必然是读完了。
    return ScriptProgram(stmts);
  }

  List<Stmt> _block({required bool inBlock}) {
    final out = <Stmt>[];
    while (_i < _lines.length) {
      final lineNo = _i + 1;
      final trimmed = _lines[_i].trim();

      if (trimmed.isEmpty) {
        _i++;
        continue;
      }
      if (trimmed.startsWith('#')) {
        _i++; // 整行注释
        continue;
      }
      if (trimmed == 'end') {
        if (!inBlock) {
          throw CommandSyntaxError('`end` 没有配对的 `for` / `if`。', lineNo);
        }
        _i++;
        return out;
      }
      if (trimmed == 'for' || trimmed == 'if' || trimmed == 'set') {
        throw CommandSyntaxError('`$trimmed` 缺参数，用法不对。', lineNo);
      }
      if (trimmed.startsWith('for ')) {
        if (inBlock) throw CommandSyntaxError('不支持嵌套循环。', lineNo);
        out.add(_parseFor(lineNo));
        continue;
      }
      if (trimmed.startsWith('if ')) {
        if (inBlock) throw CommandSyntaxError('不支持嵌套条件。', lineNo);
        out.add(_parseIf(lineNo));
        continue;
      }
      if (trimmed == 'else' || trimmed == 'elif') {
        throw CommandSyntaxError('不支持 `else` / `elif`。', lineNo);
      }
      if (trimmed.startsWith('while ') || trimmed == 'until') {
        throw CommandSyntaxError('不支持 `while` / `until`。', lineNo);
      }
      if (trimmed == 'break' || trimmed == 'continue' || trimmed == 'return') {
        throw CommandSyntaxError('不支持 `break` / `continue` / `return`。', lineNo);
      }
      if (trimmed.startsWith('set ')) {
        out.add(_parseSet(lineNo, trimmed));
        _i++;
        continue;
      }
      out.add(_parseCommand(lineNo, trimmed));
      _i++;
    }
    if (inBlock) {
      throw CommandSyntaxError('`for` / `if` 缺少配对的 `end`。', _lines.length);
    }
    return out;
  }

  SetStmt _parseSet(int lineNo, String trimmed) {
    final m = RegExp(r'^set\s+([^\s=]+)\s*=\s*(.*)$').firstMatch(trimmed);
    if (m == null) {
      throw CommandSyntaxError('`set` 用法应为 `set 名字 = 值`。', lineNo);
    }
    final name = m.group(1)!;
    _checkVarName(name, lineNo);
    var value = m.group(2)!.trim();
    // 值两端若被同一种引号包住，剥掉一层（引号只用来让空格/特殊字符安全）。
    if (value.length >= 2 &&
        (value.startsWith('"') && value.endsWith('"') ||
            value.startsWith("'") && value.endsWith("'"))) {
      value = value.substring(1, value.length - 1);
    }
    return SetStmt(lineNo, name, value);
  }

  IfStmt _parseIf(int lineNo) {
    final header = _lines[_i].trim();
    var rest = header.substring(2).trim();
    rest = _stripTrailingColon(rest);
    if (rest.isEmpty) {
      throw CommandSyntaxError('`if` 后面要跟一条命令。', lineNo);
    }
    final cond = _parseCommand(lineNo, rest);
    if (cond.redirect != Redirection.none) {
      throw CommandSyntaxError('`if` 的条件命令不能带重定向。', lineNo);
    }
    _i++;
    final body = _block(inBlock: true);
    return IfStmt(lineNo, cond, body);
  }

  ForStmt _parseFor(int lineNo) {
    final header = _lines[_i].trim();
    final m = RegExp(r'^for\s+(\S+)\s+in\s+(.+)$').firstMatch(header);
    if (m == null) {
      throw CommandSyntaxError('`for` 用法应为 `for 变量 in 列表`。', lineNo);
    }
    final name = m.group(1)!;
    _checkVarName(name, lineNo);
    var listText = _stripTrailingColon(m.group(2)!.trim());
    if (listText.isEmpty) {
      throw CommandSyntaxError('`for … in` 后面要有列表。', lineNo);
    }
    _i++;
    final body = _block(inBlock: true);
    return ForStmt(lineNo, name, _forSource(listText, lineNo), body);
  }

  ForSource _forSource(String text, int lineNo) {
    final toks = _tokenize(text, lineNo);
    // 列表是命令结果：第一个词是白名单命令名。
    if (toks.isNotEmpty &&
        !toks.first.quoted &&
        !toks.first.special &&
        kCommandNames.contains(toks.first.text)) {
      final cmd = _commandFromTokens(lineNo, toks);
      return ForCommand(cmd);
    }
    // 否则当字面量列表：每项一个 token（引号内的空格安全）。
    final items = <String>[];
    for (final t in toks) {
      if (t.special) {
        throw CommandSyntaxError('`for … in` 的字面量列表里不能有 `$t.text`。', lineNo);
      }
      items.add(t.text);
    }
    if (items.isEmpty) {
      throw CommandSyntaxError('`for … in` 的列表不能为空。', lineNo);
    }
    return ForList(items);
  }

  CommandStmt _parseCommand(int lineNo, String text) {
    final toks = _tokenize(text, lineNo);
    return _commandFromTokens(lineNo, toks);
  }

  CommandStmt _commandFromTokens(int lineNo, List<_Tok> toks) {
    if (toks.isEmpty) {
      throw CommandSyntaxError('空命令。', lineNo);
    }

    // 先扫一遍非法特殊字符（`>` / `>>` 除外，它们是合法的重定向）。
    var redirect = Redirection.none;
    final args = <String>[];
    var firstWordQuoted = false;
    for (var k = 0; k < toks.length; k++) {
      final t = toks[k];
      if (!t.special) {
        if (args.isEmpty) firstWordQuoted = t.quoted;
        args.add(t.text);
        continue;
      }
      switch (t.text) {
        case '>':
        case '>>':
          if (redirect != Redirection.none) {
            throw CommandSyntaxError('一条命令只能有一个重定向。', lineNo);
          }
          redirect =
              t.text == '>>' ? Redirection.append : Redirection.overwrite;
        default:
          final why = _specialErrors[t.text] ?? '不支持这个符号 `$t.text`。';
          throw CommandSyntaxError(why, lineNo);
      }
    }

    if (args.isEmpty) {
      throw CommandSyntaxError('空命令。', lineNo);
    }
    final name = args.removeAt(0);

    // 命令名必须在白名单里。它一定得是"未加引号的第一个词"——
    // 引号包着的命令名（`'ls' 库`）不是命令，直接判非法。
    if (firstWordQuoted || !kCommandNames.contains(name)) {
      throw CommandSyntaxError(
        '不支持的命令 `$name`。可用命令：${kCommandNames.join(' / ')}。',
        lineNo,
      );
    }

    if (redirect != Redirection.none && name != 'echo') {
      throw CommandSyntaxError('只有 `echo` 支持 `>` / `>>` 重定向。', lineNo);
    }

    return CommandStmt(lineNo, name, args, redirect: redirect);
  }

  void _checkVarName(String name, int lineNo) {
    if (name.isEmpty) {
      throw CommandSyntaxError('变量名不能为空。', lineNo);
    }
    for (var i = 0; i < name.length; i++) {
      if (!_varChar.hasMatch(name[i])) {
        throw CommandSyntaxError(
          '变量名「$name」含非法字符，只能用中文 / 英文 / 数字 / 下划线。',
          lineNo,
        );
      }
    }
  }

  static String _stripTrailingColon(String s) {
    if (s.endsWith(':')) return s.substring(0, s.length - 1).trimRight();
    return s;
  }

  // ==========================================================================
  // 分词：引号 + 特殊字符
  // ==========================================================================

  /// 词法分析。`special` 为真的 token 是运算符/非法字符，交给上层报错。
  static List<_Tok> _tokenize(String raw, int lineNo) {
    final out = <_Tok>[];
    var i = 0;
    while (i < raw.length) {
      final ch = raw[i];
      if (ch == ' ' || ch == '\t') {
        i++;
        continue;
      }
      // 引号：读到配对的同类引号为止，内容原样保留。
      if (ch == '"' || ch == "'") {
        final quote = ch;
        final sb = StringBuffer();
        i++;
        var closed = false;
        while (i < raw.length) {
          if (raw[i] == quote) {
            closed = true;
            i++;
            break;
          }
          sb.write(raw[i]);
          i++;
        }
        if (!closed) {
          throw CommandSyntaxError('引号没有闭合。', lineNo);
        }
        out.add(_Tok(sb.toString(), quoted: true));
        continue;
      }
      // `>>`
      if (ch == '>' && i + 1 < raw.length && raw[i + 1] == '>') {
        out.add(const _Tok('>>', special: true));
        i += 2;
        continue;
      }
      // `$(`：命令替换，明确不支持。
      if (ch == r'$' && i + 1 < raw.length && raw[i + 1] == '(') {
        out.add(const _Tok(r'$(', special: true));
        i += 2;
        continue;
      }
      // 单字符特殊运算符。
      const singles = '><|;&`()[]*?';
      if (singles.contains(ch)) {
        out.add(_Tok(ch, special: true));
        i++;
        continue;
      }
      // 普通词：一直读到空白 / 引号 / 特殊字符 / `$(`。
      final sb = StringBuffer();
      while (i < raw.length) {
        final c = raw[i];
        if (c == ' ' || c == '\t' || c == '"' || c == "'") break;
        if (c == r'$' && i + 1 < raw.length && raw[i + 1] == '(') break;
        if ('><|;&`()[]*?'.contains(c)) break;
        sb.write(c);
        i++;
      }
      out.add(_Tok(sb.toString(), quoted: false));
    }
    return out;
  }
}

/// 一个词法单元。
class _Tok {
  const _Tok(this.text, {this.quoted = false, this.special = false});
  final String text;
  final bool quoted;
  final bool special;
}
