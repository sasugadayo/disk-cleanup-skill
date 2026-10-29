# Read-only disk survey for the disk-cleanup skill (Windows). Deletes nothing, writes nothing.
# Output matches survey.sh: "## section" headers followed by TSV rows. Sizes are KB unless the column says otherwise.
#   powershell -ExecutionPolicy Bypass -File survey.ps1 [-StaleDays 60] [-ScanRoots C:\src,D:\work]
param([int]$StaleDays = 60, [string[]]$ScanRoots = @($HOME))
$ErrorActionPreference = 'SilentlyContinue'
$now = Get-Date
$MinKb = 10240

function Kb([string]$p) {
  if (Test-Path -LiteralPath $p -PathType Leaf) { return [int64]((Get-Item -LiteralPath $p -Force).Length / 1KB) }
  # ponytail: walks every file; slow on huge trees, but needs no extra tooling
  [int64]((Get-ChildItem -LiteralPath $p -Recurse -Force -File -Attributes !ReparsePoint |
    Measure-Object Length -Sum).Sum / 1KB)
}
function Row-IfBig([string]$p) { $s = Kb $p; if ($s -ge $MinKb) { "$s`t$p" } }
function DaysIdle([string]$proj) {
  $t = git -C $proj log -1 --format=%ct 2>$null
  if ($t -match '^\d+$') { return [int](($now - [DateTimeOffset]::FromUnixTimeSeconds([int64]$t).LocalDateTime).TotalDays) }
  [int](($now - (Get-Item -LiteralPath $proj -Force).LastWriteTime).TotalDays)
}

"## system"
"os`tWindows"
"stale_days`t$StaleDays"

""
"## disk"
$drive = if ($HOME -match '^[A-Za-z]:') { Get-PSDrive -Name $HOME.Substring(0, 1) }
if ($drive) {
  "total_kb`t$([int64](($drive.Used + $drive.Free) / 1KB))"
  "used_kb`t$([int64]($drive.Used / 1KB))"
  "free_kb`t$([int64]($drive.Free / 1KB))"
  "mount`t$($drive.Root)"
} else { "unavailable`t$HOME" }

""
"## caches`tsize_kb`tpath"
$la = $env:LOCALAPPDATA
$caches = @(
  $env:TEMP, "$la\npm-cache", "$la\pip\Cache", "$la\Yarn\Cache", "$la\pnpm\store", "$la\go-build",
  "$la\Google\Chrome\User Data\Default\Cache", "$la\Microsoft\Edge\User Data\Default\Cache",
  "$HOME\.gradle\caches", "$HOME\.m2\repository", "$HOME\.cargo\registry", "$HOME\.nuget\packages"
)
if (Get-Command go) { $caches += (go env GOCACHE), (go env GOMODCACHE) }
$caches | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Sort-Object -Unique |
  ForEach-Object { Row-IfBig $_ } | Sort-Object { [int64]($_ -split "`t")[0] } -Descending

""
"## dev_data`tsize_kb`tpath"
foreach ($d in @("$HOME\.android\avd")) { if (Test-Path -LiteralPath $d) { Row-IfBig $d } }

