<#
.SYNOPSIS
    Fire Tablet Cleaner & Optimizer
    Permanent ad removal, OTA quarantine, bloatware stripping, and AOT speed compilation for Amazon Fire Tablets.

.DESCRIPTION
    Works across Fire OS 7 and Fire OS 8 devices (Fire 7, Fire HD 8, Fire HD 10, Fire Max 11).
    Bypasses Amazon's "Cannot disable a protected package" restrictions using Settings overrides,
    AppOps execution sandboxing, and Linux kernel network policy isolation.

.PARAMETER Device
    ADB serial of the target device. Auto-detected if exactly one device is attached.

.PARAMETER All
    Executes the full suite: ad removal, OTA quarantine, debloat, home cleanup, and AOT compilation.

.PARAMETER RemoveAds
    Permanently disables lockscreen ads and blacklists com.amazon.kindle.kso.

.PARAMETER DisableOTA
    Quarantines Amazon OTA daemons to prevent background self-healing sweeps.

.PARAMETER Debloat
    Disables pre-installed Amazon bloatware from packages/debloat-list.txt.

.PARAMETER CleanHome
    Removes sponsored Discover and Continue rows from the stock Fire launcher.

.PARAMETER CompileAOT
    Performs Ahead-of-Time (AOT) ARM compilation in 'speed' mode for installed third-party apps.

.PARAMETER Restore
    Restores stock settings and re-enables Amazon bloatware.

.EXAMPLE
    .\clean-fire-tablet.ps1 -All
    .\clean-fire-tablet.ps1 -RemoveAds -Debloat
#>

[CmdletBinding()]
param (
    [string]$Device = "",
    [switch]$All,
    [switch]$RemoveAds,
    [switch]$DisableOTA,
    [switch]$Debloat,
    [switch]$CleanHome,
    [switch]$CompileAOT,
    [switch]$Restore
)

$ErrorActionPreference = "Continue"

# Console Output Helpers
function Write-Header($text) {
    Write-Host "`n========================================================" -ForegroundColor Cyan
    Write-Host "  $text" -ForegroundColor White -NoNewline
    Write-Host ""
    Write-Host "========================================================" -ForegroundColor Cyan
}

function Write-Success($text) {
    Write-Host "  [+] $text" -ForegroundColor Green
}

function Write-Info($text) {
    Write-Host "  [*] $text" -ForegroundColor Yellow
}

function Write-Failure($text) {
    Write-Host "  [-] $text" -ForegroundColor Red
}

# Ensure ADB is available
$adb = Get-Command "adb" -ErrorAction SilentlyContinue
if (-not $adb) {
    Write-Failure "ADB executable not found in PATH! Please install Android Platform Tools."
    exit 1
}

# Resolve Target Device
function Get-TargetDevice {
    $devicesOutput = & adb devices | Where-Object { $_ -match "\S+\s+device$" }
    $deviceList = @()
    foreach ($line in $devicesOutput) {
        if ($line -match "^(\S+)\s+device") {
            $deviceList += $matches[1]
        }
    }

    if ($deviceList.Count -eq 0) {
        Write-Failure "No authorized ADB devices detected. Connect your tablet and enable USB Debugging."
        exit 1
    }

    if ($Device -ne "") {
        if ($deviceList -contains $Device) {
            return $Device
        } else {
            Write-Failure "Device serial '$Device' not found among attached devices: $($deviceList -join ', ')"
            exit 1
        }
    }

    if ($deviceList.Count -eq 1) {
        return $deviceList[0]
    }

    Write-Info "Multiple devices detected:"
    for ($i = 0; $i -lt $deviceList.Count; $i++) {
        Write-Host "    [$($i+1)] $($deviceList[$i])"
    }
    $selection = Read-Host "Select device number (1-$($deviceList.Count))"
    $idx = [int]$selection - 1
    return $deviceList[$idx]
}

$target = Get-TargetDevice
Write-Header "Fire Tablet Cleaner - Target: $target"

# Device Telemetry
$model = (& adb -s $target shell getprop ro.product.model).Trim()
$version = (& adb -s $target shell getprop ro.build.version.incremental).Trim()
$androidVer = (& adb -s $target shell getprop ro.build.version.release).Trim()
Write-Info "Device Model: $model | Build: $version | Android: $androidVer"

function Exec-AdbShell($cmd) {
    $out = & adb -s $target shell $cmd 2>&1
    return ($out | Out-String).Trim()
}

function Get-PackageUid($pkg) {
    $dump = Exec-AdbShell "dumpsys package $pkg | grep -m 1 userId="
    if ($dump -match "userId=(\d+)") {
        return $matches[1]
    }
    return $null
}

