# ============================================================
# Verdaccio preheat script
#   - Run preheat across a matrix of Node versions (18 / 20 / 22 / 24) to cover
#     different engines-dependent resolution results, feeding them all into Verdaccio
#   - Within each Node version: iterate stable/ and latest/ subprojects, run pnpm install
#   - One project failure does NOT abort the whole run
#   - Emits per-node-version / per-project log files, timing, and a summary JSON
# Usage:
#   .\run-preheat.ps1                                     # default: all Node versions (18,20,22,24)
#   .\run-preheat.ps1 -NodeVersions 20,22                 # only specific Node versions
#   .\run-preheat.ps1 -NodeManager fnm                    # force fnm (default auto: fnm -> nvm)
#   .\run-preheat.ps1 -SkipNodeSwitch                     # don't switch Node, use current shell's node
#   .\run-preheat.ps1 -Categories stable                  # only stable
#   .\run-preheat.ps1 -Only stable-react                  # only run the given subproject(s)
#   .\run-preheat.ps1 -Only stable-react,latest-node      # multiple subprojects
#   .\run-preheat.ps1 -Parallel                           # parallel inside a Node version (PS7+)
#   .\run-preheat.ps1 -Registry https://...               # custom registry
#   .\run-preheat.ps1 -KeepLock                           # keep pnpm-lock.yaml
# ============================================================

[CmdletBinding()]
param(
    [string]   $Registry        = "https://npm.home.ueyeseas.com:8443/",
    [string[]] $Categories      = @("stable", "latest"),
    [string[]] $NodeVersions    = @("18", "20", "22", "24"),
    [ValidateSet("auto","fnm","nvm")]
    [string]   $NodeManager     = "auto",
    [string[]] $Only            = @(),
    [switch]   $SkipNodeSwitch,
    [switch]   $Parallel,
    [switch]   $KeepLock,
    [switch]   $KeepNodeModules
)

$ErrorActionPreference = "Continue"

# Force UTF-8 console so Chinese in pnpm output is not mojibake on PS 5.1
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
    chcp 65001 > $null
} catch {}

$baseDir  = (Get-Location).Path
$logDir   = Join-Path $baseDir "logs"
$stamp    = Get-Date -Format "yyyyMMdd-HHmmss"
$summary  = @()

if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

# ---- Node manager detection ----
function Resolve-NodeManager {
    param([string] $Preferred)
    if ($Preferred -ne "auto") { return $Preferred }

    if (Get-Command fnm -ErrorAction SilentlyContinue) { return "fnm" }
    # nvm-windows exposes `nvm` as a plain executable
    if (Get-Command nvm -ErrorAction SilentlyContinue) { return "nvm" }
    return $null
}

if (-not $SkipNodeSwitch.IsPresent) {
    $NodeManager = Resolve-NodeManager -Preferred $NodeManager
    if (-not $NodeManager) {
        Write-Host "[ERROR] Neither fnm nor nvm found. Install one, or pass -SkipNodeSwitch." -ForegroundColor Red
        exit 1
    }
}

# ---- switch Node version ----
function Switch-NodeVersion {
    param(
        [string] $TargetVersion,
        [string] $Manager,
        [bool]   $Skip
    )

    if ($Skip) {
        $current = (& node -v) 2>$null
        Write-Host "[skip] -SkipNodeSwitch set, using current Node $current" -ForegroundColor Yellow
        return $true
    }

    switch ($Manager) {
        "fnm" {
            # fnm supports `fnm use 20`; auto install missing via --install-if-missing
            & fnm use --install-if-missing $TargetVersion *> $null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[ERROR] fnm use $TargetVersion failed" -ForegroundColor Red
                return $false
            }
            # fnm only updates env for *this* shell through its shim; make sure PATH is reloaded
            try {
                $fnmEnv = & fnm env --shell powershell 2>$null
                if ($fnmEnv) { $fnmEnv | ForEach-Object { Invoke-Expression $_ } }
            } catch {}
            return $true
        }
        "nvm" {
            # nvm-windows: `nvm use <major>` works if a matching version is installed.
            & nvm use $TargetVersion *> $null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[info] Node $TargetVersion not installed locally, running nvm install" -ForegroundColor Yellow
                & nvm install $TargetVersion *> $null
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "[ERROR] nvm install $TargetVersion failed" -ForegroundColor Red
                    return $false
                }
                & nvm use $TargetVersion *> $null
                if ($LASTEXITCODE -ne 0) { return $false }
            }
            return $true
        }
        default {
            Write-Host "[ERROR] Unknown node manager: $Manager" -ForegroundColor Red
            return $false
        }
    }
}

