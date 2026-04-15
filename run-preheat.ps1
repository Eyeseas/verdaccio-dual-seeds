# ============================================================
# Verdaccio preheat script
#   - Iterate each subproject under stable/ and latest/, run pnpm install
#   - One project failure does NOT abort the whole run
#   - Emits per-project log files, timing, and a summary JSON
# Usage:
#   .\run-preheat.ps1                         # default: serial, all categories
#   .\run-preheat.ps1 -Categories stable      # only stable
#   .\run-preheat.ps1 -Parallel               # parallel inside a category (PS7+)
#   .\run-preheat.ps1 -Registry https://...   # custom registry
#   .\run-preheat.ps1 -KeepLock               # keep pnpm-lock.yaml
# ============================================================

[CmdletBinding()]
param(
    [string]   $Registry   = "https://npm.home.ueyeseas.com:8443/",
    [string[]] $Categories = @("stable", "latest"),
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

# ---- preflight ----
$pnpmCmd = Get-Command pnpm -ErrorAction SilentlyContinue
if (-not $pnpmCmd) {
    Write-Host "[ERROR] pnpm not found. Install first: npm i -g pnpm" -ForegroundColor Red
    exit 1
}

Write-Host "========================================" -ForegroundColor Green
Write-Host "Verdaccio preheat | registry = $Registry" -ForegroundColor Green
Write-Host "pnpm version : $(pnpm --version)"         -ForegroundColor Green
Write-Host "categories   : $($Categories -join ', ')  parallel=$Parallel" -ForegroundColor Green
Write-Host "log dir      : $logDir"                   -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green

pnpm config set registry $Registry | Out-Null

# ---- preheat a single seed project ----
function Invoke-Preheat {
    param(
        [string] $Category,
        [string] $FolderPath,
        [string] $FolderName,
        [string] $LogDir,
        [bool]   $KeepLock,
        [bool]   $KeepNodeModules
    )

    $logFile = Join-Path $LogDir "$Category-$FolderName.log"
    $sw      = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Host ">>> [$Category/$FolderName] start" -ForegroundColor Cyan

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
    Write-Host "<<< [$Category/$FolderName] $tag  elapsed=$([int]$sw.Elapsed.TotalSeconds)s`n" -ForegroundColor $color

    return [pscustomobject]@{
        Category = $Category
        Name     = $FolderName
        Success  = $ok
        Seconds  = [int]$sw.Elapsed.TotalSeconds
        LogFile  = $logFile
    }
}

# ---- main loop ----
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($cat in $Categories) {
    $catPath = Join-Path $baseDir $cat
    if (-not (Test-Path $catPath)) {
        Write-Host "[WARN] skip missing category: $catPath" -ForegroundColor Yellow
        continue
    }

    $folders = Get-ChildItem -Path $catPath -Directory

    if ($Parallel.IsPresent -and $folders.Count -gt 1 -and $PSVersionTable.PSVersion.Major -ge 7) {
        $results = $folders | ForEach-Object -ThrottleLimit 4 -Parallel {
            $func = ${using:function:Invoke-Preheat}
            Invoke-Expression "function Invoke-Preheat { $func }"
            Invoke-Preheat -Category $using:cat `
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
            $summary += Invoke-Preheat -Category $cat `
                                       -FolderPath $f.FullName `
                                       -FolderName $f.Name `
                                       -LogDir $logDir `
                                       -KeepLock $KeepLock.IsPresent `
                                       -KeepNodeModules $KeepNodeModules.IsPresent
        }
    }
}

$totalSw.Stop()

# ---- summary ----
Write-Host "`n========== preheat summary ==========" -ForegroundColor Magenta
$summary | Sort-Object Category, Name | Format-Table -AutoSize | Out-String | Write-Host

$okCount   = ($summary | Where-Object Success).Count
$failCount = ($summary | Where-Object { -not $_.Success }).Count
$failed    = $summary | Where-Object { -not $_.Success }

Write-Host "total=$([int]$totalSw.Elapsed.TotalSeconds)s  ok=$okCount  fail=$failCount" -ForegroundColor Magenta

if ($failed) {
    Write-Host "failures:" -ForegroundColor Red
    $failed | ForEach-Object {
        Write-Host "  - $($_.Category)/$($_.Name)  ->  $($_.LogFile)" -ForegroundColor Red
    }
}

$summaryJson = Join-Path $logDir "summary-$stamp.json"
$summary | ConvertTo-Json -Depth 3 | Out-File -FilePath $summaryJson -Encoding utf8
Write-Host "`nsummary saved: $summaryJson" -ForegroundColor Green

Set-Location $baseDir
if ($failCount -gt 0) { exit 1 } else { exit 0 }