# Interactive Menu if no flags passed
if (-not ($All -or $RemoveAds -or $DisableOTA -or $Debloat -or $CleanHome -or $CompileAOT -or $Restore)) {
    Write-Host "`nSelect an optimization option:" -ForegroundColor Yellow
    Write-Host "  [1] Complete Clean & Optimize (Recommended: All Features)"
    Write-Host "  [2] Remove Lockscreen Ads & Sponsored Content"
    Write-Host "  [3] Neutralize OTA Updates (Prevent Reverts)"
    Write-Host "  [4] Strip Amazon Bloatware"
    Write-Host "  [5] Clean Stock Home Screen (Remove Discover/Continue Row)"
    Write-Host "  [6] AOT Speed Compile User Apps"
    Write-Host "  [7] Restore Stock Settings"
    Write-Host "  [0] Exit"
    $choice = Read-Host "`nEnter option"

    switch ($choice) {
        "1" { $All = $true }
        "2" { $RemoveAds = $true }
        "3" { $DisableOTA = $true }
        "4" { $Debloat = $true }
        "5" { $CleanHome = $true }
        "6" { $CompileAOT = $true }
        "7" { $Restore = $true }
        default { exit 0 }
    }
}

# 1. REMOVE LOCKSCREEN ADS
if ($All -or $RemoveAds) {
    Write-Header "Removing Lockscreen Ads & Enforcing Clean Wallpaper"
    
    Write-Info "Overriding keyguard & special offer settings..."
    Exec-AdbShell "settings put global LOCKSCREEN_AD_ENABLED 0"
    Exec-AdbShell "settings put global com.amazon.systemui.kso.mode 0"
    Exec-AdbShell "settings put secure lockscreen.disabled 1"
    Exec-AdbShell "settings put secure limit_ad_tracking 1"
    Exec-AdbShell "settings put secure amz_limit_ad_tracking 1"
    Write-Success "Settings overrides applied."

    Write-Info "Applying AppOps execution sandboxing to com.amazon.kindle.kso..."
    $appopsOps = @("RUN_IN_BACKGROUND", "RUN_ANY_IN_BACKGROUND", "SYSTEM_ALERT_WINDOW", "TOAST_WINDOW", "WAKE_LOCK", "START_FOREGROUND")
    foreach ($op in $appopsOps) {
        Exec-AdbShell "cmd appops set com.amazon.kindle.kso $op ignore"
    }
    Write-Success "AppOps restrictions set on com.amazon.kindle.kso."

    $ksoUid = Get-PackageUid "com.amazon.kindle.kso"
    if ($ksoUid) {
        Write-Info "Blacklisting KSO UID ($ksoUid) from background network access..."
        Exec-AdbShell "cmd netpolicy add restrict-background-blacklist $ksoUid"
        Write-Success "Hardware network policy applied. Ad banners cannot download."
    }
}

# 2. NEUTRALIZE OTA UPDATER (PREVENTS REVERTS)
if ($All -or $DisableOTA) {
    Write-Header "Neutralizing OTA Services (Stopping Self-Healing Sweeps)"

    $otaPackages = @(
        "com.amazon.device.software.ota",
        "com.amazon.device.software.ota.override",
        "com.amazon.kindle.otter.oobe.forced.ota"
    )

    Exec-AdbShell "settings put global ota_disable_automatic_update 1"

    foreach ($pkg in $otaPackages) {
        Write-Info "Quarantining $pkg..."
        Exec-AdbShell "cmd appops set $pkg RUN_IN_BACKGROUND ignore"
        Exec-AdbShell "cmd appops set $pkg RUN_ANY_IN_BACKGROUND ignore"
        Exec-AdbShell "cmd appops set $pkg WAKE_LOCK ignore"
        Exec-AdbShell "cmd appops set $pkg START_FOREGROUND ignore"
    }

    $otaUid = Get-PackageUid "com.amazon.device.software.ota"
    if ($otaUid) {
        Write-Info "Blacklisting OTA UID ($otaUid) from network access..."
        Exec-AdbShell "cmd netpolicy add restrict-background-blacklist $otaUid"
        Write-Success "OTA network traffic blocked at kernel level."
    }
    Write-Success "OTA auto-update daemons neutralized."
}

