/// 9 个命令的**真正实现**（连数据库、弹确认、写撤销栈）。
///
/// 它是 [CommandHost] 的落地版：解释器只做语法与变量，脏活全在这里。
///
/// ## 三件由这一层强制的安全事
///
/// 1. **写命令逐条弹确认**（设计 §8.3）：`echo` / `sed` 的 c/d/i/a / `rm` /
///    `mkdir` / `mv` 每条都调 [onConfirm]；没有确认通道时**直接拒绝**（fail closed）。
/// 2. **用户拒绝不中断脚本**：拒绝抛 [CommandFail]，解释器记一条失败后继续下一条。
/// 3. **上限不靠模型自觉**：标题截断、正文到硬上限就失败（与编辑页同一套）。
///
/// 设计见 docs/命令语言设计.md 第 4、8、9 节。
library;

import '../../../../core/db/app_database.dart';
import '../../../../core/util/ai_limits.dart';
import '../../../note/data/note_chunk_repository.dart';
import '../../../note/data/note_repository.dart';
import '../../../note/data/notebook_repository.dart';
import 'command_interpreter.dart';
import 'command_types.dart';

/// 写命令的确认请求（与 `ToolConfirmRequest` 同形，但不反向依赖执行器）。
class CommandConfirm {
  const CommandConfirm({
    required this.title,
    required this.summary,
    this.before,
    this.after,
    this.warning,
    this.isDelete = false,
  });

  final String title;
  final String summary;
  final String? before;
  final String? after;
  final String? warning;

  /// 删除类：UI 会把按钮改成红色的「删除」，措辞要写明不可恢复。
  final bool isDelete;
}

typedef CommandConfirmFn = Future<bool> Function(CommandConfirm request);

/// 写回正文（与 `ToolExecutor._writeNote` 同义：会重切切片、派生字段）。
typedef CommandWriteFn = Future<void> Function(
  Note before, {
  required String title,
  required String content,
});

/// 记入撤销栈。
typedef CommandUndoFn = void Function(Note before);

class NoteCommandHost implements CommandHost {
  NoteCommandHost(
    this._db, {
    this.onConfirm,
    required this.writeNote,
    required this.rememberUndo,
  }) : _chunks = NoteChunkRepository(_db);

  final AppDatabase _db;
  final CommandConfirmFn? onConfirm;
  final CommandWriteFn writeNote;
  final CommandUndoFn rememberUndo;
  final NoteChunkRepository _chunks;

  /// 固定的「未归档」笔记库名（根目录下始终有一个）。
  static const inboxName = '我的轻笔记';

  /// 单次 `sed -n` 最多读几行（设计 §8.6）。
  static const maxSedReadLines = CommandLimits.maxSedReadLines;

  /// 单次 `grep` 最多返回多少条（设计 §8.6）。
  static const maxGrepHits = CommandLimits.maxGrepHits;

  /// sed 表达式：`A` / `A,B` + 动作 `p|c|d|i|a` +（可选空格）+ 内容。
  static final _sedRe = RegExp(r'^(\d+)(?:,(\d+))?([pcdia])\s?([\s\S]*)$');

  // ==========================================================================
  // ls / stat
  // ==========================================================================

  @override
  Future<CmdResult> ls(List<String> args) => _guard(() async {
        if (args.isEmpty) {
          final nbs = await _allNotebooks();
          final names = [inboxName, ...nbs.map((n) => n.name)];
          return CmdResult.ok(names.join('\n'));
        }
        if (args.length > 1) {
          throw const CommandFail('`ls` 最多带一个参数（笔记库名）。');
        }
        final ref = await _resolveNotebook(args[0]);
        if (ref == null) {
          throw CommandFail('找不到笔记库「${args[0]}」。${await _hintNotebooks()}');
        }
        return CmdResult.ok(await _listInNotebook(ref.id));
      });

