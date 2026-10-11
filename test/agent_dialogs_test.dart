// Agent 的两块界面：确认层（改前/改后、删除措辞）与答题层（四种 type）。
//
// 这些必须用 widget 测试：它们的正确性全在"屏幕上出现了什么、点下去返回什么"，
// 纯数据层测不出来。而这两块恰好是**用户唯一能拦住 AI 的地方**，
// 弄错了就是"AI 改了/删了用户的数据，而确认框根本没让他看清"。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/features/ai/domain/ask_user.dart';
import 'package:lightnote/features/ai/domain/tool_executor.dart';
import 'package:lightnote/features/ai/domain/tool_specs.dart';
import 'package:lightnote/features/ai/ui/agent_dialogs.dart';

void main() {
  /// 把弹层挂到一个最小页面上，并把返回值收进 [out]
  Future<void> hostConfirm(
    WidgetTester tester,
    ToolConfirmRequest req,
    List<bool> out,
  ) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async => out.add(await showToolConfirm(ctx, req)),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  Future<void> hostAsk(
    WidgetTester tester,
    AskRequest req,
    List<AskOption> options,
    List<AskResult> out,
  ) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async =>
                  out.add(await showAskSheet(ctx, req, options)),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  group('确认层：用户要看清"具体改什么"', () {
    testWidgets('标题 + 摘要都显示出来', (tester) async {
      final out = <bool>[];
      await hostConfirm(
        tester,
        const ToolConfirmRequest(
          risk: ToolRisk.modify,
          toolName: 'updateNote',
          title: '修改笔记',
          summary: '把「客户」改成「用户」',
        ),
        out,
      );

      expect(find.text('修改笔记'), findsOneWidget);
      expect(find.text('把「客户」改成「用户」'), findsOneWidget);
      expect(find.text('允许'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
    });

    testWidgets('★ 有改前改后时，两块并排显示（不能只给一句话让用户盲点）', (tester) async {
      final out = <bool>[];
      await hostConfirm(
        tester,
        const ToolConfirmRequest(
          risk: ToolRisk.modify,
          toolName: 'updateNote',
          title: '修改笔记',
          summary: '改这段',
          before: '旧的正文',
          after: '新的正文',
        ),
        out,
      );

      expect(find.text('改前'), findsOneWidget);
      expect(find.text('改后'), findsOneWidget);
      expect(find.text('旧的正文'), findsOneWidget);
      expect(find.text('新的正文'), findsOneWidget);
    });

    testWidgets('没有 after 时只显示一段（新建的场景）', (tester) async {
      final out = <bool>[];
      await hostConfirm(
        tester,
        const ToolConfirmRequest(
          risk: ToolRisk.create,
          toolName: 'createNote',
          title: '新建笔记',
          summary: '新建一条',
          after: '正文',
        ),
        out,
      );
      expect(find.text('改前'), findsNothing);
      expect(find.text('改后'), findsNothing);
    });

    testWidgets('★ 删除类：按钮是「删除」而不是「允许」，摘要写明不可恢复', (tester) async {
      final out = <bool>[];
      await hostConfirm(
        tester,
        const ToolConfirmRequest(
          risk: ToolRisk.delete,
          toolName: 'deleteNote',
          title: '删除笔记',
          summary: '删除《会议记录》。删了就找不回来（没有回收站）。',
        ),
        out,
      );

      expect(find.text('删除'), findsOneWidget);
      expect(find.text('允许'), findsNothing,
          reason: '「允许」太容易被顺手点掉，删除必须是明确措辞');
      expect(find.textContaining('找不回来'), findsOneWidget);
    });

    testWidgets('有 warning 时显示提醒（如"这条笔记被改过"）', (tester) async {
      final out = <bool>[];
      await hostConfirm(
        tester,
        const ToolConfirmRequest(
          risk: ToolRisk.modify,
          toolName: 'updateNote',
          title: '修改笔记',
          summary: '改',
          warning: '这条笔记在你读到它之后被改过',
        ),
        out,
      );
      expect(find.textContaining('被改过'), findsOneWidget);
    });

    testWidgets('超长正文会截断，不把弹层撑成一整篇文章', (tester) async {
      final out = <bool>[];
      await hostConfirm(
        tester,
        ToolConfirmRequest(
          risk: ToolRisk.modify,
          toolName: 'updateNote',
          title: '修改笔记',
          summary: '改',
          before: '甲' * 2000,
          after: '乙' * 2000,
        ),
        out,
      );
      expect(find.textContaining('已截断'), findsWidgets);
    });

    testWidgets('点「取消」→ false', (tester) async {
      final out = <bool>[];
      await hostConfirm(
        tester,
        const ToolConfirmRequest(
          risk: ToolRisk.modify,
          toolName: 'x',
          title: 'T',
          summary: 'S',
        ),
        out,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(out, [false]);
    });

    testWidgets('点「允许」→ true', (tester) async {
      final out = <bool>[];
      await hostConfirm(
        tester,
        const ToolConfirmRequest(
          risk: ToolRisk.modify,
          toolName: 'x',
          title: 'T',
          summary: 'S',
        ),
        out,
      );
      await tester.tap(find.text('允许'));
      await tester.pumpAndSettle();
      expect(out, [true]);
    });

    testWidgets('★ 连点两次只返回一次（不会执行两遍）', (tester) async {
      final out = <bool>[];
      await hostConfirm(
        tester,
        const ToolConfirmRequest(
          risk: ToolRisk.delete,
          toolName: 'deleteNote',
          title: '删除笔记',
          summary: 'S',
        ),
        out,
      );

      // 手快连点：第二次点击时弹层已经在关闭中
      await tester.tap(find.text('删除'));
      await tester.tap(find.text('删除'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(out, [true], reason: '重复点击必须只算一次');
    });
  });

  group('答题层：四种 type 各弹对界面', () {
    testWidgets('text → 输入框；空着时「确定」是灰的', (tester) async {
      final out = <AskResult>[];
      await hostAsk(
        tester,
        const AskRequest(question: '起个什么名字？', type: AskType.text),
        const [],
        out,
      );

      expect(find.byType(TextField), findsOneWidget);
      final btn = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(btn.onPressed, isNull, reason: '空回答不该能提交');

      await tester.enterText(find.byType(TextField), '我的新笔记');
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(out.single.status, AskResult.statusAnswered);
      expect(out.single.text, '我的新笔记');
    });

    testWidgets('text → 预填 defaultValue', (tester) async {
      final out = <AskResult>[];
      await hostAsk(
        tester,
        const AskRequest(
          question: 'q',
          type: AskType.text,
          defaultValue: '默认值',
        ),
        const [],
        out,
      );
      expect(find.text('默认值'), findsOneWidget);
    });

    testWidgets('singleChoice → 单选；选一项后才能确定，返回该 id', (tester) async {
      final out = <AskResult>[];
      await hostAsk(
        tester,
        const AskRequest(question: '改哪一篇？', type: AskType.singleChoice),
        const [
          AskOption(id: 'n1', label: '会议记录', description: '项目A / 风险'),
          AskOption(id: 'n2', label: '读书笔记'),
        ],
        out,
      );

      expect(find.text('会议记录'), findsOneWidget);
      expect(find.text('项目A / 风险'), findsOneWidget, reason: '副标题要显示');
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
        reason: '还没选，不能提交',
      );

      await tester.tap(find.text('读书笔记'));
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(out.single.selections, ['n2']);
    });

    testWidgets('singleChoice → 选第二项会替换第一项（不是累加）', (tester) async {
      final out = <AskResult>[];
      await hostAsk(
        tester,
        const AskRequest(question: 'q', type: AskType.singleChoice),
        const [AskOption(id: 'a', label: '甲'), AskOption(id: 'b', label: '乙')],
        out,
      );

      await tester.tap(find.text('甲'));
      await tester.pump();
      await tester.tap(find.text('乙'));
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(out.single.selections, ['b']);
    });

    testWidgets('multipleChoice → 多选，返回全部选中项', (tester) async {
      final out = <AskResult>[];
      await hostAsk(
        tester,
        const AskRequest(question: '改哪几篇？', type: AskType.multipleChoice),
        const [AskOption(id: 'a', label: '甲'), AskOption(id: 'b', label: '乙')],
        out,
      );

      await tester.tap(find.text('甲'));
      await tester.pump();
      await tester.tap(find.text('乙'));
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(out.single.selections, containsAll(['a', 'b']));
    });

    testWidgets('confirm → 两个按钮，「不用」返回 confirmed=false', (tester) async {
      final out = <AskResult>[];
      await hostAsk(
        tester,
        const AskRequest(question: '要删掉吗？', type: AskType.confirm),
        const [],
        out,
      );

      expect(find.text('好'), findsOneWidget);
      expect(find.text('不用'), findsOneWidget);

      await tester.tap(find.text('不用'));
      await tester.pumpAndSettle();

      expect(out.single.status, AskResult.statusAnswered);
      expect(out.single.confirmed, isFalse);
    });

    testWidgets('confirm → 「好」返回 confirmed=true', (tester) async {
      final out = <AskResult>[];
      await hostAsk(
        tester,
        const AskRequest(question: 'q', type: AskType.confirm),
        const [],
        out,
      );
      await tester.tap(find.text('好'));
      await tester.pumpAndSettle();
      expect(out.single.confirmed, isTrue);
    });

    testWidgets('★ 取消永远是出口（返回 cancelled，不是被拦下）', (tester) async {
      final out = <AskResult>[];
      await hostAsk(
        tester,
        const AskRequest(question: 'q', type: AskType.singleChoice),
        const [AskOption(id: 'a', label: '甲')],
        out,
      );

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(out.single.status, AskResult.statusCancelled,
          reason: '"拒绝"是合法回答，也是用户从挂起里脱身的唯一出口');
    });

    testWidgets('没有可选项时给出解释，而不是一个空列表', (tester) async {
      final out = <AskResult>[];
      await hostAsk(
        tester,
        const AskRequest(question: 'q', type: AskType.singleChoice),
        const [],
        out,
      );

      expect(find.textContaining('没有找到可选项'), findsOneWidget);
      // 仍然能取消
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(out.single.status, AskResult.statusCancelled);
    });
  });

  group('确认请求的构造（弹层看到的就是这些）', () {
    test('修改类带 before/after；删除类 strong 为真', () {
      final m = ToolConfirmRequest(
        risk: ToolRisk.modify,
        toolName: 'updateNote',
        title: 'T',
        summary: 'S',
        before: 'a',
        after: 'b',
      );
      expect(m.strong, isFalse);

      final d = ToolConfirmRequest(
        risk: ToolRisk.delete,
        toolName: 'deleteNote',
        title: 'T',
        summary: 'S',
      );
      expect(d.strong, isTrue);
    });

    test('工具清单里的风险级别与弹层的 strong 语义一致', () {
      for (final t in kAgentTools) {
        final req = ToolConfirmRequest(
          risk: t.risk,
          toolName: t.name,
          title: 'T',
          summary: 'S',
        );
        expect(req.strong, t.needsStrongConfirm, reason: t.name);
      }
    });
  });
}
