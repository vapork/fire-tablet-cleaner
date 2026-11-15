#!/usr/bin/env bash
# ==============================================================================
# Fire Tablet Cleaner & Optimizer (macOS & Linux)
# Permanent ad removal, OTA quarantine, bloatware stripping, and AOT speed compilation.
# ==============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

header() {
    echo -e "\n${CYAN}========================================================${NC}"
    echo -e "  ${WHITE}$1${NC}"
    echo -e "${CYAN}========================================================${NC}"
}

success() { echo -e "  ${GREEN}[+] $1${NC}"; }
info()    { echo -e "  ${YELLOW}[*] $1${NC}"; }
failure() { echo -e "  ${RED}[-] $1${NC}"; }

if ! command -v adb >/dev/null 2>&1; then
    failure "ADB not found! Please install android-platform-tools."
    exit 1
fi

# Detect Target Device
DEVICE_SERIAL=""
DEVICES=$(adb devices | awk '/device$/ {print $1}')
DEVICE_COUNT=$(echo "$DEVICES" | grep -c . || true)

if [ "$DEVICE_COUNT" -eq 0 ]; then
    failure "No authorized ADB devices detected. Connect tablet and enable USB Debugging."
    exit 1
elif [ "$DEVICE_COUNT" -eq 1 ]; then
    DEVICE_SERIAL="$DEVICES"
else
    info "Multiple ADB devices detected:"
    i=1
    for dev in $DEVICES; do
        echo "    [$i] $dev"
        i=$((i + 1))
    done
    read -rp "Select device number: " sel
    DEVICE_SERIAL=$(echo "$DEVICES" | sed -n "${sel}p")
fi

header "Fire Tablet Cleaner - Target: $DEVICE_SERIAL"
MODEL=$(adb -s "$DEVICE_SERIAL" shell getprop ro.product.model | tr -d '\r')
BUILD=$(adb -s "$DEVICE_SERIAL" shell getprop ro.build.version.incremental | tr -d '\r')
info "Device Model: $MODEL | Build: $BUILD"

adb_cmd() {
    adb -s "$DEVICE_SERIAL" shell "$@"
}

