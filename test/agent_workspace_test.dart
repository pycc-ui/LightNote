// 工作区（AI 能看到哪些笔记）的取值规则。
//
// 为什么这些值得单独测：这个值**同时**是三件东西 —— 提示词里的一句话、
// `ToolExecutor._scope` 的查询范围、以及界面标签。它一处读错，就是
// "界面说「工作」，AI 却把读书笔记里的内容引出来"这种说不清道不明的错。
// 而且它的三种输入（没记录 / 从没设过 / 坏数据）各自有**不同**的兜底，
// 光看代码很容易以为它们一样。
import 'package:flutter_test/flutter_test.dart';
import 'package:lightnote/features/ai/domain/agent_workspace.dart';

void main() {
  group('三态的基本形状', () {
    test('默认工作区是「全体空间」，不是「不选择」', () {
      // 这条断言看着像废话，但它钉住的是一个**产品决定**：
      // 默认给 none 的话，用户第一句话就会得到"我一条笔记都看不到"。
      expect(AgentWorkspace.initial.mode, WorkspaceMode.all);
      expect(AgentWorkspace.initial, AgentWorkspace.all);
      expect(AgentWorkspace.initial.isEmpty, isFalse);
    });

    test('isEmpty：none 与"选了但一个都没选中"都算空', () {
      expect(AgentWorkspace.none.isEmpty, isTrue);
      expect(AgentWorkspace.all.isEmpty, isFalse);
      expect(
        const AgentWorkspace(
          mode: WorkspaceMode.pick,
          notebookIds: ['a'],
        ).isEmpty,
        isFalse,
      );
      // 挂了个空 pick：没目录也不含轻笔记 → 依然什么都查不到
      expect(
        const AgentWorkspace(mode: WorkspaceMode.pick).isEmpty,
        isTrue,
      );
      // 但"只要轻笔记"不是空
      expect(
        const AgentWorkspace(mode: WorkspaceMode.pick, includeUnfiled: true)
            .isEmpty,
        isFalse,
      );
    });
  });

  group('parse：三种输入三种兜底', () {
    test('从没设过（空串）→ 默认「全体空间」', () {
      // 空串是"workspace_scope 这一列加进来之前的老会话"。
      // 它表达的是"用户没做过这个选择"，必须等于新会话的默认，
      // 否则同一个 App 里老会话和新会话两套默认。
      expect(AgentWorkspace.parse(''), AgentWorkspace.initial);
      expect(AgentWorkspace.parse('   '), AgentWorkspace.initial);
      expect(AgentWorkspace.parse('').mode, WorkspaceMode.all);
    });

    test('连记录都没有（null）→ 保守的 none', () {
      // 与空串**刻意不同**：读不到会话记录属于异常，
      // 异常时宁可少给它看，也不要突然放宽成全部笔记
      expect(AgentWorkspace.parse(null), AgentWorkspace.none);
      expect(AgentWorkspace.parse(null).mode, WorkspaceMode.none);
    });

    test('用户显式选的 none 与空串分得清', () {
      expect(AgentWorkspace.parse('{"mode":"none"}').mode, WorkspaceMode.none);
      expect(AgentWorkspace.parse('{"mode":"none"}'), isNot(AgentWorkspace.initial));
    });

    test('pick：目录与「我的轻笔记」都读回来', () {
      final w = AgentWorkspace.parse(
        '{"mode":"pick","notebookIds":["a","b"],"includeUnfiled":true}',
      );
      expect(w.mode, WorkspaceMode.pick);
      expect(w.notebookIds, ['a', 'b']);
      expect(w.includeUnfiled, isTrue);
    });

    test('pick 的字段要"像那么回事"才认：非布尔的 includeUnfiled 不算真', () {
      final w = AgentWorkspace.parse(
        '{"mode":"pick","notebookIds":["a",""],"includeUnfiled":"yes"}',
      );
      // 空串 id 被丢掉（它不可能是有效的笔记库 id）
      expect(w.notebookIds, ['a']);
      // 只有**真正的 true** 才算勾了轻笔记，避免被 "false" 这种字符串骗到
      expect(w.includeUnfiled, isFalse);
    });

    test('坏数据一律保守：坏 JSON / 不是对象 / 模式名不认识', () {
      expect(AgentWorkspace.parse('{不是json'), AgentWorkspace.none);
      expect(AgentWorkspace.parse('[]'), AgentWorkspace.none);
      expect(AgentWorkspace.parse('"all"'), AgentWorkspace.none);
      expect(AgentWorkspace.parse('{"mode":"随便写的"}'), AgentWorkspace.none);
    });
  });

  group('encode / parse 往返', () {
    test('三态各自往返后还是自己', () {
      for (final w in const [
        AgentWorkspace.none,
        AgentWorkspace.all,
        AgentWorkspace(
          mode: WorkspaceMode.pick,
          notebookIds: ['a', 'b'],
          includeUnfiled: true,
        ),
        AgentWorkspace(mode: WorkspaceMode.pick, notebookIds: ['a']),
      ]) {
        expect(AgentWorkspace.parse(w.encode()), w, reason: w.toString());
      }
    });

    test('非 pick 模式不多存字段，于是"从 pick 切到 all"不会被旧目录影响', () {
      expect(AgentWorkspace.all.encode(), '{"mode":"all"}');
      expect(AgentWorkspace.none.encode(), '{"mode":"none"}');
      // 一个曾经是 pick、现在切到 all 的对象：编码里不该还留着 notebookIds
      const stale = AgentWorkspace(
        mode: WorkspaceMode.all,
        notebookIds: ['a', 'b'],
        includeUnfiled: true,
      );
      expect(AgentWorkspace.parse(stale.encode()).notebookIds, isEmpty);
    });
  });

  group('resolve：翻译成查询参数', () {
    test('none = 一个目录都不含且不含轻笔记（一条都查不到）', () {
      final r = AgentWorkspace.none.resolve();
      expect(r.notebookIds, isEmpty);
      expect(r.includeUnfiled, isFalse);
    });

    test('all = 不限目录（null 才是"不限"，空列表是"一个都不含"）', () {
      final r = AgentWorkspace.all.resolve();
      expect(r.notebookIds, isNull);
      expect(r.includeUnfiled, isTrue);
    });

    test('pick = 原样透传', () {
      final r = const AgentWorkspace(
        mode: WorkspaceMode.pick,
        notebookIds: ['a'],
      ).resolve();
      expect(r.notebookIds, ['a']);
      expect(r.includeUnfiled, isFalse);
    });
  });

  group('label：给用户看的那句话', () {
    test('none / all 是固定说法', () {
      expect(AgentWorkspace.none.label((_) => '不该被用到'), '未选择');
      expect(AgentWorkspace.all.label((_) => null), '全体空间');
    });

    test('pick：拼目录名，查不到的 id 直接丢掉（笔记库删了不该留 uuid）', () {
      final w = const AgentWorkspace(
        mode: WorkspaceMode.pick,
        notebookIds: ['a', 'gone'],
      );
      expect(w.label((id) => id == 'a' ? '工作' : null), '工作');
    });

    test('pick：勾了轻笔记就带上它', () {
      final w = const AgentWorkspace(
        mode: WorkspaceMode.pick,
        notebookIds: ['a'],
        includeUnfiled: true,
      );
      expect(w.label((id) => id == 'a' ? '工作' : null), '工作、我的轻笔记');
    });

    test('pick：目录全被删了就退回「未选择」', () {
      final w = const AgentWorkspace(
        mode: WorkspaceMode.pick,
        notebookIds: ['gone'],
      );
      expect(w.isEmpty, isFalse, reason: '库里仍记着这个 id，只是名字查不到了');
      expect(w.label((_) => null), '未选择');
    });
  });

  group('相等性：目录顺序不参与比较', () {
    test('同一批目录换个顺序算同一个工作区（免得白写一次库）', () {
      const a = AgentWorkspace(
        mode: WorkspaceMode.pick,
        notebookIds: ['a', 'b'],
      );
      const b = AgentWorkspace(
        mode: WorkspaceMode.pick,
        notebookIds: ['b', 'a'],
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('不同形状不相等', () {
      expect(AgentWorkspace.none, isNot(AgentWorkspace.all));
      expect(
        const AgentWorkspace(mode: WorkspaceMode.pick, notebookIds: ['a']),
        isNot(const AgentWorkspace(mode: WorkspaceMode.pick, notebookIds: ['b'])),
      );
    });
  });
}
