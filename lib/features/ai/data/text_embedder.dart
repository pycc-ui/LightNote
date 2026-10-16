import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bert_tokenizer/bert_tokenizer.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path_provider/path_provider.dart';

/// **把一段中文算成向量**（语义检索的地基）。
///
/// 模型是 `bge-small-zh-v1.5` 的 int8 版（22.8MB），分词用纯 Dart 的
/// `bert_tokenizer`（BGE 就是 BERT 那套 WordPiece）。两者都打进包，
/// **不联网**——这是"笔记不出本地"这条承诺的技术前提。
///
/// ## 为什么用 `onnxruntime`（FFI）而不是 `flutter_onnxruntime`（MethodChannel）
///
/// 前者是 FFI、**自带各 ABI 的 `libonnxruntime.so`**：
///   · 不需要构建时联网取件（我们踩过 build hook 下不来原生库的坑）；
///   · **同一份代码在本机（Linux）就能跑测试** —— MethodChannel 那种在
///     `flutter test` 里注册不了原生侧，模型好不好用只能等真机才知道。
///
/// ## 计算全部在**一个常驻后台 isolate** 里跑
///
/// 单条 333 字的嵌入实测 **74ms**（桌面 JIT；手机上更慢）。索引一篇 5KB 的笔记
/// 就是十来片、一秒上下的纯 CPU。放在主 isolate 上等于每 74ms 卡一帧 —— 而索引
/// 恰恰要在"用户正在编辑/滚动"的时候后台补。所以：
///
/// ```
/// 主 isolate                          后台 isolate（常驻）
///   ├ 把 asset 落成真实文件（rootBundle 只能在根 isolate）
///   ├ 建 worker ─────────────────────▶ 加载模型（**只加载一次**）
///   └ 发一批文本 ─────────────────────▶ 逐条算 → 一批 Float32 向量
/// ```
///
/// 顺带解决好第二件事：**模型只在一处加载**。如果查询在主 isolate 算、索引在
/// worker 里算，进程里就会有两份 20MB+ 的会话。现在两条路都走 worker。
///
/// ## 三段流水线，每段都有坑
///
/// 1. **分词**：`[CLS] … [SEP]` + 补齐到 [maxTokens]，并给出 attention mask。
///    模型窗口只有 512 token（中文约 500 字），超了要截断 —— 截断由分词器做，
///    但**调用方要知道自己传的东西有多长**（所以整篇笔记不能直接丢进来，
///    要按片/窗口切；见 `RagIndexer`）。
/// 2. **推理**：拿 `last_hidden_state`（形状 `[1, seq, 512]`）。
/// 3. **池化 + 归一化**：按 mask 做**平均池化**（把 padding 排除掉），再 L2 归一化。
///    归一化之后**余弦相似度就等于点积**，检索那段可以少算一次开方。
class TextEmbedder {
  TextEmbedder._();

  static TextEmbedder? _instance;

  /// 单例：worker 与模型都只有一份。
  static TextEmbedder get instance => _instance ??= TextEmbedder._();

  /// 模型窗口。BGE-small 是 512 token，中文约等于 500 字 ——
  /// **超过的部分会被截断**，所以调用方要自己按这个粒度切（别整篇丢进来）。
  static const maxTokens = 512;

  /// 向量维度（bge-small-zh 的 hidden size）。
  static const dim = 512;

  /// 送进分词器前先按**字符**截断的上限。
  ///
  /// 中文 1 字 ≈ 1 token，而窗口是 512 token —— 留点余量取 480 字。
  /// 截在第 480 字意味着"一篇长笔记只有前 480 字能进这个向量"，
  /// 所以**调用方要按片/窗口切**（见 `RagIndexer`），不要整篇丢进来。
  static const maxInputChars = 480;

  /// 向量所属的模型标识，**存进 `note_vectors.model`**。
  ///
  /// 换模型（或改分词方式）时把它一起改掉：旧向量因为对不上这个字符串而
  /// 自然失效，不需要写迁移。**这也是分词方式改变时的唯一信号** —— 如果只改
  /// [splitCjk] 而不动这里，新旧向量会混在一起（长度一样、都是 512 维，
  /// 看字节分辨不出来）。
  static const modelId = 'bge-small-zh-v1.5-int8.v1';

  /// 资源在仓库/包里的路径（换模型只改这两行 + [modelId]）。
  static const _vocabAsset = 'assets/models/bge-small-zh-v1.5/vocab.txt';
  static const _modelAsset = 'assets/models/bge-small-zh-v1.5/model_int8.onnx';

  /// 把 asset 落成真实文件后的路径（`null` = 还没落过）。
  ///
  /// ONNX 与分词器都只吃文件路径，吃不了 Flutter 的 asset bundle。
  (String model, String vocab)? _paths;

  Isolate? _worker;
  SendPort? _toWorker;
  final _pending = <int, Completer<List<Float32List>>>{};
  int _nextId = 0;
  Future<void>? _spawning;

