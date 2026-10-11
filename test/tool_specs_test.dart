// 工具清单的数据契约。
//
// 这一层是"给模型看的说明书"，所以有几条**不是风格问题、而是会影响模型行为**的约束：
//
//   · **风险级别必须显式声明** —— 安全确认靠它，漏一个就等于开了个后门
//   · **描述写的是"什么时候用它"**，不是"它是干什么的"
//   · **分层数量固定**（7 / 8 / 4）—— 改数量要同步改设计文档与预算
//   · **危险工具的描述里必须出现"不可恢复"** —— 模型据此才会在调用前提醒用户
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_notes/features/ai/domain/tool_specs.dart';

void main() {
  group('清单规模与分层', () {
    test('一共 19 个工具', () {
      expect(kAgentTools.length, 19);
    });

    test('分层是 核心 7 / 常用 8 / 按需 4', () {
      expect(kCoreTools.length, 7);
      expect(kCommonTools.length, 8);
      expect(kOnDemandTools.length, 4);
    });

    test('工具名唯一（重名会让模型调错、也会让执行器分派错）', () {
      final names = kAgentTools.map((t) => t.name).toList();
      expect(names.toSet().length, names.length);
    });

    test('每层里的每个工具都声明了正确的 layer', () {
      for (final t in kCoreTools) {
        expect(t.layer, ToolLayer.core, reason: t.name);
      }
      for (final t in kCommonTools) {
        expect(t.layer, ToolLayer.common, reason: t.name);
      }
      for (final t in kOnDemandTools) {
        expect(t.layer, ToolLayer.onDemand, reason: t.name);
      }
    });
  });

  group('安全：风险级别', () {
    test('删除类工具必须标成 delete（唯一会丢数据的级别）', () {
      for (final name in ['deleteNote', 'deleteNotebook', 'batchDeleteNotes']) {
        expect(toolByName(name)!.risk, ToolRisk.delete, reason: name);
      }
    });

    test('**每个会写数据的工具都必须需要确认**（漏一个就是后门）', () {
      for (final t in kAgentTools) {
        if (t.risk == ToolRisk.read || t.risk == ToolRisk.interaction) continue;
        expect(t.needsConfirm, isTrue, reason: '${t.name} 会写数据却没要求确认');
      }
    });

    test('交互类（askUser / requestTools）不碰数据，不进风险表', () {
      for (final name in ['askUser', 'requestTools']) {
        final t = toolByName(name)!;
        expect(t.risk, ToolRisk.interaction, reason: name);
        expect(t.needsConfirm, isFalse, reason: '$name 不该弹数据确认框');
      }
    });

    test('只有删除类需要"二次确认"（措辞要写明不可恢复）', () {
      for (final t in kAgentTools) {
        expect(t.needsStrongConfirm, t.risk == ToolRisk.delete, reason: t.name);
      }
    });

    test('危险工具的描述里写明后果（模型据此才会提醒用户）', () {
      expect(toolByName('deleteNote')!.description, contains('不可恢复'));
      expect(toolByName('batchDeleteNotes')!.description, contains('不可恢复'));
      // 删笔记库不删里面的笔记 —— 这句必须写，否则模型会以为连笔记一起没了
      expect(toolByName('deleteNotebook')!.description, contains('不会删'));
    });

    test('改笔记必须要求 expectedText（锚点校验的前提）', () {
      final p = toolByName('updateNote')!.spec.parameters;
      final props = (p['properties'] as Map).cast<String, Object?>();
      expect(props.containsKey('expectedText'), isTrue);
      expect(toolByName('updateNote')!.description, contains('expectedText'));
    });
  });

  group('分层发送', () {
    test('默认发核心 + 常用，不发按需', () {
      final names = specsForRequest().map((s) => s.name).toSet();
      expect(names.length, 15);
      for (final t in kOnDemandTools) {
        expect(names.contains(t.name), isFalse, reason: '${t.name} 默认不该发');
      }
    });

    test('requestTools 批准之后才发按需层的定义', () {
      final names =
          specsForRequest(granted: {'deleteNotebook'}).map((s) => s.name).toSet();
      expect(names.contains('deleteNotebook'), isTrue);
      expect(names.contains('renameNotebook'), isFalse, reason: '没申请的仍然不发');
      expect(names.length, 16);
    });

    test('工具目录只列**还没发**的按需层，且给的是名称 + 一句话', () {
      final text = toolCatalogText();
      expect(text, contains('renameNotebook'));
      expect(text, contains('deleteNotebook'));
      expect(text, isNot(contains('searchNotes')), reason: '核心层已发完整定义，不该重复列');
      // 一句话而已，不能把 schema 也塞进去
      expect(text, isNot(contains('"type"')));
      expect(text, isNot(contains('properties')));
    });

    test('按需层全部批准后，目录为空', () {
      final all = kOnDemandTools.map((t) => t.name).toSet();
      expect(toolCatalogText(granted: all), isEmpty);
    });
  });

  group('描述是写给模型看的', () {
    test('每个描述都够长（太短模型判断不了该不该调）', () {
      for (final t in kAgentTools) {
        expect(t.description.length, greaterThan(10), reason: t.name);
      }
    });

    test('searchNotes / listChunks 的描述里说清"什么时候用"', () {
      expect(toolByName('searchNotes')!.description, contains('优先用它'));
      expect(toolByName('listChunks')!.description, contains('不含正文'));
      expect(toolByName('listChunks')!.description, contains('readChunk'));
    });

    test('askUser 的描述里带上提问纪律', () {
      final d = toolByName('askUser')!.description;
      expect(d, contains('不要问已经知道的信息'));
      expect(d, contains('source'));
    });

    test('listHistory 说明"自动只带最近 5 轮"（否则模型不知道为什么要调它）', () {
      expect(toolByName('listHistory')!.description, contains('5 轮'));
    });
  });

  group('参数 schema 的形状', () {
    test('每个工具的 parameters 都是合法的 object schema', () {
      for (final t in kAgentTools) {
        final p = t.spec.parameters;
        expect(p['type'], 'object', reason: t.name);
        expect(p['properties'], isA<Map>(), reason: t.name);
      }
    });

    test('必填项都真的在 properties 里（写错会让模型永远调不对）', () {
      for (final t in kAgentTools) {
        final p = t.spec.parameters;
        final props = (p['properties'] as Map?)?.keys.toSet() ?? {};
        final required = (p['required'] as List?)?.cast<String>() ?? const [];
        for (final r in required) {
          expect(props.contains(r), isTrue, reason: '${t.name}: required 里的 $r 不在 properties');
        }
      }
    });

    test('必填项不是空描述（模型看不到描述就只能瞎猜）', () {
      for (final t in kAgentTools) {
        final p = t.spec.parameters;
        final props = (p['properties'] as Map?) ?? const {};
        for (final entry in props.entries) {
          final schema = entry.value;
          if (schema is Map && schema['description'] is String) {
            expect((schema['description'] as String).trim(), isNotEmpty,
                reason: '${t.name}.${entry.key} 描述为空');
          }
        }
      }
    });

    test('listNotebooks 无参数（阶段 0 就是用它端到端验证的）', () {
      final p = toolByName('listNotebooks')!.spec.parameters;
      expect((p['properties'] as Map).isEmpty, isTrue);
    });

    test('toJson 的形状符合 function calling 协议', () {
      final json = toolByName('searchNotes')!.spec.toJson();
      expect(json['type'], 'function');
      final fn = json['function'] as Map;
      expect(fn['name'], 'searchNotes');
      expect(fn['description'], isA<String>());
      expect(fn['parameters'], isA<Map>());
    });
  });

  group('查名字', () {
    test('已知名字查得到、未知名字返回 null（模型可能报错名字）', () {
      expect(toolByName('readChunk')!.name, 'readChunk');
      expect(toolByName('不存在的工具'), isNull);
      expect(toolByName(''), isNull);
    });
  });
}
