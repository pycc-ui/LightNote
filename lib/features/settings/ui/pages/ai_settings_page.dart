import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/widgets/log_bar.dart';
import '../../../../core/secure/secure_store.dart';
import '../../../../core/theme/dimens.dart';
import '../../../ai/data/deepseek_config.dart';
import '../../../ai/domain/ai_repository.dart';
import '../widgets/settings_scaffold.dart';

/// AI 设置：只有 API Key（保存 / 测试连接 / 删除）。
///
/// 「模型」「思考模式」「数据授权」这三项都已移除：前两项是装饰性的（存了没人读），
/// 第三项与 AI 页的授权横幅重复，而那条横幅也按设计定案整体去掉了。
class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key});

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  final _keyController = TextEditingController();

  bool _loaded = false;
  bool _obscure = true;
  bool _hasKey = false;
  bool _savingKey = false;
  bool _testing = false;
  String? _testResult;

  // ⚠️ 这里不加「默认模型」与「深度整理时启用思考模式」两项：
  //   · 模型：现在是**每个会话**在 AI 页底部选的（原先是选工作区的位置），
  //     卡片流/摘要固定 flash；放一个全局开关会与"按会话选"打架。
  //   · 思考开关：同样用的是**每个会话**的 `thinkingEffort`。
  // 一个改了没反应的开关比没有这个开关更糟（用户会以为他调过了）。

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final key = await SecureStore.readApiKey();
    if (!mounted) return;
    if (!mounted) return;
    setState(() {
      _hasKey = key != null;
      // 已保存的 Key 不回填明文，只显示状态；用户想换就直接输入新的
      _loaded = true;
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    // 走 LogBar 而不是直接 showSnackBar：LogBar 里显式设了 persist: false，
    // 避免以后给提示加「撤销」按钮时又碰上"带 action 的 SnackBar 永不消失"那个坑。
    LogBar.info(context, message);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final theme = Theme.of(context);

    return SettingsSubPage(
      title: 'AI',
      children: [
        const SettingsGroupHeader('DeepSeek API Key'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _hasKey ? Icons.check_circle : Icons.error_outline,
                        size: 18,
                        color: _hasKey
                            ? theme.colorScheme.primary
                            : theme.colorScheme.error,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        _hasKey ? 'API Key 已配置' : '尚未配置 API Key',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Key 只保存在本机系统钥匙串（Android Keystore / '
                    'Windows DPAPI），不会写入代码、日志或联网上传，'
                    '也**不会进备份包**。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextField(
                    controller: _keyController,
                    obscureText: _obscure,
                    decoration: InputDecoration(
                      labelText: _hasKey ? '输入新的 Key 以替换' : 'sk-...',
                      prefixIcon: const Icon(Icons.key_outlined),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscure ? Icons.visibility_off : Icons.visibility,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm + 4),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: _savingKey ? null : _saveKey,
                          child: Text(_savingKey ? '保存中…' : '保存 Key'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _testing ? null : _test,
                          child: Text(_testing ? '测试中…' : '测试连接'),
                        ),
                      ),
                    ],
                  ),
                  if (_testResult != null) ...[
                    const SizedBox(height: AppSpacing.sm + 4),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _testResult!,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(height: 1.5),
                      ),
                    ),
                  ],
                  if (_hasKey)
                    TextButton.icon(
                      onPressed: _clearKey,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('删除已保存的 Key'),
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),

        // 这里不放「模型」「深度整理时启用思考模式」两项（理由见 `_load` 上方的说明）。
        //
        // 模型（`deepseek-flash` / `deepseek-v4-pro`）与思考强度都是**每个会话**
        // 在 AI 页底部选的，不放在全局设置里 —— 放这里会让人以为它能影响所有会话。
        const SettingsNote(
          '模型与思考强度都在 AI 页底部按会话选择；'
          '卡片流固定使用 `deepseek-flash`。'),
        const SettingsNote(
          '思考模式下 temperature 参数不生效（官方行为）。'
          '要让输出稳定，靠的是提示词约束与 JSON 输出，不是调温度。',
        ),

        // 授权确认机制整体不做（用户定案）：设置里没有开关，AI 页也没有首次授权
        // 横幅与发送闸门 —— 插上 Key 直接能用。
        //
        // 下面这条是**告知**，不是需要点同意的确认：它说清什么会被发出去，
        // 但不会挡住任何人。设计上"轻"优先，不把隐私做成一个功能。
        const SettingsNote(
          '只有你主动使用 AI 并勾选笔记时，相关内容才会发给 DeepSeek。'
          '未勾选任何笔记时，只发送你输入的指令本身。',
        ),
      ],
    );
  }


  Future<void> _saveKey() async {
    final key = _keyController.text.trim();
    if (key.isEmpty) {
      _toast('请输入 API Key');
      return;
    }
    if (!key.startsWith('sk-')) {
      _toast('看起来不像 DeepSeek 的 Key（通常以 sk- 开头），仍会保存。');
    }
    setState(() => _savingKey = true);
    await context.read<AiRepository>().saveApiKey(key);
    if (!mounted) return;
    setState(() {
      _savingKey = false;
      _hasKey = true;
      _keyController.clear();
    });
    _toast('已保存');
  }

  Future<void> _clearKey() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除 API Key'),
        content: const Text('删除后 AI 功能将不可用，已生成的摘要与卡片不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    await context.read<AiRepository>().clearApiKey();
    if (!mounted) return;
    setState(() {
      _hasKey = false;
      _testResult = null;
    });
    _toast('已删除');
  }

  Future<void> _test() async {
    final pending = _keyController.text.trim();
    setState(() {
      _testing = true;
      _testResult = null;
    });

    final repo = context.read<AiRepository>();
    try {
      // 输入框里有新 Key 时先用它测试，不落库
      if (pending.isNotEmpty) repo.client.setApiKey(pending);
      // 用默认的 flash 做连通性自检：AI 页可按会话选 pro，
      // 但"连接能不能通"用哪个模型测都行，flash 最省。
      final result =
          await repo.testConnection(model: DeepSeekConfig.modelFlash);
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testResult = '✅ 连接成功\n'
            '模型：${DeepSeekConfig.modelFlash}\n'
            '返回：$result';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testResult = '❌ 连接失败：$e';
      });
      // 测试用的临时 Key 不保留，恢复已保存的那个
      if (pending.isNotEmpty) await repo.init();
    }
  }
}