  /// worker 把「一批结果」发回这里的 port。
  ///
  /// 和 [init] 里那个 handshake 是两个 port：那条只管"见面递地址"（用完就关），
  /// 这条管"交货"（活到进程结束）。合成一个也能跑，但握手那块就会一直挂着。
  final _replyPort = ReceivePort();

  /// worker 已就绪（模型已加载）——**只用于测试断言**，业务不要依赖它。
  bool get isReady => _toWorker != null;

  /// 准备好资源与 worker。**幂等**，并发调用只会真正建一次。
  Future<void> init() {
    if (_toWorker != null) return Future.value();
    return _spawning ??= _spawn();
  }

  Future<void> _spawn() async {
    // 1. 资源落地（rootBundle 只能在根 isolate 读，所以放在建 worker 之前）
    final vocab = await _materializeAsset(_vocabAsset);
    final model = await _materializeAsset(_modelAsset);
    _paths = (model.path, vocab.path);

    // 2. 建 worker，等它把 SendPort 递回来
    final handshake = ReceivePort();
    final worker = await Isolate.spawn(
      _embedWorkerMain,
      handshake.sendPort,
      debugName: 'text-embedder',
    );
    _replyPort.listen(_onWorkerMessage);

    final ready = Completer<void>();
    handshake.listen((msg) {
      if (msg is SendPort) {
        _toWorker = msg;
        if (!ready.isCompleted) ready.complete();
        handshake.close();
      } else if (msg is List && msg.isNotEmpty && msg[0] == 'fatal') {
        // 模型加载失败：把错误原样抛给第一个等结果的调用方，别让它干等
        if (!ready.isCompleted) {
          ready.completeError(StateError('嵌入 worker 起不来：${msg[1]}'));
        }
      }
    });
    _worker = worker;
    await ready.future;
  }

  void _onWorkerMessage(dynamic msg) {
    if (msg is! List || msg.length < 3) return;
    final id = msg[0] as int;
    final c = _pending.remove(id);
    if (c == null) return;
    final err = msg[2] as String?;
    if (err != null) {
      c.completeError(StateError('嵌入失败：$err'));
      return;
    }
    c.complete((msg[1] as List).cast<Float32List>());
  }

  /// 把打进包的资源落成一个**真实文件**。
  ///
  /// 只拷一次；文件在就直接用。测试里（本机跑）直接读仓库里的路径，少一层拷贝。
  Future<File> _materializeAsset(String assetKey) async {
    final direct = File(assetKey);
    if (direct.existsSync()) return direct;

    final dir = await getTemporaryDirectory();
    final out = File('${dir.path}/${assetKey.split('/').last}');
    if (!out.existsSync()) {
      final data = await rootBundle.load(assetKey);
      await out.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    return out;
  }

  /// 中文按字拆开（BERT 官方的 `tokenize_chinese_chars` 就是这件事）。
  ///
  /// ⚠️ **不做这一步，向量就是错的**：`bert_tokenizer` 会把「会议记录」当成**一个词**，
  /// 再用 WordPiece 切成 `会 / ##议 / ##记 / ##录` —— 带 `##` 的是"词内续接"的 id，
  /// 与 BERT 词表里独立的 `议` / `记` **不是同一个 token**。
  /// 实测过：不拆时"会议记录"与"牛肉面"的相似度（0.689）反而高于与真正相关的
  /// 「参会/目标」那篇（0.680）—— 完全分不出语义。拆开后与 Python/HF 的结果一致。
  static String splitCjk(String text) => text.replaceAllMapped(
        RegExp(r'([\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF])'),
        (m) => ' ${m[1]} ',
      );

  /// 一段文本 → 512 维单位向量（浮点形式，给"比较相似度"用）。
  ///
  /// 内部走 [embedBatch]，别在循环里一条条调 —— 那样每条都要过一次 isolate 往返。
  Future<List<double>> embed(String text) async {
    final out = await embedBatch([text]);
    return out.first;
  }

  /// 一批文本 → 一批向量（**Float32、已 L2 归一化**）。
  ///
  /// 返回的 `Float32List` 正是 `note_vectors.vec` 要存的字节形状，调用方不必再转。
  /// 一批的数量由调用方控（见 `RagIndexer`）：批太大，中途进程被杀就白算了。
  Future<List<Float32List>> embedBatch(List<String> texts) async {
    if (texts.isEmpty) return const [];
    await init();
    final id = _nextId++;
    final c = Completer<List<Float32List>>();
    _pending[id] = c;
    _toWorker!.send([id, texts, _replyPort.sendPort, _paths!.$1, _paths!.$2]);
    return c.future;
  }

  /// L2 归一化：归一化之后**余弦相似度 = 点积**（检索时省一次开方）。
  static List<double> normalize(List<double> v) {
    var sum = 0.0;
    for (final x in v) {
      sum += x * x;
    }
    final n = math.sqrt(sum);
    if (n == 0) return v;
    return [for (final x in v) x / n];
  }

  /// 余弦相似度。两边都已归一化时就是点积。
  static double cosine(List<double> a, List<double> b) {
    var dot = 0.0;
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      dot += a[i] * b[i];
    }
    return dot;
  }

