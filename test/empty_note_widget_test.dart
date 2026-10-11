// 「打开新建笔记页 → 什么都不写 → 返回」不该留下空笔记。
//
// 这是用户报告的真实缺陷。修法有两层，这个文件测**第一层**——
// 也就是最直接的那条路径：编辑页延迟创建，没内容就不 INSERT。
//
// 为什么必须用 widget 测试：那个 bug 出在**页面生命周期**上
// （dispose → _flush → saveContent），纯数据层测不出来。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/core/prefs/preferences_service.dart';
import 'package:lightnote/features/ai/data/deepseek_client.dart';
import 'package:lightnote/features/ai/domain/ai_repository.dart';
import 'package:lightnote/features/note/data/note_repository.dart';
import 'package:lightnote/features/note/ui/note_editor_page.dart';

void main() {
  late AppDatabase db;
  late NoteRepository notes;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    notes = NoteRepository(db);
  });

  tearDown(() => db.close());

  /// 搭一个只含编辑页所需依赖的最小 widget 树。
  ///
  /// 用 [NoteEditorPage.draft] 打开（模拟"新建笔记"），
  /// 而不是先创建再把 id 传进去——后者正是旧的错误流程。
  Widget host({String? notebookId}) {
    final client = DeepSeekClient(); // 不配 Key，AI 相关功能用不到
    return MultiProvider(
      providers: [
        Provider<NoteRepository>.value(value: notes),
        Provider<PreferencesService>(create: (_) => PreferencesService(db)),
        Provider<AiRepository>(
          create: (_) => AiRepository(db: db, client: client),
        ),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => NoteEditorPage(
                      draft: NoteDraftParams(
                        notebookId: notebookId,
                        asInbox: notebookId == null,
                      ),
                    ),
                  ),
                ),
                child: const Text('新建笔记'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('什么都不写就返回：库里不留下空笔记', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('新建笔记'));
    await tester.pumpAndSettle();

    // 确认真的进了编辑页
    expect(find.byType(NoteEditorPage), findsOneWidget);

    // 立刻返回，一个字都不输入
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byType(NoteEditorPage), findsNothing);
    expect(
      await db.allActiveNotes(),
      isEmpty,
      reason: '用户什么都没写，库里不该多出一条笔记',
    );
  });

  // ---------------------------------------------------------------------------
  // 保存方式：**手动**（编辑态右上角一个勾，点它保存并进阅读态）
  //
  // 这几条原先是围绕"自动保存（500ms 防抖）"写的，改成手动之后
  // 落盘时机完全不同：不再有"等一会儿它自己就存了"这回事。
  // ---------------------------------------------------------------------------

  testWidgets('编辑态右上角是「勾」，阅读态才是「三个点」', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('新建笔记'));
    await tester.pumpAndSettle();

    // 编辑态：只有一个勾，没有菜单
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.byType(PopupMenuButton<String>), findsNothing,
        reason: '编辑时屏幕上还有没保存的改动，先别给删除/移动的入口');

    await tester.enterText(find.byType(TextField).first, '标题');
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    // 保存之后自动进阅读态，菜单出现在这里
    expect(find.byType(PopupMenuButton<String>), findsOneWidget);
    expect(find.byIcon(Icons.check), findsNothing);
    expect(find.text('编辑'), findsOneWidget, reason: '要能回编辑态');
  });

  testWidgets('只输入标题 → 点勾 → 保存并进阅读态', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('新建笔记'));
    await tester.pumpAndSettle();

    // 标题输入框是页面里第一个 TextField
    await tester.enterText(find.byType(TextField).first, '只有标题');
    await tester.pump();

    // ★ 关键：这是唯一会写库的动作
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    final all = await db.allActiveNotes();
    expect(all.length, 1, reason: '点了保存就该写库');
    expect(all.first.title, '只有标题');
  });

  testWidgets('★ 不点保存直接返回 → 先问一句；选「保存并退出」才写库', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('新建笔记'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(1), '一段正文内容');
    await tester.pump();

    await tester.pageBack();
    await tester.pumpAndSettle();

    // 只去掉自动保存、不给询问的话，用户按一下返回就静静丢内容
    expect(find.text('有未保存的改动'), findsOneWidget);

    await tester.tap(find.text('保存并退出'));
    await tester.pumpAndSettle();

    final all = await db.allActiveNotes();
    expect(all.length, 1);
    expect(all.first.content, '一段正文内容');
  });

  testWidgets('★ 询问里选「取消」→ 不退出，内容还在', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('新建笔记'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(1), '别弄丢我');
    await tester.pump();

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // 还在编辑页
    expect(find.byType(NoteEditorPage), findsOneWidget);
    expect(find.text('别弄丢我'), findsOneWidget, reason: '内容必须还在编辑器里');
    expect(await db.allActiveNotes(), isEmpty, reason: '没保存就不该写库');
  });

  testWidgets('写了又全删掉再返回：也不留下笔记', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('新建笔记'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.first, '临时写的');
    await tester.pump();
    // 全部删掉
    await tester.enterText(fields.first, '   ');
    await tester.pump();

    await tester.pageBack();
    await tester.pumpAndSettle();

    // 有改动 → 会问；选放弃
    if (find.text('放弃改动').evaluate().isNotEmpty) {
      await tester.tap(find.text('放弃改动'));
      await tester.pumpAndSettle();
    }

    // 手动保存下，中途从未落盘 → 库里一条都不该有
    expect(await db.allActiveNotes(), isEmpty,
        reason: '既没点勾也没选保存，就不该产生笔记');
  });
}
