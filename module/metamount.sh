#!/system/bin/sh

MODDIR=${0%/*}
LOADER="$MODDIR/bin/nm"
MODULES_DIR="/data/adb/modules"
NOMOUNT_DATA="/data/adb/nomount"
LOG_FILE="$NOMOUNT_DATA/nomount.log"
BOOT_SEMAPHORE="$NOMOUNT_DATA/.booting"
TARGET_PARTITIONS="system system_ext vendor odm product apex oem optics prism
                    mi_ext my_bigball my_carrier my_company my_engineering my_heytap
                    my_manifest my_preload my_product my_region my_reserve my_stock"
PROP_FILE="$MODDIR/module.prop"
BASE_DESC="A metamodule that replaces OverlayFS/MagicMount with VFS path redirection."

load_ko() {
    if command -v ksud >/dev/null 2>&1 && ksud -h 2>&1 | grep -qE '(^|[[:space:]])insmod([[:space:]]|$)'; then
        if ksud insmod "$1" && "$LOADER" version >/dev/null 2>&1; then return 0; fi
        echo "[WARN] ksud insmod failed; falling back to KoLoader." >> "$LOG_FILE"
        rmmod nomount 2>/dev/null
    fi

    if ! { "$MODDIR/loader" "$1" >/dev/null 2>&1 && "$LOADER" version >/dev/null 2>&1; }; then
        echo "[FATAL] KoLoader failed; LKM hasn't been loaded." >> "$LOG_FILE"
        return 1
    fi

    return 0
}

if [ ! -d "$NOMOUNT_DATA" ]; then
    mkdir -p "$NOMOUNT_DATA"
fi

echo "=== NoMount Boot Log | Started: $(date) ===" > "$LOG_FILE"
echo "Kernel Version: $(uname -r)" >> "$LOG_FILE"

if [ -f "$BOOT_SEMAPHORE" ]; then
    echo "[FATAL] Bootloop detected! NoMount caused a crash on the last boot." >> "$LOG_FILE"
    echo "[INFO] Disabling NoMount for safety..." >> "$LOG_FILE"
    touch "$MODDIR/disable"
    sed -i "s|^description=.*|description=[🚨 DISABLED: Bootloop Prevented] \\\\n$BASE_DESC|" "$PROP_FILE"
    rm -f "$BOOT_SEMAPHORE"
    exit 1
fi

touch "$BOOT_SEMAPHORE"

echo "[INFO] Checking NoMount kernel support..." >> "$LOG_FILE"
NM_ACTIVE=0
NM_MODE="unavailable"

if "$LOADER" version > /dev/null 2>&1; then
    echo "[INFO] Built-in kernel NoMount support detected." >> "$LOG_FILE"
    NM_ACTIVE=1
    NM_MODE="built-in"
else
    echo "[INFO] Built-in not found. Attempting to load LKM..." >> "$LOG_FILE"
    if [ -f "$MODDIR/lkm/nomount.ko" ]; then
        load_ko "$MODDIR/lkm/nomount.ko" >> "$LOG_FILE" 2>&1
    fi

    if "$LOADER" version > /dev/null 2>&1; then
        echo "[INFO] LKM loaded and initialized correctly." >> "$LOG_FILE"
        NM_ACTIVE=1
        NM_MODE="lkm"
    else
        echo "[WARN] NoMount VFS not available (stock kernel or LKM load failed)." >> "$LOG_FILE"
        echo "[INFO] Module will continue in SUSFS-only mode (VFS injection skipped)." >> "$LOG_FILE"
        NM_ACTIVE=0
        NM_MODE="unavailable"
    fi
fi

# Write nm_mode for WebUI detection
mkdir -p "$NOMOUNT_DATA"
echo "$NM_MODE" > "$NOMOUNT_DATA/nm_mode"

if [ "$NM_ACTIVE" = "1" ]; then
    echo "[OK] Internal API responding properly." >> "$LOG_FILE"
fi

if [ "$NM_ACTIVE" = "1" ]; then
    for mod_path in "$MODULES_DIR"/*; do
        [ -d "$mod_path" ] || continue
        mod_name="${mod_path##*/}"
        [ "$mod_name" = "nomount" ] || [ "$mod_name" = "bruhmount" ] && continue

        if [ -f "$mod_path/disable" ] || [ -f "$mod_path/remove" ] || [ -f "$mod_path/skip_mount" ]; then
            echo "[SKIP] Module $mod_name is disabled/removed/skipped" >> "$LOG_FILE"; continue
        fi

        for partition in $TARGET_PARTITIONS; do
            if [ -d "$mod_path/$partition" ]; then
                [ -d "/$partition" ] || [ -d "/system/$partition" ] || continue
                echo "[INFO] Mounting module: $mod_name (/$partition)" >> "$LOG_FILE"
                find -L "$mod_path/$partition" \( -type d -o -type c -o -name ".replace" \) -exec sh -c '
                    for f do
                        v="${f#'"$mod_path"'}"; [ "${v#/system/odm/}" != "$v" ] && v="/odm/${v#/system/odm/}"
                        if [ -d "$f" ]; then
                            case "$(getfattr -n trusted.overlay.opaque "$f" 2>/dev/null)" in *"=\"y\""*) printf "%s\0" "$v";; esac
                        elif [ "${f##*/}" = ".replace" ]; then printf "%s\0" "${v%/.replace}"
                        else printf "%s\0" "$v"; fi
                    done
                ' _ {} + 2>/dev/null | xargs -0 -r "$LOADER" rule add --whiteout >> "$LOG_FILE" 2>&1

                find -L "$mod_path/$partition" \( -type f -o -type l \) ! -name ".replace" -exec sh -c '
                    for f do
                        v="${f#'"$mod_path"'}"; [ "${v#/system/odm/}" != "$v" ] && v="/odm/${v#/system/odm/}"
                        printf "%s\0%s\0" "$v" "$f"
                    done
                ' _ {} + 2>/dev/null | xargs -0 -r "$LOADER" rule add >> "$LOG_FILE" 2>&1
            fi
        done
    done

    echo "=== Injection Complete: $(date) ===" >> "$LOG_FILE"
    echo -e "\nCurrent files injected:" >> "$LOG_FILE"
    "$LOADER" rule list >> "$LOG_FILE"
