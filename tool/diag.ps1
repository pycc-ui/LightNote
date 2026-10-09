# 环境诊断：确认构建/运行的前提条件是否满足
. (Join-Path $PSScriptRoot 'flutter_env.ps1') | Out-Null

Write-Output ''
Write-Output '=== 1) 工具链 ==='
Write-Output "  flutter: $((Get-Command flutter -EA SilentlyContinue).Source)"
Write-Output "  dart:    $((Get-Command dart -EA SilentlyContinue).Source)"
Write-Output "  git:     $((Get-Command git -EA SilentlyContinue).Source)"

Write-Output ''
Write-Output '=== 2) 符号链接能力（决定能否构建含插件的 Windows 版）==='
# 从 $PSScriptRoot 推导，不写死绝对路径（曾经写死过，工程一搬家就失效）
$project = Split-Path -Parent $PSScriptRoot
$target = Join-Path $project 'pubspec.yaml'
$link = Join-Path (Split-Path -Parent $project) '_symtest'
if (Test-Path $link) { Remove-Item $link -Force -EA SilentlyContinue }
try {
  New-Item -ItemType SymbolicLink -Path $link -Target $target -EA Stop | Out-Null
  Write-Output '  ✅ 可以创建符号链接 —— flutter build/run 应该能成功'
  Remove-Item $link -Force
} catch {
  Write-Output "  ❌ 不能创建符号链接: $($_.Exception.Message)"
  Write-Output '     本次会话会由 tool\fix_plugin_symlinks.ps1 用 mklink /J 兜住，'
  Write-Output '     所以构建仍然能过；这里是给你判断"是不是权限问题"用的。'
}

Write-Output ''
Write-Output '=== 3) 平台目录 ==='
foreach ($d in @('android', 'windows', 'lib', 'test')) {
  Write-Output "  $d -> $(Test-Path (Join-Path $project $d))"
}

Write-Output ''
Write-Output '=== 4) Drift 生成代码 ==='
$g = Join-Path $project 'lib\core\db\app_database.g.dart'
Write-Output "  app_database.g.dart -> $(Test-Path $g)"
if (Test-Path $g) {
  Write-Output "  大小: $([math]::Round((Get-Item $g).Length/1KB,1)) KB"
}

Write-Output ''
Write-Output '=== 5) 构建产物 ==='
$exe = Join-Path $project 'build\windows\x64\runner\Debug\smart_notes.exe'
Write-Output "  $exe"
Write-Output "  存在: $(Test-Path $exe)"

Write-Output ''
Write-Output '=== 6) 执行策略 ==='
Get-ExecutionPolicy -List | Format-Table -AutoSize