  @override
  Future<CmdResult> stat(List<String> args) => _guard(() async {
        if (args.length != 1) {
          throw const CommandFail('用法：`stat <笔记>`。');
        }
        final ref = await _requireNote(args[0]);
        final n = ref.note;
        final b = StringBuffer()
          ..writeln('笔记：${ref.notebookName}/${_titleOf(n)}')
          ..writeln('所属库：${ref.notebookName}')
          ..writeln('行数：${_lines(n.content).length}')
          ..writeln('字数：${n.content.length}')
          ..writeln('大小：${AiLimits.byteLength(n.content)} 字节')
          ..writeln('修改时间：${_stamp(n.updatedAt)}');
        return CmdResult.ok(b.toString().trimRight());
      });

  // ==========================================================================
  // sed（读 + 写）
  // ==========================================================================

  @override
  Future<CmdResult> sed(List<String> args) => _guard(() async {
        var rest = args;
        var read = false;
        if (rest.isNotEmpty && rest.first == '-n') {
          read = true;
          rest = rest.sublist(1);
        }
        if (rest.length != 2) {
          throw const CommandFail(
            "用法：`sed -n 'A,Bp' <笔记>`（读）/ `sed 'A,Bc 新内容' <笔记>`（替换）"
            " / `sed 'A,Bd' <笔记>`（删除）/ `sed 'Ai 内容' <笔记>`（前插）"
            " / `sed 'Aa 内容' <笔记>`（后插）。",
          );
        }
        final expr = _parseSed(rest[0], read: read);
        if (expr == null) {
          throw CommandFail(
            '看不懂 sed 表达式「${rest[0]}」。支持 `A,Bp` / `A,Bc 内容` / '
            '`A,Bd` / `Ai 内容` / `Aa 内容`。',
          );
        }
        final ref = await _requireNote(rest[1]);
        final note = ref.note;
        final trailing = note.content.endsWith('\n');
        final lines = _lines(note.content);

        if (read) {
          return CmdResult.ok(_sedRead(lines, expr, _titleOf(note)));
        }
        return _sedWrite(ref, expr, lines, trailing);
      });

  String _sedRead(
    List<String> lines,
    ({int a, int? b, String action, String content}) expr,
    String title,
  ) {
    final total = lines.length;
    if (total == 0) throw CommandFail('笔记《$title》没有正文。');
    if (expr.a < 1) throw CommandFail('行号从 1 开始，你写了 ${expr.a}。');
    if (expr.a > total) {
      throw CommandFail(
        '笔记《$title》只有 $total 行，第 ${expr.a} 行不存在。提示：先用 stat 确认行数。',
      );
    }
    var end = expr.b ?? expr.a;
    if (end < expr.a) throw CommandFail('范围写反了：${expr.a},$end。');
    var truncated = false;
    if (end - expr.a + 1 > maxSedReadLines) {
      end = expr.a + maxSedReadLines - 1;
      truncated = true;
    }
    if (end > total) end = total;
    final out = lines.sublist(expr.a - 1, end).join('\n');
    return truncated
        ? '$out\n（结果已截断，只读了 $maxSedReadLines 行，请缩小范围）'
        : out;
  }

  Future<CmdResult> _sedWrite(
    ({Note note, String notebookName}) ref,
    ({int a, int? b, String action, String content}) expr,
    List<String> lines,
    bool trailing,
  ) async {
    final note = ref.note;
    final total = lines.length;
    final a = expr.a;
    final b = expr.b ?? expr.a;
    final List<String> next;
    switch (expr.action) {
      case 'c':
        if (a < 1 || b < a || b > total) {
          throw CommandFail(
            '第 $b 行不存在：笔记《${_titleOf(note)}》只有 $total 行。'
            '提示：先用 stat 确认行数，再 sed -n 读目标行。',
          );
        }
        next = [...lines.sublist(0, a - 1), expr.content, ...lines.sublist(b)];
      case 'd':
        if (a < 1 || b < a || b > total) {
          throw CommandFail(
            '第 $b 行不存在：笔记《${_titleOf(note)}》只有 $total 行。'
            '提示：先用 stat 确认行数。',
          );
        }
        next = [...lines.sublist(0, a - 1), ...lines.sublist(b)];
      case 'i':
        if (a < 1 || a > total + 1) {
          throw CommandFail(
            '插入位置第 $a 行不存在：笔记《${_titleOf(note)}》只有 $total 行'
            '（可填 1..${total + 1}）。',
          );
        }
        next = [...lines.sublist(0, a - 1), expr.content, ...lines.sublist(a - 1)];
      case 'a':
        if (a < 0 || a > total) {
          throw CommandFail(
            '追加位置第 $a 行不存在：笔记《${_titleOf(note)}》只有 $total 行'
            '（可填 0..$total）。',
          );
        }
        next = [...lines.sublist(0, a), expr.content, ...lines.sublist(a)];
      default:
        throw CommandFail('不支持的 sed 动作「${expr.action}」。');
    }

    final newContent = _joinLines(next, trailing);
    _checkBytes(newContent, 'sed 修改后的正文');
    await _confirm(
      '修改笔记',
      _sedSummary(expr.action, a, expr.b, expr.content, _titleOf(note)),
      before: note.content,
      after: newContent,
    );
    rememberUndo(note);
    await writeNote(note, title: note.title, content: newContent);
    return CmdResult.ok(
      '已修改《${_titleOf(note)}》，现在共 ${_lines(newContent).length} 行。',
    );
  }

