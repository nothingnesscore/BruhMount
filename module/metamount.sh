#!/system/bin/sh

export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:$PATH:/system/bin:/system/xbin"

MODDIR=${0%/*}
LOADER="$MODDIR/bin/nm"
MODULES_DIR="/data/adb/modules"
NOMOUNT_DATA="/data/adb/nomount"
LOG_FILE="$NOMOUNT_DATA/nomount.log"
SUSFS_LOG="$NOMOUNT_DATA/susfs.log"
RESCUE_LOG="$NOMOUNT_DATA/recovery.log"
BOOT_SEMAPHORE="$NOMOUNT_DATA/.booting"
BOOT_COUNT_FILE="$NOMOUNT_DATA/.boot_count"
LAST_MOD_FILE="$NOMOUNT_DATA/.last_module"
SAFE_MODE_FILE="$NOMOUNT_DATA/safemode"
SUSFS_CONF="$NOMOUNT_DATA/susfs_config.json"
PROP_FILE="$MODDIR/module.prop"
BASE_DESC="Unified NoMount VFS Metamodule with Built-in SUSFS Automation. Zero mount table footprint."

TARGET_PARTITIONS="system system_ext vendor odm product apex oem optics prism
                    mi_ext my_bigball my_carrier my_company my_engineering my_heytap
                    my_manifest my_preload my_product my_region my_reserve my_stock"

# Ensure runtime data directory exists
mkdir -p "$NOMOUNT_DATA"

# Logging helper
log_msg() {
    local level="$1"; shift
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] [$level] $*" >> "$LOG_FILE"
}

# ==============================================================================
# 1. EMERGENCY RECOVERY & SAFE MODE ENGINE (Bootloop / Hardware Key / Semaphore)
# ==============================================================================

# Check for manual safe mode flags or global root manager safe mode
if [ -f "$MODDIR/disable" ] || [ -f "/data/adb/modules/bruhmount/disable" ] || [ -f "/data/adb/modules/nomount/disable" ] || \
   [ -f "$SAFE_MODE_FILE" ] || [ -f "/cache/.bruhmount_safemode" ] || [ -f "$NOMOUNT_DATA/disable" ] || \
   [ -f "/data/adb/ksu/.safemode" ] || [ -f "/data/adb/ksu/safemode" ] || [ -f "/data/adb/ap/safemode" ] || \
   [ -f "/data/adb/magisk/safemode" ] || [ -f "/metadata/safemode" ] || [ "$(getprop ro.sys.safemode 2>/dev/null)" = "1" ]; then
    echo "=== BruhMount Safe Mode Active: $(date) ===" >> "$LOG_FILE"
    log_msg "SAFE-MODE" "Safe mode flag or manager safe-mode detected. Bypassing all VFS injection."
    sed -i "s|^description=.*|description=[🚨 SAFE MODE ACTIVE] $BASE_DESC|" "$PROP_FILE" 2>/dev/null
    exit 0
fi

# Hardware Volume-Down Key Safe Mode Check (Emergency manual override during early boot)
check_hw_recovery() {
    if command -v getevent >/dev/null 2>&1; then
        local pressed=""
        if command -v timeout >/dev/null 2>&1; then
            pressed=$(timeout 2 getevent -l 2>/dev/null | grep -m1 -iE 'KEY_VOLUMEDOWN|0072')
        else
            local tmp_ev="$NOMOUNT_DATA/.events.tmp"
            getevent -l > "$tmp_ev" 2>/dev/null &
            local ev_pid=$!
            sleep 2
            kill -9 "$ev_pid" 2>/dev/null
            if [ -f "$tmp_ev" ]; then
                pressed=$(grep -m1 -iE 'KEY_VOLUMEDOWN|0072' "$tmp_ev" 2>/dev/null)
                rm -f "$tmp_ev"
            fi
        fi
        if [ -n "$pressed" ]; then
            return 0
        fi
    fi
    return 1
}

if check_hw_recovery; then
    echo "=== BruhMount Hardware Recovery Triggered: $(date) ===" > "$RESCUE_LOG"
    log_msg "RECOVERY" "Volume-Down key pressed during boot! Entering Emergency Safe Mode."
    echo "[$(date)] Hardware Volume-Down triggered emergency safe mode" >> "$RESCUE_LOG"
    touch "$SAFE_MODE_FILE"
    touch "$MODDIR/disable"
    touch "/data/adb/modules/bruhmount/disable" 2>/dev/null
    touch "/data/adb/modules/nomount/disable" 2>/dev/null
    sed -i "s|^description=.*|description=[🚨 EMERGENCY RECOVERY: Volume-Down Triggered] $BASE_DESC|" "$PROP_FILE" 2>/dev/null
    rm -f "$BOOT_SEMAPHORE" "$BOOT_COUNT_FILE" "$LAST_MOD_FILE"
    exit 0
fi

# Multi-stage Bootloop Detection Counter
boot_count=0
if [ -f "$BOOT_COUNT_FILE" ]; then
    boot_count=$(cat "$BOOT_COUNT_FILE" 2>/dev/null || echo 0)
    case "$boot_count" in ''|*[!0-9]*) boot_count=0 ;; esac
fi

culprit=""
if [ -f "$BOOT_SEMAPHORE" ]; then
    boot_count=$((boot_count + 1))
    echo "$boot_count" > "$BOOT_COUNT_FILE"
    log_msg "WARN" "Incomplete boot detected (attempt $boot_count without boot_completed)."

    # Level 1 Recovery (Attempt == 2): Bad Module Quarantine
    # Identify culprit via LAST_MOD_FILE or most recently modified module in /data/adb/modules/
    if [ "$boot_count" -eq 2 ]; then
        if [ -f "$LAST_MOD_FILE" ]; then
            culprit=$(cat "$LAST_MOD_FILE" 2>/dev/null | tr -d ' \n\r')
        fi
        if [ -z "$culprit" ] || [ ! -d "$MODULES_DIR/$culprit" ]; then
            for m in $(ls -td "$MODULES_DIR"/* 2>/dev/null); do
                [ -d "$m" ] || continue
                mn="${m##*/}"
                case "$mn" in
                    nomount|bruhmount|lost+found) continue ;;
                    *)
                        if [ ! -f "$m/disable" ] && [ ! -f "$m/remove" ]; then
                            culprit="$mn"
                            break
                        fi
                        ;;
                esac
            done
        fi

        if [ -n "$culprit" ] && [ -d "$MODULES_DIR/$culprit" ]; then
            log_msg "RECOVERY" "Culprit module detected: '$culprit'. Disabling to restore system stability."
            touch "$MODULES_DIR/$culprit/disable"
            echo "$culprit" > "$NOMOUNT_DATA/.quarantined"
            echo "[$(date)] Auto-disabled crashing module '$culprit' on boot failure #$boot_count" >> "$RESCUE_LOG"
            sed -i "s|^description=.*|description=[⚠️ RECOVERY: Isolated faulty module '$culprit'] $BASE_DESC|" "$PROP_FILE" 2>/dev/null
            rm -f "$LAST_MOD_FILE"
        fi
    fi

    # Level 2 Recovery (Attempt >= 3): Full Safe Mode Disable of BruhMount
    if [ "$boot_count" -ge 3 ]; then
        log_msg "FATAL" "Bootloop threshold exceeded ($boot_count attempts). Engaging Full Safe Mode."
        echo "[$(date)] Bootloop threshold exceeded ($boot_count attempts). Full safe mode engaged." >> "$RESCUE_LOG"
        touch "$MODDIR/disable"
        touch "$SAFE_MODE_FILE"
        touch "/data/adb/modules/bruhmount/disable" 2>/dev/null
        touch "/data/adb/modules/nomount/disable" 2>/dev/null
        sed -i "s|^description=.*|description=[🚨 SAFE MODE: Bootloop Prevented ($boot_count attempts)] $BASE_DESC|" "$PROP_FILE" 2>/dev/null
        rm -f "$BOOT_SEMAPHORE" "$BOOT_COUNT_FILE" "$LAST_MOD_FILE"
        exit 1
    fi
