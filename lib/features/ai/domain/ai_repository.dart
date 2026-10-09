import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/models.dart';
import '../../../core/secure/secure_store.dart';import '../data/deepseek_client.dart';
import '../data/deepseek_config.dart';
import 'prompts.dart';

/// AI 业务层：把「整理笔记」「生成卡片」「重排结构」「基于笔记问答」
/// 封装成 UI 可直接调用的方法，并负责用量落库。
///
/// UI 只依赖本类，不接触 Dio、不接触 DeepSeek 原始响应。
class AiRepository {
  AiRepository({required AppDatabase db, required DeepSeekClient client})
      : _db = db,
        _client = client;

  final AppDatabase _db;
  final DeepSeekClient _client;
  final _uuid = const Uuid();

  DeepSeekClient get client => _client;

  Future<void> init() async {
    final key = await SecureStore.readApiKey();
    _client.setApiKey(key);
  }

  Future<void> saveApiKey(String key) async {
    await SecureStore.writeApiKey(key);
    _client.setApiKey(key);
  }

  Future<void> clearApiKey() async {
    await SecureStore.deleteApiKey();
    _client.setApiKey(null);
  }

  // ---------------------------------------------------------------------------
  // 1. 整理笔记（摘要 + 要点 + 标签 + 待办）
  // ---------------------------------------------------------------------------

  /// 流式整理：UI 可以用返回的事件流做打字机效果。
  ///
  /// 注意：流结束后**不会**自动落库，因为流式返回的是 Markdown 文本，
  /// 不是结构化 JSON。需要结构化结果请用 [organizeNote]。
  Stream<AiEvent> streamOrganize({
    required String noteId,
    String model = DeepSeekConfig.modelFlash,
    bool deepThinking = true,
  }) async* {
    final note = await _db.getNote(noteId);
    if (note == null) {
      yield const AiError('笔记不存在', code: 'not_found');
      return;
    }

    final stopwatch = Stopwatch()..start();
    TokenUsage usage = TokenUsage.zero;
    var success = false;
    String? errorCode;

    final inner = _client.streamChat(
      systemPrompt: AiPrompts.organizeSystem,
      userPrompt: AiPrompts.organizeUser(note.title, note.content),
      model: model,
      thinking: deepThinking,
      reasoningEffort: 'high',
    );

    await for (final event in inner) {
      switch (event) {
        case AiChunk():
        case AiReasoning():
          yield event;
        case AiDone(
            :final promptTokens,
            :final completionTokens,
          ):
          // 这里只关心 token 用量；costCents / latencyMs 由 _logCall 末尾统一结算，
          // 提前解构出来会变成未使用变量（analyzer 会报 unused_local_variable）。
          usage = TokenUsage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
          );
          success = true;
          await _db.markNoteAiDone(noteId);
          yield event;
        case AiError():
          errorCode = event.code;
          yield event;
      }
    }

