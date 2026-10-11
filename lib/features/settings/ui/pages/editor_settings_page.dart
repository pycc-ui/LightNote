import 'package:flutter/material.dart';

import '../widgets/settings_scaffold.dart';

/// 编辑器设置。
///
/// **「自动保存」开关已移除**：保存方式定案为**手动** ——
/// 编辑态右上角是一个勾，点了才保存，保存后进阅读态。
/// 既然没有可配的余地，留一个开关只会让人以为还能自动保存。
///
/// 页面本身保留：以后加编辑相关选项（行距、默认新建位置、
/// Markdown 快捷方式等）时不用再动主页结构。
class EditorSettingsPage extends StatelessWidget {
  const EditorSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const SettingsSubPage(
      title: '编辑器',
      children: [
        SettingsGroupHeader('保存'),
        SettingsGroup(
          children: [
            ListTile(
              leading: Icon(Icons.check_circle_outline),
              title: Text('手动保存'),
              subtitle: Text(
                '编辑时右上角是一个勾，点它保存并进入阅读态。'
                '退出时如果有未保存的改动，会先问你。',
              ),
            ),
          ],
        ),
        SettingsNote(
          '正文只在保存那一下写库 —— 切片（搜索用的分段）也就在那一刻更新，'
          '并且当改动不足 20% 时会跳过重切，避免为了几个错别字把整篇重算一遍。',
        ),
      ],
    );
  }
}