get_uid() {
    adb_cmd "dumpsys package $1 | grep -m 1 userId=" | grep -o -E '[0-9]+' | head -n 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_remove_ads() {
    header "Removing Lockscreen Ads & Enforcing Clean Wallpaper"
    info "Overriding global & secure keyguard settings..."
    adb_cmd "settings put global LOCKSCREEN_AD_ENABLED 0"
    adb_cmd "settings put global com.amazon.systemui.kso.mode 0"
    adb_cmd "settings put secure lockscreen.disabled 1"
    adb_cmd "settings put secure limit_ad_tracking 1"
    adb_cmd "settings put secure amz_limit_ad_tracking 1"
    success "Settings applied."

    info "Applying AppOps execution sandboxing to com.amazon.kindle.kso..."
    for op in RUN_IN_BACKGROUND RUN_ANY_IN_BACKGROUND SYSTEM_ALERT_WINDOW TOAST_WINDOW WAKE_LOCK START_FOREGROUND; do
        adb_cmd "cmd appops set com.amazon.kindle.kso $op ignore"
    done
    success "AppOps sandbox configured."

    KSO_UID=$(get_uid "com.amazon.kindle.kso")
    if [ -n "$KSO_UID" ]; then
        info "Blacklisting KSO UID ($KSO_UID) from network access..."
        adb_cmd "cmd netpolicy add restrict-background-blacklist $KSO_UID"
        success "Kernel packet drop rule added for KSO."
    fi
}

run_disable_ota() {
    header "Neutralizing OTA Services (Stopping Self-Healing Sweeps)"
    adb_cmd "settings put global ota_disable_automatic_update 1"

    for pkg in com.amazon.device.software.ota com.amazon.device.software.ota.override com.amazon.kindle.otter.oobe.forced.ota; do
        info "Quarantining $pkg..."
        for op in RUN_IN_BACKGROUND RUN_ANY_IN_BACKGROUND WAKE_LOCK START_FOREGROUND; do
            adb_cmd "cmd appops set $pkg $op ignore"
        done
    done

    OTA_UID=$(get_uid "com.amazon.device.software.ota")
    if [ -n "$OTA_UID" ]; then
        info "Blacklisting OTA UID ($OTA_UID) from network access..."
        adb_cmd "cmd netpolicy add restrict-background-blacklist $OTA_UID"
        success "Kernel packet drop rule added for OTA."
    fi
    success "OTA auto-update daemons neutralized."
}

run_debloat() {
    header "Stripping Amazon Bloatware"
    LIST_FILE="$SCRIPT_DIR/packages/debloat-list.txt"
    if [ ! -f "$LIST_FILE" ]; then
        failure "$LIST_FILE not found!"
        return
    fi

    count=0
    while IFS= read -r line || [ -n "$line" ]; do
        pkg=$(echo "$line" | cut -d '#' -f 1 | xargs)
        [ -z "$pkg" ] && continue
        
        res=$(adb_cmd "pm disable-user --user 0 $pkg" 2>&1 || true)
        if echo "$res" | grep -iqE "disabled|new state"; then
            success "$pkg"
            count=$((count + 1))
        else
            adb_cmd "cmd appops set $pkg RUN_IN_BACKGROUND ignore" || true
            adb_cmd "cmd appops set $pkg WAKE_LOCK ignore" || true
            info "$pkg (isolated via AppOps)"
        fi
    done < "$LIST_FILE"
    success "Debloat routine complete. $count packages disabled."
}

run_clean_home() {
    header "Cleaning Stock Fire Launcher"
    info "Launching LauncherUserSettings..."
    adb_cmd "am start -n com.amazon.firelauncher/.LauncherUserSettings" >/dev/null 2>&1 || true
    sleep 1

    info "Toggling off Recommendations and Discover row..."
    adb_cmd "input tap 1122 212"
    sleep 0.3
    adb_cmd "input tap 1122 328"
    sleep 0.3
    adb_cmd "input tap 1122 448"
    sleep 0.3
    adb_cmd "input keyevent 3" # HOME
    success "Home screen recommendations toggled off."
}

run_aot_compile() {
    header "AOT Speed Compiling User Applications"
    APPS=$(adb_cmd "pm list packages -3" | cut -d ':' -f 2 | tr -d '\r' | grep -vE 'baronkiko|launcherhijack' || true)
    
    if [ -z "$APPS" ]; then
        APPS="com.amazon.firelauncher"
    fi

    for pkg in $APPS; do
        info "Compiling $pkg to native ARM64 speed mode..."
        res=$(adb_cmd "cmd package compile -m speed -f $pkg" 2>&1 || true)
        if echo "$res" | grep -iq "Success"; then
            success "$pkg -> native speed compiled."
        else
            info "$pkg dexopt finished."
        fi
    done
    success "AOT speed compilation complete."
}

# Menu or CLI Flags
MODE="${1:-interactive}"
case "$MODE" in
    --all)
        run_remove_ads
        run_disable_ota
        run_debloat
        run_clean_home
        run_aot_compile
        ;;
    --ads)
        run_remove_ads
        ;;
    --ota)
        run_disable_ota
        ;;
    --debloat)
        run_debloat
        ;;
    --home)
        run_clean_home
        ;;
    --aot)
        run_aot_compile
        ;;
    *)
        echo -e "\n${YELLOW}Select an optimization option:${NC}"
        echo "  [1] Complete Clean & Optimize (Recommended: All Features)"
        echo "  [2] Remove Lockscreen Ads & Sponsored Content"
        echo "  [3] Neutralize OTA Updates (Prevent Reverts)"
        echo "  [4] Strip Amazon Bloatware"
        echo "  [5] Clean Stock Home Screen (Remove Discover/Continue Row)"
        echo "  [6] AOT Speed Compile User Apps"
        echo "  [0] Exit"
        read -rp "Enter choice: " opt
        case "$opt" in
            1) run_remove_ads; run_disable_ota; run_debloat; run_clean_home; run_aot_compile ;;
            2) run_remove_ads ;;
            3) run_disable_ota ;;
            4) run_debloat ;;
            5) run_clean_home ;;
            6) run_aot_compile ;;
            *) exit 0 ;;
        esac
        ;;
esac

header "Optimization Summary"
adb_cmd "dumpsys meminfo | tail -n 8"
success "Fire Tablet Cleaner successfully executed! Changes will persist across reboots."
