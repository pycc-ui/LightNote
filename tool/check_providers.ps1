param(
  # 默认扫描本脚本所在工程的 lib/ 与 test/。不写死绝对路径：
  # 这里原来写死成 C:\Users\43720\Downloads\py\smart_notes，工程一搬家就失效。
  [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

# 交叉校验 Provider 注册与实际使用。
#
# 为什么需要：`context.read<X>()` 在 X 未注册时不会编译报错，
# 只会在运行时抛 ProviderNotFoundException。没有 Flutter SDK 时
# 这类错误完全不可见，所以用静态交叉引用把它提前抓出来。

$libDir  = Join-Path $Root 'lib'
$mainDart = Join-Path $libDir 'main.dart'

if (-not (Test-Path $mainDart)) { Write-Error "找不到 $mainDart"; exit 1 }

$mainSrc = Get-Content -Raw -LiteralPath $mainDart

# --- 1) 收集 main.dart 里注册的类型 ---
$registered = New-Object System.Collections.Generic.HashSet[string]

# Provider<X> / ProxyProvider<X, R> / ProxyProvider2<A, B, R> ...
foreach ($m in [regex]::Matches($mainSrc, '(Proxy)?Provider\d?<([^>]+)>')) {
  $args = $m.Groups[2].Value
  # 参数列表的最后一个泛型参数是「被提供的类型」
  $parts = $args -split ','
  $provided = $parts[-1].Trim()
  if ($provided) { [void]$registered.Add($provided) }
}

# --- 2) 收集所有 context.read<X>() / context.watch<X>() / context.select ---
$used = @{}
foreach ($f in Get-ChildItem -Recurse -File -Filter *.dart -Path $libDir) {
  $src = Get-Content -Raw -LiteralPath $f.FullName
  $rel = $f.FullName.Replace("$Root\", '')
  foreach ($m in [regex]::Matches($src, 'context\.(read|watch)<([A-Za-z_][A-Za-z0-9_]*)>')) {
    $t = $m.Groups[2].Value
    if (-not $used.ContainsKey($t)) { $used[$t] = New-Object System.Collections.ArrayList }
    if (-not $used[$t].Contains($rel)) { [void]$used[$t].Add($rel) }
  }
  # Provider.of<X>(context)
  foreach ($m in [regex]::Matches($src, 'Provider\.of<([A-Za-z_][A-Za-z0-9_]*)>')) {
    $t = $m.Groups[1].Value
    if (-not $used.ContainsKey($t)) { $used[$t] = New-Object System.Collections.ArrayList }
    if (-not $used[$t].Contains($rel)) { [void]$used[$t].Add($rel) }
  }
}

Write-Output '=== main.dart 中注册的类型 ==='
$registered | Sort-Object | ForEach-Object { Write-Output "  $_" }

Write-Output ''
Write-Output '=== 使用点交叉校验 ==='

$missing = @()
foreach ($t in ($used.Keys | Sort-Object)) {
  $files = ($used[$t] | Sort-Object) -join ', '
  if ($registered.Contains($t)) {
    Write-Output ("  [OK]      {0,-24} <- {1}" -f $t, $files)
  } else {
    Write-Output ("  [MISSING] {0,-24} <- {1}" -f $t, $files)
    $missing += $t
  }
}

Write-Output ''
if ($missing.Count -eq 0) {
  Write-Output '全部使用点都已在 main.dart 注册。'
} else {
  Write-Output "发现 $($missing.Count) 个未注册类型：$($missing -join ', ')"
}

# --- 3) 反向检查：注册了但从未使用（提示，不算错误）---
Write-Output ''
Write-Output '=== 注册但未被读取的类型（仅提示）==='
$unused = $registered | Where-Object { -not $used.ContainsKey($_) }
if ($unused) { $unused | Sort-Object | ForEach-Object { Write-Output "  $_" } }
else { Write-Output '  无' }

# --- 4) 检查不带类型参数的 context.read()/watch()/Provider.of() ---
#
# 这类写法不报编译错，但运行时会抛 ProviderNotFoundException：
#   context.read()        取到的是 BuildContext 自身，不是任何被提供的对象
#   context.watch()       同上
#   Provider.of(context)  同上
#
# 真实踩过：`SeedData.ensureSeeded(context.read())` 让 AI 页每次打开都抛
# "Could not find the correct Provider<BuildContext>"。
# flutter analyze 看不见（类型上说得通），只有真机启动才暴露，所以这里显式扫。
Write-Output ''
Write-Output '=== 无类型参数的 context.read()/watch()/Provider.of()（运行时必炸）==='
$bare = @()
foreach ($f in Get-ChildItem -Recurse -File -Filter *.dart -Path $libDir) {
  $src = Get-Content -Raw -LiteralPath $f.FullName
  $rel = $f.FullName.Replace("$Root\", '')
  $lineNo = 0
  foreach ($line in ($src -split "`n")) {
    $lineNo++
    if ($line -match 'context\.(read|watch)\s*\(\s*[^)<]' -or
        $line -match 'Provider\.of\s*\(\s*[^)<]') {
      Write-Output "  [炸] ${rel}:${lineNo}  $($line.Trim())"
      $bare += "${rel}:${lineNo}"
    }
  }
}
if ($bare.Count -eq 0) { Write-Output '  无（全部带类型参数）' }

Write-Output ''
$fail = ($missing.Count -gt 0) -or ($bare.Count -gt 0)
if ($fail) { Write-Output '存在问题，见上。' } else { Write-Output '全部通过。' }
exit $(if ($fail) { 1 } else { 0 })
