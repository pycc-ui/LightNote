import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/db/app_database.dart';
import '../../note/data/note_ai_asset_repository.dart';
import '../../note/data/notebook_repository.dart';
import '../../note/data/note_chunk_repository.dart';
import '../../note/data/note_repository.dart';
import '../../note/data/search_service.dart';
import '../../note/domain/history_chunker.dart';
import 'agent_workspace.dart';
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
/// ## 为什么安全要靠这一层，而不是靠模型
///
/// `askUser` 是模型**自愿**调用的。它忘了调，删除就直接执行了。
/// 所以风险分级（[ToolRisk]）由 [toolByName] 上的定义给出，
/// **执行器在动手之前先查级别**：删除类必须先弹确认，模型绕不过去。
/// 见《AI接入设计》的「工具清单、风险分级与调用约定」一节。
///
/// ## 没有确认通道 = 写操作一律拒绝（fail closed）
///
/// [onConfirm] 为 null 时（例如还没接 UI 的早期阶段、或者某个调用路径忘了接），
/// 写类工具**直接失败**而不是"悄悄执行"。反过来（默认放行）意味着
/// 任何一条漏接的回调都会变成"AI 可以随便改用户的数据"，而不报错。
///
/// ## 错误也是"结果"
///
/// 参数缺失、笔记找不到、锚点失效、用户拒绝……一律返回 [ToolResult.failure]
/// 并带上**可读的原因**。模型靠这句话换方案。抛异常会把整轮对话打断。
class ToolExecutor {
  ToolExecutor(
    this._db, {
    this.onConfirm,
    this.workspace = AgentWorkspace.all,
  })  : _search = SearchService(_db),
        _chunks = NoteChunkRepository(_db),
        _assets = NoteAiAssetRepository(_db);

  final AppDatabase _db;
  final SearchService _search;
  final NoteChunkRepository _chunks;

  /// AI 资产（缓存摘要）只读一份给 `getNoteMeta` 用：摘要**用户看不到**，
  /// 但"有没有摘要"能帮模型判断这篇笔记值不值得展开。
  final NoteAiAssetRepository _assets;

  /// **AI 能看到的笔记范围**。
  ///
  /// App 里始终显式传会话的工作区（见 `AiChatRepository`），这个默认值只是
  /// 给"直接 new 出来用"的调用方（主要是测试）一个不限范围的起点。
  ///
  /// ⚠️ 它是**上限**：模型自己在参数里给的 `notebookId` 只能**收窄**，
  /// 不能放宽（见 [_scope]）。否则模型随手传一个别的库 id 就绕过了用户的设定。
  final AgentWorkspace workspace;

  /// 把模型给的 `notebookId`（可选）收窄到工作区内。
  ///
  /// 返回的是查询参数；`notebookIds: []` + `includeUnfiled: false` 表示
  /// **一条都不该命中** —— 那正是"模型要的库不在工作区里"该有的结果，
  /// 而不是偷偷放宽成整个工作区（那等于告诉模型它猜对了）。
  ({List<String>? notebookIds, bool includeUnfiled}) _scope(String? narrowTo) {
    final w = workspace.resolve();
    if (narrowTo == null) return w;

    final allowed = w.notebookIds;
    // 工作区不限目录 → 模型指定的那个库就是范围（收窄，不含轻笔记）
    if (allowed == null) {
      return (notebookIds: [narrowTo], includeUnfiled: false);
    }
    if (!allowed.contains(narrowTo)) {
      return (notebookIds: const [], includeUnfiled: false);
    }
    return (notebookIds: [narrowTo], includeUnfiled: false);
  }

  /// 写操作前的确认入口。null = 没有通道 → 写操作一律拒绝。
  final ToolConfirmFn? onConfirm;

  /// 一轮对话里最多读几片正文。
  ///
  /// `readChunk` 的定义是一次一片，但模型很容易连着调五次把整篇灌进来 ——
  /// 那既贵又没必要（它该先看目录挑相关的）。所以预算记在**轮**上。
  static const maxChunksPerTurn = 3;

  /// 一轮里读片正文的字数上限（与 `readHistory` 同口径）
  static const maxChunkCharsPerTurn = 1500;

  /// 批量工具的条数上限（协议里定的 ≤10）
  static const maxBatch = 10;

  int _turnChunks = 0;
  int _turnChars = 0;

  /// 「AI 读到的是哪个版本」的快照：笔记 id → 内容 hash。
  ///
  /// 只在**读到过**的笔记上记录。写之前比对当前 hash：
  /// 不一致说明"用户在这期间手改过"，于是把这件事写进确认层让用户自己判断。
  /// 这是**粗筛**（乐观锁最简版）—— 精确定位靠 `expectedText` 锚点。
  ///
  /// 不清空：跨轮读取仍然有效（AI 可能第一轮读、第三轮才改），
  /// 而同一条笔记下次被读到时自然会被覆盖。
  final Map<String, int> _snapshot = {};

  /// 撤销栈：最近几次写操作**之前的整行**。
  ///
  /// 存整行而不是"id + 正文"：`upsertNote` 要求带齐所有"非空且无默认值"的列
  /// （`createdAt` 就是），少一个 Drift 会在写库前抛 `InvalidDataException`。
  ///
  /// 只留最近几条：撤销是"手滑了救一下"，不是版本历史。
  static const maxUndo = 5;
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

  /// 新一轮开始（模型每提出一批工具调用之前调一次）。
  ///
  /// 只重置**读片预算**；快照与撤销栈跨轮保留（见 [_snapshot]）。
  void beginTurn() {
    _turnChunks = 0;
    _turnChars = 0;
  }