    stopwatch.stop();
    await _logCall(
      noteId: noteId,
      task: 'organize',
      model: model,
      thinking: deepThinking,
      usage: usage,
      latencyMs: stopwatch.elapsedMilliseconds,
      success: success,
      errorCode: errorCode,
    );
  }

  /// 结构化整理：一次拿到摘要/要点/标签/待办，并落库。
  ///
  /// 使用 JSON Output + 非流式。内置三次尝试以应对官方承认的
  /// 「JSON Output 偶发空 content」问题。
  Future<NoteAiResult> summarize(
    String noteId, {
    String model = DeepSeekConfig.modelFlash,
    bool deepThinking = false,
  }) async {
    final note = await _db.getNote(noteId);
    if (note == null) {
      throw const DeepSeekException('笔记不存在', code: 'not_found');
    }

    final stopwatch = Stopwatch()..start();
    var usage = TokenUsage.zero;
    String? lastError;

    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final (raw, u) = await _client.completeJson(
          systemPrompt: AiPrompts.summarizeSystem,
          userPrompt: AiPrompts.summarizeUser(note.title, note.content),
          model: model,
          thinking: deepThinking,
          reasoningEffort: 'high',
          maxTokens: 2048,
        );
        usage = u;

        final result = AiPrompts.parseSummary(raw);
        if (result == null) {
          lastError = 'json_parse_failed';
          continue; // 解析失败换一次重试
        }

        final cost = DeepSeekPricing.estimateCostCents(model: model, usage: u);
        await _db.insertSummary(NoteSummariesCompanion.insert(
          id: _uuid.v4(),
          noteId: noteId,
          model: model,
          oneLine: Value(result.oneLine),
          bullets: Value(_jsonList(result.bullets)),
          suggestedTags: Value(_jsonList(result.tags)),
          actionItems: Value(_jsonList(result.actionItems)),
          rawResponse: Value(result.rawResponse),
          promptTokens: Value(u.promptTokens),
          completionTokens: Value(u.completionTokens),
          costCents: Value(cost),
          createdAt: DateTime.now().toUtc(),
        ));
        await _db.markNoteAiDone(noteId);
        await _upsertTags(noteId, result.tags);

        stopwatch.stop();
        await _logCall(
          noteId: noteId,
          task: 'summarize',
          model: model,
          thinking: deepThinking,
          usage: u,
          latencyMs: stopwatch.elapsedMilliseconds,
          success: true,
        );
        return result;
      } on DeepSeekException catch (e) {
        lastError = e.code;
        // 只有可重试的错误才继续尝试；401/402 直接抛出
        if (!e.isRetryable && e.code != 'json_empty') {
          stopwatch.stop();
          await _logCall(
            noteId: noteId,
            task: 'summarize',
            model: model,
            thinking: deepThinking,
            usage: usage,
            latencyMs: stopwatch.elapsedMilliseconds,
            success: false,
            errorCode: e.code,
          );
          rethrow;
        }
      }
    }

    stopwatch.stop();
    await _logCall(
      noteId: noteId,
      task: 'summarize',
      model: model,
      thinking: deepThinking,
      usage: usage,
      latencyMs: stopwatch.elapsedMilliseconds,
      success: false,
      errorCode: lastError ?? 'unknown',
    );
    throw DeepSeekException(
      'AI 整理连续失败（$lastError）。可稍后重试，或在设置中改用 flash 模型。',
      code: lastError,
    );
  }

  // ---------------------------------------------------------------------------
  // 2. 生成记忆卡片
  // ---------------------------------------------------------------------------

  /// 生成卡片**草稿**。不直接落库 —— 必须经用户确认，
  /// 否则劣质卡片会立刻污染复习队列。
  Future<List<CardDraft>> generateCards(
    String noteId, {
    String model = DeepSeekConfig.modelPro,
    bool deepThinking = true,
    int maxCards = 15,
  }) async {
    final note = await _db.getNote(noteId);
    if (note == null) {
      throw const DeepSeekException('笔记不存在', code: 'not_found');
    }

    final stopwatch = Stopwatch()..start();
    var usage = TokenUsage.zero;
    String? lastError;

    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final (raw, u) = await _client.completeJson(
          systemPrompt: AiPrompts.cardsSystem,
          userPrompt: AiPrompts.cardsUser(note.title, note.content,
              maxCards: maxCards),
          model: model,
          thinking: deepThinking,
          reasoningEffort: 'high',
          // 卡片比摘要长得多，max_tokens 给足，否则 JSON 会被截断
          maxTokens: 8192,
        );
        usage = u;

        final drafts = AiPrompts.parseCards(raw);
        if (drafts == null) {
          lastError = 'json_parse_failed';
          continue;
        }

        stopwatch.stop();
        await _logCall(
          noteId: noteId,
          task: 'generate_cards',
          model: model,
          thinking: deepThinking,
          usage: u,
          latencyMs: stopwatch.elapsedMilliseconds,
          success: true,
        );
        return drafts;
      } on DeepSeekException catch (e) {
        lastError = e.code;
        if (!e.isRetryable && e.code != 'json_empty') {
          stopwatch.stop();
          await _logCall(
            noteId: noteId,
            task: 'generate_cards',
            model: model,
            thinking: deepThinking,
            usage: usage,
            latencyMs: stopwatch.elapsedMilliseconds,
            success: false,
            errorCode: e.code,
          );
          rethrow;
        }
      }
    }

    stopwatch.stop();
    await _logCall(
      noteId: noteId,
      task: 'generate_cards',
      model: model,
      thinking: deepThinking,
      usage: usage,
      latencyMs: stopwatch.elapsedMilliseconds,
      success: false,
      errorCode: lastError ?? 'unknown',
    );
    throw DeepSeekException(
      '卡片生成失败（$lastError）。这篇笔记内容可能过短，或稍后重试。',
      code: lastError,
    );
  }

  /// 用户确认后把草稿落库。
  ///
  /// 新卡 `dueAt` 设为当前时间，即可立即进入今日队列。
  /// `ease` 用 SM-2 默认值 2.5，`repetitions` 为 0 表示新卡。
  Future<int> commitCardDrafts({
    required String noteId,
    required List<CardDraft> drafts,
    String? model,
  }) async {
    final selected = drafts.where((d) => d.selected && d.isValid).toList();
    if (selected.isEmpty) return 0;

    final now = DateTime.now().toUtc();
    await _db.transaction(() async {
      for (final d in selected) {
        await _db.upsertCard(CardsCompanion.insert(
          id: _uuid.v4(),
          noteId: Value(noteId),
          question: d.question,
          answer: d.answer,
          source: const Value('ai'),
          aiModel: Value(model),
          tags: Value(d.tags.isEmpty ? null : d.tags.join(',')),
          dueAt: now,
          createdAt: now,
          updatedAt: now,
        ));
      }
    });
    return selected.length;
  }

  // ---------------------------------------------------------------------------
  // 3. 基于笔记问答
  // ---------------------------------------------------------------------------

  /// 检索与问题最相关的若干条笔记作为上下文。
  ///
  /// 首版是朴素的关键词匹配（LIKE）。真正的语义检索需要 embedding，
  /// 列入后续版本；这里先保证「离线可用的降级路径」存在。
  Future<String> ask(
    String question, {
    String model = DeepSeekConfig.modelFlash,
    bool deepThinking = false,
    int topK = 5,
  }) async {
    final notes = await _db.allActiveNotes();
    if (notes.isEmpty) {
      throw const DeepSeekException('你还没有任何笔记', code: 'no_notes');
    }

    final scored = notes
        .map((n) => (note: n, score: _relevance(n, question)))
        .where((e) => e.score > 0)
        .toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    final picked = scored.take(topK).map((e) => e.note).toList();
    // 没有命中任何关键词时，退化为最近的 topK 条笔记，避免完全答不出
    final contexts = (picked.isEmpty ? notes.take(topK).toList() : picked)
        .map((n) {
      final body = n.content.length > 4000
          ? '${n.content.substring(0, 4000)}…'
          : n.content;
      return '标题：${n.title.isEmpty ? '无标题' : n.title}\n$body';
    }).toList();

    final stopwatch = Stopwatch()..start();
    final buffer = StringBuffer();
    var usage = TokenUsage.zero;
    String? errorCode;
    String? errorMessage;
    var success = false;

    // 注意：不要在 await for 内部直接 throw —— 那会跳出循环，
    // 让下面的用量审计（_logCall）被跳过，产生"失败调用没记录"的黑洞。
    // 这里先记录错误、正常结束循环，再统一收尾。
    await for (final event in _client.streamChat(
      systemPrompt: AiPrompts.askSystem,
      userPrompt: AiPrompts.askUser(question, contexts),
      model: model,
      thinking: deepThinking,
      reasoningEffort: 'medium',
    )) {
      switch (event) {
        case AiChunk(:final text):
          buffer.write(text);
        case AiDone(:final promptTokens, :final completionTokens):
          usage = TokenUsage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
          );
          success = true;
        case AiReasoning():
          break; // 问答场景不展示思维链
        case AiError(:final code, :final message):
          errorCode = code;
          errorMessage = message;
      }
    }

    stopwatch.stop();
    await _logCall(
      noteId: null,
      task: 'ask',
      model: model,
      thinking: deepThinking,
      usage: usage,
      latencyMs: stopwatch.elapsedMilliseconds,
      success: success,
      errorCode: errorCode,
    );

    if (errorMessage != null) {
      throw DeepSeekException(errorMessage, code: errorCode);
    }
    return buffer.toString();
  }

  /// 端点连通性自检，设置页用。
  Future<String> testConnection({String model = DeepSeekConfig.modelFlash}) async {
    final (content, _) = await _client.completeJson(
      systemPrompt:
          '你是一个测试助手。请输出 json：{"ok": true, "message": "连接正常"}',
      userPrompt: '请返回 json 格式的连通性确认。',
      model: model,
      thinking: false,
      maxTokens: 64,
    );
    return content;
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  /// 供 AiChatRepository 复用：AI 页的调用也要计入成本审计。
  Future<void> logChatCall({
    required String model,
    required bool thinking,
    required int promptTokens,
    required int completionTokens,
    required double costCents,
    required int latencyMs,
    required bool success,
    String? errorCode,
  }) {
    return _logCall(
      noteId: null,
      task: 'agent',
      model: model,
      thinking: thinking,
      usage: TokenUsage(
        promptTokens: promptTokens,
        completionTokens: completionTokens,
      ),
      latencyMs: latencyMs,
      success: success,
      errorCode: errorCode,
    );
  }

  /// 把 AI 建议的标签写入标签表并关联到笔记（幂等）。
  Future<void> _upsertTags(String noteId, List<String> names) async {
    for (final raw in names) {
      final name = raw.trim();
      if (name.isEmpty || name.length > 20) continue;
      try {
        final tagId = await _db.ensureTag(_uuid.v4(), name);
        await _db.attachTag(noteId, tagId);
      } catch (_) {
        // 单个标签失败不应中断整体整理流程
      }
    }
  }

  /// 关键词相关度打分：标题命中权重更高，其次统计正文命中次数。
  static double _relevance(Note note, String question) {
    final terms = question
        .toLowerCase()
        .split(RegExp(r'[\s,，。？?！!、;；:：]+'))
        .where((t) => t.length >= 2)
        .toList();
    if (terms.isEmpty) return 0;

    final title = note.title.toLowerCase();
    final body = note.content.toLowerCase();
    var score = 0.0;
    for (final t in terms) {
      if (title.contains(t)) score += 5.0;
      score += body.split(t).length - 1; // 出现次数
    }
    return score;
  }

  /// 把字符串列表编码为 JSON 数组字符串。
  ///
  /// 用 dart:convert 而不是手写转义：模型返回的要点里出现引号、反斜杠、
  /// 换行、Tab 都很常见，手写转义漏掉任何一种都会让存库的 JSON 非法，
  /// 进而在阅读页解析失败。
  static String _jsonList(List<String> items) => jsonEncode(items);

  Future<void> _logCall({
    required String? noteId,
    required String task,
    required String model,
    required bool thinking,
    required TokenUsage usage,
    required int latencyMs,
    required bool success,
    String? errorCode,
  }) async {
    try {
      await _db.insertAiCall(AiCallsCompanion.insert(
        id: _uuid.v4(),
        noteId: Value(noteId),
        task: task,
        model: model,
        thinkingEnabled: Value(thinking),
        promptTokens: Value(usage.promptTokens),
        completionTokens: Value(usage.completionTokens),
        costCents: Value(
          DeepSeekPricing.estimateCostCents(model: model, usage: usage),
        ),
        latencyMs: Value(latencyMs),
        success: Value(success),
        errorCode: Value(errorCode),
        createdAt: DateTime.now().toUtc(),
      ));
    } catch (_) {
      // 审计写入失败不能影响主流程
    }
  }
}
