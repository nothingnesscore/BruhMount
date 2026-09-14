ui_print " "
ui_print "======================================="
ui_print "               BruhMount               "
ui_print "  NoMount VFS + Built-in SUSFS Metamodule   "
ui_print "======================================="
ui_print " "

ui_print "- Device Architecture: $ARCH"

# Check root implementation
if [ "$KSU" = "true" ]; then
  ROOT_IMP=ksu
  ui_print "- Root implementation: KernelSU"
elif [ "$APATCH" = "true" ]; then
  ROOT_IMP=ap
  ui_print "- Root implementation: APatch"
else
  abort "! Unsupported root env"
fi

if [ ! -f "$MODPATH/bin/nm-$ARCH" ]; then
  abort "! Unsupported architecture: $ARCH"
fi
mv "$MODPATH/bin/nm-$ARCH" "$MODPATH/bin/nm"
set_perm "$MODPATH/bin/nm" 0 0 0755

mkdir -p "/data/adb/$ROOT_IMP/bin"
if ln -sf "/data/adb/modules/bruhmount/bin/nm" "/data/adb/$ROOT_IMP/bin/nm" 2>/dev/null || \
   ln -sf "$MODPATH/bin/nm" "/data/adb/$ROOT_IMP/bin/nm" 2>/dev/null; then
    ui_print "- Symlink 'nm' created."
else
    ui_print "! Failed to create 'nm' symlink, skipping.."
fi

USE_KSUD=false

mkdir -p "$MODPATH/lkm"
if [ -f "$MODPATH/bin/lkmloader-$ARCH" ]; then
  mv "$MODPATH/bin/lkmloader-$ARCH" "$MODPATH/lkm/lkmloader"
  set_perm "$MODPATH/lkm/lkmloader" 0 0 0755
elif [ -f "$MODPATH/bin/ko-loader-$ARCH" ]; then
  mv "$MODPATH/bin/ko-loader-$ARCH" "$MODPATH/lkm/lkmloader"
  set_perm "$MODPATH/lkm/lkmloader" 0 0 0755
fi

if [ -f "$MODPATH/bin/ksu_susfs-$ARCH" ]; then
  mv "$MODPATH/bin/ksu_susfs-$ARCH" "$MODPATH/bin/ksu_susfs"
  set_perm "$MODPATH/bin/ksu_susfs" 0 0 0755
  ln -sf "/data/adb/modules/bruhmount/bin/ksu_susfs" "/data/adb/$ROOT_IMP/bin/ksu_susfs" 2>/dev/null || \
  ln -sf "$MODPATH/bin/ksu_susfs" "/data/adb/$ROOT_IMP/bin/ksu_susfs" 2>/dev/null || true
  ui_print "- Built-in SUSFS CLI tool provisioned."
fi

rm -rf "$MODPATH"/bin/nm-* "$MODPATH"/bin/lkmloader-* "$MODPATH"/bin/ko-loader-* "$MODPATH"/bin/ksu_susfs-*

load_ko() {
  local ko_path="$1"
  local output
  local ret

  if [ "$USE_KSUD" = true ] && [ "$MODULE_WAS_BUSY" = false ]; then
    if ksud insmod "$ko_path" >/dev/null 2>&1 && "$MODPATH/bin/nm" version >/dev/null 2>&1; then 
      return 0
    fi
    ui_print "  [!] ksud insmod failed; falling back to lkmloader."
    rmmod nomount 2>/dev/null
    USE_KSUD=false
  fi

  if [ -f "$MODPATH/lkm/lkmloader" ]; then
    output=$("$MODPATH/lkm/lkmloader" "$ko_path" 2>&1)
    ret=$?

    if [ $ret -eq 0 ] && "$MODPATH/bin/nm" version >/dev/null 2>&1; then
      return 0
    fi

    if [ "$MODULE_WAS_BUSY" = true ] && echo "$output" | grep -iq "File exists"; then
      ui_print "  [~] lkmloader verified compatibility (Dry-run pass)."
      return 0
    fi

    ui_print "  [!] lkmloader output: $output"
  fi

  return 1
}

OLD_MODPATH="/data/adb/modules/bruhmount"
if [ ! -d "$OLD_MODPATH" ] && [ -d "/data/adb/modules/nomount" ]; then
  OLD_MODPATH="/data/adb/modules/nomount"
fi

KVER=$(uname -r | cut -d'.' -f1,2)
AKVER=$(uname -r | grep -oE 'android[0-9]+')

if [ -n "$AKVER" ]; then
  ui_print "- Detected Kernel: $KVER ($AKVER branch)"
else
  ui_print "- Detected Kernel: $KVER (Custom/Unknown branch)"
fi

NOMOUNT_LOADED=false
OLD_LKM_UNLOADED=false
RESTORED_OLD_KO=false
IS_BUILTIN=false
MODULE_WAS_BUSY=false

