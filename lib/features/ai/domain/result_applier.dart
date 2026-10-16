import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/db/app_database.dart';
import '../../../core/util/app_params.dart';

/// **A 类任务的产出落库器**：把模型回答末尾那段 json 代码块变成真的笔记。
///
/// ## 为什么要有它
///
/// 让模型把正文塞进 SQL 参数（`create_notes_batch('[{...}]')`）有两个硬伤：
///   · 单条 SQL 有 2 万字符上限 → 多篇长笔记直接写不进去；
///   · 正文要先转义成 JSON 再套进 SQL 单引号里，引号一错整句报错。
///
/// 所以 A 类（整理 / 生成）改成：**模型只负责写内容，App 负责落库**。
/// 回答末尾附一个 json 代码块，这里解析 → 校验 → 逐条落库。
///
/// ## 三条设计原则
///
/// 1. **逐条落库，不是整批**：每条单独调一次 UDF，于是某一条失败**不影响其他条**，
///    而且失败原因天然带着"是哪一条"。用户看到的是"3 篇成了、1 篇没成"，
///    而不是"整批回滚、什么都没发生"。
/// 2. **失败要说清、并给修的机会**：把失败项 + 原因 + **已落库的 id** 交回去
///    （见 [repairMessage]），模型只需修没成的那几项 —— 已落库的不能再建一遍。
/// 3. **校验这一层只做"UDF 之前"的事**：正文大小、锚点唯一这些**最终**判据仍在 UDF 里
///    （那是唯一真相），这里只做能让错误信息更早、更准的那部分。
class AiResultApplier {
  AiResultApplier(this._db);

  final AppDatabase _db;

  /// 解析回答末尾的 json 代码块并逐条落库。
  ///
  /// [answer] 是模型这一轮的完整回答。没有 json 代码块 / 块里空 → 返回"什么都没做"
  /// （B 类问答就是这种情况，不该报错）。
  Future<AppliedResult> apply(String answer) async {
    final payload = extractPayload(answer);
    if (payload == null) return const AppliedResult(hadPayload: false);

    final created = <String>[];
    final updated = <String>[];
    final deleted = <String>[];
    final failed = <Map<String, Object?>>[];

    // ---- 新建 ----
    final notes = payload['notes'];
    if (notes is List) {
      for (var i = 0; i < notes.length; i++) {
        final e = notes[i];
        if (e is! Map) {
          failed.add({'kind': 'note', 'index': i, 'reason': '不是对象'});
          continue;
        }
        final title = (e['title'] ?? '').toString();
        final content = (e['content'] ?? '').toString();
        final raw = e['notebook_id'];
        final notebookId =
            raw == null || raw.toString().trim().isEmpty ? null : raw.toString();

        if (content.trim().isEmpty) {
          failed.add({'kind': 'note', 'index': i, 'title': title, 'reason': '正文为空'});
          continue;
        }
        if (AiLimits.byteLength(content) > AiLimits.noteHardBytes) {
          failed.add({
            'kind': 'note',
            'index': i,
            'title': title,
            'reason': '正文 ${AiLimits.byteLength(content) ~/ 1024}KB '
                '超过 ${AiLimits.noteHardBytes ~/ 1024}KB 上限',
          });
          continue;
        }

        final one = jsonEncode([
          {
            'title': safeTitle(title),
            'content': content,
            if (notebookId != null) 'notebook_id': notebookId,
          }
        ]);
        final r = await _call('create_notes_batch', one);
        if (r.ok) {
          created.addAll(_stringIds((r.data as Map?)?['note_ids']));
        } else {
          failed.add(
              {'kind': 'note', 'index': i, 'title': title, 'reason': r.error});
        }
      }
    }

    // ---- 改正文 ----
    final updates = payload['updates'];
    if (updates is List) {
      for (var i = 0; i < updates.length; i++) {
        final e = updates[i];
        if (e is! Map) {
          failed.add({'kind': 'update', 'index': i, 'reason': '不是对象'});
          continue;
        }
        final id = (e['id'] ?? '').toString().trim();
        final old = (e['old'] ?? '').toString();
        final neu = (e['new'] ?? '').toString();
        if (id.isEmpty || old.isEmpty) {
          failed.add({
            'kind': 'update',
            'index': i,
            'reason': '缺 id 或缺 old（old 是要被替换的那段原文）',
          });
          continue;
        }
        final one = jsonEncode([
          {'id': id, 'old': old, 'new': neu}
        ]);
        final r = await _call('update_notes_batch', one);
        if (r.ok) {
          updated.add(id);
        } else {
          failed.add({'kind': 'update', 'index': i, 'id': id, 'reason': r.error});
        }
      }
    }

    // ---- 删 ----
    final deletes = payload['deletes'];
    if (deletes is List) {
      for (final e in deletes) {
        final id = e.toString().trim();
        if (id.isEmpty) continue;
        final r = await _call('delete_notes_batch', jsonEncode([id]));
        if (r.ok) {
          deleted.add(id);
        } else {
          failed.add({'kind': 'delete', 'id': id, 'reason': r.error});
        }
      }
    }

    if (created.isNotEmpty || updated.isNotEmpty || deleted.isNotEmpty) {
      _db.notifyUpdates({
        const TableUpdate('notes'),
        const TableUpdate('notebooks'),
        const TableUpdate('note_chunks'),
      });
    }

    return AppliedResult(
      hadPayload: true,
      createdIds: created,
      updatedIds: updated,
      deletedIds: deleted,
      failed: failed,
    );
  }

