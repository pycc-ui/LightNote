// A 类任务的产出落库（批 3）：模型写的 json 块 → 真的笔记。
//
// 这一层的价值全在"失败的部分"上：
//   · 逐条落库 → 一条错了不影响别的（用户看到"3 篇成了、1 篇没成"）
//   · 失败要说清是哪一条、为什么 → 才可能让模型自己修
//   · 回灌里要带上**已落库的 id** → 否则模型会重建一遍，用户看到重复笔记
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/core/db/ai_udfs.dart';
import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/core/util/app_params.dart';
import 'package:lightnote/features/ai/domain/ai_chat_repository.dart';
import 'package:lightnote/features/ai/domain/result_applier.dart';

void main() {
  late AppDatabase db;
  late AiResultApplier applier;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory(setup: installAiUdfs));
    applier = AiResultApplier(db);
    await db.customStatement(
      "INSERT INTO notebooks (id, name, sort_order, created_at, updated_at) "
      "VALUES ('nb1', '工作', 0, 0, 0)",
    );
    await db.customStatement(
      "INSERT INTO notes (id, notebook_id, title, content, excerpt, source, "
      "is_inbox, pinned, word_count, created_at, updated_at) "
      "VALUES ('n1', 'nb1', '项目A', '风险是时间紧。还有别的。', '', 'local', 0, 0, 0, 0, 0)",
    );
  });
  tearDown(() => db.close());

  Future<List<Map<String, Object?>>> rows(String sql) async {
    final r = await db.customSelect(sql).get();
    return [for (final e in r) e.data];
  }

  _claimCases();

  group('抽取产出块', () {
    test('认 ```json 围栏里的对象', () {
      const answer = '''
整理完了，三篇如下。

```json
{"notes":[{"title":"A","content":"正文"}]}
```
''';
      final p = AiResultApplier.extractPayload(answer);
      expect(p, isNotNull);
      expect((p!['notes'] as List), hasLength(1));
    });

    test('★ 有多个块时只认**最后**一个（前面可能只是示意）', () {
      const answer = '''
先给个格式示意：
```json
{"notes":[{"title":"示意","content":"这不是真的"}]}
```
真正的产出：
```json
{"notes":[{"title":"真的","content":"正文"}]}
```
''';
      final p = AiResultApplier.extractPayload(answer)!;
      expect(((p['notes'] as List).first as Map)['title'], '真的');
    });

    test('没有围栏、末尾直接跟一个对象也认', () {
      final p = AiResultApplier.extractPayload(
          '好了。\n{"notes":[{"title":"A","content":"B"}]}');
      expect(p, isNotNull);
    });

    test('★ 不含 notes/updates/deletes 的 JSON 不算产出块（别把举例当指令）', () {
      expect(AiResultApplier.extractPayload('说明：```json\n{"example":1}\n```'),
          isNull);
      expect(AiResultApplier.extractPayload('就是聊聊天，没有产出。'), isNull);
      expect(AiResultApplier.extractPayload(''), isNull);
    });

    test('正文里含 } 和转义引号也能正确配对', () {
      final raw = jsonEncode({
        'notes': [
          {'title': '含 } 的标题', 'content': '正文里有 \\" 和 } 花括号'}
        ]
      });
      final p = AiResultApplier.extractPayload('答：\n$raw');
      expect(p, isNotNull);
      expect(((p!['notes'] as List).first as Map)['title'], '含 } 的标题');
    });
  });

  group('展示文本去掉产出块', () {
    test('去掉 json 块、保留正文并收尾', () {
      const answer = '''
我整理成三篇。

```json
{"notes":[{"title":"A","content":"B"}]}
```
''';
      final s = AiResultApplier.stripPayload(answer);
      expect(s, '我整理成三篇。');
      expect(s.contains('json'), isFalse);
    });

    test('没有产出块时原样（只是 trim）', () {
      expect(AiResultApplier.stripPayload(' 就聊聊天 '), '就聊聊天');
    });
  });

  group('落库：成功的路径', () {
    test('新建 + 改正文 + 删，三样都落', () async {
      const answer = '''
整理好了。

```json
{"notes":[{"title":"合并稿","content":"# 合并\\n正文","notebook_id":"nb1"}],
 "updates":[{"id":"n1","old":"还有别的。","new":"风险已识别。"}],
 "deletes":["n1"]}
```
''';
      final r = await applier.apply(answer);

      expect(r.hadPayload, isTrue);
      expect(r.createdIds, hasLength(1));
      expect(r.updatedIds, ['n1']);
      expect(r.deletedIds, ['n1']);
      expect(r.failed, isEmpty);

      final n = await rows(
          "SELECT title, content FROM notes WHERE id = '${r.createdIds.first}'");
      expect(n.first['title'], '合并稿');
      expect(n.first['content'], contains('正文'));
      // n1 被删了（逻辑删除）
      final del = await rows("SELECT deleted_at FROM notes WHERE id = 'n1'");
      expect(del.first['deleted_at'], isNotNull);
    });

    test('B 类问答（没有 json 块）→ 什么都不做，也不报错', () async {
      final r = await applier.apply('你关于项目A 写过：风险是时间紧。');
      expect(r.hadPayload, isFalse);
      expect(r.hasWork, isFalse);
      expect(r.summary, '没有需要落库的内容');
    });

    test('标题为空 → 用「未命名」兜底；超长 → 截断', () async {
      final long = '标' * (AiLimits.titleHardMax + 50);
      final r = await applier.apply(jsonEncode({
        'notes': [
          {'title': '', 'content': 'x'},
          {'title': long, 'content': 'y'},
        ]
      }));
      expect(r.createdIds, hasLength(2));
      final got = await rows(
          "SELECT title FROM notes WHERE id IN ('${r.createdIds[0]}','${r.createdIds[1]}')");
      final titles = got.map((e) => e['title']).toList();
      expect(titles, contains('未命名'));
      expect(titles.any((t) => (t as String).length == AiLimits.titleHardMax), isTrue);
    });
  });

  group('★ 落库：失败的那一条不影响别的', () {
    test('正文超硬上限 → 那一篇不落，别的照落', () async {
      final huge = 'a' * (AiLimits.noteHardBytes + 10);
      final r = await applier.apply(jsonEncode({
        'notes': [
          {'title': '太大了', 'content': huge},
          {'title': '正常', 'content': '正文'},
        ]
      }));

      expect(r.createdIds, hasLength(1), reason: '只有正常那篇落库');
      expect(r.failed, hasLength(1));
      expect(r.failed.first['title'], '太大了');
      expect(r.failed.first['reason'], contains('50KB'));
      expect(r.summary, contains('未处理'));
    });

    test('锚点不唯一 → 原因里带上"出现几次"（模型据此把锚点写长）', () async {
      await db.customStatement(
          "UPDATE notes SET content = '风险风险' WHERE id = 'n1'");
      final r = await applier.apply(jsonEncode({
        'updates': [
          {'id': 'n1', 'old': '风险', 'new': '没事'}
        ]
      }));
      expect(r.updatedIds, isEmpty);
      expect(r.failed, hasLength(1));
      expect(r.failed.first['id'], 'n1');
      expect(r.failed.first['reason'], contains('2'),
          reason: 'UDF 要说清出现了几次');
    });

    test('不存在的 id / 缺 old → 可读的错', () async {
      final r = await applier.apply(jsonEncode({
        'updates': [
          {'id': '不存在', 'old': 'x', 'new': 'y'},
          {'id': 'n1', 'old': '', 'new': 'y'},
        ]
      }));
      expect(r.failed, hasLength(2));
      expect(r.failed.first['reason'], isNotNull);
      expect(r.failed[1]['reason'], contains('old'));
    });

    test('正文为空的新建 → 拒绝（不建空笔记）', () async {
      final r = await applier.apply(jsonEncode({
        'notes': [
          {'title': '空', 'content': '   '}
        ]
      }));
      expect(r.createdIds, isEmpty);
      expect(r.failed.first['reason'], contains('空'));
    });
  });

  group('★ 修复请求要带上"已落库的 id"', () {
    test('回灌 JSON 里同时有 failed 和 done', () async {
      final huge = 'a' * (AiLimits.noteHardBytes + 10);
      final r = await applier.apply(jsonEncode({
        'notes': [
          {'title': '正常', 'content': '正文'},
          {'title': '太大', 'content': huge},
        ]
      }));
      final msg = jsonDecode(r.repairMessage()) as Map;

      expect(msg['failed'], hasLength(1));
      final done = msg['done'] as Map;
      expect(done['created_note_ids'], r.createdIds);
      expect(msg['note'], contains('不要再建'));
    });

    test('merge：修复轮的成功项累加、失败项取最新', () async {
      const first = AppliedResult(
        hadPayload: true,
        createdIds: ['a'],
        failed: [
          {'kind': 'note', 'title': 'B', 'reason': '正文为空'}
        ],
      );
      const later = AppliedResult(
        hadPayload: true,
        createdIds: ['b'],
        failed: [],
      );
      final merged = first.merge(later);
      expect(merged.createdIds, ['a', 'b']);
      expect(merged.failed, isEmpty, reason: '修好了就不该再报旧的失败');
    });
  });
}

