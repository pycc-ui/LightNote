import 'package:flutter/material.dart';

import '../../../../core/app_info.dart';
import '../widgets/settings_scaffold.dart';

/// 关于：版本、技术栈、隐私说明。
class AboutSettingsPage extends StatelessWidget {
  const AboutSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: '关于',
      children: [
        const SettingsGroupHeader('版本'),
        const SettingsGroup(
          children: [
            ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('版本'),
              subtitle: Text('$kAppDisplayName v$kAppVersion'),
            ),
            ListTile(
              leading: Icon(Icons.build_outlined),
              title: Text('技术栈'),
              subtitle: Text('Flutter · Dart · SQLite(Drift) · DeepSeek'),
            ),
          ],
        ),
        const SettingsGroupHeader('数据与隐私'),
        const SettingsNote(
          '本 App 数据默认只存本机，不联网、不同步。\n\n'
          '只有在你主动使用 AI 功能并勾选笔记时，'
          '相关内容才会发送给 DeepSeek。API Key 存在系统钥匙串里，'
          '既不上传也不进备份包。\n\n'
          '笔记库是一个标准 SQLite 文件，可以用「备份与恢复」导出后在'
          '任何 SQLite 工具里打开查看——数据是你的。',
        ),
      ],
    );
  }
}