  /// 从展示文本里**去掉产出块**（json 代码块是管道，不该让用户读到它）。
  static String stripPayload(String answer) {
    // 与 extractPayload 同一套正则（**要带捕获组**，下面用 group(1) 解析内容）
    final fences =
        RegExp(r'```(?:json)?\s*([\s\S]*?)```').allMatches(answer).toList();
    for (final m in fences.reversed) {
      final obj = _tryObject(m.group(1)!);
      if (obj != null && _looksLikePayload(obj)) {
        return '${answer.substring(0, m.start).trimRight()}\n'
            '${answer.substring(m.end).trimLeft()}'
            .trim();
      }
    }
    return answer.trim();
  }

  /// **流式显示用**：把**还没写完**的产出块也切掉。
  ///
  /// ## 为什么非要有这一个（这是个真实 bug）
  ///
  /// 产出块里装的是**整篇笔记正文**。而流式那条路是"每个分片都把累计文本重写
  /// 一遍"，[stripPayload] 却只在**整轮跑完**时才生效 —— 中间那十几秒里，用户
  /// 就看着一大坨原始 JSON（含笔记全文）在对话气泡里滚出来。写笔记的时候把笔记
  /// 正文渲染进对话，这是不能接受的。
  ///
  /// [stripPayload] 干不了这件事：它要求围栏**已经闭合**（` ```…``` `）。这里
  /// 要的恰恰是相反的 —— 一个**没写完**的块也要立刻从显示里拿掉：
  ///
  /// ```
  /// 我已经整理好了：      →   我已经整理好了：
  /// ```json                    （下面这些一律不显示）
  /// {"notes": [{"title"…
  /// ```
  ///
  /// ## 认三种起始形态（都取**最早**出现的那处）
  ///
  /// | | 形态 | 为什么要认 |
  /// |---|---|---|
  /// | 1 | ` ```json `（闭合与否都算） | 正常情况 |
  /// | 2 | **正在长出来**的围栏：`` ` ``/```` `` ````/```` ``` ````/` ```j `/` ```js `/` ```json ` | 分片是逐字到的，`json` 后到 |
  /// | 3 | 没围栏、直接 `{"notes"`（或 updates / deletes）开头的载荷 | 模型偶尔省略围栏 |
  ///
  /// 形态 2 **只认 `j` 打头的**（不认光秃秃的三反引号）：否则一段正常的代码块
  /// 写到结尾时会被当成"正在长出来的产出块"切掉。
  /// 代价是产出块到来时会有三个字符的反引号闪一下（约几十毫秒），可以接受。
  ///
  /// 形态 3 会连带吃掉**它上一行那个光秃秃的围栏**（` ``` ` 后面直接跟对象的那种
  /// 写法，[extractPayload] 也认）。
  static String stripForStreaming(String partial) {
    final at = _payloadStart(partial);
    return at == null ? partial : partial.substring(0, at).trimRight();
  }

