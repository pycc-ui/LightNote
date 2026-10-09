# LightNote —— 一键构建/运行脚本
#
# 用法（在 PowerShell 里，当前目录随意）：
#   <工程>\tool\run.cmd              # 构建 debug 并运行
#   <工程>\tool\run.cmd build        # 只构建 debug
#   <工程>\tool\run.cmd release      # 构建 release（可拷走单独用）
#   <工程>\tool\run.cmd test         # 跑测试
#   <工程>\tool\run.cmd analyze      # 静态分析
#   <工程>\tool\run.cmd doctor       # 环境自检
#   <工程>\tool\run.cmd pubget       # flutter pub get
#   <工程>\tool\run.cmd raw <参数>   # 透传任意 flutter 命令
#
# 或者直接双击工程根目录的 rebuild-and-run.cmd。
#
# 一律用 .cmd 而不是 .ps1：本机执行策略会拦截 .ps1，
# 而且 .ps1 的环境变量在脚本结束后会丢失。
#
# 为什么需要包装脚本而不是直接敲 flutter：
#   本机 dart.exe 无法写入真实的 AppData（会抛 PathAccessException，
#   崩在遥测初始化里），所以脚本把 APPDATA / LOCALAPPDATA / TEMP / PUB_CACHE
#   重定向到了工作区目录。详见 tool\flutter_env.ps1 的注释。
#
# 所有路径都从 $PSScriptRoot 推导，不写死绝对路径。

param(
  [ValidateSet('run', 'build', 'release', 'test', 'analyze', 'doctor', 'pubget', 'raw')]
  [string]$Mode = 'run',
  [string]$Device = 'windows',
  [string]$Args = ''
)

$ErrorActionPreference = 'Continue'

# 载入环境（重定向 + PATH）
. (Join-Path $PSScriptRoot 'flutter_env.ps1') | Out-Null

$project = Split-Path -Parent $PSScriptRoot
Set-Location $project

Write-Host ''
Write-Host "项目目录: $project" -ForegroundColor Cyan
Write-Host "模式:     $Mode" -ForegroundColor Cyan
Write-Host ''

$sw = [System.Diagnostics.Stopwatch]::StartNew()

# 构建 Windows 之前先补齐插件链接。
# 起因：本机普通用户令牌没有 SeCreateSymbolicLinkPrivilege，
# dart 建符号链接会失败，flutter 直接拒绝构建。详见脚本内注释。
if ($Mode -in @('build', 'release', 'run')) {
  & (Join-Path $PSScriptRoot 'fix_plugin_symlinks.ps1') -ProjectRoot $project
  if ($LASTEXITCODE -ne 0) {
    Write-Host '插件链接修复失败，已中止构建。' -ForegroundColor Red
    exit 1
  }
}

switch ($Mode) {
  'doctor'  { flutter doctor -v }
  'analyze' { flutter analyze }
  'test'    { flutter test }
  'pubget'  { flutter pub get }
  'raw'     { Invoke-Expression "flutter $Args" }
  'build'   { flutter build windows --debug }
  'release' { flutter build windows --release }
  'run'     { flutter run -d $Device }
}

$code = $LASTEXITCODE
$sw.Stop()
$secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)

Write-Host ''
if ($code -eq 0) {
  Write-Host "完成，耗时 ${secs}s" -ForegroundColor Green
} else {
  Write-Host "失败（exit=$code），耗时 ${secs}s" -ForegroundColor Red
}

if ($Mode -in @('build', 'run', 'release')) {
  $sub = if ($Mode -eq 'release') { 'Release' } else { 'Debug' }
  $exe = Join-Path $project "build\windows\x64\runner\$sub\smart_notes.exe"
  if (Test-Path $exe) {
    $size = [math]::Round((Get-Item $exe).Length / 1MB, 2)
    Write-Host ''
    Write-Host "可执行文件: $exe  (${size} MB)" -ForegroundColor Green
    if ($Mode -eq 'release') {
      Write-Host ''
      Write-Host 'Release 版整个目录可以拷到别处或别的电脑单独运行：' -ForegroundColor Cyan
      Write-Host "  $(Split-Path $exe -Parent)"
      Write-Host '（Debug 版不行：依赖工作区里的构建产物）'
    }
  }
}

exit $code