ui_print "- Checking Kernel support via Internal API..."
if "$MODPATH/bin/nm" version > /dev/null 2>&1 || "$OLD_MODPATH/bin/nm" version > /dev/null 2>&1; then
  if grep -q '^nomount ' /proc/modules; then
    ui_print "  [*] Active LKM detected during update."
    ui_print "  [*] Clearing active rules to flush VFS references..."
    "$MODPATH/bin/nm" clear all >/dev/null 2>&1 || "$OLD_MODPATH/bin/nm" clear all >/dev/null 2>&1
    sleep 1
    ui_print "  [*] Attempting safe unload of the old driver..."
    rmmod_output=$(rmmod nomount 2>&1)
    if [ $? -eq 0 ]; then
      ui_print "  [+] Old driver unloaded successfully."
      OLD_LKM_UNLOADED=true
    else
      ui_print "  [!] rmmod failed: $rmmod_output"
      ui_print "  [!] Old driver is busy. Using 'File exists' as compatibility dry-run."
      MODULE_WAS_BUSY=true
    fi
  else
    IS_BUILTIN=true
  fi
fi

if [ "$IS_BUILTIN" = true ]; then
  ui_print "  [OK] NoMount Internal API detected (Built-in)."
  NOMOUNT_LOADED=true
  rm -rf "$MODPATH/lkm"
else
  if [ "$MODULE_WAS_BUSY" = false ]; then
    ui_print "  [*] Built-in support not found. Attempting LKM injection..."
  fi

  if command -v ksud >/dev/null 2>&1 && ksud -h 2>&1 | grep -qE '(^|[[:space:]])insmod([[:space:]]|$)'; then
    USE_KSUD=true
    ui_print "- KernelSU ksud insmod detected; lkmloader will remain as fallback."
  fi

  EXACT_MATCH="$MODPATH/lkm/nomount-${AKVER}-${KVER}.ko"
  if [ -n "$AKVER" ] && [ -f "$EXACT_MATCH" ]; then
    ui_print "  [*] Trying exact match: ${EXACT_MATCH##*/}"
    if load_ko "$EXACT_MATCH"; then
      mv "$EXACT_MATCH" "$MODPATH/lkm/nomount.ko"
      NOMOUNT_LOADED=true
      if [ "$MODULE_WAS_BUSY" = true ]; then
        ui_print "  [+] Update staged. It will fully apply on next reboot."
      fi
    else
      rmmod nomount 2>/dev/null
    fi
  fi

  if [ "$NOMOUNT_LOADED" = false ]; then
    for mod in "$MODPATH"/lkm/nomount*-${KVER}.ko; do
      if [ ! -f "$mod" ] || [ "$mod" = "$EXACT_MATCH" ]; then continue; fi
      ui_print "  [*] Trying fallback: ${mod##*/}"
      if load_ko "$mod"; then
        mv "$mod" "$MODPATH/lkm/nomount.ko"
        NOMOUNT_LOADED=true
        if [ "$MODULE_WAS_BUSY" = true ]; then
          ui_print "  [+] Fallback update staged. It will fully apply on next reboot."
        fi
        break
      else
        rmmod nomount 2>/dev/null
      fi
    done
  fi

  if [ "$NOMOUNT_LOADED" = false ] && [ -f "$OLD_MODPATH/lkm/nomount.ko" ]; then
    ui_print "  [!] New modules failed. Restoring previous working LKM..."
    mkdir -p "$MODPATH/lkm"
    cp "$OLD_MODPATH/lkm/nomount.ko" "$MODPATH/lkm/nomount.ko"
    cp "$OLD_MODPATH/bin/nm" "$MODPATH/bin/nm" && set_perm "$MODPATH/bin/nm" 0 0 0755
    if load_ko "$MODPATH/lkm/nomount.ko"; then
      NOMOUNT_LOADED=true
      RESTORED_OLD_KO=true
    else
      rmmod nomount 2>/dev/null
    fi
  fi

  rm -f "$MODPATH"/lkm/nomount-*.ko
fi

if [ "$NOMOUNT_LOADED" = true ]; then
  if [ "$USE_KSUD" = true ] || [ "$IS_BUILTIN" = true ]; then
    rm -f "$MODPATH/lkm/lkmloader" || true
  fi
  ui_print "  [OK] System is ready for injection."
  if [ "$OLD_LKM_UNLOADED" = true ] || [ "$RESTORED_OLD_KO" = true ]; then
    if [ -f "$MODPATH/metamount.sh" ]; then
      ui_print "  [*] Executing metamount.sh to refresh bindings..."
      sh "$MODPATH/metamount.sh"
    fi
  fi
else
  ui_print " "
  ui_print "***************************************************"
  ui_print "* [!] WARNING: KERNEL DRIVER NOT DETECTED         *"
  ui_print "***************************************************"
  ui_print "* NoMount Internal API missing/unresponsive and   *"
  ui_print "* no compatible loadable kernel module was found. *"
  ui_print "*                                                 *"
  ui_print "* This module will NOT FUNCTION until you flash   *"
  ui_print "* a Kernel compiled with CONFIG_NOMOUNT=y         *"
  ui_print "***************************************************"
  ui_print " "
  abort "! Kernel module not detected"
fi

NOMOUNT_DATA="/data/adb/nomount"
mkdir -p "$NOMOUNT_DATA"
rm -f "$NOMOUNT_DATA/.booting"

ui_print "- Installation complete."