  ({int a, int? b, String action, String content})? _parseSed(
    String expr, {
    required bool read,
  }) {
    final m = _sedRe.firstMatch(expr.trim());
    if (m == null) return null;
    final action = m.group(3)!;
    if (read && action != 'p') return null;
    if (!read && action == 'p') return null;
    return (
      a: int.parse(m.group(1)!),
      b: m.group(2) == null ? null : int.parse(m.group(2)!),
      action: action,
      content: m.group(4) ?? '',
    );
  }

  // ==========================================================================
  // grep
  // ==========================================================================

  @override
  Future<CmdResult> grep(List<String> args) => _guard(() async {
        if (args.isEmpty || args.length > 2) {
          throw const CommandFail('用法：`grep "词" [笔记或笔记库]`。');
        }
        final pattern = args[0];
        if (pattern.isEmpty) throw const CommandFail('grep 的关键词不能为空。');

        final hits = <String>[];
        if (args.length == 1) {
          final notes = await _db.allActiveNotes();
          final names = {for (final n in await _allNotebooks()) n.id: n.name};
          for (final n in notes) {
            _scan(n, names[n.notebookId] ?? inboxName, pattern, hits);
            if (hits.length >= maxGrepHits) break;
          }
        } else {
          final path = args[1];
          final nbRef = await _resolveNotebook(path);
          if (nbRef != null) {
            for (final n in await _notesIn(nbRef.id)) {
              _scan(n, nbRef.name, pattern, hits);
              if (hits.length >= maxGrepHits) break;
            }
          } else {
            final ref = await _requireNote(path);
            _scan(ref.note, ref.notebookName, pattern, hits);
          }
        }

        if (hits.isEmpty) {
          return CmdResult.fail(
            '没有匹配「$pattern」的行。提示：换个更短的关键词，或先用 ls 看看有哪些笔记。',
          );
        }
        final truncated = hits.length >= maxGrepHits;
        final out = hits.join('\n') +
            (truncated
                ? '\n（结果已截断，只显示前 $maxGrepHits 条，请缩小范围）'
                : '');
        return CmdResult.ok(out);
      });

  void _scan(Note n, String notebookName, String pattern, List<String> hits) {
    final lines = _lines(n.content);
    for (var i = 0; i < lines.length && hits.length < maxGrepHits; i++) {
      final at = lines[i].indexOf(pattern);
      if (at < 0) continue;
      hits.add(
        '$notebookName/${_titleOf(n)}:${i + 1}: '
        '${_snippet(lines[i], at, pattern.length)}',
      );
    }
  }

  // ==========================================================================
  // echo
  // ==========================================================================