# ---- ensure pnpm exists under current Node ----
function Confirm-Pnpm {
    if (Get-Command pnpm -ErrorAction SilentlyContinue) { return $true }

    Write-Host "[info] pnpm missing under current Node, trying corepack" -ForegroundColor Yellow
    if (-not (Get-Command corepack -ErrorAction SilentlyContinue)) {
        Write-Host "[ERROR] corepack not found. Install pnpm manually under this Node (npm i -g pnpm)." -ForegroundColor Red
        return $false
    }
    & corepack enable *> $null
    & corepack prepare pnpm@latest --activate *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] corepack prepare pnpm@latest failed" -ForegroundColor Red
        return $false
    }
    return [bool](Get-Command pnpm -ErrorAction SilentlyContinue)
}

Write-Host "========================================" -ForegroundColor Green
Write-Host "Verdaccio preheat | registry = $Registry" -ForegroundColor Green
Write-Host "node versions: $($NodeVersions -join ', ')    node manager: $NodeManager    skip-switch=$($SkipNodeSwitch.IsPresent)" -ForegroundColor Green
Write-Host "categories   : $($Categories -join ', ')    parallel=$($Parallel.IsPresent)" -ForegroundColor Green
if ($Only.Count -gt 0) {
    Write-Host "only projects: $($Only -join ', ')" -ForegroundColor Green
}
Write-Host "log dir      : $logDir"                   -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green

# ---- preheat a single seed project ----
function Invoke-Preheat {
    param(
        [string] $NodeVersion,
        [string] $Category,
        [string] $FolderPath,
        [string] $FolderName,
        [string] $LogDir,
        [bool]   $KeepLock,
        [bool]   $KeepNodeModules
    )

    $logFile = Join-Path $LogDir "node$NodeVersion-$Category-$FolderName.log"
    $sw      = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Host ">>> [node$NodeVersion/$Category/$FolderName] start" -ForegroundColor Cyan

    try {
        Push-Location $FolderPath

        if (-not $KeepLock) {
            Remove-Item -Force -ErrorAction SilentlyContinue pnpm-lock.yaml, package-lock.json, yarn.lock
        }
        if (-not $KeepNodeModules) {
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue node_modules
        }

        pnpm install --no-frozen-lockfile --ignore-scripts 2>&1 |
            Tee-Object -FilePath $logFile | Out-Host

        $exit = $LASTEXITCODE
    }
    catch {
        $exit = 1
        $_ | Out-File -FilePath $logFile -Append
    }
    finally {
        Pop-Location
        $sw.Stop()
    }

    $ok    = ($exit -eq 0)
    $tag   = if ($ok) { "OK" }    else { "FAIL" }
    $color = if ($ok) { "Green" } else { "Red" }
    Write-Host "<<< [node$NodeVersion/$Category/$FolderName] $tag  elapsed=$([int]$sw.Elapsed.TotalSeconds)s`n" -ForegroundColor $color

    return [pscustomobject]@{
        NodeVersion = $NodeVersion
        Category    = $Category
        Name        = $FolderName
        Success     = $ok
        Seconds     = [int]$sw.Elapsed.TotalSeconds
        LogFile     = $logFile
    }
}

