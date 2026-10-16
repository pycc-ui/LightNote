// 语义检索的地基：**中文句子能不能算出有意义的向量**。
//
// 这个测试跑在本机（Linux）上，不需要真机 —— 模型与分词器都是跨平台的。
// 它要回答三个问题：
//   1. 模型加载得起来吗（23.9MB 的 int8 ONNX + 21128 词的词表）
//   2. 出来的向量"像不像人话"：**意思相近的句子应该更近**
//   3. 探针里当场抓到的那个召回漏洞（字面搜不到"会议"），语义能补上吗
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/features/ai/data/text_embedder.dart';

import 'ort_gate.dart';

void main() {
  final embedder = TextEmbedder.instance;

  setUpAll(() async {
    await embedder.init();
  });
  tearDownAll(() => embedder.dispose());

  test('★ 模型能加载，输出 512 维单位向量', () async {
    final v = await embedder.embed('会议记录');

    expect(v, hasLength(TextEmbedder.dim));
    // 归一化过了：模长应该是 1
    var sum = 0.0;
    for (final x in v) {
      sum += x * x;
    }
    expect(sum, closeTo(1.0, 1e-6), reason: '归一化之后余弦=点积，检索那段才省事');
    expect(v.any((x) => x != 0), isTrue);
  }, skip: ortSkipReason);

  test('★★ 意思相近的更近：这是"语义检索"能成立的前提', () async {
    const a = '本季度把项目A 的试点推到 3 个部门，6 月底给出验收报告。';
    const b = '试点范围先定 2 个部门，第三个等第一轮反馈再定。';
    const c = '今天中午吃了牛肉面，还加了两个卤蛋。';

    final va = await embedder.embed(a);
    final vb = await embedder.embed(b);
    final vc = await embedder.embed(c);

    final ab = TextEmbedder.cosine(va, vb);
    final ac = TextEmbedder.cosine(va, vc);

    expect(ab, greaterThan(ac),
        reason: '同主题（项目试点）应当比"吃牛肉面"更近（ab=$ab, ac=$ac）');
    expect(ab, greaterThan(0.4), reason: '同主题的相似度不该低得离谱（实际 $ab）');
  }, skip: ortSkipReason);

  test('★★ 补上关键词搜不到的那种：问"会议"能命中"启动会"', () async {
    // 探针里实测：`search_notes('会议')` 返回 0 条 ——
    // 标题是「周一 · 项目A 启动会」、正文只有「参会」，字面没有"会议"两个字。
    const query = '会议记录';
    const hit = '# 参会\n张伟、李娜、王强、我\n\n# 目标\n本季度把项目A 的试点推到 3 个部门。';
    const miss = '今天中午吃了牛肉面，还加了两个卤蛋。\n\n下午去理了个发。';

    final vq = await embedder.embed(query);
    final vh = await embedder.embed(hit);
    final vm = await embedder.embed(miss);

    final toHit = TextEmbedder.cosine(vq, vh);
    final toMiss = TextEmbedder.cosine(vq, vm);

    expect(toHit, greaterThan(toMiss),
        reason: '"会议记录" vs "参会/目标" 应当胜过 vs "牛肉面"（$toHit vs $toMiss）');
  }, skip: ortSkipReason);

  test('同义改写也能靠近（关键词那一路做不到的）', () async {
    final v1 = await embedder.embed('绩效考核怎么定');
    final v2 = await embedder.embed('KPI 与目标的拆解方法');
    final v3 = await embedder.embed('怎么腌萝卜');

    expect(TextEmbedder.cosine(v1, v2), greaterThan(TextEmbedder.cosine(v1, v3)),
        reason: '词不一样但意思近 —— 这正是要靠向量的场景');
  }, skip: ortSkipReason);

  test('超长文本会被截断（模型窗口 512 token），但不崩', () async {
    final long = '会议记录。' * 2000; // 远超窗口
    final v = await embedder.embed(long);
    expect(v, hasLength(TextEmbedder.dim));
  }, skip: ortSkipReason);
}
