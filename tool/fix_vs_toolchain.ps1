# 修复「VS 工具链找不到」——用目录联接把老路径接回工作区里的实际位置
#
# ============================================================================
# 背景（这是一条真实踩过的坑，别删掉这段）
# ============================================================================
#
# tools\vsbuildtools 是从旧工作区（Downloads\py\tools）**整体搬过来**的。
# 但 VS 的安装位置不在目录里，而是记在：
#
#   C:\ProgramData\Microsoft\VisualStudio\Packages\_Instances\<实例ID>\state.json
#
# `vswhere.exe` 就是读这个文件来回答"VS 装在哪"的，flutter 又依赖 vswhere。
# 搬目录不会同步它，于是：
#
#   · 编译器文件都在新位置，VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\cl.exe 能打开
#   · 但 vswhere 报 isComplete=false、state=14
#   · flutter 报 "Unable to find suitable Visual Studio toolchain"
#
# 三个修法，这里用第 2 个：
#
#   1) 用管理员改 ProgramData 里的 state.json（动系统安装记录，改坏更难收拾）
#   2) **建目录联接 mklink /J，把老路径接回新位置** ← 本脚本
#      vswhere 一看路径存在，立刻恢复 isComplete=true。不需要管理员，可逆。
#   3) 重装 VS Build Tools 到固定位置（最彻底，但要十几分钟）
#
# 代价：VS 的"官方认知"仍然是老路径，**所以这个联接不能删**。
# 这也是为什么本脚本每次构建前都会检查一遍——删了会自动接回来。
#
# ============================================================================

param(
  [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

$workspace = Split-Path -Parent $ProjectRoot
$toolsRoot = Join-Path $workspace 'tools'

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) {
  # 没装 vswhere 说明这台机器上没有 VS，交给 flutter doctor 去报
  Write-Host '跳过 VS 工具链检查：找不到 vswhere.exe' -ForegroundColor DarkGray
  exit 0
}

$raw = & $vswhere -all -prerelease -products * -format json 2>$null | Out-String
if (-not $raw -or $raw.Trim() -eq '' -or $raw.Trim() -eq '[]') {
  Write-Host '跳过 VS 工具链检查：vswhere 没找到任何 VS 实例' -ForegroundColor DarkGray
  exit 0
}

try {
  $instances = @($raw | ConvertFrom-Json)
} catch {
  Write-Host "跳过 VS 工具链检查：无法解析 vswhere 输出（$($_.Exception.Message)）" -ForegroundColor DarkGray
  exit 0
}

$repaired = 0
$problems = @()

foreach ($inst in $instances) {
  $recorded = $inst.installationPath
  if (-not $recorded) { continue }
  if (Test-Path $recorded) { continue }   # 记录位置有效，不用管

  # 记录位置失效了。猜实际位置：<工作区>\tools\<原目录名>
  $realName = Split-Path $recorded -Leaf
  $real = Join-Path $toolsRoot $realName

  Write-Host ''
  Write-Host "VS 工具链的记录位置已失效：" -ForegroundColor Yellow
  Write-Host "  记录：$recorded"
  Write-Host "  实际：$real"

  if (-not (Test-Path $real)) {
    $problems += "在 $real 也找不到工具链。只能重装 VS Build Tools，或把工具链放回该位置。"
    continue
  }

  $parent = Split-Path $recorded -Parent
  if (-not (Test-Path $parent)) {
    New-Item -ItemType Directory -Force -Path $parent -ErrorAction SilentlyContinue | Out-Null
  }
  if (-not (Test-Path $parent)) {
    $problems += "无法创建目录 $parent（权限不足？）。请以管理员身份手动执行：`n" +
                 "    mklink /J `"$recorded`" `"$real`""
    continue
  }

  # 用 cmd 的 mklink：PowerShell 的 New-Item -ItemType SymbolicLink 会被权限拦住。
  # junction（/J）不需要额外权限，CMake 与 MSVC 都当普通目录用。
  $out = & cmd /c mklink /J "`"$recorded`"" "`"$real`"" 2>&1

  if (Test-Path $recorded) {
    Write-Host "  ✅ 已建立目录联接接回实际位置" -ForegroundColor Green
    Write-Host '     这个联接不要删——删了 flutter build 就找不到编译器。' -ForegroundColor DarkGray
    $repaired++
  } else {
    $problems += "建立联接失败：$out`n    请手动执行： mklink /J `"$recorded`" `"$real`""
  }
}

if ($repaired -gt 0) {
  Write-Host ''
  Write-Host "已修复 $repaired 个 VS 工具链路径。" -ForegroundColor Green
  Write-Host '（说明：VS 把安装位置记在 ProgramData 的 state.json 里，' -ForegroundColor DarkGray
  Write-Host '  搬动 tools 目录不会同步它，这是自动接回来的。）' -ForegroundColor DarkGray
}

if ($problems.Count -gt 0) {
  Write-Host ''
  Write-Host 'VS 工具链有问题，构建会失败：' -ForegroundColor Red
  foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Red }
  Write-Host ''
  Write-Host '彻底解决的办法：把 tools 目录搬到固定位置后重装 VS Build Tools；' -ForegroundColor Yellow
  Write-Host '或用管理员权限修改 state.json 里的 installationPath。' -ForegroundColor Yellow
  exit 1
}

exit 0
