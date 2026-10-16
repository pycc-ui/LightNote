// 【真实 API 探针】用真 key 跑"整理笔记 / 生成笔记"，把**每轮来回的完整 JSON** 落成文件。
//
// 跑法：
//   DEEPSEEK_API_KEY=sk-xxx flutter test test/ai_live_probe_test.dart -r expanded
//
// 产出：
//   · 控制台：链路摘要（轮数 / 每轮调了哪些函数 / token / 费用）
//   · 仓库根目录 `AI探针-工具调用链路.md`：**每一轮发出去的 `messages` 数组、
//     收回来的 `tool_calls`（含 arguments 原文）与 usage**——API 上的原始 JSON，没加工。
//
// 它**不参与默认测试**：没设 `DEEPSEEK_API_KEY` 就 skip（要花真钱）。
// 也不断言业务结果（模型输出本来不确定），只收集事实。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart' show CancelToken;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/core/db/ai_udfs.dart';
import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/core/db/models.dart';
import 'package:lightnote/features/ai/data/deepseek_client.dart';
import 'package:lightnote/features/ai/data/deepseek_config.dart';
import 'package:lightnote/features/ai/domain/ai_chat_repository.dart';
import 'package:lightnote/features/ai/domain/ai_model.dart';
import 'package:lightnote/features/ai/domain/ai_repository.dart';
import 'package:lightnote/features/ai/domain/tool_types.dart';
import 'package:lightnote/features/note/data/note_repository.dart';

/// 一轮来回的原始记录。
class RoundTrip {
  RoundTrip(this.round, this.systemPrompt, this.messages);

  final int round;
  final String systemPrompt;
  final List<AgentMessage> messages;

  String text = '';
  List<ToolCall> calls = const [];
  int promptTokens = 0;
  int completionTokens = 0;
  double costCents = 0;
  int ms = 0;
  String? error;

  /// 这一轮发出去的 `messages` 的**原始 JSON**（请求体里那个数组）。
  String get requestJson => const JsonEncoder.withIndent('  ')
      .convert([for (final m in messages) m.toJson()]);

  int get sentChars =>
      systemPrompt.length + messages.fold<int>(0, (a, m) => a + m.content.length);
}

/// 包一层真客户端，把每一轮的来与回都记下来。
class LoggingClient extends DeepSeekClient {
  LoggingClient(this._inner);

  final DeepSeekClient _inner;
  final List<RoundTrip> trips = [];

  @override
  bool get hasApiKey => _inner.hasApiKey;

  @override
  void setApiKey(String? key) => _inner.setApiKey(key);

  @override
  Stream<AiEvent> streamChat({
    required String systemPrompt,
    required String userPrompt,
    String model = 'fake',
    bool thinking = false,
    String reasoningEffort = 'high',
    int? maxTokens,
    bool jsonMode = false,
    double? temperature,
    CancelToken? cancelToken,
  }) =>
      _inner.streamChat(
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        model: model,
        thinking: thinking,
        reasoningEffort: reasoningEffort,
        maxTokens: maxTokens,
        jsonMode: jsonMode,
        temperature: temperature,
        cancelToken: cancelToken,
      );

  @override
  Stream<AiEvent> streamAgent({
    required String systemPrompt,
    required List<AgentMessage> messages,
    List<ToolSpec> tools = const [],
    String model = 'fake',
    bool thinking = false,
    String reasoningEffort = 'high',
    int? maxTokens,
    CancelToken? cancelToken,
  }) async* {
    final t = RoundTrip(
        trips.length + 1, systemPrompt, List<AgentMessage>.from(messages));
    trips.add(t);
    final t0 = DateTime.now();

    await for (final e in _inner.streamAgent(
      systemPrompt: systemPrompt,
      messages: messages,
      tools: tools,
      model: model,
      thinking: thinking,
      reasoningEffort: reasoningEffort,
      maxTokens: maxTokens,
      cancelToken: cancelToken,
    )) {
      switch (e) {
        case AiChunk():
          t.text += e.text;
        case AiReasoning():
          break;
        case AiDone():
          t.calls = e.toolCalls;
          t.promptTokens = e.promptTokens;
          t.completionTokens = e.completionTokens;
          t.costCents = e.costCents;
        case AiError(:final message, :final code):
          t.error = '$message ($code)';
      }
      yield e;
    }
    t.ms = DateTime.now().difference(t0).inMilliseconds;
  }
}

