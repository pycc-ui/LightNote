# 修复 Flutter 在 Windows 上的插件符号链接
#
# 背景（这是一条真实踩过的坑，别删掉这段）：
#   `flutter build windows` 会为每个插件在
#     windows\flutter\ephemeral\.plugin_symlinks\<插件名>
#   建一个**目录符号链接**。建不出来就直接 throwToolExit：
#     "Building with plugins requires symlink support."
#
#   本机 RUTOLAPTOP\43720 不是管理员，创建符号链接需要
#   SeCreateSymbolicLinkPrivilege。这个权限在普通用户登录会话里是有的
#   （所以 cmd 的 mklink 能成功），但在受限令牌里会被剔除，
#   于是 dart 进程里的 Link.createSync 报 ERROR_PRIVILEGE_NOT_HELD(1314)。
#
#   Flutter 的逻辑是 `if (link.existsSync()) continue;` —— **只要链接已经存在
#   就不会再去建**。所以我们提前用 cmd mklink 把它建好，Flutter 就会跳过
#   link.createSync，报错也就不再发生。
#
#   优先用 junction（/J）而不是目录符号链接（/D）：
#   junction 在老版本 Windows 上也不需要额外权限，更稳。
#   两者 CMake 都当普通目录用。
#
# 用法：由 tool\run.ps1 在 build/release/run 之前自动调用，一般不用手敲。

param(
  [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

$depsFile = Join-Path $ProjectRoot '.flutter-plugins-dependencies'
if (-not (Test-Path $depsFile)) {
  Write-Host "跳过符号链接修复：找不到 $depsFile（先跑一次 flutter pub get）" -ForegroundColor DarkGray
  exit 0
}

$json = Get-Content $depsFile -Raw | ConvertFrom-Json
$plugins = $json.plugins.windows
if ($null -eq $plugins -or $plugins.Count -eq 0) {
  Write-Host '跳过符号链接修复：没有 Windows 插件' -ForegroundColor DarkGray
  exit 0
}

$linkRoot = Join-Path $ProjectRoot 'windows\flutter\ephemeral\.plugin_symlinks'
New-Item -ItemType Directory -Force -Path $linkRoot | Out-Null

$created = 0
$repaired = 0
$failed = @()

foreach ($p in $plugins) {
  $name = $p.name
  # .flutter-plugins-dependencies 里的路径在 Windows 上是双反斜杠转义，需要还原
  $target = $p.path -replace '\\\\', '\'
  $target = $target.TrimEnd('\')

  $link = Join-Path $linkRoot $name

  if (-not (Test-Path $target)) {
    $failed += "$name（目标不存在：$target）"
    continue
  }

  # 已存在且**指向正确目标**才跳过。
  #
  # 这里不能只判断 `Test-Path $link`：
  #   · 上个版本留在这里的 junction 会随工程一起被搬走，
  #     但 junction 里存的是**绝对路径**，搬完就指向一个不存在的老位置；
  #   · 而 Test-Path 对"断掉的 junction"返回的是 **true**
  #     （目录项本身在，只是目标没了）。
  # 于是脚本会认为"已经好了"直接跳过，Flutter 却因为链接无效而构建失败——
  # 这个 bug 真的发生过：工程从 Downloads\py 搬到 Downloads\LightNote 之后，
  # build 报 "Building with plugins requires symlink support."。
  #
  # 正确做法是解析链接的真实目标再比一次。
  $ok = $false
  if (Test-Path $link) {
    try {
      $resolved = (Get-Item $link -Force).Target
      if ($resolved) {
        # Target 可能是绝对路径，也可能是相对链接
        $abs = if ([System.IO.Path]::IsPathRooted($resolved)) {
          $resolved
        } else {
          Join-Path (Split-Path $link -Parent) $resolved
        }
        if ([string]::Equals(
            (Resolve-Path $abs -EA SilentlyContinue).Path,
            (Resolve-Path $target -EA SilentlyContinue).Path,
            [StringComparison]::OrdinalIgnoreCase)) {
          $ok = $true
        }
      }
    } catch {
      # 解析失败就当它无效，下面会重建
    }

    if (-not $ok) {
      # 目标是目录，junction 要连着里面的内容一起删，不会伤到源目录
      Remove-Item $link -Recurse -Force -EA SilentlyContinue
      $repaired++
    }
  }

  if ($ok) { continue }

  # 走 cmd 的 mklink：PowerShell 的 New-Item -ItemType SymbolicLink 同样会被
  # 权限拦住，而 mklink 在这个受限会话里是可用的。
  $out = & cmd /c mklink /J "`"$link`"" "`"$target`"" 2>&1
  if ($LASTEXITCODE -eq 0) {
    $created++
  } else {
    # junction 不行就退一步试真符号链接
    $out2 = & cmd /c mklink /D "`"$link`"" "`"$target`"" 2>&1
    if ($LASTEXITCODE -eq 0) {
      $created++
    } else {
      $failed += "$name -> $target`n      /J: $out`n      /D: $out2"
    }
  }
}

if ($created -gt 0) {
  Write-Host "已建立 $created 个插件链接（$linkRoot）" -ForegroundColor DarkGray
}
if ($repaired -gt 0) {
  Write-Host "已重建 $repaired 个失效链接（工程搬家后 junction 里的绝对路径会失效）" -ForegroundColor DarkGray
}

if ($failed.Count -gt 0) {
  Write-Host ''
  Write-Host '以下插件无法建立链接，构建很可能失败：' -ForegroundColor Yellow
  foreach ($f in $failed) { Write-Host "  - $f" -ForegroundColor Yellow }
  Write-Host ''
  Write-Host '处理办法（任选其一）：' -ForegroundColor Yellow
  Write-Host '  1) 以管理员身份打开 PowerShell，手动执行：'
  Write-Host "     mklink /J `"$linkRoot\<插件名>`" `"<插件目录>`""
  Write-Host '  2) 把项目与 Flutter SDK 放到同一个盘，并取消“开发者模式”相关限制后重试'
  exit 1
}

exit 0