  @override
  Future<CmdResult> echo(List<String> args, {required bool append}) =>
      _guard(() async {
        if (args.length < 2) {
          throw const CommandFail('用法：`echo "内容" > <笔记>`（`>>` 为追加）。');
        }
        final path = args.last;
        final content = args.sublist(0, args.length - 1).join(' ');
        final sp = _splitPath(path);
        if (sp == null) {
          throw CommandFail('路径「$path」写法不对（最多 `库/笔记` 两级）。');
        }
        if (sp.title.isEmpty) throw const CommandFail('笔记名不能为空。');

        final existing = await _tryFindNote(path);
        if (existing != null) {
          final note = existing.note;
          final next = append
              ? (note.content.trim().isEmpty
                  ? content
                  : '${note.content.trimRight()}\n$content')
              : content;
          _checkBytes(next, 'echo 写入的正文');
          await _confirm(
            append ? '追加内容' : '覆盖笔记',
            '${append ? '在末尾追加' : '覆盖'}《${_titleOf(note)}》，'
            '写入 ${content.length} 字：「${_clip(content)}」',
            before: note.content,
            after: next,
          );
          rememberUndo(note);
          await writeNote(note, title: note.title, content: next);
          return CmdResult.ok(
            '已${append ? '追加' : '覆盖'}《${_titleOf(note)}》，'
            '现在共 ${_lines(next).length} 行。',
          );
        }

        // 新建：目标笔记库必须已存在（不隐式建库，避免拼错库名时悄悄建一堆库）。
        String? notebookId;
        var notebookName = inboxName;
        if (sp.notebookName != null) {
          final ref = await _resolveNotebook(sp.notebookName!);
          if (ref == null) {
            throw CommandFail(
              '找不到笔记库「${sp.notebookName}」。${await _hintNotebooks()}',
            );
          }
          notebookId = ref.id;
          notebookName = ref.name;
        }
        final title = sp.title.length > AiLimits.titleHardMax
            ? safeTruncate(sp.title, AiLimits.titleHardMax)
            : sp.title;
        _checkBytes(content, 'echo 写入的正文');
        await _confirm(
          '新建笔记',
          '在「$notebookName」新建《$title》，写入 ${content.length} 字：'
          '「${_clip(content)}」',
          after: content,
        );
        final note = notebookId == null
            ? await NoteRepository(_db).createInbox(title: title, content: content)
            : await NoteRepository(_db)
                .createInNotebook(notebookId, title: title, content: content);
        await _chunks.rebuild(note.id, content);
        return CmdResult.ok(
          '已新建《${_titleOf(note)}》（在「$notebookName」），'
          '共 ${_lines(content).length} 行。',
        );
      });

  // ==========================================================================
  // rm / mkdir / mv
  // ==========================================================================

  @override
  Future<CmdResult> rm(List<String> args) => _guard(() async {
        if (args.length != 1) throw const CommandFail('用法：`rm <笔记>`。');
        final ref = await _requireNote(args[0]);
        await _confirm(
          '删除笔记',
          '删除《${_titleOf(ref.note)}》。**删了就找不回来**（没有回收站）。',
          before: ref.note.content,
          isDelete: true,
        );
        await _db.softDeleteNote(ref.note.id);
        await _chunks.clearFor(ref.note.id);
        return CmdResult.ok('已删除《${_titleOf(ref.note)}》。');
      });

  @override
  Future<CmdResult> mkdir(List<String> args) => _guard(() async {
        if (args.length != 1) throw const CommandFail('用法：`mkdir <笔记库>`。');
        final name = args[0].trim();
        if (name.isEmpty) throw const CommandFail('笔记库名不能为空。');
        if (name == inboxName) {
          throw const CommandFail('「$inboxName」是固定存在的，不用新建。');
        }
        if (await _notebookByName(name) != null) {
          throw CommandFail('笔记库「$name」已经存在。');
        }
        await _confirm('新建笔记库', '新建笔记库「$name」');
        final nb = await NotebookRepository(_db).create(name: name);
        return CmdResult.ok('已新建笔记库「${nb.name}」。');
      });

  @override
  Future<CmdResult> mv(List<String> args) => _guard(() async {
        if (args.length != 2) {
          throw const CommandFail('用法：`mv <笔记或笔记库> <目标>`。');
        }
        final src = args[0];
        final dst = args[1];
        final noteRef = await _tryFindNote(src);
        if (noteRef != null) return _moveNote(noteRef, dst);
        final nbRef = await _resolveNotebook(src);
        if (nbRef != null && nbRef.id != null) return _renameNotebook(nbRef, dst);
        throw CommandFail('找不到笔记或笔记库「$src」。${await _hintNotebooks()}');
      });

