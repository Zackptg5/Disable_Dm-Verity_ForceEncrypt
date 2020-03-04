###################
# Helper Functions
###################

toupper() {
  echo "$@" | tr '[:lower:]' '[:upper:]'
}

is_mounted() {
  grep -q " `readlink -f $1` " /proc/mounts 2>/dev/null
  return $?
}

#######################
# Installation Related
#######################

find_block() {
  for BLOCK in "$@"; do
    DEVICE=`find /dev/block -type l -iname $BLOCK | head -n 1` 2>/dev/null
    if [ ! -z $DEVICE ]; then
      readlink -f $DEVICE
      return 0
    fi
  done
  # Fallback by parsing sysfs uevents
  for uevent in /sys/dev/block/*/uevent; do
    local DEVNAME=`file_getprop $uevent DEVNAME`
    local PARTNAME=`file_getprop $uevent PARTNAME`
    for BLOCK in "$@"; do
      if [ "`toupper $BLOCK`" = "`toupper $PARTNAME`" ]; then
        echo /dev/block/$DEVNAME
        return 0
      fi
    done
  done
  return 1
}

mount_part() {
  local PART=$1
  local POINT=/${PART}
  [ -L $POINT ] && rm -f $POINT
  mkdir $POINT 2>/dev/null
  is_mounted $POINT && return
  ui_print "- Mounting $PART"
  mount -o rw $POINT 2>/dev/null
  if ! is_mounted $POINT; then
    local BLOCK=`find_block $PART$slot`
    mount -o rw $BLOCK $POINT
  fi
  is_mounted $POINT || abort "! Cannot mount $POINT"
}

check_data() {
  DATA=false
  DATA_DE=false
  if grep ' /data ' /proc/mounts | grep -vq 'tmpfs'; then
    # Test if data is writable
    touch /data/.rw && rm /data/.rw && DATA=true
    # Test if DE storage is writable
    $DATA && [ -d /data/adb ] && touch /data/adb/.rw && rm /data/adb/.rw && DATA_DE=true
  fi
  $DATA && NVBASE=/data || NVBASE=/cache/data_adb
  $DATA_DE && NVBASE=/data/adb
  MAGISKBIN=$NVBASE/magisk
}

get_flags() {
  # Get zipname variables
  OIFS=$IFS; IFS=\|;
  ZIPFILE="$(echo $(basename $ZIPFILE) | tr '[:upper:]' '[:lower:]')"
  while true; do
    case $ZIPFILE in
      "package.zip") get_key_opts; break;;
      *enfec*|*enforceencrypt*) KEEPFORCEENCRYPT=true; ZIPFILE=$(echo $ZIPFILE | sed -r "s/(enfec|enforceencrypt)//g");;
      *fec*|*forceencrypt*) KEEPFORCEENCRYPT=false; ZIPFILE=$(echo $ZIPFILE | sed -r "s/(fec|forceencrypt)//g");;
      *quota*) KEEPQUOTA=false; ZIPFILE=$(echo $ZIPFILE | sed "s/quota//g");;
      *) break;;
    esac
  done
  IFS=$OIFS
  # override variables
  grep ' / ' /proc/mounts | grep -qv 'rootfs' || grep -q ' /system_root ' /proc/mounts && SYSTEM_ROOT=true || SYSTEM_ROOT=false
  ! $SYSTEM_ROOT && [ -f /system_root/init.rc ] && SYSTEM_ROOT=true
  KEEPVERITY=false
  if [ -z $KEEPFORCEENCRYPT ]; then
    grep ' /data ' /proc/mounts | grep -q 'dm-' && FDE=true || FDE=false
    [ -d /data/unencrypted ] && FBE=true || FBE=false
    # No data access means unable to decrypt in recovery
    if $FDE || $FBE || ! $DATA; then
      KEEPFORCEENCRYPT=true
      ui_print "- Encrypted data, keep forceencrypt"
    else
      KEEPFORCEENCRYPT=false
    fi
  fi
  [ -z $KEEPQUOTA ] && KEEPQUOTA=true
  export KEEPVERITY
  export KEEPFORCEENCRYPT
  export KEEPQUOTA
}

patch_dtb_partitions() {
  local result=1
  for name in dtb dtbo; do
    local IMAGE=`find_block $name$slot`
    if [ ! -z $IMAGE ]; then
      ui_print "- $name image: $IMAGE"
      if $bin/magiskboot dtb $IMAGE patch dt.patched; then
        result=0
        ui_print "- Flashing patched $name"
        cat dt.patched /dev/zero > $IMAGE
        rm -f dt.patched
      fi
    fi
  done
  return $result
}

chooseport() {
  # Keycheck binary by someone755 @Github, idea for code below by Zappo @xda-developers
  # Calling it first time detects previous input. Calling it second time will do what we want
  while true; do
    $bin/keycheck
    $bin/keycheck
    local SEL=$?
    if [ "$1" == "UP" ]; then
      UP=$SEL
      break
    elif [ "$1" == "DOWN" ]; then
      DOWN=$SEL
      break
    elif [ $SEL -eq $UP ]; then
      return 0
    elif [ $SEL -eq $DOWN ]; then
      return 1
    fi
  done
}

get_key_opts() {
  ui_print "  Sideload detected! Zipname options can't be read"
  ui_print "  Using Vol Key selection method"
  ui_print " "
  ui_print "- Vol Key Programming -"
  ui_print "  Press Vol Up"
  chooseport "UP"
  ui_print "  Press Vol Down"
  chooseport "DOWN"
  ui_print " "
  ui_print "- Select Options -"
  ui_print "  Vol+ = yes, Vol- = no"
  ui_print " "
  sleep 1
  ui_print "  Disable Disc Quota? (Select 'no' if unsure)"
  chooseport && KEEPQUOTA=false
  ui_print "  Disable force encryption?"
  if chooseport; then
    KEEPFORCEENCRYPT=false
  else
    ui_print "  Keep encryption enabled if present or auto-detect?"
    ui_print "  Vol+ = keep encryption enabled, Vol- = auto-detect"
    chooseport && KEEPFORCEENCRYPT=true
  fi
}

########
# Flags
########

check_data
get_flags
[ -L /system/vendor ] && VEN=/vendor || VEN=/system/vendor
$bb mount -o rw,remount -t auto $(echo $VEN | cut -d '/' -f-2) 2>/dev/null

ui_print " "
ui_print "- Chosen/Default Arguments:"
ui_print "   Keep ForceEncrypt: $KEEPFORCEENCRYPT"
ui_print "   Keep Dm-Verity: $KEEPVERITY"
ui_print "   Keep Disc Quota: $KEEPQUOTA"
ui_print " "
