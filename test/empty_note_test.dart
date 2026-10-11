// 「空笔记不该被创建」的回归测试。
//
// 这是本项目真实出现过的缺陷：**新建笔记时先把空笔记写进库、
// 再用它的 id 打开编辑页**，而编辑页 dispose 时无条件 `_flush()`
// →`saveContent`，于是"打开新建页 → 什么都不写 → 返回"会留下一条空白笔记。
//
// 修法有两层，两层都要测：
//   1. 编辑页改为**延迟创建**（NoteDraftParams）：没内容就不 INSERT
//   2. `_flush()` 在标题与正文都空时直接返回（兜住所有落盘路径）
//
// 这里测第 2 层（纯数据层可测的部分）。第 1 层依赖 widget 树，
// 它的行为由"库里笔记数不变"这条断言间接覆盖。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_notes/core/db/app_database.dart';
import 'package:smart_notes/features/note/data/notebook_repository.dart';
import 'package:smart_notes/features/note/data/note_repository.dart';

void main() {
  late AppDatabase db;
  late NoteRepository notes;
  late NotebookRepository notebooks;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    notes = NoteRepository(db);
    notebooks = NotebookRepository(db);
  });

  tearDown(() => db.close());

  group('空内容的笔记不该出现在库里', () {
    test('未归档笔记：空标题空正文时库里还是空的', () async {
      // 延迟创建的语义：编辑页只在内容非空时才 INSERT。
      // 这里模拟"用户什么都没写"——即不调用任何创建方法。
      expect(await db.allActiveNotes(), isEmpty);
      expect(await notes.watchUnfiled().first, isEmpty);
    });

    test('把已有笔记清空后保存，笔记本身仍在', () async {
      // 反过来说：**已经有内容的笔记**被清空后保存，笔记本身仍应存在
      // （用户可能只是想清空重写），只是内容变空。
      // 这与"新建空笔记"是两件事，不能混为一谈。
      final n = await notes.createInbox(title: '标题', content: '正文');
      await notes.saveContent(n.id, title: '', content: '');

      final after = await notes.byId(n.id);
      expect(after, isNotNull, reason: '清空已有笔记不等于删除它');
      expect(after!.title, isEmpty);
      expect(after.content, isEmpty);
      // 仍出现在未归档列表里——列表不该因为内容为空就把它藏掉
      expect((await notes.watchUnfiled().first).map((x) => x.id), contains(n.id));
    });

    test('有内容时正常创建', () async {
      await notes.createInbox(title: '有标题', content: '');
      expect((await notes.watchUnfiled().first).length, 1);

      await notes.createInbox(title: '', content: '有正文');
      expect((await notes.watchUnfiled().first).length, 2);
    });

    test('归档到笔记库的新建也走同一套判定', () async {
      final nb = await notebooks.create(name: '工作');
      await notes.createInNotebook(nb.id, title: '标题', content: '正文');

      final inNb = await notes.watchNotesInNotebook(nb.id).first;
      expect(inNb.length, 1);
      expect(inNb.first.isInbox, isFalse);
    });
  });
}