else
    # Clean boot sequence initialization
    echo "1" > "$BOOT_COUNT_FILE"
fi

# Arm the boot semaphore for this boot cycle
touch "$BOOT_SEMAPHORE"

echo "=== NoMount Boot Log | Started: $(date) ===" > "$LOG_FILE"
echo "Kernel Version: $(uname -r)" >> "$LOG_FILE"


# ==============================================================================
# 2. NOMOUNT DRIVER INITIALIZATION
# ==============================================================================

load_ko() {
    if command -v ksud >/dev/null 2>&1 && ksud -h 2>&1 | grep -qE '(^|[[:space:]])insmod([[:space:]]|$)'; then
        if ksud insmod "$1" >> "$LOG_FILE" 2>&1 && "$LOADER" version >/dev/null 2>&1; then return 0; fi
        log_msg "WARN" "ksud insmod failed; falling back to lkmloader."
        rmmod nomount 2>/dev/null
    fi

    local loader_bin="$MODDIR/lkm/lkmloader"
    if [ ! -x "$loader_bin" ] && [ -x "$MODDIR/loader" ]; then
        loader_bin="$MODDIR/loader"
    fi

    if ! { "$loader_bin" "$1" >> "$LOG_FILE" 2>&1 && "$LOADER" version >/dev/null 2>&1; }; then
        log_msg "FATAL" "lkmloader failed; LKM hasn't been loaded."
        return 1
    fi

    return 0
}

