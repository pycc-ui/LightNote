// **"配好 Key 重启之后还要手动点重试"** 的回归测试。
//
// ## 那个 bug 是怎么来的
//
// `main.dart` 里初始化 Key 是"发了不等"的：
//
// ```dart
// WidgetsBinding.instance.addPostFrameCallback((_) {
//   context.read<AiRepository>().init();   // 没有 await
// });
// ```
//
// 而 `InboxPage._bootstrap`（预热 + 取第一屏）**也**挂在 post-frame 上。
// 两者没有先后保证。一旦预热先跑，client 里还没有 Key：
//   · 预热内部抛 no_api_key → 被吞掉 → 静默退回
//   · `takeBatch` 同样失败 → 页面进 error 状态 → 用户看到「生成失败」+ 重试
// 手点一次重试就好了（那时 init 早已跑完）——正是用户报的现象。
//
// ## 修法与这里测的东西
//
// 修法不是在 main 里补一个 await（那只是把顺序碰对，下次改别处又会踩），
// 而是让 `AiRepository` **自己保证**：每个要发请求的方法都先 `await
// ensureReady()`。所以这个文件断言的就是"不显式 init 也能正常发请求"。
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/core/db/models.dart';
import 'package:lightnote/core/secure/secure_store.dart';
import 'package:lightnote/features/ai/data/deepseek_client.dart';
import 'package:lightnote/features/ai/data/deepseek_config.dart';
import 'package:lightnote/features/ai/domain/ai_repository.dart';

/// 桩客户端：**只记录"被调用时有没有 Key"**，然后返回可解析的假响应。
///
/// 这样测试不需要网络，却能精确复现问题——如果 `AiRepository` 忘了
/// 先准备 Key，这里收到的 `hadKeyOnCall` 就是 false。
class _StubClient extends DeepSeekClient {
  _StubClient({required this.reply});

  /// 固定返回的正文
  final String reply;

  /// 每次 completeJson 被调用时，client 当时有没有 Key
  final List<bool> keyStateOnCall = [];

  int callCount = 0;

  @override
  Future<(String, TokenUsage)> completeJson({
    required String systemPrompt,
    required String userPrompt,
    String model = DeepSeekConfig.modelFlash,
    bool thinking = false,
    String reasoningEffort = 'medium',
    int maxTokens = 2048,
    CancelToken? cancelToken,
  }) async {
    callCount++;
    keyStateOnCall.add(hasApiKey);
    if (!hasApiKey) {
      throw const DeepSeekException('未配置 API Key', code: 'no_api_key');
    }
    return (reply, TokenUsage.zero);
  }
}

/// 一份可解析的假卡片响应。
const _oneCard = '{"cards":[{"title":"标题","body":"正文","tag":"标签"}]}';

/// 用一份最简素材去触发一次真实请求。
Future<List<FeedDraft>> _generate(AiRepository ai) => ai.generateFeedNotes(
      const [FeedMaterial(title: '素材标题', chunk: '素材片段')],
    );

void main() {
  // SecureStore 走平台通道，需要 binding 先就绪；否则它会退回会话内存储
  // （功能上没问题，但会打一堆警告，且测的不是真实路径）。
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await SecureStore.deleteApiKey();
  });

  tearDown(() async {
    await SecureStore.deleteApiKey();
    await db.close();
  });

  group('ensureReady：发请求前自己把 Key 准备好', () {
    test('**不显式调 init**，直接发请求也能成功（核心回归）', () async {
      // 模拟"用户已配好 Key、App 重启"：Key 在，但这个 AiRepository 实例
      // 还没被 init 过——正是启动竞态下的状态。
      await SecureStore.writeApiKey('sk-test-key');

      final client = _StubClient(reply: _oneCard);
      final ai = AiRepository(db: db, client: client);

      // **故意不调 ai.init()**
      final cards = await _generate(ai);

      expect(cards, hasLength(1));
      expect(client.keyStateOnCall, [true],
          reason: '发请求时必须已经有 Key——这正是修复点');
    });

    test('真的没有 Key 时仍然明确失败（不能被"自动初始化"掩盖）', () async {
      // 钥匙串空、也没有开发用 Key 文件
      final client = _StubClient(reply: _oneCard);
      final ai = AiRepository(db: db, client: client);

      await expectLater(
        _generate(ai),
        throwsA(isA<DeepSeekException>()),
      );
      expect(client.keyStateOnCall, [false],
          reason: '没 Key 就该以 no_api_key 失败，而不是静默成功');
    });
  });

  group('init 本身', () {
    test('重复调用只读一次钥匙串（幂等）', () async {
      await SecureStore.writeApiKey('sk-test-key');
      final client = _StubClient(reply: _oneCard);
      final ai = AiRepository(db: db, client: client);

      await ai.init();
      await ai.init();
      await ai.init();

      expect(client.hasApiKey, isTrue);
      // 没有可观察的"读了几次"，但至少要有 Key 且不抛
      expect(client.callCount, 0);
    });

    test('并发调用 ensureReady 不会重复初始化', () async {
      await SecureStore.writeApiKey('sk-test-key');
      final client = _StubClient(reply: _oneCard);
      final ai = AiRepository(db: db, client: client);

      // 三个并发请求，共用同一个初始化 future
      final results = await Future.wait([_generate(ai), _generate(ai), _generate(ai)]);

      expect(results.every((r) => r.length == 1), isTrue);
      expect(client.keyStateOnCall.every((had) => had), isTrue,
          reason: '三个并发请求都必须在有 Key 之后才发出');
    });

    test('saveApiKey 之后立刻能用，不需要等 init', () async {
      final client = _StubClient(reply: _oneCard);
      final ai = AiRepository(db: db, client: client);

      await ai.saveApiKey('sk-just-set');
      final cards = await _generate(ai);

      expect(cards, hasLength(1));
      expect(client.keyStateOnCall, [true]);
    });
  });
}