  /// 产出块在 [text] 里的起始下标（没有就返回 null）。取所有形态里**最早**的。
  static int? _payloadStart(String text) {
    final starts = <int>[];

    // 形态 1：```json（可能还没闭合）
    for (final m in RegExp(r'(?:^|\n)[ \t]*```[ \t]*json',
            caseSensitive: false, multiLine: true)
        .allMatches(text)) {
      starts.add(m.start);
    }

    // 形态 2：结尾正在长出来的围栏（**必须一直延伸到文本结尾**，
    // 否则会把"代码块写在中间、后面还有正文"那种正常内容切掉）
    for (final m in RegExp(r'(?:^|\n)[ \t]*`{1,3}[ \t]*j(?:s(?:o(?:n)?)?)?[ \t]*$',
            caseSensitive: false, multiLine: true)
        .allMatches(text)) {
      if (text.substring(m.end).trim().isEmpty) starts.add(m.start);
    }

    // 形态 3：行首直接是载荷对象（{"notes" / {"updates" / {"deletes"）
    for (final m in RegExp(
            r'(?:^|\n)[ \t]*\{[ \t]*"(?:notes|updates|deletes)"',
            caseSensitive: false,
            multiLine: true)
        .allMatches(text)) {
      starts.add(m.start);
      // 它上一行如果是"光秃秃的围栏"，一起吃掉
      final before = text.substring(0, m.start);
      final fence = RegExp(r'(?:^|\n)[ \t]*```[ \t]*(?:json)?[ \t]*$',
              caseSensitive: false, multiLine: true)
          .firstMatch(before);
      if (fence != null && before.substring(fence.end).trim().isEmpty) {
        starts.add(fence.start);
      }
    }

    if (starts.isEmpty) return null;
    starts.sort();
    return starts.first;
  }

  /// 从回答里抽 json 产出块。**只认最后一段** ```json 围栏。
  ///
  /// 为什么要"最后一段"：模型常先写解释、再给产出；也可能中途贴一小段示意 JSON。
  /// 真正要落库的是**最后**那个完整块。
  /// 兼容三种写法：```json 围栏、``` 裸围栏（内容是对象）、以及末尾直接跟一个 `{...}`。
  static Map<String, Object?>? extractPayload(String answer) {
    // 1) 所有围栏块，从后往前找第一个能解析成对象的
    final fences = RegExp(r'```(?:json)?\s*([\s\S]*?)```').allMatches(answer).toList();
    for (final m in fences.reversed) {
      final obj = _tryObject(m.group(1)!);
      if (obj != null && _looksLikePayload(obj)) return obj;
    }
    // 2) 末尾直接跟一个对象（没有围栏）
    final obj = _lastObject(answer);
    if (obj != null && _looksLikePayload(obj)) return obj;
    return null;
  }

  /// 至少得认得一个键，否则不当作产出块 ——
  /// 免得把模型随手贴的一段无关 JSON（比如举例说明）当成落库指令。
  static bool _looksLikePayload(Map<String, Object?> m) =>
      m.containsKey('notes') || m.containsKey('updates') || m.containsKey('deletes');

  static Map<String, Object?>? _tryObject(String raw) {
    try {
      final v = jsonDecode(raw.trim());
      if (v is Map) return v.cast<String, Object?>();
    } catch (_) {}
    return null;
  }

  /// 用括号配对找**最后一个**完整对象（字符串与转义都要跳过）。
  static Map<String, Object?>? _lastObject(String text) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    var start = -1;
    Map<String, Object?>? found;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == r'\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
      } else if (ch == '{') {
        if (depth == 0) start = i;
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0 && start >= 0) {
          found = _tryObject(text.substring(start, i + 1)) ?? found;
          start = -1;
        }
      }
    }
    return found;
  }

  static List<String> _stringIds(Object? raw) {
    if (raw is! List) return const [];
    return [for (final e in raw) e.toString()];
  }

  /// 标题的兜底：模型给的标题超长就截断（与 UDF 用同一个上限）。
  static String safeTitle(String title) {
    final t = title.trim();
    if (t.isEmpty) return '未命名';
    return t.length <= AiLimits.titleHardMax
        ? t
        : t.substring(0, AiLimits.titleHardMax);
  }

  /// 调一次写函数（UDF），把它的返回值解成 ok/error/data。
  Future<({bool ok, String? error, Object? data})> _call(
    String fn,
    String jsonArg,
  ) async {
    final rows = await _db
        .customSelect('SELECT $fn(?) AS r', variables: [Variable<String>(jsonArg)])
        .get();
    final raw = rows.first.data['r'];
    if (raw is! String) return (ok: false, error: '函数没有返回结果', data: null);
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return (ok: false, error: '返回值形状不对', data: null);
      final ok = m['ok'] == true;
      return (
        ok: ok,
        error: ok ? null : (m['error']?.toString() ?? '未知错误'),
        data: m['data'],
      );
    } catch (e) {
      return (ok: false, error: '返回值解析失败：$e', data: null);
    }
  }
}

