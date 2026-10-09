import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/models.dart';
import '../data/deepseek_config.dart';
import 'ai_repository.dart';
import 'prompts.dart';

/// AI 会话仓储：把设计稿 §5.6 的 AI 页（工作区 / 思考强度 / 选择文件 / 指令）
/// 接到真实 DeepSeek 调用上，并持久化会话历史。
///
/// 隐私设计（对应设计稿「必须用户确认，不自动上传」）：
/// 1. 首次发送前必须通过一次明确的授权闸门 [ensurePrivacyConsent]；
/// 2. 每次请求只发送**用户显式选中**的笔记正文，不做全库上传；
/// 3. 未选中任何文件时，只发送用户当前这条指令，不带笔记内容；
/// 4. 授权状态与「本次发送包含哪些笔记」都在 UI 上明示。
class AiChatRepository {
  AiChatRepository({required AppDatabase db, required AiRepository ai})
      : _db = db,
        _ai = ai;

  final AppDatabase _db;
  final AiRepository _ai;
  final _uuid = const Uuid();

  static const _kPrivacyAccepted = 'ai_privacy_accepted';

  /// 单次请求最多带入的笔记条数，防止一次点满导致费用失控
  static const maxContextNotes = 8;

  /// 单条笔记带正文的上限字符数
  static const maxCharsPerNote = 6000;

  AiRepository get ai => _ai;

  // ---------------------------------------------------------------------------
  // 隐私授权
  // ---------------------------------------------------------------------------

  Future<bool> hasPrivacyConsent() async =>
      (await _db.readSetting(_kPrivacyAccepted)) == 'true';

  Future<void> acceptPrivacy() =>
      _db.writeSetting(_kPrivacyAccepted, 'true');

  Future<void> revokePrivacy() => _db.deleteSetting(_kPrivacyAccepted);

  // ---------------------------------------------------------------------------
  // 会话
  // ---------------------------------------------------------------------------

  Stream<List<AiConversation>> watchConversations() =>
      _db.watchConversations();

  Stream<List<AiMessage>> watchMessages(String conversationId) =>
      _db.watchMessages(conversationId);

  Future<AiConversation> createConversation({
    String? workspaceFolderId,
    String thinkingEffort = 'medium',
  }) async {
    final now = DateTime.now().toUtc();
    final id = _uuid.v4();
    await _db.upsertConversation(AiConversationsCompanion.insert(
      id: id,
      workspaceFolderId: Value(workspaceFolderId),
      thinkingEffort: Value(thinkingEffort),
      title: const Value(''),
      createdAt: now,
      updatedAt: now,
    ));
    return (await _db.getConversation(id))!;
  }

  Future<void> setWorkspace(String conversationId, String? folderId) async {
    await (_db.update(_db.aiConversations)
          ..where((t) => t.id.equals(conversationId)))
        .write(AiConversationsCompanion(
      workspaceFolderId: Value(folderId),
      updatedAt: Value(DateTime.now().toUtc()),
    ));
  }

  Future<void> setThinkingEffort(String conversationId, String effort) async {
    await (_db.update(_db.aiConversations)
          ..where((t) => t.id.equals(conversationId)))
        .write(AiConversationsCompanion(
      thinkingEffort: Value(effort),
      updatedAt: Value(DateTime.now().toUtc()),
    ));
  }

  Future<void> deleteConversation(String id) => _db.deleteConversation(id);

  // ---------------------------------------------------------------------------
  // 发送
  // ---------------------------------------------------------------------------

  /// 发送一条指令。
  ///
  /// [contextNoteIds] 是用户在「+ → 选择文件」里显式挑选的笔记；
  /// 为空时**不附带任何笔记正文**。
  /// 返回助手消息的 id，UI 可以监听该条消息的流式更新。
  Future<String> send({
    required String conversationId,
    required String userInput,
    required List<String> contextNoteIds,
    required String workspaceFolderId,
    required String thinkingEffort,
    required bool thinkingEnabled,
  }) async {
    final now = DateTime.now().toUtc();

    // 1) 落用户消息
    await _db.insertAiMessage(AiMessagesCompanion.insert(
      id: _uuid.v4(),
      conversationId: conversationId,
      role: 'user',
      content: Value(userInput),
      createdAt: now,
    ));

    // 2) 首条用户消息作为会话标题
    final conv = await _db.getConversation(conversationId);
    if (conv != null && conv.title.trim().isEmpty) {
      final title = userInput.length > 20
          ? '${userInput.substring(0, 20)}…'
          : userInput;
      await _db.touchConversation(conversationId, title: title);
    }

    // 3) 组装上下文：只带用户显式选中的笔记
    final contexts = <String>[];
    for (final id in contextNoteIds.take(maxContextNotes)) {
      final note = await _db.getNote(id);
      if (note == null) continue;
      final body = note.content.length > maxCharsPerNote
          ? '${note.content.substring(0, maxCharsPerNote)}…'
          : note.content;
      contexts.add(
        '《${note.title.trim().isEmpty ? '无标题' : note.title.trim()}》\n$body',
      );
    }

    final workspaceLabel = workspaceFolderId.isEmpty
        ? null
        : (await _db.getFolder(workspaceFolderId))?.name;

    // 4) 落助手占位消息，拿到 id 供流式更新
    final assistantId = _uuid.v4();
    await _db.insertAiMessage(AiMessagesCompanion.insert(
      id: assistantId,
      conversationId: conversationId,
      role: 'assistant',
      content: const Value(''),
      createdAt: DateTime.now().toUtc(),
    ));

    // 5) 流式请求，边收边写库
    final buffer = StringBuffer();
    await for (final event in _ai.client.streamChat(
      systemPrompt: AiPrompts.agentSystem(workspaceLabel),
      userPrompt: AiPrompts.agentUser(userInput, contexts),
      model: DeepSeekConfig.modelFlash,
      thinking: thinkingEnabled,
      reasoningEffort: thinkingEffort,
    )) {
      switch (event) {
        case AiChunk(:final text):
          buffer.write(text);
          await _db.updateAiMessage(assistantId, buffer.toString());
        case AiDone(
            :final promptTokens,
            :final completionTokens,
            :final costCents,
            :final latencyMs
          ):
          await _ai.logChatCall(
            model: DeepSeekConfig.modelFlash,
            thinking: thinkingEnabled,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            costCents: costCents,
            latencyMs: latencyMs,
            success: true,
          );
        case AiError(:final message, :final code):
          // 把错误写进消息里，用户能在会话中看到失败原因而不是静默卡住
          await _db.updateAiMessage(
            assistantId,
            buffer.isEmpty ? '⚠️ $message' : '${buffer.toString()}\n\n⚠️ $message',
          );
          await _ai.logChatCall(
            model: DeepSeekConfig.modelFlash,
            thinking: thinkingEnabled,
            promptTokens: 0,
            completionTokens: 0,
            costCents: 0,
            latencyMs: 0,
            success: false,
            errorCode: code,
          );
        case AiReasoning():
          break; // AI 页不展示思维链，避免干扰
      }
    }

    await _db.touchConversation(conversationId);
    return assistantId;
  }

  /// 「+ → 选择目录」时列出候选笔记：优先工作区，其次全部
  Future<List<Note>> candidateNotes(String? workspaceFolderId) async {
    if (workspaceFolderId != null && workspaceFolderId.isNotEmpty) {
      final inFolder = await _db.watchNotesInFolder(workspaceFolderId).first;
      if (inFolder.isNotEmpty) return inFolder;
    }
    return _db.allActiveNotes();
  }
}
