#!/system/bin/sh

export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:$PATH:/system/bin:/system/xbin"

MODDIR=${0%/*}
NM_BIN="$MODDIR/bin/nm"
NOMOUNT_DATA="/data/adb/nomount"
EXCLUSION_JSON="$NOMOUNT_DATA/.exclusion_list.json"
LOG_FILE="$NOMOUNT_DATA/nomount.log"

# 1. Apply UID Exclusion List to kernel NoMount VFS
if [ -x "$NM_BIN" ] && [ -f "$EXCLUSION_JSON" ]; then
    uids=$(grep -o '"uid":"[0-9]*"' "$EXCLUSION_JSON" 2>/dev/null | cut -d'"' -f4)
    if [ -n "$uids" ]; then
        set -f
        "$NM_BIN" uid add $uids >/dev/null 2>&1
    fi
fi

# 2. Boot Completion Safety Watchdog
# Ensures boot semaphores are never left orphaned if boot-completed.sh is delayed or blocked
(
    waited=0
    boot_done="0"
    while [ "$waited" -lt 120 ]; do
        boot_done="$(getprop sys.boot_completed 2>/dev/null)"
        if [ "$boot_done" = "1" ]; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    # Only clear boot semaphores if system actually finished booting
    if [ "$boot_done" = "1" ] && [ -f "$NOMOUNT_DATA/.booting" ]; then
        rm -f "$NOMOUNT_DATA/.booting" "$NOMOUNT_DATA/.boot_count" "$NOMOUNT_DATA/.last_module"
        ts="$(date '+%Y-%m-%d %H:%M:%S')"
        echo "[$ts] [WATCHDOG] Boot completion confirmed via sys.boot_completed (uptime: ${waited}s). Semaphores cleaned." >> "$LOG_FILE"
    elif [ "$boot_done" != "1" ]; then
        ts="$(date '+%Y-%m-%d %H:%M:%S')"
        echo "[$ts] [WATCHDOG] Warning: sys.boot_completed did not signal within ${waited}s." >> "$LOG_FILE"
    fi
) &

exit 0

