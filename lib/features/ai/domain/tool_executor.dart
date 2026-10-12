import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/db/app_database.dart';
import '../../../core/util/app_params.dart';
import '../../../core/util/text_utils.dart';
import '../../note/data/note_chunk_repository.dart';
import 'command/command_interpreter.dart';
import 'command/command_parser.dart';
import 'command/command_types.dart';
import 'command/note_command_host.dart';
import 'tool_specs.dart';
import 'tool_types.dart';

/// 一次写操作**要用户点头**时的描述（App 弹层用它渲染）。
///
/// 放在这里而不是 UI 层：确认是**执行器的职责**，UI 只是它的一个实现。
/// 这样"没有确认通道时写操作一律拒绝"这条安全规则才落得下来。
class ToolConfirmRequest {
  const ToolConfirmRequest({
    required this.risk,
    required this.toolName,
    required this.title,
    required this.summary,
    this.before,
    this.after,
    this.warning,
  });

  final ToolRisk risk;
  final String toolName;

  /// 弹层标题，如「修改笔记」
  final String title;

  /// 一句话说清要做什么
  final String summary;

  /// 改前（Markdown / 纯文本原文）—— 用来显示 diff
  final String? before;

  /// 改后
  final String? after;

  /// 需要额外提醒的话，如「这条笔记在你读到它之后被改过」
  final String? warning;

  /// 删除类：**二次确认 + 文案要写明不可恢复**
  bool get strong => risk == ToolRisk.delete;
}

/// 问用户"要不要这么做"。返回 false = 用户拒绝（**合法回答，不是错误**）。
typedef ToolConfirmFn = Future<bool> Function(ToolConfirmRequest request);

/// **App 侧的工具执行器**：AI 提出调用 → 这里真正去做。
///
/// 从"命令语言"改造之后，工具只剩两个：`run`（执行一段命令脚本）与 `askUser`
/// （挂起提问，由对话流程接管，不走这里）。所有笔记操作都在脚本里以
/// `ls` / `stat` / `sed` / `grep` / `echo` / `rm` / `mkdir` / `mv` 出现。
///
/// ## 风险拦截仍然在 App
///
/// 单个命令的**风险分级与确认**下沉到了 [NoteCommandHost]：写命令逐条弹确认，
/// 用户拒绝则跳过这一条、继续下一条（设计 §8.3）。这里只负责把 `run` 接上宿主、
/// 解析脚本、格式化结果。
///
/// ## 错误也是"结果"
///
/// 语法错误、单条命令失败、用户拒绝……一律走 [ToolResult.failure] 或带可读文本的
/// 成功结果。模型靠这些话换方案。抛异常会把整轮对话打断。
class ToolExecutor {
  ToolExecutor(
    this._db, {
    this.onConfirm,
  }) : _chunks = NoteChunkRepository(_db);

  final AppDatabase _db;
  final NoteChunkRepository _chunks;

  /// 写操作前的确认入口。null = 没有通道 → 写操作一律拒绝（fail closed）。
  final ToolConfirmFn? onConfirm;

  /// 撤销栈：最近几次写操作**之前的整行**。
  ///
  /// 存整行而不是"id + 正文"：`upsertNote` 要求带齐所有"非空且无默认值"的列
  /// （`createdAt` 就是），少一个 Drift 会在写库前抛 `InvalidDataException`。
  ///
  /// 只留最近几条：撤销是"手滑了救一下"，不是版本历史。
  static const maxUndo = AgentLimits.maxUndo;
  final List<Note> _undo = [];

  /// 最近一次可撤销的写操作（null = 没有）。UI 拿它显示「撤销」。
  ({String noteId, String title})? get undoable {
    if (_undo.isEmpty) return null;
    final u = _undo.last;
    return (noteId: u.id, title: u.title);
  }

  /// 撤销最近一次修改。返回被恢复的笔记 id（没有可撤销的返回 null）。
  Future<String?> undoLast() async {
    if (_undo.isEmpty) return null;
    final before = _undo.removeLast();
    await _writeNote(before, title: before.title, content: before.content);
    return before.id;
  }