/// 7 篇会议记录（每篇 500–900 字，带 Markdown 标题）—— 故意写成"要通读才能整理"的形态。
const _meetings = <(String, String)>[
  ('周一 · 项目A 启动会', '''
# 参会
张伟、李娜、王强、我

# 目标
本季度把项目A 的试点推到 3 个部门，6 月底给出验收报告。

# 讨论要点
- 试点范围先定 2 个部门，第三个等第一轮反馈再定
- 预算走年度预算，不新开专项
- 数据接口由张伟那边提供，5 月底前给到测试环境

# 待办
- 我：本周内出一版试点方案初稿
- 李娜：对接法务确认数据合规口径
- 王强：整理去年试点的失败原因，周五同步
'''),
  ('周二 · 项目A 技术评审', '''
# 参会
张伟、我、外部顾问老陈

# 结论
接口方案选 B 方案（消息队列），不走轮询。理由是轮询在试点规模下会把数据库压垮。

# 风险
主要风险是时间紧：接口 5 月底给到，我们只剩两周做联调。
老陈提醒：消息队列要有降级方案，试点期间至少要有一次演练。

# 待办
- 我：出降级方案
- 张伟：确认队列中间件是否已采购
'''),
  ('周三 · 项目A 试点方案评审', '''
# 参会
李娜、王强、我

# 评审意见
1. 方案里"试点部门自评"这一节删掉，改成统一问卷，否则口径不可比
2. 验收指标从 5 个减到 3 个：采纳率、单次耗时、错误率
3. 预算一节要补上人力成本折算

# 争议
王强认为试点部门应该自己出人做推广；李娜认为推广必须由我们主导，否则推不动。最后定：我们主导，试点部门配合。

# 待办
- 我：按意见改一版，周四给到
'''),
  ('周四 · 数据合规沟通', '''
# 参会
李娜、法务小周、我

# 结论
用户数据不出境；试点期间不做画像，只做基础统计。
数据留存期定 6 个月，到期自动清理。

# 需要补的材料
- 数据流向图（我做）
- 权限矩阵（小周做）
- 试点部门的数据使用承诺书（李娜去要）

# 提醒
小周特别强调：承诺书必须试点部门负责人签，不能是接口人代签。
'''),
  ('周五 · 周会汇报', '''
# 本周进展
- 试点方案初稿完成，已过一轮评审
- 接口方案定为消息队列，降级方案在写
- 合规材料收集中

# 下周计划
- 试点方案定稿并送签
- 接口联调环境就绪
- 完成第一次降级演练

# 问题
预算还没批下来，可能要等到下月初。如果拖到 6 月，验收时间会被压缩。
'''),
  ('补充 · 王强的失败复盘', '''
# 去年试点为什么失败
1. 试点部门没人用：推广靠自发，一周后活跃度归零
2. 指标定得太虚（"提升效率"），验收时无法证明有效
3. 没有降级方案，接口挂了一次就被叫停

# 这次要改
- 推广由我们主导，每周固定一次驻场
- 指标必须可量化，且提前和试点部门对齐
- 降级方案必须在试点开始前演练过
'''),
  ('补充 · 预算与人力', '''
# 预算
走年度预算，不新开专项。已用额度需要和陈总确认。

# 人力
- 我：产品 + 项目推进，约 60% 投入
- 李娜：合规 + 对接，约 30%
- 王强：技术，约 40%
- 张伟：接口，约 20%

# 风险
如果预算拖到下月，人力要先撤一半去做别的项目，联调时间会被压到一周以内。
'''),
];

/// 报告文件（写在仓库根目录，方便直接打开看）。两段场景拼在一起。
final _reportSections = <String>[];
const _reportPath = 'AI探针-工具调用链路.md';

