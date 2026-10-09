import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/db/models.dart';
import 'deepseek_config.dart';

/// DeepSeek 客户端：只负责「发请求 + 解析 SSE + 映射错误」。
///
/// 不涉及业务语义（摘要/卡片），那些在 AiRepository 里。
/// UI 不直接使用本类。
class DeepSeekClient {
  DeepSeekClient({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: DeepSeekConfig.baseUrl,
              connectTimeout: DeepSeekConfig.connectTimeout,
              receiveTimeout: DeepSeekConfig.readTimeout,
            ));

  final Dio _dio;

  String? _apiKey;

  bool get hasApiKey => _apiKey != null && _apiKey!.isNotEmpty;

  /// 设置密钥。只在内存中持有，持久化由 SecureStore 负责。
  void setApiKey(String? key) {
    _apiKey = (key == null || key.trim().isEmpty) ? null : key.trim();
  }

  DeepSeekClient withApiKey(String? key) {
    setApiKey(key);
    return this;
  }

  /// 流式对话。
  ///
  /// 产出 [AiEvent] 序列：若干 [AiChunk] / [AiReasoning]，最后以 [AiDone]
  /// 或 [AiError] 收尾。调用方用 `await for` 消费。
  Stream<AiEvent> streamChat({
    required String systemPrompt,
    required String userPrompt,
    String model = DeepSeekConfig.modelFlash,
    bool thinking = false,
    String reasoningEffort = 'high',
    bool jsonMode = false,
    int? maxTokens,
    double? temperature,
    CancelToken? cancelToken,
  }) async* {
    if (!hasApiKey) {
      yield const AiError(
        '未配置 API Key，请到「设置」中填写 DeepSeek API Key。',
        code: 'no_api_key',
      );
      return;
    }

    final body = <String, dynamic>{
      'model': model,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userPrompt},
      ],
      'stream': true,
      // 思考模式开关。注意：DeepSeek 思考模式默认开启，
      // 所以轻量任务必须显式 disabled，否则会白白多花推理成本。
      'thinking': {'type': thinking ? 'enabled' : 'disabled'},
      if (maxTokens != null) 'max_tokens': maxTokens,
    };

    if (thinking) {
      body['reasoning_effort'] = reasoningEffort;
      // 思考模式不支持 temperature / presence_penalty / frequency_penalty：
      // 传了不报错但也不生效，所以干脆不传，避免误导。
    } else if (temperature != null) {
      body['temperature'] = temperature;
    }

    if (jsonMode) {
      // JSON Output 要求 prompt 中出现 "json" 字样并给出样例，见 prompts.dart
      body['response_format'] = {'type': 'json_object'};
    }

    final stopwatch = Stopwatch()..start();
    final buffer = StringBuffer();
    final reasoningBuffer = StringBuffer();
    var promptTokens = 0;
    var cachedTokens = 0;
    var completionTokens = 0;
    var finished = false;

    try {
      final response = await _dio.post<ResponseBody>(
        DeepSeekConfig.chatPath,
        data: jsonEncode(body),
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            'Authorization': 'Bearer $_apiKey',
            'Content-Type': 'application/json',
            'Accept': 'text/event-stream',
          },
          // 自己判断状态码，才能把 401/402/429 的响应体读出来给用户看
          validateStatus: (_) => true,
        ),
      );

      final status = response.statusCode ?? 0;
      final stream = response.data?.stream;
      if (stream == null) {
        yield const AiError('服务端未返回数据流', code: 'empty_stream');
        return;
      }

      // 逐行解析 SSE。
      // 用 `utf8.decoder`（dart:convert 的顶层 Utf8Decoder 实例），
      // 而不是 `Utf8Decoder(...).decoder` —— 后者不存在，会报 undefined_getter。
      final lines = stream
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter());

      await for (final line in lines) {
        if (line.isEmpty || line.startsWith(':')) continue;
        if (!line.startsWith('data:')) continue;

        final payload = line.substring(5).trim();
        // SSE 流结束标记
        if (payload == '[DONE]') {
          finished = true;
          break;
        }

        Map<String, dynamic> json;
        try {
          json = jsonDecode(payload) as Map<String, dynamic>;
        } catch (_) {
          continue; // 半行/心跳，跳过
        }

        // 错误可能在流中间以 data 形式返回
        if (json['error'] != null) {
          final err = json['error'];
          final msg = err is Map ? (err['message'] ?? err).toString() : err.toString();
          yield AiError(_humanize(msg, status), code: _codeOf(status));
          return;
        }

        final choices = json['choices'];
        if (choices is! List || choices.isEmpty) {
          // usage 可能只出现在最后一块
          final u = json['usage'];
          if (u is Map) {
            final parsed = _parseUsage(u);
            promptTokens = parsed.promptTokens;
            cachedTokens = parsed.cachedPromptTokens;
            completionTokens = parsed.completionTokens;
          }
          continue;
        }

        final delta = (choices.first as Map)['delta'];
        if (delta is Map) {
          final content = delta['content'];
          if (content is String && content.isNotEmpty) {
            buffer.write(content);
            yield AiChunk(content);
          }
          // 思考模式下思维链与正文同级返回，字段名 reasoning_content
          final reasoning = delta['reasoning_content'];
          if (reasoning is String && reasoning.isNotEmpty) {
            reasoningBuffer.write(reasoning);
            yield AiReasoning(reasoning);
          }
        }

        final u = json['usage'];
        if (u is Map) {
          final parsed = _parseUsage(u);
          promptTokens = parsed.promptTokens;
          cachedTokens = parsed.cachedPromptTokens;
          completionTokens = parsed.completionTokens;
        }
      }

      stopwatch.stop();

      // 空正文 + 未收到 [DONE]：多半是服务端异常或 JSON 模式偶发空返回
      if (buffer.isEmpty && !finished) {
        yield const AiError('服务端返回了空内容，请重试。', code: 'empty_content');
        return;
      }

      final usage = TokenUsage(
        promptTokens: promptTokens,
        cachedPromptTokens: cachedTokens,
        completionTokens: completionTokens,
      );

      yield AiDone(
        fullText: buffer.toString(),
        promptTokens: usage.promptTokens,
        completionTokens: usage.completionTokens,
        costCents: DeepSeekPricing.estimateCostCents(model: model, usage: usage),
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } on DioException catch (e) {
      yield _mapDioError(e);
    } catch (e) {
      yield AiError('请求失败：$e', code: 'unknown');
    }
  }

  /// 非流式调用，用于 JSON Output 类任务。
  ///
  /// 返回 (正文, 用量)。失败抛 [DeepSeekException]。
  Future<(String, TokenUsage)> completeJson({
    required String systemPrompt,
    required String userPrompt,
    String model = DeepSeekConfig.modelFlash,
    bool thinking = false,
    String reasoningEffort = 'high',
    int maxTokens = 4096,
    CancelToken? cancelToken,
  }) async {
    if (!hasApiKey) {
      throw const DeepSeekException('未配置 API Key', code: 'no_api_key');
    }

    final body = <String, dynamic>{
      'model': model,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userPrompt},
      ],
      'stream': false,
      'thinking': {'type': thinking ? 'enabled' : 'disabled'},
      // JSON 可能被中途截断，max_tokens 必须留足
      'max_tokens': maxTokens,
      // JSON Output：官方要求 prompt 含 "json" 字样 + 输出样例
      'response_format': {'type': 'json_object'},
    };
    if (thinking) {
      body['reasoning_effort'] = reasoningEffort;
    }

    try {
      final res = await _dio.post<Map<String, dynamic>>(
        DeepSeekConfig.chatPath,
        data: jsonEncode(body),
        cancelToken: cancelToken,
        options: Options(
          headers: {
            'Authorization': 'Bearer $_apiKey',
            'Content-Type': 'application/json',
          },
          validateStatus: (_) => true,
        ),
      );

      final status = res.statusCode ?? 0;
      final data = res.data;

      if (status < 200 || status >= 300) {
        final msg = data?['error'] is Map
            ? (data!['error']['message'] ?? '').toString()
            : 'HTTP $status';
        throw DeepSeekException(_humanize(msg, status), code: _codeOf(status));
      }

      final choices = data?['choices'];
      if (choices is! List || choices.isEmpty) {
        throw const DeepSeekException('响应中没有 choices', code: 'bad_response');
      }

      final content =
          ((choices.first as Map)['message'] as Map?)?['content']?.toString() ?? '';

      final usage = data?['usage'] is Map
          ? _parseUsage(data!['usage'] as Map)
          : TokenUsage.zero;

      // 官方承认 JSON Output 有概率返回空 content —— 这里明确报错，
      // 由上层决定重试还是降级，不要在这里静默返回空串。
      if (content.trim().isEmpty) {
        throw const DeepSeekException(
          '模型返回了空的 JSON 内容（DeepSeek JSON Output 的已知偶发问题），请重试。',
          code: 'json_empty',
        );
      }

      return (content, usage);
    } on DioException catch (e) {
      final mapped = _mapDioError(e);
      throw DeepSeekException(
        mapped.message,
        code: mapped.code,
        isRetryable: mapped.isRetryable,
      );
    }
  }

  static TokenUsage _parseUsage(Map usage) {
    int asInt(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
    return TokenUsage(
      // 兼容 prompt_tokens / input_tokens 两种命名
      promptTokens: asInt(usage['prompt_tokens'] ?? usage['input_tokens']),
      cachedPromptTokens: asInt(
        usage['prompt_cache_hit_tokens'] ??
            usage['cache_read_input_tokens'] ??
            usage['prompt_tokens_details']?['cached_tokens'],
      ),
      completionTokens:
          asInt(usage['completion_tokens'] ?? usage['output_tokens']),
    );
  }

  static AiError _mapDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
        return const AiError('连接 DeepSeek 超时，请检查网络。',
            code: 'timeout', isRetryable: true);
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        // transformTimeout 是 Dio 5.x 新增的枚举值：响应体转换阶段超时。
        // switch 必须覆盖全部枚举值，否则 Dart 会报 non_exhaustive_switch。
        return const AiError('等待响应超时。长笔记建议缩短内容或改用 flash 模型。',
            code: 'timeout', isRetryable: true);
      case DioExceptionType.cancel:
        return const AiError('已取消', code: 'cancelled');
      case DioExceptionType.connectionError:
        return const AiError('无法连接网络，请检查网络或代理设置。',
            code: 'network', isRetryable: true);
      case DioExceptionType.badCertificate:
        return const AiError('证书校验失败。', code: 'bad_cert');
      case DioExceptionType.badResponse:
        final status = e.response?.statusCode ?? 0;
        final body = e.response?.data;
        String msg = 'HTTP $status';
        if (body is Map && body['error'] is Map) {
          msg = (body['error']['message'] ?? msg).toString();
        }
        return AiError(_humanize(msg, status),
            code: _codeOf(status), isRetryable: status == 429 || status >= 500);
      case DioExceptionType.unknown:
        return AiError('请求异常：${e.message ?? e.error}', code: 'unknown');
    }
  }

  static String _codeOf(int status) => switch (status) {
        401 => 'unauthorized',
        402 => 'insufficient_balance',
        422 => 'invalid_params',
        429 => 'rate_limited',
        >= 500 => 'server_error',
        _ => 'http_$status',
      };

  static String _humanize(String message, int status) => switch (status) {
        401 => 'API Key 无效或已过期，请到「设置」重新填写。',
        402 => '账户余额不足，请到 DeepSeek 平台充值。',
        422 => '请求参数不合法：$message',
        429 => '请求过于频繁，请稍后重试。',
        >= 500 => 'DeepSeek 服务暂时不可用（$status），请稍后重试。',
        _ => message,
      };
}

class DeepSeekException implements Exception {
  const DeepSeekException(this.message, {this.code, this.isRetryable = false});

  final String message;
  final String? code;
  final bool isRetryable;

  @override
  String toString() => message;
}