  /// 执行一个工具。
  ///
  /// [history] 只有 `listHistory` / `readHistory` 用得到：它们是**本会话**
  /// 的切片，数据在调用方（`ai_messages` 读出来的消息列表）手里。
  Future<ToolResult> execute(
    String name,
    Map<String, Object?> args, {
    List<AiMessage> history = const [],
  }) async {
    final tool = toolByName(name);
    if (tool == null) {
      return ToolResult.failure(
        '没有叫 `$name` 的工具。请只用给定的工具；'
        '需要别的工具时先用 requestTools 申请。',
      );
    }

    try {
      switch (name) {
        // ---- 笔记：搜 / 目录 / 读 ----
        case 'searchNotes':
          return await _searchNotes(args);
        case 'listChunks':
          return await _listChunks(args);
        case 'readChunk':
          return await _readChunk(args);

        // ---- 笔记库 / 笔记列表 / 元信息 ----
        case 'listNotebooks':
          return await _listNotebooks();
        case 'listNotes':
          return await _listNotes(args);
        case 'getNoteMeta':
          return await _getNoteMeta(args);

        // ---- 本会话历史 ----
        case 'listHistory':
          return _listHistory(args, history);
        case 'readHistory':
          return _readHistory(args, history);
        case 'searchHistory':
          return _searchHistory(args, history);

        // ---- 创建类（轻确认）----
        case 'createNote':
          return await _createNote(args);
        case 'createNotebook':
          return await _createNotebook(args);

        // ---- 修改类 ----
        case 'updateNote':
          return await _updateNote(args);
        case 'appendToNote':
          return await _appendToNote(args);
        case 'replaceInNote':
          return await _replaceInNote(args);
        case 'moveNote':
          return await _moveNote(args);
        case 'renameNotebook':
          return await _renameNotebook(args);
        case 'batchMoveNotes':
          return await _batchMoveNotes(args);

        // ---- 删除类 ----
        case 'deleteNote':
          return await _deleteNote(args);
        case 'deleteNotebook':
          return await _deleteNotebook(args);
        case 'batchDeleteNotes':
          return await _batchDeleteNotes(args);

        // ---- 交互类：由上层（对话流程）接管，不在这里执行 ----
        case 'askUser':
        case 'requestTools':
          return ToolResult.failure(
            '`$name` 由对话流程处理，不该走到执行器。',
          );
      }
    } catch (e) {
      return ToolResult.failure('执行 `$name` 时出错：$e');
    }

    return ToolResult.failure('没有叫 `$name` 的工具。');
  }

  // ==========================================================================
  // 写操作：确认层
  // ==========================================================================

  /// 所有写操作的**唯一入口**。
  ///
  /// 三件事按顺序做，缺一不可：
  ///   1. 没有确认通道 → **直接拒绝**（fail closed）
  ///   2. 问用户；被拒 → 返回"用户拒绝了"，模型据此换方案
  ///   3. 同意 → 执行
  ///
  /// 返回值是 `(是否放行, 拒绝时的失败结果)`。
  Future<(bool, ToolResult?)> _ask(
    AgentTool tool,
    ToolConfirmRequest request,
  ) async {
    final confirm = onConfirm;
    if (confirm == null) {
      return (
        false,
        ToolResult.failure(
          '现在没有可用的确认通道，写操作一律不执行。'
          '请把要做的事说给用户，让他自己决定。',
        ),
      );
    }
    final yes = await confirm(request);
    if (!yes) {
      return (
        false,
        // "用户拒绝"是**合法回答**，不是错误 —— 但必须让模型知道，
        // 否则它会以为改完了（静默失败比报错糟得多）
        ToolResult.failure(
          '用户**拒绝了**这次操作（${request.summary}）。'
          '不要重试同一个操作；换个做法，或者问用户想怎么做。',
        ),
      );
    }
    return (true, null);
  }

  /// 记下"改之前长什么样"，供撤销用。
  void _rememberUndo(Note note) {
    _undo.add(note);
    if (_undo.length > maxUndo) _undo.removeAt(0);
  }