/// 一次落库的结果。
class AppliedResult {
  const AppliedResult({
    this.hadPayload = false,
    this.createdIds = const [],
    this.updatedIds = const [],
    this.deletedIds = const [],
    this.failed = const [],
  });

  /// 回答里**有没有** json 产出块。没有 → B 类问答，什么都没做（不是错误）。
  final bool hadPayload;
  final List<String> createdIds;
  final List<String> updatedIds;
  final List<String> deletedIds;

  /// 没落成的项：`{kind, index?, id?, title?, reason}`。
  final List<Map<String, Object?>> failed;

  int get doneCount =>
      createdIds.length + updatedIds.length + deletedIds.length;

  bool get hasWork => hadPayload && (doneCount > 0 || failed.isNotEmpty);

  /// 把两轮（原轮 + 修复轮）的结果并起来。
  ///
  /// 修复轮只该产出"没成的那些"，所以成功项是**相加**；失败项取**最后一个**——
  /// 一次修不好就不再重复报旧原因（最后一次的失败原因才是当前的真相）。
  AppliedResult merge(AppliedResult later) => AppliedResult(
        hadPayload: hadPayload || later.hadPayload,
        createdIds: [...createdIds, ...later.createdIds],
        updatedIds: [...updatedIds, ...later.updatedIds],
        deletedIds: [...deletedIds, ...later.deletedIds],
        failed: later.failed,
      );

  /// 给用户看的一句话（拼在回答末尾）。
  String get summary {
    final parts = <String>[
      if (createdIds.isNotEmpty) '新建 ${createdIds.length} 篇',
      if (updatedIds.isNotEmpty) '修改 ${updatedIds.length} 篇',
      if (deletedIds.isNotEmpty) '删除 ${deletedIds.length} 篇',
    ];
    if (parts.isEmpty && failed.isEmpty) return '没有需要落库的内容';
    final okPart = parts.isEmpty ? '没有落成的项' : '已落库：${parts.join(' · ')}';
    if (failed.isEmpty) return okPart;
    final why = failed
        .take(3)
        .map((f) => '${_label(f)}：${f['reason']}')
        .join('；');
    final more = failed.length > 3 ? '等 ${failed.length} 项' : '';
    return '$okPart；**未处理**：$why$more';
  }

  static String _label(Map<String, Object?> f) {
    final id = f['id'];
    final title = f['title'];
    final kind = switch (f['kind']) {
      'note' => '新建',
      'update' => '修改',
      'delete' => '删除',
      _ => '项',
    };
    if (title != null && title.toString().isNotEmpty) return '$kind「$title」';
    if (id != null) return '$kind $id';
    final i = f['index'];
    return i == null ? kind : '$kind第 ${(i as int) + 1} 项';
  }

  /// 给模型的修复请求（作为一条 user 消息回灌）。
  ///
  /// 关键是**把已落库的 id 一起给它**：不这么做，模型会把已经建好的再建一遍，
  /// 用户看到的就是重复笔记。
  String repairMessage() => jsonEncode({
        'failed': failed,
        'done': {
          'created_note_ids': createdIds,
          'updated_note_ids': updatedIds,
          'deleted_note_ids': deletedIds,
        },
        'note': '上面这些是已落库的，**不要再建/再改**。'
            '请只针对 failed 里的项给出修正后的完整 json 代码块（格式同前）。',
      });
}