""
"## project_dirs`tkind`tsize_kb`tdays_idle`tpath"
# Each kind is only reported next to the file that proves what it is, and never when git tracks it.
$markers = @{
  'node_modules' = { param($p, $proj) Test-Path -LiteralPath (Join-Path $proj 'package.json') }
  '.venv'        = { param($p, $proj) Test-Path -LiteralPath (Join-Path $p 'pyvenv.cfg') }
  'venv'         = { param($p, $proj) Test-Path -LiteralPath (Join-Path $p 'pyvenv.cfg') }
  'target'       = { param($p, $proj) (Test-Path -LiteralPath (Join-Path $proj 'Cargo.toml')) -or (Test-Path -LiteralPath (Join-Path $proj 'pom.xml')) }
  'vendor'       = { param($p, $proj) Test-Path -LiteralPath (Join-Path $proj 'composer.json') }
}
function Find-ProjectDirs([string]$root, [int]$depth) {
  if ($depth -lt 0) { return }
  foreach ($d in Get-ChildItem -LiteralPath $root -Directory -Force) {
    if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
    if ($markers.ContainsKey($d.Name)) { $d.FullName; continue }
    if ($d.Name.StartsWith('.') -or $d.Name -eq 'AppData') { continue }
    Find-ProjectDirs $d.FullName ($depth - 1)
  }
}
$ScanRoots | ForEach-Object { Find-ProjectDirs $_ 5 } | ForEach-Object {
  $p = $_; $proj = Split-Path $p -Parent; $name = Split-Path $p -Leaf
  if (-not (& $markers[$name] $p $proj)) { return }
  if (git -C $proj ls-files -- $name 2>$null | Select-Object -First 1) { return }
  $s = Kb $p
  if ($s -lt $MinKb) { return }
  "$name`t$s`t$(DaysIdle $proj)`t$p"
} | Sort-Object { [int64]($_ -split "`t")[1] } -Descending

""
docker info *> $null
if ((Get-Command docker) -and $LASTEXITCODE -eq 0) {
  "## docker_summary"
  docker system df

  $used = @(docker ps -aq | ForEach-Object { docker inspect --format '{{.Image}}' $_ }) | Sort-Object -Unique
  ""
  "## docker_unused_images`tsize`trepo:tag`tcreated`timage_id"
  docker images --no-trunc --format "{{.ID}}`t{{.Size}}`t{{.Repository}}:{{.Tag}}`t{{.CreatedSince}}" | ForEach-Object {
    $id, $size, $name, $created = $_ -split "`t"
    if ($used -notcontains $id) { "$size`t$name`t$created`t$($id -replace '^sha256:', '')" }
  }

  ""
  "## docker_used_images`trepo:tag`tcontainers"
  foreach ($id in $used) {
    $tag = docker image inspect --format '{{index .RepoTags 0}}' $id
    $cs = (docker ps -a --filter "ancestor=$id" --format '{{.Names}}({{.State}})') -join ','
    "$(if ($tag) { $tag } else { $id })`t$cs"
  }

  ""
  "## docker_unused_volumes`tsize`tname`tcompose_project`tcreated"
  $sizes = @{}; $in = $false
  foreach ($l in docker system df -v) {
    if ($l -match '^VOLUME NAME') { $in = $true; continue }
    if ($in -and -not $l.Trim()) { $in = $false }
    if ($in) { $f = $l -split '\s+'; $sizes[$f[0]] = $f[-1] }
  }
  foreach ($v in docker volume ls -qf dangling=true) {
    $proj = docker volume inspect --format '{{index .Labels "com.docker.compose.project"}}' $v
    $created = (docker volume inspect --format '{{.CreatedAt}}' $v)
    "$($sizes[$v])`t$v`t$proj`t$(if ($created) { $created.Substring(0, 10) })"
  }
} else {
  "## docker`tunavailable (not installed, not running, or no permission)"
}

""
"## downloads_large_old`tsize_kb`tdays_old`tpath"
Get-ChildItem -LiteralPath "$HOME\Downloads" -File -Force -Depth 1 |
  Where-Object { $_.Length -gt 100MB -and $_.LastWriteTime -lt $now.AddDays(-$StaleDays) } |
  Sort-Object Length -Descending |
  ForEach-Object { "$([int64]($_.Length / 1KB))`t$([int](($now - $_.LastWriteTime).TotalDays))`t$($_.FullName)" }

""
"## trash`tsize_kb`tpath"
try {
  $bin = (New-Object -ComObject Shell.Application).NameSpace(10)
  $sum = ($bin.Items() | ForEach-Object { $_.Size } | Measure-Object -Sum).Sum
  "$([int64]($sum / 1KB))`tRecycle Bin"
} catch { "unreadable`tRecycle Bin" }
