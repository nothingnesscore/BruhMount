#!/system/bin/sh

export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:$PATH:/system/bin:/system/xbin"

MODDIR=${0%/*}
NOMOUNT_DATA="/data/adb/nomount"
LOG_FILE="$NOMOUNT_DATA/nomount.log"
BOOT_SEMAPHORE="$NOMOUNT_DATA/.booting"
BOOT_COUNT_FILE="$NOMOUNT_DATA/.boot_count"
LAST_MOD_FILE="$NOMOUNT_DATA/.last_module"
PROP_FILE="$MODDIR/module.prop"
[ -f "$PROP_FILE" ] || PROP_FILE="/data/adb/modules/bruhmount/module.prop"
[ -f "$PROP_FILE" ] || PROP_FILE="/data/adb/modules/nomount/module.prop"
BASE_DESC="Unified NoMount VFS Metamodule with Built-in SUSFS Automation. Zero mount table footprint."

# 1. Clean up boot safety semaphores
rm -f "$BOOT_SEMAPHORE" "$BOOT_COUNT_FILE" "$LAST_MOD_FILE"

# 2. Clean up any leftover '..5.u.S' SUSFS redirection remnants
for s_dir in /sdcard /sdcard/Android/data /sdcard/Android/media /data/media/0 /data/media/0/Android/data /data/media/0/Android/media; do
    [ -e "$s_dir/..5.u.S" ] && rm -rf "$s_dir/..5.u.S" 2>/dev/null
done

# 3. Late-stage SUSFS Commitments (Lock in kstat inode spoofing & library map cloaking)
SUSFS_BIN="$MODDIR/bin/ksu_susfs"
SUSFS_CONF="$NOMOUNT_DATA/susfs_config.json"
get_s_conf() {
    local key="$1"; local def="$2"
    if [ -f "$SUSFS_CONF" ]; then
        local v; v=$(grep -o "\"$key\":[[:space:]]*[a-zA-Z0-9_]*" "$SUSFS_CONF" 2>/dev/null | cut -d: -f2 | tr -d ' "')
        [ -n "$v" ] && echo "$v" && return
    fi
    echo "$def"
}

if [ -x "$SUSFS_BIN" ]; then
    s_ver="$("$SUSFS_BIN" show version 2>/dev/null || echo "")"
    if [ -n "$s_ver" ] && ! echo "$s_ver" | grep -qE "NOT_SUPPORTED|error"; then
        # Late commit kstat spoofing post-boot
        if [ "$(get_s_conf "susfs_kstat_spoof" "true")" = "true" ]; then
            for kp in /system/etc/hosts /system/bin/su /system/xbin/su /system/bin/daemonsu /sbin/su /vendor/bin/su /system/bin/magisk /system/framework/services.jar /system/framework/framework.jar /system/build.prop /vendor/build.prop; do
                [ -e "$kp" ] && "$SUSFS_BIN" update_sus_kstat "$kp" >/dev/null 2>&1
            done
        fi

        # Late cloaking of any module shared libraries
        if [ "$(get_s_conf "susfs_map_hide" "true")" = "true" ]; then
            find -L /data/adb/modules -type f -name "*.so" 2>/dev/null | while read -r lib; do
                "$SUSFS_BIN" add_sus_map "$lib" >/dev/null 2>&1
            done
        fi
    fi
fi

# 4. Notify KernelSU that modules are mounted and ready
if command -v ksud >/dev/null 2>&1; then
    ksud kernel notify-module-mounted >/dev/null 2>&1
fi

ts="$(date '+%Y-%m-%d %H:%M:%S')"
echo "[$ts] [OK] System boot completed safely. Boot counter and semaphores cleared." >> "$LOG_FILE"

# 5. Restore clean description ONLY if no quarantine warning or safe mode is active
if [ -f "$PROP_FILE" ] && [ ! -f "$MODDIR/disable" ] && [ ! -f "$NOMOUNT_DATA/safemode" ]; then
    if ! grep -q "⚠️ RECOVERY:" "$PROP_FILE" 2>/dev/null; then
        sed -i "s|^description=.*|description=${BASE_DESC}|" "$PROP_FILE" 2>/dev/null
    fi
fi

exit 0

