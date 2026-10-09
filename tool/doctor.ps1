# 完整环境诊断：把两条运行路径的缺口一次看清
. (Join-Path $PSScriptRoot 'flutter_env.ps1') | Out-Null

$project = Split-Path -Parent $PSScriptRoot
Set-Location $project

Write-Output '=== flutter doctor -v ==='
flutter doctor -v