  /// 写回一篇笔记（正文 / 标题），并**重切它的切片**。
  ///
  /// 所有修改路径都走它：正文变了而切片不重切的话，搜索与 `readChunk`
  /// 就会指向错位置（而且不会报错）。
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
      excerpt: Value(_excerptOf(content)),
      source: Value(before.source),
      isInbox: Value(before.isInbox),
      pinned: Value(before.pinned),
      wordCount: Value(content.length),
      lastAiAt: Value(before.lastAiAt),
      createdAt: Value(before.createdAt),
      updatedAt: Value(DateTime.now().toUtc()),
      deletedAt: Value(before.deletedAt),
    ));
    await _chunks.rebuild(before.id, content);
  }

  /// 内容 hash（快照比对用）
  static int _hashOf(String s) => s.hashCode;

  static String _excerptOf(String content) {
    final flat = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length > 80 ? '${flat.substring(0, 80)}…' : flat;
  }

  // ==========================================================================
  // 只读工具
  // ==========================================================================

  Future<ToolResult> _searchNotes(Map<String, Object?> a) async {
    final query = _str(a, 'query');
    if (query == null || query.trim().isEmpty) {
      return ToolResult.failure('searchNotes 需要 `query`（关键词）。');
    }
    final limit = (_int(a, 'limit') ?? 20).clamp(1, 50);
    final scope = _scope(_str(a, 'notebookId'));
    final results = await _search.search(
      query,
      notebookIds: scope.notebookIds,
      includeUnfiled: scope.includeUnfiled,
      limit: limit,
    );

    if (results.isEmpty) {
      return ToolResult.success({
        'count': 0,
        'results': const [],
        'hint': '没有搜到。换个关键词（用户原话里的词最好），'
            '或者先用 listNotebooks / listNotes 看看库里有什么。',
      });
    }

    return ToolResult.success({
      'count': results.length,
      'results': [
        for (final r in results)
          {
            'noteId': r.noteId,
            'title': r.title,
            'hit': r.isTitleHit ? 'title' : 'chunk',
            // 只有正文命中才有片号；标题命中是"整篇相关"
            if (r.chunkIndex != null) 'chunkIndex': r.chunkIndex,
            if (r.heading.isNotEmpty) 'heading': r.heading,
            'snippet': r.snippet,
          },
      ],
      'hint': '要看具体内容用 readChunk(noteId, index)；'
          '`chunkIndex` 就是 index。标题命中的没有 chunkIndex。',
    });
  }

  /// 片目录：**只有元数据，绝不含正文**。
  ///
  /// 这是 token 经济的关键一步：一篇 5000 字的笔记直接灌进去要几千 token，
  /// 而目录只要几十个。模型看完目录再决定读哪一两片。
  Future<ToolResult> _listChunks(Map<String, Object?> a) async {
    final noteId = _str(a, 'noteId');
    if (noteId == null || noteId.isEmpty) {
      return ToolResult.failure('listChunks 需要 `noteId`。');
    }
    final note = await _db.getNote(noteId);
    if (note == null) {
      return ToolResult.failure(
        '找不到笔记 `$noteId`（可能已被删除）。用 searchNotes 重新找。',
      );
    }
    final chunks = await _chunks.chunksFor(noteId, note.content);
    if (chunks.isEmpty) {
      return ToolResult.success({
        'noteId': noteId,
        'title': note.title,
        'chunkCount': 0,
        'chunks': const [],
        'hint': '这条笔记没有正文，切不出片。',
      });
    }
    return ToolResult.success({
      'noteId': noteId,
      'title': note.title,
      'chunkCount': chunks.length,
      'chunks': [
        for (final c in chunks)
          {
            'index': c.index,
            'heading': c.heading,
            'level': c.level,
            // charCount 必须有：模型据此决定"这一片会不会太长"
            'charCount': c.charCount,
          },
      ],
      'hint': '目录**不含正文**。要看内容用 readChunk(noteId, index)，'
          '一轮最多 $maxChunksPerTurn 片、共 $maxChunkCharsPerTurn 字。',
    });
  }

  Future<ToolResult> _readChunk(Map<String, Object?> a) async {
    final noteId = _str(a, 'noteId');
    final index = _int(a, 'index');
    if (noteId == null || noteId.isEmpty) {
      return ToolResult.failure('readChunk 需要 `noteId`。');
    }
    if (index == null) {
      return ToolResult.failure('readChunk 需要 `index`（片号，从 listChunks 拿）。');
    }
    if (_turnChunks >= maxChunksPerTurn) {
      return ToolResult.failure(
        '这一轮已经读过 $maxChunksPerTurn 片了，够用了。'
        '先用读到的内容回答；确实还需要更多再开新一轮。',
      );
    }

    final note = await _db.getNote(noteId);
    if (note == null) {
      return ToolResult.failure(
        '找不到笔记 `$noteId`（可能已被删除）。'
        '用 searchNotes 重新找一次，拿一个有效的 id。',
      );
    }
    final text = await _chunks.readChunk(noteId, note.content, index);
    if (text == null) {
      final total = (await _chunks.chunksFor(noteId, note.content)).length;
      return ToolResult.failure(
        '笔记 `$noteId` 没有第 $index 片（共 $total 片）。'
        '先用 listChunks 看目录。',
      );
    }
    if (_turnChars + text.length > maxChunkCharsPerTurn) {
      return ToolResult.failure(
        '这一轮读的正文会超过 $maxChunkCharsPerTurn 字上限'
        '（已读 $_turnChars 字，这一片还有 ${text.length} 字）。'
        '先用已有内容回答，或者只挑最相关的那一片。',
      );
    }

    _turnChunks++;
    _turnChars += text.length;
    // 记下「AI 读到的是哪个版本」。之后要改这条笔记时比对当前 hash：
    // 不一致说明用户在这期间手改过 —— 那是**粗筛**，精确定位靠 expectedText 锚点。
    _snapshot[noteId] = _hashOf(note.content);
    final chunks = await _chunks.chunksFor(noteId, note.content);
    return ToolResult.success({
      'noteId': noteId,
      'title': note.title,
      'index': index,
      if (index < chunks.length) 'heading': chunks[index].heading,
      'charCount': text.length,
      'text': text,
    });
  }

  Future<ToolResult> _listNotebooks() async {
    final all = await _db.allNotebooks();
    if (all.isEmpty) {
      return ToolResult.success({
        'count': 0,
        'notebooks': const [],
        'hint': '用户还没有建笔记库。可以建议他新建，或直接用「我的轻笔记」。',
      });
    }
    return ToolResult.success({
      'count': all.length,
      'notebooks': [
        for (final n in all)
          {
            'id': n.id,
            'name': n.name,
            'noteCount': await _db.notebookNoteCount(n.id),
          },
      ],
    });
  }

  Future<ToolResult> _listNotes(Map<String, Object?> a) async {
    final limit = (_int(a, 'limit') ?? 50).clamp(1, 100);
    final scope = _scope(_str(a, 'notebookId'));
    final briefs = await _db.noteBriefs(
      notebookIds: scope.notebookIds,
      includeUnfiled: scope.includeUnfiled,
      limit: limit,
    );
    if (briefs.isEmpty) {
      return ToolResult.success({
        'count': 0,
        'notes': const [],
        // 说清"为什么没有"：范围之外的东西模型看不到，它该换地方找或问用户，
        // 而不是反复用同一个库名重试
        'hint': workspace.isEmpty
            ? '当前会话没有设置工作区，看不到任何笔记。'
                '请让用户在 AI 页选择工作区（全体空间 / 挑选笔记库）。'
            : '这个范围里没有笔记。工作区之外的内容你看不到，'
                '需要的话请让用户调整工作区。',
      });
    }
    return ToolResult.success({
      'count': briefs.length,
      'notes': [
        for (final b in briefs)
          {
            'id': b.id,
            'title': b.title,
            'notebookId': b.notebookId,
            'modifiedAt': _stamp(b.updatedAt),
          },
      ],
      // 顺序本身就是信息：模型说"最近那篇"时靠的就是它，所以得说明白
      'order': '按修改时间倒序，最近改过的在最前',
      'hint': '这里只有元数据（没有正文）。看内容先 listChunks 再 readChunk；'
          '想知道某篇多大用 getNoteMeta。',
    });
  }

  /// 一条笔记的**元信息**，**不含正文**。
  ///
  /// 与 `listChunks` 的分工：这个是"这篇是什么、值不值得展开"，
  /// 那个是"该读哪一片"。两者都不带正文 —— 这是 token 经济的前提：
  /// 模型要先能**廉价地**判断，才不会一上来就把整篇灌进来。
  Future<ToolResult> _getNoteMeta(Map<String, Object?> a) async {
    final noteId = _str(a, 'noteId');
    if (noteId == null || noteId.isEmpty) {
      return ToolResult.failure('getNoteMeta 需要 `noteId`。');
    }
    final note = await _db.getNote(noteId);
    if (note == null) {
      return ToolResult.failure(
        '找不到笔记 `$noteId`（可能已被删除）。用 searchNotes 重新找。',
      );
    }
    // 片数走 `chunksFor` 而不是 `chunkCount`：前者会在"正文变了但没重切"时
    // 顺手修好切片，报出来的数字和 readChunk 真能读到的片**一定一致**。
    final chunks = await _chunks.chunksFor(noteId, note.content);
    final notebook = note.notebookId == null
        ? null
        : await _db.getNotebook(note.notebookId!);
    final summary = await _assets.getFreshSummary(noteId);

    return ToolResult.success({
      'noteId': note.id,
      'title': note.title,
      'notebookId': note.notebookId,
      'notebookName': notebook?.name ?? '我的轻笔记',
      'isInbox': note.isInbox,
      'createdAt': _stamp(note.createdAt),
      'modifiedAt': _stamp(note.updatedAt),
      'charCount': note.content.length,
      'chunkCount': chunks.length,
      'hasSummary': summary != null,
      // 摘要 ≤300 字，比正文便宜一个数量级，有就直接给 —— 但它是**旧版本**
      // 的概括（正文改多了会作废，作废了这里就是 false），所以标注清楚。
      if (summary != null) 'summary': summary,
      'hint': '这里没有正文。看目录用 listChunks(noteId)，'
          '看内容用 readChunk(noteId, index)。',
    });
  }

  ToolResult _listHistory(Map<String, Object?> a, List<AiMessage> history) {
    if (history.isEmpty) {
      return ToolResult.success({
        'count': 0,
        'chunks': const [],
        'hint': '本会话还没有更早的内容。',
      });
    }
    final limit = (_int(a, 'limit') ?? 20).clamp(1, 50);
    final rows = HistoryChunker.catalog(history, limit: limit);
    return ToolResult.success({
      'count': rows.length,
      'chunks': rows,
      'hint': '目录只有元数据。要看某一轮的正文用 readHistory(indexes: [...])，'
          '一轮最多 $maxChunksPerTurn 片。',
    });
  }

  ToolResult _readHistory(Map<String, Object?> a, List<AiMessage> history) {
    final raw = a['indexes'];
    if (raw is! List || raw.isEmpty) {
      return ToolResult.failure('readHistory 需要 `indexes`（片号数组，从 listHistory 拿）。');
    }
    final indexes = <int>[];
    for (final x in raw) {
      final v = _asInt(x);
      if (v != null) indexes.add(v);
    }
    if (indexes.isEmpty) {
      return ToolResult.failure('`indexes` 里没有有效的片号。');
    }
    if (history.isEmpty) {
      return ToolResult.success({
        'count': 0,
        'chunks': const [],
        'hint': '本会话还没有更早的内容。',
      });
    }

    final pieces = HistoryChunker.slice(
      history,
      indexes: indexes,
      maxPieces: maxChunksPerTurn,
      maxChars: maxChunkCharsPerTurn,
    );
    if (pieces.isEmpty) {
      return ToolResult.failure(
        '这些片号在本会话里不存在（共 ${HistoryChunker.chunk(history).length} 片）。'
        '先用 listHistory 看目录。',
      );
    }
    return ToolResult.success({
      'count': pieces.length,
      'chunks': [
        for (final p in pieces) {'index': p.index, 'text': p.text},
      ],
    });
  }

  /// 在本会话历史里按关键词搜 —— `searchNotes` 的**会话版**。
  ///
  /// 两个设计都照抄 `searchNotes`，因为它们解决的是同一个问题：
  ///
  /// 1. **只给片号 + 片段，不给全文**。命中一片就说清"是这几句"，
  ///    要正文再 `readHistory(indexes: [...])` —— 一次搜索不该顺手灌进 700 字。
  /// 2. **片号来自同一个 [HistoryChunker]**，所以这里的 `index`
  ///    和 `listHistory` / `readHistory` 用的是**同一套编号**，
  ///    模型拿到就能直接用，不需要做任何换算。
  ///
  /// 排序与 `searchNotes` 相反：那里按 `updatedAt` 倒序，这里**从最新的一片
  /// 往前找**（所以结果也是最新的在前）。"我们之前是不是聊过 X" 问的几乎
  /// 总是最近那次，先命中就先省一次往返。
  ToolResult _searchHistory(Map<String, Object?> a, List<AiMessage> history) {
    final query = (_str(a, 'query') ?? '').trim();
    if (query.isEmpty) {
      return ToolResult.failure('searchHistory 需要 `query`（关键词）。');
    }
    if (history.isEmpty) {
      return ToolResult.success({
        'count': 0,
        'results': const [],
        'hint': '本会话还没有更早的内容。',
      });
    }
    final limit = (_int(a, 'limit') ?? 5).clamp(1, 20);

    final all = HistoryChunker.chunk(history);
    final hits = <Map<String, Object?>>[];
    // 大小写：`searchNotes` 走 SQLite 的 LIKE，英文是不区分大小写的。
    // 这里要**对齐那个手感**，否则搜 "SM-2" 找不到 "sm-2"。
    // toLowerCase 极少数情况下会改变长度，长度变了就退回精确匹配，不硬凑偏移。
    final lower = query.toLowerCase();
    for (final c in all.reversed) {
      if (hits.length >= limit) break;
      var at = c.text.indexOf(query);
      if (at < 0 && lower != query) {
        final hay = c.text.toLowerCase();
        if (hay.length == c.text.length) at = hay.indexOf(lower);
      }
      if (at < 0) continue;
      hits.add({
        'index': c.index,
        'at': _stamp(c.at),
        'roles': c.roles,
        'userSnippet': c.userSnippet,
        'charCount': c.charCount,
        'snippet': _snippetAround(c.text, at, query.length),
      });
    }

    if (hits.isEmpty) {
      return ToolResult.success({
        'count': 0,
        'results': const [],
        'hint': '本会话更早的内容里没有「$query」。'
            '换个说法再搜（少几个字、只留关键词），或者用 listHistory 看目录。',
      });
    }
    return ToolResult.success({
      'count': hits.length,
      'results': hits,
      'hint': '要看命中那一片的正文用 readHistory(indexes: [片号])，'
          '一轮最多 $maxChunksPerTurn 片。片号与 listHistory 同一套。',
    });
  }

  // ==========================================================================
  // 创建类
  // ==========================================================================

  Future<ToolResult> _createNote(Map<String, Object?> a) async {
    final title = (_str(a, 'title') ?? '').trim();
    final content = _str(a, 'content');
    if (content == null) {
      return ToolResult.failure('createNote 需要 `content`（正文）。');
    }
    final notebookId = _str(a, 'notebookId');
    if (notebookId != null && await _db.getNotebook(notebookId) == null) {
      return ToolResult.failure(
        '找不到笔记库 `$notebookId`。用 listNotebooks 看看有哪些。',
      );
    }

    final (ok, denied) = await _ask(
      toolByName('createNote')!,
      ToolConfirmRequest(
        risk: ToolRisk.create,
        toolName: 'createNote',
        title: '新建笔记',
        summary: '新建笔记《${title.isEmpty ? '无标题' : title}》'
            '（${content.length} 字）',
        after: content,
      ),
    );
    if (!ok) return denied!;

    final note = notebookId == null
        ? await NoteRepository(_db).createInbox(title: title, content: content)
        : await NoteRepository(_db)
            .createInNotebook(notebookId, title: title, content: content);
    await _chunks.rebuild(note.id, content);

    return ToolResult.success({
      'noteId': note.id,
      'title': note.title,
      'charCount': content.length,
    });
  }

  Future<ToolResult> _createNotebook(Map<String, Object?> a) async {
    final name = (_str(a, 'name') ?? '').trim();
    if (name.isEmpty) {
      return ToolResult.failure('createNotebook 需要 `name`（笔记库名字）。');
    }

    final (ok, denied) = await _ask(
      toolByName('createNotebook')!,
      ToolConfirmRequest(
        risk: ToolRisk.create,
        toolName: 'createNotebook',
        title: '新建笔记库',
        summary: '新建笔记库「$name」',
      ),
    );
    if (!ok) return denied!;

    final nb = await NotebookRepository(_db).create(name: name);
    return ToolResult.success({'notebookId': nb.id, 'name': nb.name});
  }

  // ==========================================================================
  // 修改类
  // ==========================================================================

  /// 在笔记**末尾追加**一段内容。
  ///
  /// ## 为什么单独给一个工具，而不是让模型用 `updateNote` 拼全文
  ///
  /// "把这段加到末尾"用 `updateNote` 要这么干：先 `readChunk` 读出全文
  /// （几千字进上下文），再把「原文 + 新内容」整体写回去。中间任何一次抄漏
  /// 都会**静默丢掉内容** —— 而它看起来完全像成功。
  ///
  /// 追加不需要读全文：拼接由 App 在本地做，模型只出"加什么"。
  /// 于是这个工具的输入长度和"要加的东西"成正比，而不是和整篇成正比。
  ///
  /// ## 仍然走确认层
  ///
  /// 它改了用户的数据，所以和 `updateNote` 一样弹「改前 / 改后」+ 可撤销。
  /// 不能因为"只是追加、不删东西"就免确认 —— 那等于开了一个
  /// 不需要点头的写入通道，模型可以反复往里灌内容。
  Future<ToolResult> _appendToNote(Map<String, Object?> a) async {
    final noteId = _str(a, 'noteId');
    final text = _str(a, 'text');
    if (noteId == null || noteId.isEmpty) {
      return ToolResult.failure('appendToNote 需要 `noteId`。');
    }
    if (text == null || text.trim().isEmpty) {
      return ToolResult.failure(
        'appendToNote 需要 `text`（要追加的内容），空内容没什么可加的。',
      );
    }

    final note = await _db.getNote(noteId);
    if (note == null) {
      return ToolResult.failure(
        '找不到笔记 `$noteId`（可能已被删除）。用 searchNotes 重新找。',
      );
    }

    // 空行分隔：直接接在最后一行后面会和原文黏成一段（Markdown 里尤其明显）。
    // 正文本来就是空的（新建还没写）时不加分隔，否则笔记会以空行开头。
    //
    // 追加内容首尾的空白会被去掉：写进用户笔记里的东西不该带着一串空行，
    // 下面报出的 `appendedChars` 用的是**同一份** trim 后的文本，不会自相矛盾。
    final body = note.content;
    final next = body.trim().isEmpty
        ? text.trim()
        : '${body.trimRight()}\n\n${text.trim()}';

    // 追加**不要求**先读过这篇，所以这里不是"必须拦"的粗筛，
    // 只是"如果它确实读过、而读完之后用户又改过"就提醒一句。
    final seen = _snapshot[noteId];
    final changedSinceRead = seen != null && seen != _hashOf(body);

    final (ok, denied) = await _ask(
      toolByName('appendToNote')!,
      ToolConfirmRequest(
        risk: ToolRisk.modify,
        toolName: 'appendToNote',
        title: '追加内容',
        summary: '在《${note.title.trim().isEmpty ? '无标题' : note.title}》'
            '末尾追加 ${text.trim().length} 字：「${_clip(text)}」',
        before: body,
        after: next,
        warning: changedSinceRead
            ? '这条笔记在你读到它之后被改过，确认一下追加的位置对不对。'
            : null,
      ),
    );
    if (!ok) return denied!;

    _rememberUndo(note);
    await _writeNote(note, title: note.title, content: next);

    return ToolResult.success({
      'noteId': note.id,
      'charCount': next.length,
      'appendedChars': text.trim().length,
      'undoAvailable': true,
    });
  }

  /// 改笔记的某一段。
  ///
  /// ## 为什么用锚点而不是"第几段"
  ///
  /// AI 读到"第 3 段"之后，用户往前面插了一段 —— 再按 index 3 改就**改错地方**，
  /// 而且改得毫无声息。`expectedText` 校验的是"要改的那段原文还在不在"，
  /// 不在就返回错误让 AI 重新定位。见《AI接入设计》的「参数锚点」一节。
  Future<ToolResult> _updateNote(Map<String, Object?> a) async {
    final noteId = _str(a, 'noteId');
    if (noteId == null) return ToolResult.failure('updateNote 需要 `noteId`。');
    final newContent = _str(a, 'newContent');
    final newTitle = _str(a, 'title');
    final expected = a['expectedText'] is String ? a['expectedText'] as String : null;

    if (newContent == null && newTitle == null) {
      return ToolResult.failure('updateNote 至少要有 `newContent` 或 `title` 之一。');
    }

    final note = await _db.getNote(noteId);
    if (note == null) {
      return ToolResult.failure(
        '找不到笔记 `$noteId`（可能已被删除）。用 searchNotes 重新找。',
      );
    }

    // ---- ① 锚点校验：**必须**通过，否则宁可失败也不写到别处 ----
    var nextBody = note.content;
    if (newContent != null) {
      if (expected == null || expected.isEmpty) {
        return ToolResult.failure(
          'updateNote 改正文时必须给 `expectedText`（要替换掉的那段原文）。'
          '先用 readChunk 读出来，把原文一字不差地放进来。',
        );
      }
      final at = note.content.indexOf(expected);
      if (at < 0) {
        return ToolResult.failure(
          '**锚点失效**：`expectedText` 已经不在正文里了（用户可能刚改过）。'
          '重新 readChunk 一次，用新的原文再试。',
        );
      }
      nextBody = note.content.replaceRange(at, at + expected.length, newContent);
    }

    // ---- ② 快照粗筛：读过之后被改过就提醒（不拦，交给用户判断）----
    final seen = _snapshot[noteId];
    final changedSinceRead = seen != null && seen != _hashOf(note.content);

    // ---- ③ 确认层：改前 vs 改后 ----
    final (ok, denied) = await _ask(
      toolByName('updateNote')!,
      ToolConfirmRequest(
        risk: ToolRisk.modify,
        toolName: 'updateNote',
        title: '修改笔记',
        summary: expected == null
            ? '改标题：《${note.title}》→《${newTitle!}》'
            : '把「${_clip(expected)}」改成「${_clip(newContent!)}」',
        before: note.content,
        after: nextBody,
        warning: changedSinceRead
            ? '这条笔记在你读到它之后被改过，确认一下是不是还改这里。'
            : null,
      ),
    );
    if (!ok) return denied!;

    _rememberUndo(note);
    await _writeNote(note, title: newTitle ?? note.title, content: nextBody);

    return ToolResult.success({
      'noteId': note.id,
      'charCount': nextBody.length,
      'undoAvailable': true,
    });
  }

  /// 纯字符串替换（**全部**替换）。
  ///
  /// 与 `updateNote` 一样走 App 确认 —— 不是"App 绕过 AI 直接改"。
  /// 这样确认、撤销、审计不用各多一套分支（《AI接入设计》的「参数锚点」一节里的定案）。
  Future<ToolResult> _replaceInNote(Map<String, Object?> a) async {
    final noteId = _str(a, 'noteId');
    final find = _str(a, 'find');
    final replace = a['replace'] is String ? a['replace'] as String : '';
    if (noteId == null) return ToolResult.failure('replaceInNote 需要 `noteId`。');
    if (find == null) return ToolResult.failure('replaceInNote 需要 `find`（要找的字符串）。');
    if (find == replace) {
      return ToolResult.failure('`find` 与 `replace` 一样，替换没有意义。');
    }

    final note = await _db.getNote(noteId);
    if (note == null) {
      return ToolResult.failure('找不到笔记 `$noteId`（可能已被删除）。');
    }
    final count = find.allMatches(note.content).length;
    if (count == 0) {
      return ToolResult.failure(
        '正文里找不到「${_clip(find)}」，没有做任何修改。'
        '先用 readChunk 确认原文。',
      );
    }

    final next = note.content.replaceAll(find, replace);
    final (ok, denied) = await _ask(
      toolByName('replaceInNote')!,
      ToolConfirmRequest(
        risk: ToolRisk.modify,
        toolName: 'replaceInNote',
        title: '替换文字',
        summary: '把「${_clip(find)}」全部换成「${_clip(replace)}」（共 $count 处）',
        before: note.content,
        after: next,
      ),
    );
    if (!ok) return denied!;

    _rememberUndo(note);
    await _writeNote(note, title: note.title, content: next);

    return ToolResult.success({
      'noteId': note.id,
      'replaced': count,
      'undoAvailable': true,
    });
  }

  Future<ToolResult> _moveNote(Map<String, Object?> a) async {
    final noteId = _str(a, 'noteId');
    if (noteId == null) return ToolResult.failure('moveNote 需要 `noteId`。');
    // `notebookId` 为空 = 移回「我的轻笔记」（协议里用 null/空串都能表达）
    final notebookId = _str(a, 'notebookId');
    final target = notebookId == null
        ? null
        : await _db.getNotebook(notebookId);
    if (notebookId != null && target == null) {
      return ToolResult.failure('找不到笔记库 `$notebookId`。用 listNotebooks 看看。');
    }

    final note = await _db.getNote(noteId);
    if (note == null) {
      return ToolResult.failure('找不到笔记 `$noteId`（可能已被删除）。');
    }

    final (ok, denied) = await _ask(
      toolByName('moveNote')!,
      ToolConfirmRequest(
        risk: ToolRisk.modify,
        toolName: 'moveNote',
        title: '移动笔记',
        summary: '把《${note.title.trim().isEmpty ? '无标题' : note.title}》'
            '移到「${target?.name ?? '我的轻笔记'}」',
      ),
    );
    if (!ok) return denied!;

    if (target == null) {
      await _db.moveNoteToNotebook(noteId, null);
    } else {
      await _db.moveNoteToNotebook(noteId, target.id);
    }
    return ToolResult.success({
      'noteId': noteId,
      'notebookId': target?.id,
      'notebookName': target?.name ?? '我的轻笔记',
    });
  }

  Future<ToolResult> _renameNotebook(Map<String, Object?> a) async {
    final id = _str(a, 'notebookId');
    final name = (_str(a, 'name') ?? '').trim();
    if (id == null) return ToolResult.failure('renameNotebook 需要 `notebookId`。');
    if (name.isEmpty) return ToolResult.failure('renameNotebook 需要 `name`。');

    final nb = await _db.getNotebook(id);
    if (nb == null) return ToolResult.failure('找不到笔记库 `$id`。');

    final (ok, denied) = await _ask(
      toolByName('renameNotebook')!,
      ToolConfirmRequest(
        risk: ToolRisk.modify,
        toolName: 'renameNotebook',
        title: '重命名笔记库',
        summary: '「${nb.name}」→「$name」',
      ),
    );
    if (!ok) return denied!;

    await NotebookRepository(_db).rename(id, name);
    return ToolResult.success({'notebookId': id, 'name': name});
  }

  Future<ToolResult> _batchMoveNotes(Map<String, Object?> a) async {
    final raw = a['noteIds'];
    if (raw is! List || raw.isEmpty) {
      return ToolResult.failure('batchMoveNotes 需要 `noteIds`（笔记 id 数组）。');
    }
    if (raw.length > maxBatch) {
      return ToolResult.failure('一次最多移动 $maxBatch 条（收到 ${raw.length} 条）。');
    }
    final ids = [for (final x in raw) '$x'];
    final notebookId = _str(a, 'notebookId');
    final target = notebookId == null ? null : await _db.getNotebook(notebookId);
    if (notebookId != null && target == null) {
      return ToolResult.failure('找不到笔记库 `$notebookId`。');
    }

    final (ok, denied) = await _ask(
      toolByName('batchMoveNotes')!,
      ToolConfirmRequest(
        risk: ToolRisk.modify,
        toolName: 'batchMoveNotes',
        title: '批量移动',
        summary: '把 ${ids.length} 条笔记移到「${target?.name ?? '我的轻笔记'}」',
      ),
    );
    if (!ok) return denied!;

    final moved = await NoteRepository(_db).moveManyToNotebook(ids, target?.id);
    return ToolResult.success({'moved': moved, 'notebookId': target?.id});
  }

  /// 一句话摘要用（确认层里显示，太长会撑爆弹层）
  static String _clip(String s, {int max = 40}) {
    final flat = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length > max ? '${flat.substring(0, max)}…' : flat;
  }

  /// 时间戳（本地时间）。**只到分钟**：模型要知道的是"几天前的"，
  /// 秒和时区对它没用，写全了只是多占 token。
  ///
  /// 与 `HistoryChunker` 目录里的格式**保持一致** —— 两处都在回灌给模型，
  /// 格式不同会让人以为它们不是一回事。
  static String _stamp(DateTime utc) {
    final l = utc.toLocal();
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${p2(l.month)}-${p2(l.day)} ${p2(l.hour)}:${p2(l.minute)}';
  }

  /// 命中位置前后各取一点，拼成单行片段（搜索结果显示用）。
  ///
  /// 换行全部压成空格：片段是要**塞进 JSON 的一行**，
  /// 里面带 `\n` 只会让模型更难看出命中在哪。
  static String _snippetAround(String text, int at, int len,
      {int before = 30, int after = 60}) {
    final from = at - before < 0 ? 0 : at - before;
    final to = at + len + after > text.length ? text.length : at + len + after;
    final flat = text.substring(from, to).replaceAll(RegExp(r'\s+'), ' ').trim();
    return '${from > 0 ? '…' : ''}$flat${to < text.length ? '…' : ''}';
  }

  // ==========================================================================
  // 删除类
  //
  // ## 没有回收站
  // 定案见《AI接入设计》的「确认流程：风险拦截在 App」：
  // `deleteNote` 授权确认后**直接删**，不提供 `restoreNote`。
  // 内部实现仍然是**软删除**（`deletedAt` 置位、行还在）——那是为了防 bug、
  // 留后路，而不是给用户一个回收站入口。
  //
  // ## 为什么删笔记要连切片一起清
  // 外键虽然带 `ON DELETE CASCADE`，但软删**不会触发**级联。留着片的话，
  // 搜索会把"命中哪一片"算到已删的笔记头上，用户点进去发现笔记没了。
  // ==========================================================================

  Future<ToolResult> _deleteNote(Map<String, Object?> a) async {
    final noteId = _str(a, 'noteId');
    if (noteId == null) return ToolResult.failure('deleteNote 需要 `noteId`。');

    final note = await _db.getNote(noteId);
    // 已经删掉的：当成成功。**重复点击「允许」只执行一次**就靠这一条 ——
    // 第二次找不到笔记（`deletedAt` 已置位），不会二次删除、也不会报错吓人。
    if (note == null || note.deletedAt != null) {
      return ToolResult.success({'noteId': noteId, 'alreadyDeleted': true});
    }

    final title = note.title.trim().isEmpty ? '无标题' : note.title.trim();
    final (ok, denied) = await _ask(
      toolByName('deleteNote')!,
      ToolConfirmRequest(
        risk: ToolRisk.delete,
        toolName: 'deleteNote',
        title: '删除笔记',
        // 措辞必须写明后果：用户点「允许」时要清楚这是不可逆的
        summary: '删除《$title》。**删了就找不回来**（没有回收站）。',
        before: note.content,
      ),
    );
    if (!ok) return denied!;

    await _db.softDeleteNote(noteId);
    await _chunks.clearFor(noteId);
    return ToolResult.success({'noteId': noteId, 'title': title});
  }

  Future<ToolResult> _deleteNotebook(Map<String, Object?> a) async {
    final id = _str(a, 'notebookId');
    if (id == null) return ToolResult.failure('deleteNotebook 需要 `notebookId`。');

    final nb = await _db.getNotebook(id);
    // ⚠️ `getNotebook` **不筛软删**（返回的行 `deletedAt` 已置位）——
    // 只看 `nb == null` 会漏掉"已经删过一次"的情况，于是重复点击会再删一遍。
    if (nb == null || nb.deletedAt != null) {
      return ToolResult.success({'notebookId': id, 'alreadyDeleted': true});
    }
    final count = await _db.notebookNoteCount(id);

    final (ok, denied) = await _ask(
      toolByName('deleteNotebook')!,
      ToolConfirmRequest(
        risk: ToolRisk.delete,
        toolName: 'deleteNotebook',
        title: '删除笔记库',
        // 说清"里面的笔记不会删"—— 不说的话用户会以为笔记也没了，不敢点
        summary: '删除笔记库「${nb.name}」。'
            '里面的 $count 条笔记**不会删**，会退回「我的轻笔记」。',
      ),
    );
    if (!ok) return denied!;

    await NotebookRepository(_db).softDelete(id);
    return ToolResult.success({
      'notebookId': id,
      'name': nb.name,
      'notesKept': count,
    });
  }

  Future<ToolResult> _batchDeleteNotes(Map<String, Object?> a) async {
    final raw = a['noteIds'];
    if (raw is! List || raw.isEmpty) {
      return ToolResult.failure('batchDeleteNotes 需要 `noteIds`（笔记 id 数组）。');
    }
    if (raw.length > maxBatch) {
      return ToolResult.failure(
        '一次最多删 $maxBatch 条（收到 ${raw.length} 条）。'
        '分几次来，或者先问用户要不要缩小范围。',
      );
    }
    final ids = [for (final x in raw) '$x'];

    // 只列真正还活着的，已删的跳过（重复点击也不会二次删）
    final alive = <Note>[];
    for (final id in ids) {
      final n = await _db.getNote(id);
      if (n != null && n.deletedAt == null) alive.add(n);
    }
    if (alive.isEmpty) {
      return ToolResult.success({'deleted': 0, 'alreadyDeleted': true});
    }

    final (ok, denied) = await _ask(
      toolByName('batchDeleteNotes')!,
      ToolConfirmRequest(
        risk: ToolRisk.delete,
        toolName: 'batchDeleteNotes',
        title: '批量删除',
        summary: '删除 ${alive.length} 条笔记'
            '（${alive.take(3).map((n) => '《${n.title.trim().isEmpty ? '无标题' : n.title.trim()}》').join('、')}'
            '${alive.length > 3 ? ' 等' : ''}）。**删了就找不回来**。',
      ),
    );
    if (!ok) return denied!;

    await NoteRepository(_db).softDeleteMany(alive.map((n) => n.id));
    return ToolResult.success({'deleted': alive.length});
  }

  // ==========================================================================
  // 参数读取
  //  // 模型的参数是 JSON，类型不一定对（该给整数给了字符串、该给数组给了单值）。
  // 一律**宽松接受、失败给可读原因**：报"参数类型不对"比报
  // "NoSuchMethodError" 有用得多。
  // ==========================================================================

  static String? _str(Map<String, Object?> a, String key) {
    final v = a[key];
    if (v == null) return null;
    final s = v is String ? v : v.toString();
    return s.trim().isEmpty ? null : s.trim();
  }

  static int? _asInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  static int? _int(Map<String, Object?> a, String key) => _asInt(a[key]);

  /// 把一个工具结果编码成回灌给模型的字符串（`role: tool` 的 content）。
  static String encodeResult(ToolResult r) => r.encode();

  /// 把模型给的 `arguments`（JSON 字符串）解析成 map。
  ///
  /// 解析不出来时返回空 map —— 后面的参数校验会给出"缺 query"这种
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