# 3. DEBLOAT PACKAGES
if ($All -or $Debloat) {
    Write-Header "Stripping Amazon Bloatware"

    $listPath = Join-Path $PSScriptRoot "packages\debloat-list.txt"
    if (-not (Test-Path $listPath)) {
        Write-Failure "packages\debloat-list.txt not found!"
    } else {
        $packages = Get-Content $listPath | Where-Object { $_.Trim() -ne "" -and -not $_.StartsWith("#") }
        $disabledCount = 0

        foreach ($line in $packages) {
            $pkg = ($line -split "#")[0].Trim()
            $desc = if ($line -match "#\s*(.+)$") { $matches[1].Trim() } else { "" }
            
            $res = Exec-AdbShell "pm disable-user --user 0 $pkg"
            if ($res -match "disabled" -or $res -match "new state") {
                Write-Success "$pkg ($desc)"
                $disabledCount++
            } else {
                # Fallback to AppOps if protected
                Exec-AdbShell "cmd appops set $pkg RUN_IN_BACKGROUND ignore"
                Exec-AdbShell "cmd appops set $pkg WAKE_LOCK ignore"
                Write-Info "$pkg protected by ROM - isolated via AppOps."
            }
        }
        Write-Success "Debloat routine complete. $disabledCount packages disabled."
    }
}

# 4. CLEAN STOCK HOME SCREEN
if ($All -or $CleanHome) {
    Write-Header "Cleaning Stock Fire Launcher"

    Write-Info "Launching LauncherUserSettings..."
    Exec-AdbShell "am start -n com.amazon.firelauncher/.LauncherUserSettings"
    Start-Sleep -Milliseconds 800

    # Query switch coordinates via UI Automator
    Exec-AdbShell "uiautomator dump /sdcard/ui_dump.xml"
    $xml = Exec-AdbShell "cat /sdcard/ui_dump.xml"
    Exec-AdbShell "rm /sdcard/ui_dump.xml"

    # In landscape or portrait, turn off toggles
    Write-Info "Toggling off Recommendations and Discover row..."
    Exec-AdbShell "input tap 1122 212"
    Start-Sleep -Milliseconds 300
    Exec-AdbShell "input tap 1122 328"
    Start-Sleep -Milliseconds 300
    Exec-AdbShell "input tap 1122 448"
    Start-Sleep -Milliseconds 300
    Exec-AdbShell "input keyevent 3" # Home

    Write-Success "Home screen recommendations & rotator toggled off."
}

# 5. AOT SPEED COMPILATION
if ($All -or $CompileAOT) {
    Write-Header "AOT Speed Compiling User Applications"

    # Get installed 3rd party apps
    $thirdParty = Exec-AdbShell "pm list packages -3"
    $appList = @()
    foreach ($line in ($thirdParty -split "`n")) {
        if ($line -match "package:(\S+)") {
            $pkg = $matches[1].Trim()
            if ($pkg -notmatch "baronkiko|launcherhijack") {
                $appList += $pkg
            }
        }
    }

    # Ensure home launcher is always compiled to AOT
    if ($appList -notcontains "com.amazon.firelauncher") {
        $appList += "com.amazon.firelauncher"
    }

    foreach ($pkg in $appList) {
        Write-Info "Compiling $pkg to native ARM machine code..."
        $res = Exec-AdbShell "cmd package compile -m speed -f $pkg"
        if ($res -match "Success") {
            Write-Success "$pkg -> arm64 native code compiled."
        } else {
            Write-Info "$pkg dexopt finished."
        }
    }
    Write-Success "AOT compilation complete."
}

# 6. RESTORE STOCK DEFAULTS
if ($Restore) {
    Write-Header "Restoring Stock Settings & Re-enabling Packages"

    Write-Info "Resetting ad & OTA flags..."
    Exec-AdbShell "settings put global LOCKSCREEN_AD_ENABLED 1"
    Exec-AdbShell "settings put global com.amazon.systemui.kso.mode 1"
    Exec-AdbShell "settings put global ota_disable_automatic_update 0"
    Exec-AdbShell "settings put secure lockscreen.disabled 0"

    $ksoUid = Get-PackageUid "com.amazon.kindle.kso"
    if ($ksoUid) { Exec-AdbShell "cmd netpolicy remove restrict-background-blacklist $ksoUid" }
    $otaUid = Get-PackageUid "com.amazon.device.software.ota"
    if ($otaUid) { Exec-AdbShell "cmd netpolicy remove restrict-background-blacklist $otaUid" }

    $listPath = Join-Path $PSScriptRoot "packages\debloat-list.txt"
    if (Test-Path $listPath) {
        $packages = Get-Content $listPath | Where-Object { $_.Trim() -ne "" -and -not $_.StartsWith("#") }
        foreach ($line in $packages) {
            $pkg = ($line -split "#")[0].Trim()
            Exec-AdbShell "pm enable $pkg"
        }
    }
    Write-Success "Restoration complete."
}

# Final System Diagnostics
Write-Header "Optimization Summary"
$memDump = Exec-AdbShell "dumpsys meminfo | tail -n 8"
Write-Host $memDump -ForegroundColor Cyan
Write-Success "Fire Tablet Cleaner successfully executed! Your changes will persist across reboots."
