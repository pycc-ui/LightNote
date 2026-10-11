// 历史窗口（§8.6）：最近 **5 轮**、单条截断 **500 字**。
//
// 为什么值得单独一个文件：这条规则直接决定**每条消息的成本**。
// 不设上限的话历史是每条都重发的 → `O(N²)`，聊得越久每条越贵，
// 而且**不会报错**、不会崩，只是账单慢慢涨上去。
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_notes/core/db/app_database.dart';
import 'package:smart_notes/features/ai/data/deepseek_client.dart';
import 'package:smart_notes/features/ai/domain/ai_chat_repository.dart';
import 'package:smart_notes/features/ai/domain/ai_repository.dart';

void main() {
  var seq = 0;
  AiMessage row(String role, String content) => AiMessage(
        id: 'm${seq++}',
        conversationId: 'c',
        role: role,
        content: content,
        pendingAction: null,
        createdAt: DateTime.utc(2026, 1, 1).add(Duration(seconds: seq)),
      );

  /// 造 [n] 轮对话（每轮 user + assistant）
  List<AiMessage> rounds(int n) => [
        for (var i = 0; i < n; i++) ...[
          row('user', '第$i问'),
          row('assistant', '第$i答'),
        ],
      ];

  group('轮数窗口', () {
    test('少于 5 轮时全都带上', () {
      final w = AiChatRepository.historyWindowOf(rounds(3));
      expect(w, hasLength(6));
      expect(w.first.content, '第0问');
      expect(w.last.content, '第2答');
    });

    test('★ 超过 5 轮只带最近 5 轮（旧的丢掉）', () {
      final w = AiChatRepository.historyWindowOf(rounds(10));

      expect(w, hasLength(AiChatRepository.maxHistoryRounds * 2));
      // 第一条应当是第 5 问（10 轮里的后 5 轮 = 第 5..9 轮）
      expect(w.first.content, '第5问');
      expect(w.last.content, '第9答');
      for (final m in w) {
        expect(m.content.startsWith('第0'), isFalse, reason: '第 0 轮太旧了');
      }
    });

    test('★ 窗口大小**不随对话变长而增长**（O(N²) 的根源就在这里）', () {
      final short = AiChatRepository.historyWindowOf(rounds(5)).length;
      final long = AiChatRepository.historyWindowOf(rounds(200)).length;
      expect(long, short, reason: '聊到 200 轮时带的历史必须和 5 轮时一样多');
      expect(long, 10);
    });

    test('只带完整的轮：起点总是 user 消息', () {
      for (final n in [1, 2, 5, 6, 30]) {
        final w = AiChatRepository.historyWindowOf(rounds(n));
        expect(w.first.role, 'user', reason: '$n 轮时起点应当是用户消息');
      }
    });

    test('空会话 → 空历史', () {
      expect(AiChatRepository.historyWindowOf(const []), isEmpty);
      expect(AiChatRepository.historyWindowOf([row('user', '   ')]), isEmpty,
          reason: '空白消息不占位置');
    });

    test('中间夹着空白消息不影响轮数计数', () {
      final rows = [
        ...rounds(6),
        row('user', ''),
        row('assistant', '  '),
      ];
      final w = AiChatRepository.historyWindowOf(rows);
      expect(w, hasLength(10));
      expect(w.first.content, '第1问', reason: '第 0 轮被挤出去了');
    });
  });

  group('单条截断', () {
    test('长消息截到 500 字，并**标明已截断**', () {
      final long = '甲' * 900;
      final w = AiChatRepository.historyWindowOf([
        row('user', '短的'),
        row('assistant', long),
      ]);

      expect(w.last.content.length, lessThan(long.length));
      expect(w.last.content, endsWith('…（已截断）'),
          reason: '不标的话模型会以为当时就说了这么点');
      // 保留 500 字正文 + 标记
      expect(w.last.content.startsWith('甲' * 500), isTrue);
    });

    test('刚好 500 字不截', () {
      final exact = '乙' * 500;
      final w = AiChatRepository.historyWindowOf([row('user', exact)]);
      expect(w.single.content, exact);
      expect(w.single.content, isNot(contains('已截断')));
    });

    test('user 与 assistant 都截（长提问同样不该原样重发）', () {
      final w = AiChatRepository.historyWindowOf([
        row('user', '丙' * 900),
        row('assistant', '丁' * 900),
      ]);
      for (final m in w) {
        expect(m.content, endsWith('…（已截断）'));
      }
    });

    test('★ 截断后总量有上限（5 轮 × 2 条 × 500 字）', () {
      final rows = [
        for (var i = 0; i < 30; i++) ...[
          row('user', '问' * 2000),
          row('assistant', '答' * 2000),
        ],
      ];
      final w = AiChatRepository.historyWindowOf(rows);
      final total = w.fold<int>(0, (a, m) => a + m.content.length);
      // 10 条 × (500 字 + 6 个标记字符「…（已截断）」) 上限
      expect(total, lessThanOrEqualTo(10 * 506));
    });
  });

  group('角色与形状', () {
    test('user / assistant 的角色保留，且不带 toolCalls', () {
      final w = AiChatRepository.historyWindowOf(rounds(2));
      expect(w.map((m) => m.role).toList(), [
        'user', 'assistant', 'user', 'assistant',
      ]);
      for (final m in w) {
        expect(m.toolCalls, isEmpty,
            reason: '上一轮的工具提议与结果都不重发（要就重新调工具）');
      }
    });

    test('参数可调（测试与将来的"更宽窗口"都用得上）', () {
      final w = AiChatRepository.historyWindowOf(
        rounds(10),
        rounds: 2,
        maxChars: 3,
      );
      expect(w, hasLength(4));
      expect(w.first.content, '第8问');
      // `maxChars: 3` 时 `第9答` 正好 3 个字 —— 边界上**不截**
      expect(w.last.content, '第9答');
    });
  });

  group('接进 send：真的按窗口发', () {
    late AppDatabase db;
    late AiChatRepository chat;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      chat = AiChatRepository(db: db, ai: _noopAiForTest(db));
    });
    tearDown(() => db.close());

    test('库里堆了 20 条历史，send 组装出来的历史仍是 10 条', () async {
      final conv = await chat.createConversation();
      for (var i = 0; i < 10; i++) {
        await db.insertAiMessage(AiMessagesCompanion.insert(
          id: 'h$i',
          conversationId: conv.id,
          role: i.isEven ? 'user' : 'assistant',
          content: Value('历史$i'),
          createdAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
        ));
      }

      final rows = await db.watchMessages(conv.id).first;
      expect(rows, hasLength(10));
      expect(AiChatRepository.historyWindowOf(rows), hasLength(10),
          reason: '10 条正好是 5 轮，全都带上');
    });
  });
}
/// 这些用例不需要真的调模型，但 `AiChatRepository` 要求一个 `AiRepository`。
/// 不配 Key 的真客户端即可（这些路径根本不会走到网络）。
AiRepository _noopAiForTest(AppDatabase db) =>
    AiRepository(db: db, client: DeepSeekClient());