void main() {
  final apiKey = Platform.environment['DEEPSEEK_API_KEY']?.trim() ?? '';
  final hasKey = apiKey.isNotEmpty;
  final skipReason = hasKey ? null : '未设置 DEEPSEEK_API_KEY（要花真钱，默认跳过）';

  late AppDatabase db;
  late LoggingClient client;
  late AiChatRepository chat;
  late NoteRepository notes;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory(setup: installAiUdfs));
    client = LoggingClient(DeepSeekClient()..setApiKey(apiKey));
    chat = AiChatRepository(db: db, ai: AiRepository(db: db, client: client));
    notes = NoteRepository(db);
  });
  tearDown(() => db.close());

  tearDownAll(() {
    if (_reportSections.isEmpty) return;
    File(_reportPath).writeAsStringSync(_reportSections.join('\n\n---\n\n'));
    print('\n链路原文已写入: $_reportPath');
  });

  /// 表格里用：参数里最要紧的那一句（SQL 就看 query 的前 200 字）。
  String briefArgs(String raw) {
    try {
      final m = jsonDecode(raw);
      if (m is Map && m['query'] is String) {
        final q = (m['query'] as String).replaceAll('\n', ' ');
        return '`${q.length > 200 ? '${q.substring(0, 200)}…' : q}`';
      }
    } catch (_) {}
    return raw.length > 120 ? '${raw.substring(0, 120)}…' : raw;
  }

  /// 把这一轮的来与回拼成 Markdown（全是不加工的原始 JSON）。
  String dump(String title, String note) {
    final b = StringBuffer()
      ..writeln('# $title')
      ..writeln()
      ..writeln(note)
      ..writeln();

    final totalIn = client.trips.fold<int>(0, (a, t) => a + t.promptTokens);
    final totalOut = client.trips.fold<int>(0, (a, t) => a + t.completionTokens);
    final totalCost = client.trips.fold<double>(0, (a, t) => a + t.costCents);

    b
      ..writeln('| 轮 | 调用的函数 | 进上下文 | in | out | 费用 | 耗时 |')
      ..writeln('|---|---|---|---|---|---|---|');
    for (final t in client.trips) {
      final fns = t.calls.isEmpty
          ? '（不调工具，直接回答）'
          : t.calls
              .map((c) => '`${c.name}` ${briefArgs(c.arguments)}')
              .join('<br>');
      b.writeln('| ${t.round} | $fns | ${t.sentChars} 字 | '
          '${t.promptTokens} | ${t.completionTokens} | '
          '${t.costCents.toStringAsFixed(2)} 分 | ${t.ms}ms |');
    }
    b
      ..writeln()
      ..writeln('**合计：${client.trips.length} 轮 / in $totalIn out $totalOut '
          'token / ${DeepSeekPricing.formatCents(totalCost)}**')
      ..writeln();

    for (final t in client.trips) {
      b
        ..writeln('## 轮 ${t.round}')
        ..writeln()
        ..writeln('### ① 发出去的请求（`messages` 数组的原始 JSON；'
            '`role: "tool"` 的就是上一轮工具调用的结果）')
        ..writeln()
        ..writeln('```json')
        ..writeln(t.requestJson)
        ..writeln('```')
        ..writeln()
        ..writeln('> system prompt 共 ${t.systemPrompt.length} 字'
            '（固定段 + 摘要，整轮不变 —— 前缀缓存的前提）')
        ..writeln()
        ..writeln('### ② 收回来的响应')
        ..writeln()
        ..writeln('```json')
        ..writeln(const JsonEncoder.withIndent('  ').convert({
          'text': t.text,
          'tool_calls': [for (final c in t.calls) c.toJson()],
          'usage': {
            'prompt_tokens': t.promptTokens,
            'completion_tokens': t.completionTokens,
            'cost_cents': t.costCents,
            'elapsed_ms': t.ms,
          },
          if (t.error != null) 'error': t.error,
        }))
        ..writeln('```')
        ..writeln();
    }
    return b.toString();
  }

  test('探针 A · 整理 7 篇会议记录成 3 篇', () async {
    for (final (t, c) in _meetings) {
      await notes.createInbox(title: t, content: c);
    }
    final conv = await chat.createConversation(model: AiModel.pro);
    final t0 = DateTime.now();

    await chat.send(
      conversationId: conv.id,
      userInput: '把我最近的会议记录整理成三篇主题笔记：'
          '一篇讲项目进展与风险，一篇讲合规要求，一篇讲预算与人力。',
      thinkingEffort: 'medium',
      thinkingEnabled: true,
    );

    final rows = await db.watchMessages(conv.id).first;
    final assistant = rows.lastWhere((m) => m.role == 'assistant');
    final all = await db
        .customSelect('SELECT title, word_count FROM notes '
            'WHERE deleted_at IS NULL ORDER BY created_at')
        .get();
    final n = all.length;

    final note = '耗时 ${DateTime.now().difference(t0).inSeconds} 秒；'
        '中断原因：${assistant.interruptReason ?? "（正常写完）"}；'
        '库里现有 $n 篇（原 7 篇 + 落库新建的）';
    _reportSections.add(dump('探针 A · 整理 7 篇会议记录 → 3 篇', note));

    print('\n=== 探针 A ===\n$note');
    for (final r in all) {
      print('  · ${r.read<String>('title')}（${r.read<int>('word_count')} 字）');
    }
    print('\n回答（前 600 字）：\n${_clip(assistant.content, 600)}');
  }, skip: skipReason, timeout: const Timeout(Duration(minutes: 20)));

  test('探针 B · 生成 3 篇新笔记', () async {
    final conv = await chat.createConversation(model: AiModel.pro);
    final t0 = DateTime.now();

    await chat.send(
      conversationId: conv.id,
      userInput: '给我写三篇笔记，主题是「本地优先的笔记软件为什么值得做」：'
          '分别从隐私、成本、离线可用三个角度写，每篇 400 字左右。',
      thinkingEffort: 'medium',
      thinkingEnabled: true,
    );

    final rows = await db.watchMessages(conv.id).first;
    final assistant = rows.lastWhere((m) => m.role == 'assistant');
    final all = await db
        .customSelect('SELECT title, word_count FROM notes '
            'WHERE deleted_at IS NULL ORDER BY created_at')
        .get();

    final note = '耗时 ${DateTime.now().difference(t0).inSeconds} 秒；'
        '中断原因：${assistant.interruptReason ?? "（正常写完）"}；'
        '新建 ${all.length} 篇';
    _reportSections.add(dump('探针 B · 生成 3 篇新笔记', note));

    print('\n=== 探针 B ===\n$note');
    for (final r in all) {
      print('  · ${r.read<String>('title')}（${r.read<int>('word_count')} 字）');
    }
    print('\n回答（前 600 字）：\n${_clip(assistant.content, 600)}');
  }, skip: skipReason, timeout: const Timeout(Duration(minutes: 20)));
}

String _clip(String s, int n) =>
    s.length <= n ? s : '${s.substring(0, n)}…（共 ${s.length} 字）';
