import 'package:flutter/material.dart';

import '../features/note/ui/inbox_page.dart';
import '../features/note/ui/library_page.dart';
import '../features/settings/ui/settings_page.dart';

/// 底部导航外壳：轻笔记 / 笔记库 / 设置。
///
/// 为什么单独一个文件：`main.dart` 只该负责「装配依赖 + 启动前自检」，
/// 把导航外壳塞进它会让人以为 App 的入口就是这个 Scaffold。
/// 现在 `main.dart` 是引导层，这里是 UI 顶层。
///
/// ## 为什么只有 3 个位置
///
/// **AI 不在这里**——它是"偶尔进去问一次"的助手，不是和三个主页面平级的
/// 常驻目的地。入口放在「笔记库」右下角、新建按钮的上面（见 `LibraryPage`
/// 的两个 FAB）。少一个 tab 也让底部栏更清爽。
///
/// 「记忆卡片复习」的入口已随功能一起移除（轻笔记卡片流取代了它）。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // IndexedStack 保留各页滚动位置与输入状态，切标签不会丢失上下文
      body: IndexedStack(
        index: _index,
        children: const [
          InboxPage(),
          LibraryPage(),
          SettingsPage(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.bolt_outlined),
            selectedIcon: Icon(Icons.bolt),
            label: '轻笔记',
          ),
          NavigationDestination(
            icon: Icon(Icons.library_books_outlined),
            selectedIcon: Icon(Icons.library_books),
            label: '笔记库',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}