log_msg "INFO" "Checking NoMount kernel support..."
NM_ACTIVE=0
NM_MODE="unavailable"

if "$LOADER" version > /dev/null 2>&1; then
    log_msg "INFO" "Built-in kernel NoMount support detected."
    NM_ACTIVE=1
    NM_MODE="built-in"
else
    log_msg "INFO" "Built-in not found. Attempting to load LKM..."
    if [ -f "$MODDIR/lkm/nomount.ko" ]; then
        load_ko "$MODDIR/lkm/nomount.ko" >> "$LOG_FILE" 2>&1
    fi

    if "$LOADER" version > /dev/null 2>&1; then
        log_msg "INFO" "LKM loaded and initialized correctly."
        NM_ACTIVE=1
        NM_MODE="lkm"
    else
        log_msg "WARN" "NoMount VFS not available (stock kernel or LKM load failed)."
        log_msg "INFO" "Module will continue in SUSFS-only mode (VFS injection skipped)."
        NM_ACTIVE=0
        NM_MODE="unavailable"
    fi
fi

# Write nm_mode for WebUI detection
echo "$NM_MODE" > "$NOMOUNT_DATA/nm_mode"

SUSFS_BIN="$MODDIR/bin/ksu_susfs"

# Helper to read toggle settings from config.json with fallback defaults
get_susfs_conf() {
    local key="$1"
    local default="$2"
    if [ -f "$SUSFS_CONF" ]; then
        local val
        val=$(grep -o "\"$key\":[[:space:]]*[a-zA-Z0-9_]*" "$SUSFS_CONF" 2>/dev/null | cut -d: -f2 | tr -d ' "')
        if [ -n "$val" ]; then
            echo "$val"
            return
        fi
    fi
    echo "$default"
}

# ==============================================================================
# 3. METAMODULE VFS INJECTION
# ==============================================================================