  Future<CmdResult> _moveNote(
    ({Note note, String notebookName}) ref,
    String dst,
  ) async {
    final note = ref.note;

    // 目标是一个已存在的笔记库名（且不含 `/`）→ 只移动，不改名。
    if (!dst.contains('/')) {
      final nb = await _resolveNotebook(dst);
      if (nb != null) {
        await _confirm('移动笔记', '把《${_titleOf(note)}》移到「${nb.name}」');
        await _db.moveNoteToNotebook(note.id, nb.id);
        return CmdResult.ok('已把《${_titleOf(note)}》移到「${nb.name}」。');
      }
    }

    // 否则把目标当 `库/新名` 或 `新名`。
    final sp = _splitPath(dst);
    if (sp == null || sp.title.isEmpty) {
      throw CommandFail('目标「$dst」写法不对（最多 `库/笔记` 两级）。');
    }
    String? targetId = note.notebookId;
    var targetName = ref.notebookName;
    if (sp.notebookName != null) {
      final nb = await _resolveNotebook(sp.notebookName!);
      if (nb == null) {
        throw CommandFail('找不到笔记库「${sp.notebookName}」。${await _hintNotebooks()}');
      }
      targetId = nb.id;
      targetName = nb.name;
    }
    final newTitle = sp.title;
    if (newTitle == _titleOf(note) && targetId == note.notebookId) {
      return CmdResult.ok('源和目标相同，没有变化。');
    }
    final clash = await _candidatesIn(targetId, newTitle);
    if (clash.isNotEmpty && clash.first.id != note.id) {
      throw CommandFail('「$targetName」里已经有笔记叫「$newTitle」，换个名字。');
    }

    await _confirm(
      '移动 / 重命名笔记',
      '把《${_titleOf(note)}》改为「$targetName/$newTitle」',
    );
    rememberUndo(note);
    await writeNote(note, title: newTitle, content: note.content);
    if (targetId != note.notebookId) {
      await _db.moveNoteToNotebook(note.id, targetId);
    }
    return CmdResult.ok(
      '已把《${_titleOf(note)}》'
      '${targetId != note.notebookId ? '移到「$targetName」并' : ''}'
      '改名为「$newTitle」。',
    );
  }

  Future<CmdResult> _renameNotebook(
    ({String? id, String name}) ref,
    String dst,
  ) async {
    if (dst.contains('/')) throw const CommandFail('笔记库名不能带 `/`。');
    final newName = dst.trim();
    if (newName.isEmpty) throw const CommandFail('笔记库名不能为空。');
    if (newName == inboxName) throw const CommandFail('不能改名为「$inboxName」。');
    if (await _notebookByName(newName) != null) {
      throw CommandFail('已经有一个笔记库叫「$newName」。');
    }
    await _confirm('重命名笔记库', '「${ref.name}」→「$newName」');
    await NotebookRepository(_db).rename(ref.id!, newName);
    return CmdResult.ok('已把笔记库「${ref.name}」改名为「$newName」。');
  }

  // ==========================================================================
  // 确认 / 工具
  // ==========================================================================

  Future<void> _confirm(
    String title,
    String summary, {
    String? before,
    String? after,
    bool isDelete = false,
  }) async {
    final c = onConfirm;
    if (c == null) {
      throw const CommandFail(
        '现在没有可用的确认通道，写操作一律不执行。请把要做的事说给用户，让他自己决定。',
      );
    }
    final yes = await c(CommandConfirm(
      title: title,
      summary: summary,
      before: before,
      after: after,
      isDelete: isDelete,
    ));
    if (!yes) {
      throw CommandFail(
        '用户**拒绝了**这次操作（$summary）。不要重试同一个操作；换个做法，或者问用户想怎么做。',
      );
    }
  }

  /// 统一把 [CommandFail] 变成 `CmdResult.fail`（继续执行下一条）。
  Future<CmdResult> _guard(Future<CmdResult> Function() body) async {
    try {
      return await body();
    } on CommandFail catch (e) {
      return CmdResult.fail(e.message);
    }
  }

  // ==========================================================================
  // 解析 / 查询辅助
  // ==========================================================================