# ---- main loop: outer Node matrix (serial), inner categories + projects (can parallel) ----
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($nv in $NodeVersions) {
    Write-Host "################################################" -ForegroundColor Blue
    Write-Host "#  Node matrix: switching to Node $nv"              -ForegroundColor Blue
    Write-Host "################################################" -ForegroundColor Blue

    $switched = Switch-NodeVersion -TargetVersion $nv -Manager $NodeManager -Skip:$SkipNodeSwitch.IsPresent
    if (-not $switched) {
        Write-Host "[WARN] Skipping Node $nv (switch failed)" -ForegroundColor Red
        foreach ($cat in $Categories) {
            $catPath = Join-Path $baseDir $cat
            if (-not (Test-Path $catPath)) { continue }
            Get-ChildItem -Path $catPath -Directory |
                Where-Object { ($Only.Count -eq 0) -or ($Only -contains $_.Name) } |
                ForEach-Object {
                    $summary += [pscustomobject]@{
                        NodeVersion = $nv
                        Category    = $cat
                        Name        = $_.Name
                        Success     = $false
                        Seconds     = 0
                        LogFile     = (Join-Path $logDir "node$nv-switch-failed.log")
                    }
                }
            Set-Content -Path (Join-Path $logDir "node$nv-switch-failed.log") -Value "Node $nv switch failed"
        }
        continue
    }

    if (-not (Confirm-Pnpm)) {
        Write-Host "[WARN] pnpm unavailable under Node $nv, skipping" -ForegroundColor Red
        continue
    }

    $currentNode = (& node -v) 2>$null
    $currentPnpm = (& pnpm --version) 2>$null
    Write-Host "[info] active node=$currentNode  pnpm=$currentPnpm" -ForegroundColor Green
    pnpm config set registry $Registry | Out-Null

    foreach ($cat in $Categories) {
        $catPath = Join-Path $baseDir $cat
        if (-not (Test-Path $catPath)) {
            Write-Host "[WARN] skip missing category: $catPath" -ForegroundColor Yellow
            continue
        }

        $folders = Get-ChildItem -Path $catPath -Directory
        if ($Only.Count -gt 0) {
            $folders = $folders | Where-Object { $Only -contains $_.Name }
        }

        if (-not $folders -or $folders.Count -eq 0) {
            if ($Only.Count -gt 0) {
                Write-Host "[WARN] no subproject under '$cat' matches -Only ($($Only -join ','))" -ForegroundColor Yellow
            } else {
                Write-Host "[WARN] no subproject under '$cat'" -ForegroundColor Yellow
            }
            continue
        }

        if ($Parallel.IsPresent -and $folders.Count -gt 1 -and $PSVersionTable.PSVersion.Major -ge 7) {
            $results = $folders | ForEach-Object -ThrottleLimit 4 -Parallel {
                $func = ${using:function:Invoke-Preheat}
                Invoke-Expression "function Invoke-Preheat { $func }"
                Invoke-Preheat -NodeVersion $using:nv `
                               -Category $using:cat `
                               -FolderPath $_.FullName `
                               -FolderName $_.Name `
                               -LogDir $using:logDir `
                               -KeepLock $using:KeepLock.IsPresent `
                               -KeepNodeModules $using:KeepNodeModules.IsPresent
            }
            $summary += $results
        }
        else {
            if ($Parallel.IsPresent -and $PSVersionTable.PSVersion.Major -lt 7) {
                Write-Host "[WARN] PowerShell < 7 does not support -Parallel, falling back to serial" -ForegroundColor Yellow
            }
            foreach ($f in $folders) {
                $summary += Invoke-Preheat -NodeVersion $nv `
                                           -Category $cat `
                                           -FolderPath $f.FullName `
                                           -FolderName $f.Name `
                                           -LogDir $logDir `
                                           -KeepLock $KeepLock.IsPresent `
                                           -KeepNodeModules $KeepNodeModules.IsPresent
            }
        }
    }
}

$totalSw.Stop()

# ---- summary ----
Write-Host "`n========== preheat summary ==========" -ForegroundColor Magenta
$summary | Sort-Object NodeVersion, Category, Name | Format-Table -AutoSize | Out-String | Write-Host

$okCount   = ($summary | Where-Object Success).Count
$failCount = ($summary | Where-Object { -not $_.Success }).Count
$failed    = $summary | Where-Object { -not $_.Success }

Write-Host "total=$([int]$totalSw.Elapsed.TotalSeconds)s  ok=$okCount  fail=$failCount" -ForegroundColor Magenta

if ($failed) {
    Write-Host "failures:" -ForegroundColor Red
    $failed | ForEach-Object {
        Write-Host "  - node$($_.NodeVersion)/$($_.Category)/$($_.Name)  ->  $($_.LogFile)" -ForegroundColor Red
    }
}

$summaryJson = Join-Path $logDir "summary-$stamp.json"
$summary | ConvertTo-Json -Depth 3 | Out-File -FilePath $summaryJson -Encoding utf8
Write-Host "`nsummary saved: $summaryJson" -ForegroundColor Green

Set-Location $baseDir
if ($failCount -gt 0) { exit 1 } else { exit 0 }
