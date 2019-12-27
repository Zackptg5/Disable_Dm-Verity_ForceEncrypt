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
      *fec*|*forceencrypt*) KEEPFORCEENCRYPT=false; ZIPFILE=$(echo $ZIPFILE | sed -r "s/(fec|forceencrypt)//g");;
      *verity*) KEEPVERITY=false; ZIPFILE=$(echo $ZIPFILE | sed "s/verity//g");;
      *quota*) KEEPQUOTA=false; ZIPFILE=$(echo $ZIPFILE | sed "s/quota//g");;
      *) break;;
    esac
  done
  IFS=$OIFS
  # override variables
  grep ' / ' /proc/mounts | grep -qv 'rootfs' || grep -q ' /system_root ' /proc/mounts && SYSTEM_ROOT=true || SYSTEM_ROOT=false
  ! $SYSTEM_ROOT && [ -f /system_root/init.rc ] && SYSTEM_ROOT=true
  if [ -z $KEEPVERITY ]; then
    if $SYSTEM_ROOT; then
      KEEPVERITY=true
      ui_print "- System-as-root, keep dm/avb-verity"
    else
      KEEPVERITY=false
    fi
  fi
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

patch_dtbo_image() {
  local DTBOIMAGE=`find_block dtbo$slot`
  if [ ! -z $DTBOIMAGE ]; then
    ui_print "- DTBO image: $DTBOIMAGE"
    if $bin/magiskboot dtb $DTBOIMAGE patch dtbo; then
      ui_print "- Patching DTBO to remove avb-verity"
      cat dtbo /dev/zero > $DTBOIMAGE
      rm -f dtbo
      return 0
    fi
  fi
  return 1
}

mount_apex() {
  # Mount apex files so dynamic linked stuff works
  if [ -d /system/apex ]; then
    [ -L /apex ] && rm -f /apex
    # Apex files present - needs to extract and mount the payload imgs
    if [ -f "/system/apex/com.android.runtime.release.apex" ]; then
      local j=0
      [ -e /dev/block/loop1 ] && local minorx=$(ls -l /dev/block/loop1 | awk '{print $6}') || local minorx=1
      for i in /system/apex/*.apex; do
        local DEST="/apex/$(basename $i | sed 's/.apex$//')"
        [ "$DEST" == "/apex/com.android.runtime.release" ] && DEST="/apex/com.android.runtime"
        mkdir -p $DEST
        unzip -qo $i apex_payload.img -d /apex
        mv -f /apex/apex_payload.img $DEST.img
        while [ $j -lt 100 ]; do
          local loop=/dev/loop$j
          mknod $loop b 7 $((j * minorx))k 2>/dev/null
          losetup $loop $DEST.img 2>/dev/null
          j=$((j + 1))
          losetup $loop | grep -q $DEST.img && break
        done;
        uloop="$uloop $((j - 1))"
        mount -t ext4 -o loop,noatime,ro $loop $DEST || return 1
      done
    # Already extracted payload imgs present, just mount the folders
    elif [ -d "/system/apex/com.android.runtime.release" ]; then
      for i in /system/apex/*; do
        local DEST="/apex/$(basename $i)"
        [ "$DEST" == "/apex/com.android.runtime.release" ] && DEST="/apex/com.android.runtime"
        mkdir -p $DEST
        mount -o bind,ro $i $DEST
      done
    fi
  fi
}

umount_apex() {
  # Unmount apex
  if [ -d /system/apex ]; then
    for i in /apex/*; do
      umount -l $i 2>/dev/null
    done
    if [ -f "/system/apex/com.android.runtime.release.apex" ]; then
      for i in $uloop; do
        local loop=/dev/loop$i
        losetup -d $loop 2>/dev/null || break
      done
    fi
    rm -rf /apex
  fi
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
  ui_print "  Disable verity?"
  chooseport && KEEPVERITY=false
  ui_print "  Disable force encryption?"
  chooseport && KEEPFORCEENCRYPT=false
  ui_print "  Disable Disc Quota? (Select 'no' if unsure)"
  chooseport && KEEPQUOTA=false
}

########
# Flags
########

check_data
get_flags

ui_print " "
ui_print "- Chosen/Default Arguments:"
ui_print "   Keep ForceEncrypt: $KEEPFORCEENCRYPT"
ui_print "   Keep Dm-Verity: $KEEPVERITY"
ui_print "   Keep Disc Quota: $KEEPQUOTA"
ui_print " "
