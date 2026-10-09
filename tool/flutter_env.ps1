# Flutter 环境包装脚本
#
# 为什么需要这个：本机 dart.exe 直接运行时会在
#   C:\Users\43720\AppData\Roaming\.dart-tool\dart-flutter-telemetry.config
# 上抛 PathAccessException（OS Error 5, 拒绝访问），
# 崩在 unified_analytics 的遥测初始化里，连一行用户代码都跑不到。
#
# 对照实验结论：
#   · PowerShell 自己建同一个目录 -> 成功
#   · 只设 DART_SUPPRESS_ANALYTICS=1 -> 仍然失败
#   · 把 APPDATA / LOCALAPPDATA 重定向到工作区 -> 成功
#
# 所以这里只在「本进程及其子进程」内重定向这几个变量，
# 不写用户级/机器级环境变量，避免影响系统上其他程序。
#
# 用法：
#   . .\tool\flutter_env.ps1          # 在当前会话生效（点源）
#   flutter --version
#
# 或直接：
#   .\tool\flutter_env.ps1 -Command 'flutter analyze'

param(
  [string]$Command
)

$ErrorActionPreference = 'Stop'

# ---- 路径推导（不要写死绝对路径）----
#
# 曾经这里写死成 'C:\Users\43720\Downloads\py\tools\...'，结果整个工程
# 从 Downloads\py 搬到 Downloads\LightNote 之后，全项目的脚本一起失效。
# 现在改成从本脚本位置往上推：
#
#   <项目>            = smart_notes
#   <项目>/tool       = 本文件所在目录（$PSScriptRoot）
#   <工作区>          = <项目> 的上一级，工具链就在它下面的 tools/
#
# 这样只要保持「smart_notes 与 tools 同级」这个相对结构，
# 放在哪个盘、哪一级目录都无所谓。
$toolDir   = $PSScriptRoot
$project   = Split-Path -Parent $toolDir
$workspace = Split-Path -Parent $project

$toolsRoot   = Join-Path $workspace 'tools'
$flutterRoot = Join-Path $toolsRoot 'flutter'
$pubCache    = Join-Path $toolsRoot 'pub-cache'
$fakeAppData = Join-Path $toolsRoot 'appdata'
$gitCmd      = 'C:\Program Files\Git\cmd'

# 结构不对时给出明确指引，而不是让后面的命令报一堆莫名其妙的错
if (-not (Test-Path (Join-Path $flutterRoot 'bin\flutter.bat'))) {
  Write-Host ''
  Write-Host "找不到 Flutter SDK：$flutterRoot\bin\flutter.bat" -ForegroundColor Red
  Write-Host ''
  Write-Host '脚本按「<工作区>\smart_notes 与 <工作区>\tools 同级」来推导路径。' -ForegroundColor Yellow
  Write-Host "当前推导结果：" -ForegroundColor Yellow
  Write-Host "  项目      = $project"
  Write-Host "  工作区    = $workspace"
  Write-Host "  工具链    = $toolsRoot"
  Write-Host ''
  Write-Host '如果工具链在别处，直接改本文件上方 $toolsRoot 的推导即可。' -ForegroundColor Yellow
  throw "Flutter SDK 不在预期位置"
}

# ---------------------------------------------------------------------------
# Visual Studio 工具链：确认它的"记录位置"还有效
#
# VS 把安装位置记在 ProgramData 的 state.json 里（vswhere 读它，flutter 依赖
# vswhere），搬动 tools 目录不会同步，于是会出现"编译器文件都在、却报
# Unable to find suitable Visual Studio toolchain"。
#
# 具体原因、三个修法与代价，全部写在 tool\fix_vs_toolchain.ps1 的头部注释里。
# 这里只负责调用它——不把逻辑塞进来，是为了那一整套说明有一个明确的归属地。
# ---------------------------------------------------------------------------

$fixVs = Join-Path $PSScriptRoot 'fix_vs_toolchain.ps1'
if (Test-Path $fixVs) {
  & $fixVs -ProjectRoot $project
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

# 依赖目录与临时目录先建好，避免首次运行时再去创建
foreach ($d in @(
    "$fakeAppData\Roaming",
    "$fakeAppData\Local",
    "$fakeAppData\Temp",
    $pubCache
  )) {
  New-Item -ItemType Directory -Force -Path $d | Out-Null
}

# ---- 重定向（仅本进程）----
$env:APPDATA      = "$fakeAppData\Roaming"
$env:LOCALAPPDATA = "$fakeAppData\Local"
$env:PUB_CACHE    = $pubCache

# TEMP/TMP 必须一起重定向：pub 会用它创建临时目录，
# 若不改，仍会指向真实的 %LOCALAPPDATA%\Temp 而报「拒绝访问」，
# 表现为 'pub upgrade' 无限重试。
$env:TEMP = "$fakeAppData\Temp"
$env:TMP  = "$fakeAppData\Temp"

# 关掉遥测，少一次无谓的文件写入
$env:DART_SUPPRESS_ANALYTICS = '1'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'

# ---- PATH ----
$env:Path = "$flutterRoot\bin;$gitCmd;" + $env:Path

# ---- 自检 ----
$dart = Join-Path $flutterRoot 'bin\cache\dart-sdk\bin\dart.exe'
if (-not (Test-Path $dart)) { throw "找不到 dart.exe：$dart" }

Write-Host '环境已就绪：' -ForegroundColor Green
Write-Host "  项目          = $project"
Write-Host "  FLUTTER_ROOT  = $flutterRoot"
Write-Host "  PUB_CACHE     = $pubCache"
Write-Host "  APPDATA       = $env:APPDATA"
Write-Host "  LOCALAPPDATA  = $env:LOCALAPPDATA"
Write-Host "  PATH 前缀      = $flutterRoot\bin"

if ($Command) {
  Write-Host ''
  Write-Host "执行: $Command" -ForegroundColor Cyan
  Invoke-Expression $Command
  exit $LASTEXITCODE
}