  /// 新一轮开始。
  ///
  /// 读预算从"每轮几片"改成了"单次脚本的上限"（见 [CommandLimits]），
  /// 由解释器自己管，所以这里不再重置任何东西。留着空实现是为了不改调用方。
  void beginTurn() {}

  /// 执行一个工具。
  ///
  /// [history] 保留是为了不改 `AgentLoop` 的调用形状；命令语言模式下没有工具用到它。
  Future<ToolResult> execute(
    String name,
    Map<String, Object?> args, {
    List<AiMessage> history = const [],
  }) async {
    try {
      switch (name) {
        case 'run':
          return await _runScript(args);
        case 'askUser':
          // 由对话流程（AgentLoop）接管，不该走到执行器。
          return ToolResult.failure('`askUser` 由对话流程处理，不该走到执行器。');
        default:
          return ToolResult.failure(
            '没有叫 `$name` 的工具。现在只有 `run`（执行命令脚本）与 `askUser`。',
          );
      }
    } catch (e) {
      return ToolResult.failure('执行 `$name` 时出错：$e');
    }
  }

  /// `run`：解析脚本 → 交给解释器执行 → 把执行记录格式化回灌。
  Future<ToolResult> _runScript(Map<String, Object?> a) async {
    final script = _str(a, 'script');
    if (script == null) {
      return ToolResult.failure('run 需要 `script`（命令脚本）。');
    }

    final ScriptProgram program;
    try {
      program = parseScript(script);
    } on CommandSyntaxError catch (e) {
      // 语法错误 → 整段拒绝执行，返回出错位置（设计 §8.4）。
      return ToolResult.failure('脚本语法错误：$e');
    }

    final host = NoteCommandHost(
      _db,
      onConfirm: _commandConfirm,
      writeNote: (before, {required title, required content}) =>
          _writeNote(before, title: title, content: content),
      rememberUndo: _rememberUndo,
    );

    final run = await CommandInterpreter(host).run(program);
    return ToolResult.success(run.format());
  }

  /// 把宿主的确认请求转成 UI 认识的 [ToolConfirmRequest]。
  ///
  /// 没有确认通道时返回 null —— 宿主据此**拒绝全部写命令**（fail closed）。
  CommandConfirmFn? get _commandConfirm {
    final confirm = onConfirm;
    if (confirm == null) return null;
    return (req) => confirm(ToolConfirmRequest(
          risk: req.isDelete ? ToolRisk.delete : ToolRisk.modify,
          toolName: 'run',
          title: req.title,
          summary: req.summary,
          before: req.before,
          after: req.after,
          warning: req.warning,
        ));
  }

  /// 记下"改之前长什么样"，供撤销用。
  void _rememberUndo(Note note) {
    _undo.add(note);
    if (_undo.length > maxUndo) _undo.removeAt(0);
  }

  /// 写回一篇笔记（正文 / 标题），并**重切它的切片**。
  ///
  /// 所有修改路径都走它：正文变了而切片不重切的话，搜索就会指向错位置
  /// （而且不会报错）。`excerpt` / `wordCount` 走 [TextUtils]，与编辑页同一套。
  Future<void> _writeNote(
    Note before, {
    required String title,
    required String content,
  }) async {
    await _db.upsertNote(NotesCompanion(
      id: Value(before.id),
      notebookId: Value(before.notebookId),
      title: Value(title),
      content: Value(content),
      excerpt: Value(TextUtils.excerpt(content)),
      source: Value(before.source),
      isInbox: Value(before.isInbox),
      pinned: Value(before.pinned),
      wordCount: Value(TextUtils.wordCountOfMarkdown(content)),
      lastAiAt: Value(before.lastAiAt),
      createdAt: Value(before.createdAt),
      updatedAt: Value(DateTime.now().toUtc()),
      deletedAt: Value(before.deletedAt),
    ));
    await _chunks.rebuild(before.id, content);
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

  /// 把一个工具结果编码成回灌给模型的字符串（`role: tool` 的 content）。
  static String encodeResult(ToolResult r) => r.encode();

  /// 把模型给的 `arguments`（JSON 字符串）解析成 map。
  ///
  /// 解析不出来时返回空 map —— 后面的参数校验会给出"缺 script"这种
  /// **具体**的抱怨，比"JSON 坏了"更容易让模型纠正。
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
