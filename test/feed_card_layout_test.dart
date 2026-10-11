// 卡片底部一行的布局：**左标签、右按钮**。
//
// 这个文件是为了量出来的东西，不是猜出来的——之前改这一行时
// 误删过 `Spacer`，按钮就跑到了标签旁边；光看截图容易以为是"差不多"。
// 用 `tester.getRect` 精确断言位置，这类回归就再也藏不住。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightnote/features/note/ui/widgets/feed_card.dart';

void main() {
  /// 把卡片放进固定尺寸的窗口，返回按钮的范围。
  Future<Rect> pumpCard(
    WidgetTester tester, {
    required String? tag,
    required bool added,
    Size size = const Size(420, 900),
    VoidCallback? onAdd,
    VoidCallback? onRemove,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: FeedCard(
              title: '记笔记时想分类，等于自断灵感',
              tag: tag,
              addedToInbox: added,
              onTap: () {},
              onAddToInbox: onAdd ?? () {},
              onRemoveFromInbox: onRemove ?? () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    return tester.getRect(find.byType(FilledButton));
  }

  testWidgets('按钮贴在卡片内容区右侧（有标签时也一样）', (tester) async {
    const tag = '笔记法';
    final btn = await pumpCard(tester, tag: tag, added: false);

    // 基准是**底部那一行的右边**，不是 Card 的右边——
    // 卡片自己还有 20px 内边距，按钮本来就不该贴到卡片边缘。
    // （第一版断言用了 Card.right，于是把正确的布局判成了失败。）
    final row = tester.getRect(find.byType(Row).at(1));
    expect(row.right - btn.right, lessThanOrEqualTo(1.0),
        reason: '按钮应当贴在这一行的右端');
  });

  testWidgets('标签贴内容区左侧', (tester) async {
    const tag = '笔记法';
    await pumpCard(tester, tag: tag, added: false);

    final row = tester.getRect(find.byType(Row).at(1));
    final tagRect = tester.getRect(find.text(tag));
    expect(tagRect.left - row.left, lessThanOrEqualTo(1.0),
        reason: '标签应当贴在这一行的左端');
  });

  testWidgets('标签与按钮被撑开，不挤在一起', (tester) async {
    const tag = '笔记法';
    final btn = await pumpCard(tester, tag: tag, added: false);
    final tagRect = tester.getRect(find.text(tag));

    expect(btn.left - tagRect.right, greaterThan(100),
        reason: '两端应当被撑开');
  });

  testWidgets('没有标签时左下退回「AI 生成」', (tester) async {
    await pumpCard(tester, tag: null, added: false);
    expect(find.text('AI 生成'), findsOneWidget);
  });

  testWidgets('标签为空字符串时也退回「AI 生成」', (tester) async {
    await pumpCard(tester, tag: '', added: false);
    expect(find.text('AI 生成'), findsOneWidget);
  });

  testWidgets('有标签时显示标签，不显示「AI 生成」', (tester) async {
    await pumpCard(tester, tag: '记忆', added: false);
    expect(find.text('记忆'), findsOneWidget);
    expect(find.text('AI 生成'), findsNothing);
  });

  group('按钮是「加入 ⇄ 移出」的开关', () {
    testWidgets('未加入：文案是加入我的轻笔记，点了调 onAdd', (tester) async {
      var added = 0;
      var removed = 0;
      await pumpCard(
        tester,
        tag: '记忆',
        added: false,
        onAdd: () => added++,
        onRemove: () => removed++,
      );

      expect(find.text('加入我的轻笔记'), findsOneWidget);
      expect(find.text('从我的轻笔记移出'), findsNothing);

      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      expect(added, 1);
      expect(removed, 0);
    });

    testWidgets('已加入：文案是从我的轻笔记移出，点了调 onRemove', (tester) async {
      var added = 0;
      var removed = 0;
      await pumpCard(
        tester,
        tag: '记忆',
        added: true,
        onAdd: () => added++,
        onRemove: () => removed++,
      );

      expect(find.text('从我的轻笔记移出'), findsOneWidget);
      expect(find.text('加入我的轻笔记'), findsNothing);

      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      expect(removed, 1);
      expect(added, 0);
    });

    testWidgets('已加入时按钮**仍可点**（不是禁用变灰）', (tester) async {
      // 早先加入后是禁用，用户以为坏了——其实是想撤销却没有入口。
      await pumpCard(tester, tag: '记忆', added: true);
      final btn = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(btn.onPressed, isNotNull,
          reason: '已加入时点它要能移出，不能禁用');
    });

    testWidgets('已加入时图标换成移除样式', (tester) async {
      await pumpCard(tester, tag: '记忆', added: true);
      expect(find.byIcon(Icons.remove_circle_outline), findsOneWidget);
      expect(find.byIcon(Icons.bolt_outlined), findsNothing);
    });

    testWidgets('未加入时是闪电图标', (tester) async {
      await pumpCard(tester, tag: '记忆', added: false);
      expect(find.byIcon(Icons.bolt_outlined), findsOneWidget);
      expect(find.byIcon(Icons.remove_circle_outline), findsNothing);
    });
  });

  testWidgets('长标签会被省略，不会把按钮挤出卡片', (tester) async {
    // 极端情况：标签异常长（脏数据）。按钮仍须贴在右端。
    final btn = await pumpCard(
      tester,
      tag: '这是一个非常非常长的标签用来测试省略',
      added: false,
    );
    final row = tester.getRect(find.byType(Row).at(1));
    expect(row.right - btn.right, lessThanOrEqualTo(1.0),
        reason: '标签再长也不该把按钮挤走');
  });
}