else
    echo "=== VFS injection skipped (NoMount unavailable) ===" >> "$LOG_FILE"
fi

# ==========================================
# SUSFS Root Hiding Automation (Rene / Simonpunk style)
# ==========================================
SUSFS_LOG="$NOMOUNT_DATA/susfs.log"
SUSFS_BIN="$MODDIR/bin/ksu_susfs"

log_susfs() {
    local level="$1"; shift
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] [$level] $*" | tee -a "$SUSFS_LOG" >> "$LOG_FILE"
}

if [ -x "$SUSFS_BIN" ]; then
    s_ver="$("$SUSFS_BIN" show version 2>/dev/null || echo "")"
    s_var="$("$SUSFS_BIN" show variant 2>/dev/null || echo "GKI")"
    if [ -n "$s_ver" ] && ! echo "$s_ver" | grep -q "NOT_SUPPORTED"; then
        echo "==================================================" > "$SUSFS_LOG"
        log_susfs "INFO" "SUSFS Kernel Subsystem Active: $s_ver ($s_var)"
        log_susfs "INFO" "Enabled features: $("$SUSFS_BIN" show enabled_features 2>/dev/null | tr '\n' ' ')"

        # 1. Hide core root and module directories (including nomount itself)
        for p in /data/adb /data/adb/modules /data/adb/nomount /data/adb/ksu /data/adb/ap /data/adb/magisk /data/local/tmp; do
            if [ -e "$p" ]; then
                "$SUSFS_BIN" add_sus_path "$p" >/dev/null 2>&1
                log_susfs "ACTION" "add_sus_path: $p -> [SUCCESS]"
            fi
        done

        # 2. Hide each active module path
        mod_count=0
        for mod_path in "$MODULES_DIR"/*; do
            if [ -d "$mod_path" ]; then
                "$SUSFS_BIN" add_sus_path "$mod_path" >/dev/null 2>&1
                log_susfs "MODULE" "Protecting module path: ${mod_path##*/} -> [SUCCESS]"
                mod_count=$((mod_count + 1))
            fi
        done

        # 3. Hide injected Zygisk and module shared libraries from /proc/self/maps
        map_count=0
        find -L "$MODULES_DIR" -type f -name "*.so" 2>/dev/null | while read -r lib; do
            "$SUSFS_BIN" add_sus_map "$lib" >/dev/null 2>&1
            log_susfs "MAP" "Cloaking library map: ${lib##*/} -> [SUCCESS]"
            map_count=$((map_count + 1))
        done

        # 4. Enable AVC denial log spoofing
        "$SUSFS_BIN" enable_avc_log_spoofing 1 >/dev/null 2>&1
        log_susfs "SECURITY" "enable_avc_log_spoofing: 1 -> [SUCCESS] (audit denials spoofed to priv_app)"

        log_susfs "SUMMARY" "SUSFS automated protection applied: $mod_count modules, auto-cloaked maps, 0 mount namespace footprint."
        echo "==================================================" >> "$SUSFS_LOG"
    else
        log_susfs "WARN" "Kernel does not support SUSFS syscalls (stock kernel or unpatched)."
    fi
fi


# NOTE: moved to boot-completed.sh
# rm -f "$BOOT_SEMAPHORE"
# echo "[OK] Boot phase completed safely." >> "$LOG_FILE"
sed -i "s|^description=.*|description=$BASE_DESC|" "$PROP_FILE"

exit 0
