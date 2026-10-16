# LightNote（轻笔记）

> 一款纯本地、AI 辅助的轻量级笔记应用。所有笔记存在你手机里，AI 需要你自己的 DeepSeek API Key。

Flutter + Dart + SQLite(Drift) + DeepSeek API。核心链路：**速记 → 笔记库 → 阅读**。AI 是独立助手，负责整理、问答、增删改；还有一条「轻笔记」卡片流，从你的笔记里抽素材生成灵感卡片，看到喜欢的可以收进笔记库。

两条原则：**轻**（少依赖、做减法）与**省 token**（用户自备 Key，不经过服务器）。

---

## 📥 下载安装

**最新版本：[Releases 页面](https://github.com/pycc-ui/LightNote/releases/latest)**

下载 `LightNote-v1.0.0-release.apk`，传到手机点击安装即可（可能需要允许「安装未知来源应用」）。

> 目前仅编译了 **arm64** 架构，适配绝大多数现代手机。

## 🚀 快速开始

1. 去 [DeepSeek 开放平台](https://platform.deepseek.com/) 注册账号，申请一个 API Key。
2. 打开 App →「设置」→ 填入 Key。
3. 开始记笔记。

> 没有 Key 也能用，只是 AI 功能不可用。所有笔记都存在本地，不需要注册、不需要登录。

## ✨ 核心特性

- **纯本地存储**：所有笔记存在手机 SQLite，无云同步，隐私安全。
- **AI 增删改查**：对勾选的笔记下指令，AI 帮你整理、改写、问答。
- **本地语义检索**：笔记在本地算成向量，「会议记录」也能命中标题里没有这两个字的笔记；模型随包发布，不联网。
- **轻笔记卡片流**：AI 从笔记库抽素材生成卡片，滑动阅读，收下喜欢的。
- **Markdown 渲染**：支持数学公式（LaTeX）、代码块、表格、任务列表。
- **流式输出**：AI 回答逐字显示，不用等整个回复。

## 🛠️ 自己编译

需要 Flutter stable（Dart ≥ 3.10，即 Flutter ≥ 3.35，见 `pubspec.yaml` 的 `environment`）。

```powershell
flutter build apk --release --target-platform android-arm64
```

产物在 `build\app\outputs\flutter-apk\`。arm64 的 release 包约 **56MB** —— 大的是打进包的嵌入模型
（23.9MB，压缩后 13.6MB）与 `libonnxruntime.so`（13.6MB），它们都在 `assets/models/` 里随仓库走，
clone 下来就带着，不用另外下载。

Windows 桌面版：`flutter build windows --release`，产物在 `build\windows\x64\runner\Release\`。

跑测试用 `tool/test.sh`（**别直接敲 `flutter test`**：嵌入模型的原生库要 `LD_LIBRARY_PATH`，脚本负责配好，
不配的话碰模型的用例会跳过而不是失败）。开发调试、静态检查等其他命令见
[架构和功能开发流程设计](docs/架构和功能开发流程设计.md)。

## 📚 开发者文档

完整文档从 [docs/README.md](docs/README.md) 进。常看的：

| 想知道                  | 看                                  |
| -------------------- | ---------------------------------- |
| 这个软件想做成什么样           | [软件理念设计](docs/软件理念设计.md)           |
| 有哪几个核心功能、做到什么程度      | [核心功能设计](docs/核心功能设计.md)           |
| 代码怎么分层、怎么加一个功能、出错怎么办 | [架构和功能开发流程设计](docs/架构和功能开发流程设计.md) |
| 界面有哪几屏、交互是什么样        | [界面设计](docs/界面设计.md)               |
| 表结构、字段、迁移、切片算法       | [数据库设计](docs/数据库设计.md)             |
| AI 怎么接、怎么省钱、有哪些工具    | [AI接入设计](docs/AI接入设计.md)           |
| AI 用 SQL 怎么读写笔记、有哪些函数 | [AI操作数据库设计](docs/AI操作数据库设计.md)     |
| 新文件放哪、叫什么名字          | [目录设计](docs/目录设计.md)               |
| 测试怎么跑、踩过哪些坑          | [测试设计](docs/测试设计.md)               |
| 文档该怎么写               | [文档设计](docs/文档设计.md)               |

## 📄 开源协议

[MIT License](LICENSE)。随意使用、修改、分发，保留版权声明即可。
