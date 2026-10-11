// **阶段 0 的验收测试**：客户端能不能带工具发请求、能不能把流式
// `tool_calls` 分片拼成完整调用、能不能回灌 `role: tool`。
//
// 这是整条 AI Agent 路线的前置验证 —— 没有它，后面 19 个工具、工具循环、
// `askUser` 往返全都无从谈起。
//
// 用假适配器喂一段**真实的 SSE 形状**，不联网。
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/core/db/models.dart';
import 'package:lightnote/features/ai/data/deepseek_client.dart';
import 'package:lightnote/features/ai/domain/tool_types.dart';

/// 假 HTTP 适配器：把预置的 SSE 文本当成响应体，并记下最后一次请求。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.sse);

  final String sse;

  RequestOptions? lastRequest;

  /// 最后一次请求的 JSON body（解析好的）。
  Map<String, dynamic> get lastBody =>
      jsonDecode(lastRequest!.data as String) as Map<String, dynamic>;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    return ResponseBody(
      Stream.value(Uint8List.fromList(utf8.encode(sse))),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 把若干 JSON 块拼成 SSE 文本（每块一行 `data:`，最后补 `[DONE]`）。
String sse(List<String> chunks, {bool done = true}) {
  final b = StringBuffer();
  for (final c in chunks) {
    b.writeln('data: $c');
    b.writeln();
  }
  if (done) b.writeln('data: [DONE]');
  return b.toString();
}

DeepSeekClient _clientWith(_FakeAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.deepseek.com'))
    ..httpClientAdapter = adapter;
  return DeepSeekClient(dio: dio)..setApiKey('sk-test');
}

void main() {
  group('streamAgent：工具定义与消息列表', () {
    test('请求体带上了 tools / tool_choice，且消息列表按序', () async {
      final adapter = _FakeAdapter(sse([
        '{"choices":[{"delta":{"content":"好"}}]}',
      ]));
      final client = _clientWith(adapter);

      await client
          .streamAgent(
            systemPrompt: '你是助手',
            messages: [
              AgentMessage.user('列出我的笔记库'),
              AgentMessage.assistant('', toolCalls: const [
                ToolCall(id: 'c1', name: 'listNotebooks', arguments: '{}'),
              ]),
              AgentMessage.tool(toolCallId: 'c1', content: '{"ok":true}'),
            ],
            tools: const [
              ToolSpec(
                name: 'listNotebooks',
                description: '列出全部笔记库。没有参数。',
                parameters: {'type': 'object', 'properties': <String, dynamic>{}},
              ),
            ],
          )
          .toList();

      final body = adapter.lastBody;
      expect(body['stream'], isTrue);
      expect(body['tool_choice'], 'auto');

      final tools = body['tools'] as List;
      expect(tools.length, 1);
      expect((tools.first as Map)['type'], 'function');
      final fn = (tools.first as Map)['function'] as Map;
      expect(fn['name'], 'listNotebooks');
      expect(fn['description'], contains('列出全部笔记库'));
      expect(fn['parameters'], isA<Map>());

      final messages = (body['messages'] as List).cast<Map>();
      expect(messages.first['role'], 'system');
      expect(messages.first['content'], '你是助手');
      expect(messages[1]['role'], 'user');
      expect(messages[2]['role'], 'assistant');
      expect((messages[2]['tool_calls'] as List).length, 1);
      expect(messages[3]['role'], 'tool');
      expect(messages[3]['tool_call_id'], 'c1',
          reason: 'role:tool 必须带 tool_call_id，否则协议拒绝整条请求');
    });

    test('没有工具时不发 tools / tool_choice（别凭空加字段）', () async {
      final adapter = _FakeAdapter(sse([
        '{"choices":[{"delta":{"content":"好"}}]}',
      ]));
      await _clientWith(adapter)
          .streamAgent(systemPrompt: 's', messages: [AgentMessage.user('u')])
          .toList();

      expect(adapter.lastBody.containsKey('tools'), isFalse);
      expect(adapter.lastBody.containsKey('tool_choice'), isFalse);
    });
  });

  group('流式 tool_calls 分片拼接（最容易写错的地方）', () {
    test('三段分片的 arguments 能拼成完整 JSON', () async {
      final adapter = _FakeAdapter(sse([
        // 第一块：带 id 与 name，arguments 为空
        '{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1",'
            '"type":"function","function":{"name":"listNotes","arguments":""}}]}}]}',
        // 后面几块：只有 arguments 的片段
        '{"choices":[{"delta":{"tool_calls":[{"index":0,'
            '"function":{"arguments":"{\\"notebookId\\":"}}]}}]}',
        '{"choices":[{"delta":{"tool_calls":[{"index":0,'
            '"function":{"arguments":"\\"nb-1\\",\\"limit\\":5}"}}]}}]}',
        '{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}',
      ]));
      final events = await _clientWith(adapter)
          .streamAgent(
            systemPrompt: 's',
            messages: [AgentMessage.user('u')],
            tools: const [ToolSpec(name: 'listNotes', description: 'd')],
          )
          .toList();

      expect(events.whereType<AiError>(), isEmpty,
          reason: '"只提工具、没有正文"是正常情况，不能报 empty_content');

      final done = events.whereType<AiDone>().single;
      expect(done.toolCalls.length, 1);
      expect(done.toolCalls.single.id, 'call_1');
      expect(done.toolCalls.single.name, 'listNotes');
      expect(done.toolCalls.single.arguments, '{"notebookId":"nb-1","limit":5}');
      expect(done.toolCalls.single.argsMap, {'notebookId': 'nb-1', 'limit': 5});
      expect(done.isToolOnly, isTrue);
      expect(done.fullText, isEmpty);
    });

    test('同一轮里多个工具调用按 index 排序，不串位', () async {
      final adapter = _FakeAdapter(sse([
        '{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"b","function":{"name":"toolB","arguments":"{}"}}]}}]}',
        '{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"toolA","arguments":"{}"}}]}}]}',
        '{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}',
      ]));
      final done = (await _clientWith(adapter)
              .streamAgent(
                systemPrompt: 's',
                messages: [AgentMessage.user('u')],
                tools: const [
                  ToolSpec(name: 'toolA', description: 'a'),
                  ToolSpec(name: 'toolB', description: 'b'),
                ],
              )
              .toList())
          .whereType<AiDone>()
          .single;

      expect(done.toolCalls.map((c) => c.name), ['toolA', 'toolB'],
          reason: 'index 乱序到达时必须按 index 排回来');
      expect(done.toolCalls.map((c) => c.id), ['a', 'b']);
    });

    test('没名字的残片被丢掉（宁可让模型重来，也不执行一个空名字的工具）', () async {
      final adapter = _FakeAdapter(sse([
        '{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{}"}}]}}]}',
        '{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}',
      ]));
      final done = (await _clientWith(adapter)
              .streamAgent(
                systemPrompt: 's',
                messages: [AgentMessage.user('u')],
                tools: const [ToolSpec(name: 'x', description: 'x')],
              )
              .toList())
          .whereType<AiDone>()
          .single;

      expect(done.toolCalls, isEmpty);
    });

    test('正文 + 工具调用并存时，两者都要拿到', () async {
      final adapter = _FakeAdapter(sse([
        '{"choices":[{"delta":{"content":"我先查一下。"}}]}',
        '{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"searchNotes","arguments":"{\\"query\\":\\"间隔重复\\"}"}}]}}]}',
        '{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}',
      ]));
      final done = (await _clientWith(adapter)
              .streamAgent(
                systemPrompt: 's',
                messages: [AgentMessage.user('u')],
                tools: const [ToolSpec(name: 'searchNotes', description: 'd')],
              )
              .toList())
          .whereType<AiDone>()
          .single;

      expect(done.fullText, '我先查一下。');
      expect(done.toolCalls.single.name, 'searchNotes');
      expect(done.isToolOnly, isFalse);
    });

    test('坏 JSON 的 arguments：不抛错，argsMap 返回 null 交给调用方处理', () async {
      final adapter = _FakeAdapter(sse([
        '{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"x","arguments":"{不是 json"}}]}}]}',
        '{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}',
      ]));
      final done = (await _clientWith(adapter)
              .streamAgent(
                systemPrompt: 's',
                messages: [AgentMessage.user('u')],
                tools: const [ToolSpec(name: 'x', description: 'x')],
              )
              .toList())
          .whereType<AiDone>()
          .single;

      expect(done.toolCalls.single.arguments, '{不是 json');
      expect(done.toolCalls.single.argsMap, isNull);
    });
  });

  group('回归：抽出 _runStream 之后普通对话不受影响', () {
    test('streamChat 仍然拼出完整正文、拿到用量', () async {
      final adapter = _FakeAdapter(sse([
        '{"choices":[{"delta":{"content":"你好"}}]}',
        '{"choices":[{"delta":{"content":"，世界"}}]}',
        '{"choices":[{"delta":{},"finish_reason":"stop"}]}',
        '{"usage":{"prompt_tokens":120,"completion_tokens":8,"prompt_cache_hit_tokens":100}}',
      ]));
      final events = await _clientWith(adapter)
          .streamChat(systemPrompt: 's', userPrompt: 'u')
          .toList();

      expect(events.whereType<AiError>(), isEmpty);
      final chunks = events.whereType<AiChunk>().map((e) => e.text).join();
      expect(chunks, '你好，世界');
      final done = events.whereType<AiDone>().single;
      expect(done.fullText, '你好，世界');
      expect(done.promptTokens, 120);
      expect(done.completionTokens, 8);
      expect(done.toolCalls, isEmpty);
    });

    test('真·空返回仍然报错（不能因为加了工具就放过这个保护）', () async {
      // 没有 [DONE]，也没有任何正文/工具 —— 模拟服务端异常
      final adapter = _FakeAdapter(sse([
        '{"choices":[{"delta":{}}]}',
      ], done: false));
      final events = await _clientWith(adapter)
          .streamChat(systemPrompt: 's', userPrompt: 'u')
          .toList();

      expect(events.whereType<AiError>().single.code, 'empty_content');
    });

    test('流中间的错误被映射出来', () async {
      final adapter = _FakeAdapter(sse([
        '{"error":{"message":"rate limit"}}',
      ]));
      final events = await _clientWith(adapter)
          .streamChat(systemPrompt: 's', userPrompt: 'u')
          .toList();

      expect(events.whereType<AiError>(), isNotEmpty);
    });
  });

  group('ToolResult 的统一形状', () {
    test('成功 → ok:true + data', () {
      expect(jsonDecode(ToolResult.success({'id': '1'}).encode()),
          {'ok': true, 'data': {'id': '1'}});
    });

    test('失败 → ok:false + error（失败也是一种"结果"，别让整轮崩掉）', () {
      expect(jsonDecode(ToolResult.failure('笔记不存在').encode()),
          {'ok': false, 'error': '笔记不存在'});
    });
  });
}
