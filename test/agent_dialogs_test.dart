// Agent 的**答题层**：askUser 的四种 type 各弹对界面。
//
// 必须用 widget 测试：正确性全在「屏幕上出现了什么、点下去返回什么」，
// 数据层测不出来。而这块是**用户唯一能拦住 AI 的地方** —— 第三版去掉了写操作的
// 确认弹层（约束改由 UDF 与 SqlGuard 承担，见 docs/AI操作数据库设计.md），
// 于是「问对问题」成了唯一的兜底，弄错了用户就没法说清他要的是哪一篇。
//
// （原先还有一组「确认层」测试，随 `showToolConfirm` 一起删除了。）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/features/ai/domain/ask_user.dart';
import 'package:lightnote/features/ai/ui/agent_dialogs.dart';

void main() {
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

}