// 「只说不做」的检测（正则的行为边界）——**不能误判"用户过去的行为"**。
void _claimCases() {
  group('★ 完成声明检测：只抓"它自己做了事"，不误判用户的过去', () {
    test('抓得到：完成体与承诺（实测抓到的那句就在这里）', () {
      // ↓ 这句是探针里真实出现的：模型说了这句、却没给 json 块，结果库里一篇没有
      expect(
          AiChatRepository.claimsCompletionForTest('三篇都会放进「我的轻笔记」。'), isTrue);
      expect(AiChatRepository.claimsCompletionForTest('已新建三篇笔记。'), isTrue);
      expect(AiChatRepository.claimsCompletionForTest('已保存到你选的笔记库'), isTrue);
      expect(AiChatRepository.claimsCompletionForTest('已把三篇整理成主题笔记并落库'), isTrue);
    });

    test('已知漏网（宁漏勿误）：夹了宾语的完成体抓不到', () {
      // "已经把这些整理成三篇" —— 「已经」与「整理成」之间夹了「把这些」，
      // 纯文本模式抓不到。这类靠**提示词规则 11**（没有 json 块就不许声称做了）兜。
      expect(AiChatRepository.claimsCompletionForTest('已经把这些整理成三篇了'), isFalse);
    });

    test('★ 不抓：描述用户过去的行为（这是 B 类的正常回答）', () {
      expect(AiChatRepository.claimsCompletionForTest('你写过关于间隔重复的笔记。'), isFalse);
      expect(AiChatRepository.claimsCompletionForTest('你之前记录过这个风险。'), isFalse);
      expect(AiChatRepository.claimsCompletionForTest('这篇笔记里提到合规要求。'), isFalse);
    });
  });
}

