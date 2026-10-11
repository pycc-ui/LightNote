# LightNote（lightnote）

Flutter + Dart + SQLite(Drift) + DeepSeek API 的**本地优先**笔记应用。

核心链路：**速记 → 笔记库 → 阅读**。AI 不在这条链路上 —— 它是独立助手页，
进去对显式勾选的笔记下指令（整理、问答、增删改）。另有一条「轻笔记」AI 卡片流：
从你勾选的笔记库抽素材生成卡片，看到喜欢的收进笔记库。

两条设计原则：**轻**（少依赖、功能做减法、笔记库平铺）与**省 token** ——
理由与取舍见 [软件理念设计](docs/软件理念设计.md)。

---

## 快速编译

```powershell
flutter run -d windows             # 开发（热重载）
flutter build windows --release    # 给别人用的 Windows 包
flutter build apk --release        # 给别人用的安卓包

flutter analyze                    # 静态检查
flutter test                       # 测试（项目约定：只在大版本发布前跑）
```

产物位置：

| 平台 | 产物 | 怎么发出去 |
|---|---|---|
| Windows | `build\windows\x64\runner\Release\` | 整个目录打成 zip |
| Android | `build\app\outputs\flutter-apk\app-release.apk` | 发这一个文件 |

**版本号只改两个地方**：

| 文件 | 改什么 |
|---|---|
| `pubspec.yaml` | `version: 1.0.0+2` ← **源头**。Android 的 versionName/versionCode 与 Windows 的 exe 版本资源都由它派生 |
| `lib/core/app_info.dart` | `kAppVersion` ← Dart 运行时读不到 pubspec，所以复制一份（关于页显示、写进备份清单） |

`windows/runner/Runner.rc` 里也有个 `"1.0.0"`，那是**模板兜底值**，正常不用动。
`+2` 是构建号（每发一次 +1，商店要求只增不减），和 `1.0.0` 是两回事。

---

## 文档

**全部文档从 [docs/README.md](docs/README.md) 进。** 常看的：

| 想知道 | 看 |
|---|---|
| 这个软件想做成什么样 | [软件理念设计](docs/软件理念设计.md) |
| 有哪几个核心功能、做到什么程度 | [核心功能设计](docs/核心功能设计.md) |
| 代码怎么分层、怎么加一个功能、出错了怎么办 | [架构和功能开发流程设计](docs/架构和功能开发流程设计.md) |
| 界面有哪几屏、交互是什么样 | [界面设计](docs/界面设计.md) |
| 表结构、字段、迁移、切片算法 | [数据库设计](docs/数据库设计.md) |
| AI 怎么接、怎么省钱、有哪些工具 | [AI接入设计](docs/AI接入设计.md) |
| 新文件放哪、叫什么名字 | [目录设计](docs/目录设计.md) |
| 测试怎么跑、踩过哪些坑 | [测试设计](docs/测试设计.md) |
| 文档该怎么写 | [文档设计](docs/文档设计.md) |

---

## 关于命名

产品名统一用英文 **LightNote**，代码标识统一为 `lightnote`：

| 标识 | 值 | 说明 |
|---|---|---|
| Dart 包名 | `lightnote` | 源码里全部写成 `package:lightnote/...`（`pubspec.yaml` 的 `name`） |
| Android 包名 / applicationId | `com.lightnote.app` | `android/app/build.gradle.kts` 的 `namespace` 与 `applicationId`，与 `lib/core/app_info.dart` 的 `kAppPackageId` 一致；Kotlin 源码在 `android/app/src/main/kotlin/com/lightnote/app/` |
| 数据库文件名 | `lightnote.sqlite` | 与包名一致（`kDatabaseFileName` / `kBackupDbEntryPath`，两处必须同步）。**还没有正式发布过，所以现在改得动；发布之后即冻结**——改名等于让所有人的笔记"消失" |
| Windows 可执行文件名 | `smart_notes.exe` | **刻意保持原名**（`windows/CMakeLists.txt` 的 `BINARY_NAME`）：本机构建脚手架与 `bin\` 下的 shim 按这个名字找它，改名会断开编译通道，另案处理 |