  ({String? notebookName, String title})? _splitPath(String path) {
    final p = path.trim();
    if (p.isEmpty) return null;
    final parts = p.split('/');
    if (parts.length == 1) return (notebookName: null, title: parts[0].trim());
    if (parts.length == 2) {
      return (notebookName: parts[0].trim(), title: parts[1].trim());
    }
    return null;
  }

  Future<List<Notebook>> _allNotebooks() => _db.allNotebooks();

  Future<Notebook?> _notebookByName(String name) async {
    for (final n in await _allNotebooks()) {
      if (n.name == name) return n;
    }
    return null;
  }

  Future<({String? id, String name})?> _resolveNotebook(String name) async {
    final t = name.trim();
    if (t == inboxName) return (id: null, name: inboxName);
    final nb = await _notebookByName(t);
    if (nb == null) return null;
    return (id: nb.id, name: nb.name);
  }

  /// 某笔记库（或轻笔记）里的全部笔记。`notebookId == null` 表示「我的轻笔记」。
  Future<List<Note>> _notesIn(String? notebookId) => _db.notesInScope(
        notebookIds: notebookId == null ? const [] : [notebookId],
        includeUnfiled: notebookId == null,
        limit: 500,
      );

  Future<String> _listInNotebook(String? notebookId) async {
    final notes = await _notesIn(notebookId);
    if (notes.isEmpty) return '（这个笔记库还没有笔记）';
    return notes.map(_titleOf).join('\n');
  }

  Future<List<Note>> _candidatesIn(String? notebookId, String title) async {
    final notes = await _notesIn(notebookId);
    return [
      for (final n in notes)
        if (_titleOf(n) == title) n,
    ];
  }

  Future<List<({Note note, String notebookName})>> _matchAll(String title) async {
    final notes = await _db.allActiveNotes();
    final names = {for (final n in await _allNotebooks()) n.id: n.name};
    return [
      for (final n in notes)
        if (_titleOf(n) == title)
          (note: n, notebookName: names[n.notebookId] ?? inboxName),
    ];
  }

  /// 找到唯一一篇笔记；找不到 / 有歧义 → 抛可读的 [CommandFail]。
  Future<({Note note, String notebookName})> _requireNote(String path) async {
    final sp = _splitPath(path);
    if (sp == null) {
      throw CommandFail('路径「$path」写法不对（最多 `库/笔记` 两级）。');
    }
    if (sp.title.isEmpty) {
      throw CommandFail('路径「$path」里缺少笔记名。');
    }
    if (sp.notebookName != null) {
      final ref = await _resolveNotebook(sp.notebookName!);
      if (ref == null) {
        throw CommandFail('找不到笔记库「${sp.notebookName}」。${await _hintNotebooks()}');
      }
      final cs = await _candidatesIn(ref.id, sp.title);
      if (cs.isEmpty) {
        throw CommandFail(
          '笔记库「${ref.name}」里没有笔记「${sp.title}」。'
          '这里有：${await _listInNotebook(ref.id)}。'
          '提示：检查名字是否写错，或先用 ls 查看。',
        );
      }
      if (cs.length > 1) {
        throw CommandFail(
          '「${ref.name}」里有 ${cs.length} 篇同名笔记「${sp.title}」，无法确定是哪一篇。',
        );
      }
      return (note: cs.first, notebookName: ref.name);
    }
    final ms = await _matchAll(sp.title);
    if (ms.isEmpty) {
      throw CommandFail('没找到笔记「${sp.title}」。${await _hintTitle()}');
    }
    if (ms.length > 1) {
      final list =
          ms.map((m) => '${m.notebookName}/${_titleOf(m.note)}').join('、');
      throw CommandFail('有 ${ms.length} 篇笔记叫「${sp.title}」，请用 `库/笔记` 指定：$list。');
    }
    return ms.first;
  }