  /// 关掉 worker 并释放模型。测试收尾用；App 里让它常驻（检索是高频动作）。
  Future<void> dispose() async {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('嵌入器已关闭'));
    }
    _pending.clear();
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    _toWorker = null;
    _paths = null;
    _spawning = null;
  }
}

// ============================================================================
// 后台 isolate 侧
// ============================================================================

/// worker 主循环：加载一次模型，然后按请求逐批算向量。
///
/// 协议（都用最朴素的 `List`，避免自定义类型在 isolate 间传不过去）：
///   · 父 → 子：`[int id, List<String> texts, SendPort reply, String modelPath, String vocabPath]`
///   · 子 → 父：`[int id, List<Float32List>? vecs, String? error]`
void _embedWorkerMain(SendPort handshake) {
  final inbound = ReceivePort();
  handshake.send(inbound.sendPort);

  _EmbedCore? core;
  inbound.listen((msg) {
    final m = msg as List;
    final id = m[0] as int;
    final texts = (m[1] as List).cast<String>();
    final reply = m[2] as SendPort;
    try {
      core ??= _EmbedCore(
        modelPath: m[3] as String,
        vocabPath: m[4] as String,
      );
      final vecs = <Float32List>[for (final t in texts) core!.embed(t)];
      reply.send([id, vecs, null]);
    } catch (e, st) {
      // 单条失败不干掉 worker：把错误发回去，调用方那条自己失败
      reply.send([id, null, '$e\n$st']);
    }
  });
}

/// 真正碰 ONNX 的那一层。**只在 worker isolate 里 new**。
class _EmbedCore {
  _EmbedCore({required String modelPath, required String vocabPath}) {
    // `bert_tokenizer` 只提供 fromStringContent（没有 fromFile），词表自己读。
    // 21K 行的词表读一次几毫秒，worker 生命周期里只做一次。
    _tokenizer = BertTokenizer.fromStringContent(
      File(vocabPath).readAsStringSync(),
      toLowerCase: true,
    );
    _session = OrtSession.fromFile(File(modelPath), OrtSessionOptions());
  }

  late final BertTokenizer _tokenizer;
  late final OrtSession _session;

  /// 一段文本 → 512 维单位向量（Float32，存库/比较都用它）。
  Float32List embed(String text) {
    // **必须先按字符截断再分词**：不然纯 Dart 的 WordPiece 要把几万字先切一遍
    // （实测 1.2 万字要几十秒）。
    final clipped = text.length <= TextEmbedder.maxInputChars
        ? text
        : text.substring(0, TextEmbedder.maxInputChars);
    final ids = _tokenizer.prepareNerInput(
      TextEmbedder.splitCjk(clipped),
      TextEmbedder.maxTokens,
    );

    // 三个输入张量：形状都是 [1, seq]（batch=1），类型 int64
    final seq = ids.inputIds.length;
    final inputIds = OrtValueTensor.createTensorWithDataList(
        Int64List.fromList(ids.inputIds), [1, seq]);
    final mask = OrtValueTensor.createTensorWithDataList(
        Int64List.fromList(ids.inputMask), [1, seq]);
    final types = OrtValueTensor.createTensorWithDataList(
        Int64List.fromList(ids.segmentIds), [1, seq]);

    final runOptions = OrtRunOptions();
    // worker isolate 里没有 Flutter 的事件循环压力，同步跑反而少一层回调；
    // 但 runAsync 在 isolate 里同样可用，这里沿用它以免两处写法分叉。
    final outputs = _session.run(runOptions, {
      'input_ids': inputIds,
      'attention_mask': mask,
      'token_type_ids': types,
    });

    // 输出形状 [1, seq, 512] → `value` 是三层嵌套 List
    final hidden = (outputs.first?.value as List<List<List<double>>>?)?.first;
    inputIds.release();
    mask.release();
    types.release();
    runOptions.release();
    for (final o in outputs) {
      o?.release();
    }
    if (hidden == null || hidden.isEmpty) {
      throw StateError('模型没有返回 last_hidden_state');
    }

    // 按 attention mask 做**平均池化**（把 padding 排除掉），再归一化
    final dims = hidden.first.length;
    final vec = Float32List(dims);
    var counted = 0;
    for (var t = 0; t < hidden.length; t++) {
      if (t < ids.inputMask.length && ids.inputMask[t] == 0) continue;
      counted++;
      final row = hidden[t];
      for (var d = 0; d < dims; d++) {
        vec[d] += row[d];
      }
    }
    if (counted > 0) {
      for (var d = 0; d < dims; d++) {
        vec[d] /= counted;
      }
    }
    return _l2(vec);
  }

  /// 就地 L2 归一化（Float32 版；`TextEmbedder.normalize` 是给 `List<double>` 的）。
  static Float32List _l2(Float32List v) {
    var sum = 0.0;
    for (final x in v) {
      sum += x * x;
    }
    final n = math.sqrt(sum);
    if (n == 0) return v;
    for (var i = 0; i < v.length; i++) {
      v[i] = v[i] / n;
    }
    return v;
  }
}