if [ "$NM_ACTIVE" = "1" ]; then
    log_msg "OK" "Internal NoMount API responding properly."

    # 1. Early UID exclusion application
    EXCLUSION_JSON="$NOMOUNT_DATA/.exclusion_list.json"
    if [ -f "$EXCLUSION_JSON" ]; then
        early_uids=$(grep -o '"uid":"[0-9]*"' "$EXCLUSION_JSON" 2>/dev/null | cut -d'"' -f4)
        if [ -n "$early_uids" ]; then
            set -f
            "$LOADER" uid add $early_uids >/dev/null 2>&1
            set +f
            log_msg "INFO" "Applied early UID exclusions to in-memory VFS."
        fi
    fi

    # 2. Early SUSFS Kstat Staging (Stage pristine stock stat BEFORE any injection)
    conf_kstat_spoof=$(get_susfs_conf "susfs_kstat_spoof" "true")
    KSTAT_PATHS="
        /system/etc/hosts
        /system/bin/su
        /system/xbin/su
        /system/bin/daemonsu
        /sbin/su
        /vendor/bin/su
        /system/bin/magisk
        /system/framework/services.jar
        /system/framework/framework.jar
        /system/build.prop
        /vendor/build.prop
    "
    if [ -x "$SUSFS_BIN" ] && [ "$conf_kstat_spoof" = "true" ]; then
        for kp in $KSTAT_PATHS; do
            if [ -e "$kp" ]; then
                "$SUSFS_BIN" add_sus_kstat "$kp" >/dev/null 2>&1
            fi
        done
        log_msg "SUSFS" "Pre-staged stock kstat attributes for sensitive files."
    fi

    for mod_path in "$MODULES_DIR"/*; do
        [ -d "$mod_path" ] || continue
        mod_name="${mod_path##*/}"
        [ "$mod_name" = "nomount" ] || [ "$mod_name" = "bruhmount" ] && continue

        if [ -f "$mod_path/disable" ] || [ -f "$mod_path/remove" ] || [ -f "$mod_path/skip_mount" ]; then
            log_msg "SKIP" "Module $mod_name is disabled/removed/skipped"
            continue
        fi

        for partition in $TARGET_PARTITIONS; do
            if [ -d "$mod_path/$partition" ]; then
                [ -d "/$partition" ] || [ -d "/system/$partition" ] || continue
                
                # Track current module to allow culprit quarantine if bootloop occurs
                echo "$mod_name" > "$LAST_MOD_FILE"
                log_msg "INFO" "Mounting module: $mod_name (/$partition)"

                # 1. Whiteouts and opaque directories
                find -L "$mod_path/$partition" \( -type d -o -type c -o -name ".replace" \) -exec sh -c '
                    for f do
                        v="${f#'"$mod_path"'}"; [ "${v#/system/odm/}" != "$v" ] && v="/odm/${v#/system/odm/}"
                        if [ -d "$f" ]; then
                            case "$(getfattr -n trusted.overlay.opaque "$f" 2>/dev/null)" in *"=\"y\""*) printf "%s\0" "$v";; esac
                        elif [ "${f##*/}" = ".replace" ]; then printf "%s\0" "${v%/.replace}"
                        else printf "%s\0" "$v"; fi
                    done
                ' _ {} + 2>/dev/null | xargs -0 -r "$LOADER" rule add --whiteout >> "$LOG_FILE" 2>&1

                # 2. Files and symlinks
                find -L "$mod_path/$partition" \( -type f -o -type l \) ! -name ".replace" -exec sh -c '
                    for f do
                        v="${f#'"$mod_path"'}"; [ "${v#/system/odm/}" != "$v" ] && v="/odm/${v#/system/odm/}"
                        printf "%s\0%s\0" "$v" "$f"
                    done
                ' _ {} + 2>/dev/null | xargs -0 -r "$LOADER" rule add >> "$LOG_FILE" 2>&1
            fi
        done
    done

    # 3. Post-injection Kstat Update (Binds newly overlaid inodes back to stock stats)
    if [ -x "$SUSFS_BIN" ] && [ "$conf_kstat_spoof" = "true" ]; then
        for kp in $KSTAT_PATHS; do
            if [ -e "$kp" ]; then
                "$SUSFS_BIN" update_sus_kstat "$kp" >/dev/null 2>&1
            fi
        done
    fi

    # Note: Keep LAST_MOD_FILE until boot-completed.sh confirms stable boot
    log_msg "INFO" "VFS Injection Complete: $(date)"
    echo -e "\nCurrent files injected:" >> "$LOG_FILE"
    "$LOADER" rule list >> "$LOG_FILE" 2>&1
