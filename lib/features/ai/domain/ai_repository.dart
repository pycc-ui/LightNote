
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../app/api_key_file.dart';
import '../../../core/db/app_database.dart';
import '../../../core/db/models.dart';
import '../../../core/secure/secure_store.dart';
import '../../../core/util/ai_limits.dart';
import '../data/deepseek_client.dart';
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

  bool _initialized = false;
  Future<void>? _initInflight;

  /// 读 Key 并交给 client。**重复调用是安全的**。
  ///
  /// ⚠️ 不要把"Key 已就绪"当成调用方的前置条件。这个方法和
  /// `InboxPage._bootstrap` 都挂在 post-frame 回调上，**两者没有先后保证**：
  ///
  /// 一旦预热先跑，client 里还没有 Key，请求立刻以 `no_api_key` 失败 →
  /// 预热静默退回、`takeBatch` 也失败 → 用户看到「生成失败」和重试按钮，
  /// 手点一次才好。这就是"配好 Key 重启还要手动重试"的根因。
  ///
  /// 所以每个真正要发请求的方法都先 `await ensureReady()`：谁先用谁负责把 Key
  /// 准备好，而不是靠调用顺序碰运气（在 main 里补一个 await 只是把顺序碰对，
  /// 下次改别处又会踩）。
  Future<void> init() {
    if (_initialized) return Future.value();
    final running = _initInflight;
    if (running != null) return running;

    final future = _doInit();
    _initInflight = future;
    return future.whenComplete(() {
      if (identical(_initInflight, future)) _initInflight = null;
    });
  }

  Future<void> _doInit() async {
    final key = await SecureStore.readApiKey();
    if (key != null && key.trim().isNotEmpty) {
      _client.setApiKey(key);
      _initialized = true;
      return;
    }
    // 钥匙串里没有时才看开发用的 Key 文件（见 ApiKeyFile 的说明）。
    // 顺序刻意如此：**用户自己配过的永远优先**，不能被文件悄悄覆盖。
    final fromFile = await ApiKeyFile.read();
    _client.setApiKey(fromFile);
    _initialized = true;
  }

  /// 发请求前统一走这里。
  ///
  /// 已经配过 Key 时它只做一次布尔判断，开销可以忽略。
  Future<void> ensureReady() => init();

  Future<void> saveApiKey(String key) async {
    await SecureStore.writeApiKey(key);
    _client.setApiKey(key);
    // 标记为已初始化，避免下一次请求又去钥匙串读一遍（可能读回旧值）
    _initialized = true;
  }

  Future<void> clearApiKey() async {
    await SecureStore.deleteApiKey();
    _client.setApiKey(null);
    // 清掉之后**允许**重新初始化：不然用户重新配一把 Key，
    // 这个进程内会一直用着 null。
    _initialized = true;
  }

  // ---------------------------------------------------------------------------
  // 生成轻笔记卡片（卡片流）
  // ---------------------------------------------------------------------------

  /// 从素材生成轻笔记卡片。
  ///
  /// [materials] 每份包含"摘要 + 一块原文切片"，**一份对应一张卡片**——
  /// 摘要做"面"、切片做"点"，提示词要求卡片基于切片，这样卡片才具体。
  /// 详见 [FeedMaterial] 与 `AiPrompts.feedSystem`。
  ///
  /// [count] 是**要几张卡片**，和素材份数是两件事：
  /// 素材够就一份一张；素材不够时提示词会要求从同一份素材的不同角度补足。
  /// 不传则退化为"一份素材一张卡片"。
  ///
  /// [avoidTitles] 是已经生成过的标题（池子 + 预留）。库里笔记少时切片会被
  /// 反复取到，让模型主动避开这些标题才能真的不重复。
  ///
  /// > `count` 不能被省掉、写成"一份素材一张卡"：那样素材数会被笔记数卡死 ——
  /// > 库里只有 3 条笔记就只能出 3 张卡，内存池永远补不满，用户等一次只拿到几张。
  ///
  /// 关思考模式：它会吃光额度，`max_tokens=20` 时正文直接返回空字符串。
  /// 生成创意文本不需要长链推理，关掉更快更省。
  Future<List<FeedDraft>> generateFeedNotes(
    List<FeedMaterial> materials, {
    int? count,
    List<String> avoidTitles = const [],
    String model = DeepSeekConfig.modelFlash,
    bool deepThinking = false,
  }) async {
    await ensureReady();
    if (materials.isEmpty) {
      throw const DeepSeekException('没有可用素材', code: 'no_source');
    }

    final stopwatch = Stopwatch()..start();
    var usage = TokenUsage.zero;
    String? lastError;

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final (raw, u) = await _client.completeJson(
          systemPrompt: AiPrompts.feedSystem,
          userPrompt: AiPrompts.feedUser(
            materials,
            count: count,
            avoidTitles: avoidTitles,
          ),
          model: model,
          thinking: deepThinking,
          // 额度要跟"一次生成几张 × 每张多长"匹配。
          //
          // 卡片流是**并发多路、每路单卡**（见 `FeedRepository._generateCardsParallel`），
          // 所以单次请求通常只要 1 张。卡片正文已从 400–800 砍到 200–400，
          // 输出上限跟着从 16384 收到 `AiLimits.feedMaxOutputTokens`（2048）：
          // 正常远用不到，纯粹是**防"黑天鹅"**——模型偶尔跑飞一次就烧几千 token。
          // 额度不够会被截断，截断后 JSON 解析失败 = 整批白烧，所以仍留足余量。
          maxTokens: AiLimits.feedMaxOutputTokens,
        );
        usage = u;

        final drafts = AiPrompts.parseFeedCards(raw);
        if (drafts == null) {
          lastError = 'json_parse_failed';
          continue;
        }

        stopwatch.stop();
        await _logCall(
          // 轻笔记生成不是针对某一条笔记的，所以没有 noteId
          noteId: null,
          task: 'feed_generate',
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
            noteId: null,
            task: 'feed_generate',
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
      noteId: null,
      task: 'feed_generate',
      model: model,
      thinking: deepThinking,
      usage: usage,
      latencyMs: stopwatch.elapsedMilliseconds,
      success: false,
      errorCode: lastError ?? 'unknown',
    );
    throw DeepSeekException(
      '生成失败（$lastError）。稍后重试，或先在笔记库里多写几条笔记作为素材。',
      code: lastError,
    );
  }

  // ---------------------------------------------------------------------------
  /// 端点连通性自检，设置页用。
  Future<String> testConnection({String model = DeepSeekConfig.modelFlash}) async {
    await ensureReady();
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

  /// 查询 DeepSeek 账户余额（设置页「查看余额」用）。
  Future<AccountBalance> fetchBalance() async {
    await ensureReady();
    return _client.fetchBalance();
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