  /// 尽力找到；找不到返回 null；有歧义仍抛（写操作歧义必须拦）。
  Future<({Note note, String notebookName})?> _tryFindNote(String path) async {
    final sp = _splitPath(path);
    if (sp == null) {
      throw CommandFail('路径「$path」写法不对（最多 `库/笔记` 两级）。');
    }
    if (sp.notebookName != null) {
      final ref = await _resolveNotebook(sp.notebookName!);
      if (ref == null) return null; // 笔记库不存在 → 交给调用方（新建时报错）
      final cs = await _candidatesIn(ref.id, sp.title);
      if (cs.isEmpty) return null;
      if (cs.length > 1) {
        throw CommandFail('「${ref.name}」里有 ${cs.length} 篇同名笔记「${sp.title}」。');
      }
      return (note: cs.first, notebookName: ref.name);
    }
    final ms = await _matchAll(sp.title);
    if (ms.isEmpty) return null;
    if (ms.length > 1) {
      final list =
          ms.map((m) => '${m.notebookName}/${_titleOf(m.note)}').join('、');
      throw CommandFail('有 ${ms.length} 篇笔记叫「${sp.title}」，请用 `库/笔记` 指定：$list。');
    }
    return ms.first;
  }

  Future<String> _hintNotebooks() async {
    final nbs = await _allNotebooks();
    final names = [inboxName, ...nbs.map((n) => n.name)];
    return '现有笔记库：${names.join('、')}。提示：先用 ls 查看。';
  }

  Future<String> _hintTitle() async {
    final notes = await _db.allActiveNotes();
    if (notes.isEmpty) return '提示：先用 ls 查看有哪些笔记库和笔记。';
    final titles = notes.take(20).map(_titleOf).toList();
    return '现有笔记（前 ${titles.length} 篇）：${titles.join('、')}。'
        '提示：检查名字是否写错，或先用 ls 查看。';
  }

  // ==========================================================================
  // 文本 / 上限
  // ==========================================================================

  static String _titleOf(Note n) =>
      n.title.trim().isEmpty ? '（无标题）' : n.title.trim();

  /// 正文按行拆。结尾换行不算额外一行（`"a\n"` = 1 行，`""` = 0 行）。
  static List<String> _lines(String content) {
    if (content.isEmpty) return const [];
    var s = content;
    if (s.endsWith('\n')) s = s.substring(0, s.length - 1);
    return s.split('\n');
  }

  static String _joinLines(List<String> lines, bool trailing) {
    final s = lines.join('\n');
    return trailing ? '$s\n' : s;
  }

  /// 与编辑页同一套硬上限：正文到硬上限就失败（不截断 —— 截断等于悄悄删内容）。
  static void _checkBytes(String content, String what) {
    final bytes = AiLimits.byteLength(content);
    if (bytes >= AiLimits.noteHardBytes) {
      final kb = (bytes / 1024).toStringAsFixed(1);
      throw CommandFail(
        '$what 有 $kb KB，超过 ${AiLimits.noteHardBytes ~/ 1024} KB 的硬上限，'
        'App 拒绝保存。请精简内容，或拆成多篇（先 mv/echo 建新篇）。',
      );
    }
  }

  static String _sedSummary(
    String action,
    int a,
    int? b,
    String content,
    String title,
  ) {
    final range = b == null ? '$a' : '$a-$b';
    return switch (action) {
      'c' => '把《$title》第 $range 行替换为「${_clip(content)}」',
      'd' => '删除《$title》第 $range 行',
      'i' => '在《$title》第 $a 行前插入「${_clip(content)}」',
      'a' => '在《$title》第 $a 行后插入「${_clip(content)}」',
      _ => '修改《$title》',
    };
  }

  static String _clip(String s, {int max = 40}) {
    final flat = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length > max ? '${flat.substring(0, max)}…' : flat;
  }

  /// 命中位置前后各取一点，压成单行片段（grep 结果显示用）。
  static String _snippet(String line, int at, int len,
      {int before = 20, int after = 50}) {
    final from = at - before < 0 ? 0 : at - before;
    final to = at + len + after > line.length ? line.length : at + len + after;
    final flat = line.substring(from, to).trim();
    return '${from > 0 ? '…' : ''}$flat${to < line.length ? '…' : ''}';
  }

  /// 时间戳（本地时间，只到分钟）。与执行器/HistoryChunker 同格式。
  static String _stamp(DateTime utc) {
    final l = utc.toLocal();
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${p2(l.month)}-${p2(l.day)} ${p2(l.hour)}:${p2(l.minute)}';
  }
}