else
    log_msg "INFO" "VFS injection skipped (NoMount driver unavailable)."
fi

# ==============================================================================
# 4. SUSFS KERNEL AUTOMATION & STEALTH ENGINE
# ==============================================================================

log_susfs() {
    local level="$1"; shift
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] [$level] $*" | tee -a "$SUSFS_LOG" >> "$LOG_FILE"
}

if [ -x "$SUSFS_BIN" ]; then
    s_ver="$("$SUSFS_BIN" show version 2>/dev/null || echo "")"
    s_var="$("$SUSFS_BIN" show variant 2>/dev/null || echo "GKI")"
    if [ -n "$s_ver" ] && ! echo "$s_ver" | grep -qE "NOT_SUPPORTED|error"; then
        echo "==================================================" > "$SUSFS_LOG"
        log_susfs "INFO" "SUSFS Kernel Subsystem Active: $s_ver ($s_var)"
        log_susfs "INFO" "Kernel Features: $("$SUSFS_BIN" show enabled_features 2>/dev/null | tr '\n' ' ')"

        # Read configured toggles
        conf_path_hide=$(get_susfs_conf "susfs_path_hide" "true")
        conf_map_hide=$(get_susfs_conf "susfs_map_hide" "true")
        conf_avc_spoof=$(get_susfs_conf "susfs_avc_spoof" "true")
        conf_hide_mounts=$(get_susfs_conf "susfs_hide_mounts" "true")
        conf_kernel_log=$(get_susfs_conf "susfs_kernel_log" "false")

        # 1. Path Hiding (Root, metamodule, modern detection triggers, and active modules)
        if [ "$conf_path_hide" = "true" ]; then
            path_count=0
            SUS_PATHS="
                /data/adb
                /data/adb/modules
                /data/adb/modules_update
                /data/adb/nomount
                /data/adb/ksu
                /data/adb/ksu/bin
                /data/adb/ap
                /data/adb/ap/bin
                /data/adb/magisk
                /data/adb/magisk.db
                /data/adb/magisk_simple
                /data/local/tmp
                /data/local/tmp/main.jar
                /data/adb/lspd
                /data/adb/tricky_store
                /data/adb/pif
                /data/adb/shamiko
                /data/adb/snickle
                /data/adb/rezygisk
                /data/adb/riru
                /data/adb/service.d
                /data/adb/post-fs-data.d
                /data/adb/boot-completed.d
                /data/adb/env
                /data/su
                /sbin/.magisk
                /system/addon.d
                /system/bin/install-recovery.sh
                /vendor/bin/install-recovery.sh
                /sys/block/loop0
                /cache/magisk.log
                /sdcard/TWRP
                /sdcard/Fox
                /sdcard/MT2
                /sdcard/APKTool
                /sdcard/Apktool_M
                /sdcard/TitaniumBackup
                /sdcard/SwiftBackup
                /sdcard/AppManager
                /sdcard/Android/data/io.github.muntashirakon.AppManager
                /sdcard/Android/media/io.github.muntashirakon.AppManager
                /sdcard/Android/data/bin.mt.plus
                /sdcard/Android/data/com.termux
                /data/media/0/TWRP
                /data/media/0/Fox
                /data/media/0/MT2
                /data/media/0/APKTool
                /data/media/0/Apktool_M
                /data/media/0/TitaniumBackup
                /data/media/0/SwiftBackup
                /data/media/0/AppManager
                /data/media/0/Android/data/io.github.muntashirakon.AppManager
                /data/media/0/Android/media/io.github.muntashirakon.AppManager
                /data/media/0/Android/data/bin.mt.plus
                /data/media/0/Android/data/com.termux
            "
            for p in $SUS_PATHS; do
                if [ -e "$p" ]; then
                    case "$p" in
                        /sdcard/*|/data/media/*)
                            "$SUSFS_BIN" add_sus_path_loop "$p" >/dev/null 2>&1 || "$SUSFS_BIN" add_sus_path "$p" >/dev/null 2>&1
                            ;;
                        *)
                            "$SUSFS_BIN" add_sus_path "$p" >/dev/null 2>&1
                            ;;
                    esac
                    log_susfs "ACTION" "add_sus_path: $p -> [SUCCESS]"
                    path_count=$((path_count + 1))
                fi
            done

            # Hide each active module path
            for mod_path in "$MODULES_DIR"/*; do
                if [ -d "$mod_path" ]; then
                    "$SUSFS_BIN" add_sus_path "$mod_path" >/dev/null 2>&1
                    log_susfs "MODULE" "Protecting module path: ${mod_path##*/} -> [SUCCESS]"
                    path_count=$((path_count + 1))
                fi
            done
            log_susfs "SUMMARY" "Path hiding applied to $path_count locations."
        else
            log_susfs "CONFIG" "Path hiding toggle is [DISABLED]."
        fi

        # 2. Module Maps Cloaking (Masks injected shared libraries from /proc/*/maps)
        if [ "$conf_map_hide" = "true" ]; then
            map_count=0
            find -L "$MODULES_DIR" -type f -name "*.so" 2>/dev/null | while read -r lib; do
                "$SUSFS_BIN" add_sus_map "$lib" >/dev/null 2>&1
                log_susfs "MAP" "Cloaking library map: ${lib##*/} -> [SUCCESS]"
                map_count=$((map_count + 1))
            done
            log_susfs "SUMMARY" "Maps cloaking processed."
        else
            log_susfs "CONFIG" "Maps cloaking toggle is [DISABLED]."
        fi

        # 3. Mount Hiding for Non-SU processes
        if [ "$conf_hide_mounts" = "true" ]; then
            "$SUSFS_BIN" hide_sus_mnts_for_non_su_procs 1 >/dev/null 2>&1
            log_susfs "MOUNT" "hide_sus_mnts_for_non_su_procs: 1 -> [SUCCESS] (Root mounts hidden from non-su)"
        else
            "$SUSFS_BIN" hide_sus_mnts_for_non_su_procs 0 >/dev/null 2>&1
            log_susfs "MOUNT" "hide_sus_mnts_for_non_su_procs: 0 -> [DISABLED]"
        fi

        # 4. SELinux AVC Denial Log Spoofing
        if [ "$conf_avc_spoof" = "true" ]; then
            "$SUSFS_BIN" enable_avc_log_spoofing 1 >/dev/null 2>&1
            log_susfs "SECURITY" "enable_avc_log_spoofing: 1 -> [SUCCESS] (audit denials spoofed to priv_app)"
        else
            "$SUSFS_BIN" enable_avc_log_spoofing 0 >/dev/null 2>&1
            log_susfs "SECURITY" "enable_avc_log_spoofing: 0 -> [DISABLED]"
        fi

        # 5. Kernel SUSFS Logging Control
        if [ "$conf_kernel_log" = "true" ]; then
            "$SUSFS_BIN" enable_log 1 >/dev/null 2>&1
            log_susfs "LOG" "enable_log: 1 -> [ENABLED]"
        else
            "$SUSFS_BIN" enable_log 0 >/dev/null 2>&1
            log_susfs "LOG" "enable_log: 0 -> [SILENCED for stealth anti-detection]"
        fi

        echo "==================================================" >> "$SUSFS_LOG"
    else
        log_susfs "WARN" "Kernel does not support SUSFS syscalls (stock kernel or unpatched)."
    fi
fi

# Reset description ONLY if no recovery quarantine occurred and not in safe mode
if [ -z "$culprit" ] && [ ! -f "$SAFE_MODE_FILE" ] && [ ! -f "$MODDIR/disable" ]; then
    sed -i "s|^description=.*|description=${BASE_DESC}|" "$PROP_FILE" 2>/dev/null
fi

exit 0
